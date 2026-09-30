import CoreLocation
import SwiftUI

// App-level background work: the Watch workout-control listeners, deferred
// boot, launch tasks, migrations and the chunked temp-asymmetry rescore.
// `EmuquApp.swift` holds the `App` conformance and its `body`, the declaration
// of the app rather than the work it kicks off at launch.

extension EmuquApp {

    /// App-level listeners for Watch workout-control notifications.
    /// Mirrors the `listenForWatch*Requests` methods on `FitnessTabView`
    /// but operates on `AppDependencies.current.app.recorderBox` so the gestures work even
    /// when the user has never tapped the Fitness tab in this session.
    @MainActor
    func runAppLevelWatchWorkoutListeners() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.appLevelWatchStartListener() }
            group.addTask { await self.appLevelWatchStopListener() }
            group.addTask { await self.appLevelWatchPauseListener() }
            group.addTask { await self.appLevelWatchResumeListener() }
            group.addTask { await self.appLevelWatchAcknowledgeListener() }
        }
    }

    func appLevelWatchStartListener() async {
        let stream = NotificationCenter.default.notifications(named: .watchRequestedWorkoutStart)
        for await note in stream {
            let sport = Sport(rawValue: (note.userInfo?["sport"] as? String) ?? "run") ?? .run
            startWorkoutFromWatch(sport: sport, targetZone: note.userInfo?["targetZone"] as? Int)
        }
    }

    /// Bind the recorder lazily — the Watch can ask before the phone UI has
    /// ever shown the Record tab. A request that arrives mid-workout is
    /// ignored rather than restarting the session.
    private func startWorkoutFromWatch(sport: Sport, targetZone: Int?) {
        if AppDependencies.current.app.recorderBox.recorder == nil {
            AppDependencies.current.app.recorderBox.bind(core: collector, conversation: voiceChat)
        }
        guard let recorder = AppDependencies.current.app.recorderBox.recorder else { return }
        switch recorder.phase {
        case .idle, .finished, .failed: break
        case .recording, .finalizing: return
        }
        recorder.targetZone = targetZone
        do {
            try recorder.start(sport: sport, source: .strap, intervalPlan: nil, thresholds: [], route: nil)
        } catch {
            debugLog("[App][watch] start workout from Watch failed: \(error.localizedDescription)", level: .warning)
        }
    }

    @MainActor
    func appLevelWatchStopListener() async {
        let stream = NotificationCenter.default.notifications(named: .watchRequestedWorkoutStop)
        for await _ in stream {
            guard let recorder = AppDependencies.current.app.recorderBox.recorder, Self.isRecording(recorder) else { continue }
            Task { await recorder.stop() }
        }
    }

    /// A Watch stop only applies mid-workout; every other phase ignores it.
    @MainActor
    private static func isRecording(_ recorder: WorkoutRecorder) -> Bool {
        if case .recording = recorder.phase { return true }
        return false
    }

    @MainActor
    func appLevelWatchPauseListener() async {
        let stream = NotificationCenter.default.notifications(named: .watchRequestedWorkoutPause)
        for await _ in stream {
            guard let recorder = AppDependencies.current.app.recorderBox.recorder else { continue }
            if case .recording = recorder.phase {
                recorder.pause(isAuto: false)
            }
        }
    }

    @MainActor
    func appLevelWatchResumeListener() async {
        let stream = NotificationCenter.default.notifications(named: .watchRequestedWorkoutResume)
        for await _ in stream {
            guard let recorder = AppDependencies.current.app.recorderBox.recorder else { continue }
            if case .recording = recorder.phase {
                recorder.resume()
            }
        }
    }

    @MainActor
    func appLevelWatchAcknowledgeListener() async {
        let stream = NotificationCenter.default.notifications(named: .watchAcknowledgedFinished)
        for await _ in stream {
            AppDependencies.current.app.recorderBox.recorder?.acknowledgeFinished()
        }
    }

    /// Load archived sessions and present onboarding if needed, then start iCloud sync.
    /// Called either directly (returning user) or after disclaimer acceptance (new user).
    ///
    /// 2026-04 — open-wait fix. Previous implementation blocked the launch
    /// on `storeKitManager.refreshStatus()` (StoreKit `currentEntitlements`
    /// network round-trip, 1–3 s cold-cell) + `healthKit.requestAuthorization`
    /// (up to 1 s) before flipping `isLoading = false`. User report:
    /// "from the time I open it I wait. People don't want to be waiting all
    /// day." Now the dashboard appears immediately using the cached
    /// purchase state from last launch; the refresh runs as a background
    /// task and the paywall-gating decision re-evaluates when it completes.
    /// Body for the root `.task` modifier. Extracted so the `body` Scene
    /// expression stays simple enough for the type-checker (SwiftUI body
    /// expressions get expensive to type-check fast as they grow). Owns
    /// the safety timeout that force-flips `isLoading=false` if some
    /// background init hangs (a real report: a phone hung on splash forever
    /// on a fresh install).
    @MainActor
    /// Fire the deferred boot() methods on the heavy singletons, each timed so a
    /// slow one is named in the log. Extracted from the root `.task` closure to
    /// keep that closure small enough for the Swift type-checker.
    func runDeferredBoot() {
        let bootStart = Date()
        timedBoot("watchBridge") { watchBridge.boot() }
        timedBoot("collector") { collector.boot() }
        timedBoot("syncManager") { syncManager.boot() }
        timedBoot("storeKitManager") { storeKitManager.boot() }
        timedBoot("voiceChat") { voiceChat.boot() }
        let totalMs = Int(Date().timeIntervalSince(bootStart) * 1000)
        debugLog("[App][launch] boot sequence total: \(totalMs)ms", level: .info)
    }

    func timedBoot(_ label: String, _ work: () -> Void) {
        let t = Date()
        work()
        let ms = Int(Date().timeIntervalSince(t) * 1000)
        if ms > 50 { debugLog("[App][launch] boot \(label): \(ms)ms", level: .info) }
    }

    /// The safety timeout below force-flips the splash off if `isLoading` is
    /// still true 8 seconds from now (some background init hung, the
    /// disclaimer modal failed to present, the `.task` closure body never ran
    /// past an await point, etc.) so the user can at least see the disclaimer
    /// and try the app.
    /// Under `-UITests-SeedArchive` (Debug only) one scored night is archived
    /// before the first screen; a no-op otherwise.
    private func seedArchiveForUITests() async {
        #if DEBUG
            await UITestArchiveSeed.plantIfRequested(into: collector)
        #endif
    }

    func runLaunchTask() async {
        await seedArchiveForUITests()
        let acceptedDisclaimer = settingsManager.hasAcceptedDisclaimer
        NSLog("[App][launch] root .task fired (hasAcceptedDisclaimer=\(acceptedDisclaimer))")
        debugLog("[App][launch] root .task fired, isLoading=\(isLoading), hasAcceptedDisclaimer=\(acceptedDisclaimer)", level: .info)
        Task { @MainActor in
            await sleepQuietly(8_000_000_000, context: "runLaunchTask")
            await runLaunchSafetyCheck()
        }
        guard acceptedDisclaimer else {
            // Show disclaimer immediately — no data loading until accepted.
            NSLog("[App][launch] new install path — flipping isLoading=false, presenting disclaimer")
            debugLog("[App][launch] new install — flipping isLoading=false and presenting disclaimer", level: .info)
            isLoading = false
            activeModal = .disclaimer
            return
        }
        NSLog("[App][launch] returning user — calling loadDataAndContinue()")
        debugLog("[App][launch] returning user — calling loadDataAndContinue()", level: .info)
        loadDataAndContinue()
    }

    /// Force-flip the splash off and present a fallback modal if the
    /// launch hung. Logs the full state vector so the post-mortem has
    /// data even when persistent logging is off.
    @MainActor
    func runLaunchSafetyCheck() async {
        guard isLoading else { return }
        let modalDesc = String(describing: activeModal)
        let accepted = settingsManager.hasAcceptedDisclaimer
        let completed = settingsManager.settings.hasCompletedOnboarding
        NSLog("[App][launch] SAFETY TIMEOUT — splash up after 8s, force-flipping isLoading=false")
        debugLog("[App][launch] SAFETY TIMEOUT: splash still up after 8s — force-flipping isLoading=false. activeModal=\(modalDesc), dataLoaded=\(dataLoaded), hasAcceptedDisclaimer=\(accepted), hasCompletedOnboarding=\(completed)", level: .error)
        isLoading = false
        if activeModal == nil {
            if !accepted {
                activeModal = .disclaimer
            } else if !completed {
                activeModal = .onboarding
            }
        }
    }

    /// Kicks off the one-shot batch reanalyze of all
    /// archived sessions, but **only** when the user explicitly chose
    /// "Recalculate now" in the disclosure sheet. Idempotent — flips
    /// `hasRunScoreHistoryRecompute` so Settings can hide its manual
    /// "Recalculate" entry once the migration has run.
    func runMigrationRecomputeIfChosen() {
        let choice = migrationRecomputeChoice
        migrationRecomputeChoice = .undecided
        guard choice == .runNow else {
            debugLog("[App] migration recompute deferred (user chose later)", level: .info)
            return
        }
        guard !settingsManager.settings.hasRunScoreHistoryRecompute else {
            debugLog("[App] migration recompute already run — skipping (idempotent)", level: .info)
            return
        }
        debugLog("[App] migration recompute starting (user chose 'Recalculate now')", level: .info)
        Task.detached(priority: .background) {
            let result = await collector.reanalyzeAllSessions { done, total in
                debugLog("[App] migration reanalyze: \(done)/\(total)", level: .info)
            }
            debugLog("[App] migration reanalyze done — updated=\(result.updated) skipped=\(result.skipped)", level: .info)
            await MainActor.run {
                settingsManager.settings.hasRunScoreHistoryRecompute = true
            }
        }
    }

    /// Refresh purchase entitlements without blocking launch.
    ///
    /// If the cached state was stale — family sharing granted, a trial expired
    /// in the background — the observable flips on `StoreKitManager` fire view
    /// updates and the scene re-evaluates the modal gate on the fly. Also run
    /// on each return to the foreground (`EmuquApp.handleScenePhaseChange`).
    func refreshPurchaseEntitlementsInBackground() {
        Task(priority: .userInitiated) {
            await storeKitManager.refreshStatus()
            await MainActor.run { presentPaywallIfNowRequired() }
        }
    }

    /// Re-check gating in case the refresh changed something.
    @MainActor
    private func presentPaywallIfNowRequired() {
        guard !storeKitManager.isPurchased,
              settingsManager.settings.hasCompletedOnboarding,
              activeModal == nil
        else { return }
        activeModal = .paywall
    }

    /// Ensure HealthKit authorization has been requested, off the launch path.
    ///
    /// A no-op for returning users who already granted permission, and launch is
    /// never blocked on it — missing authorization degrades to an empty sleep
    /// card rather than stopping the app from opening.
    ///
    /// Skipped entirely when onboarding is about to present.
    /// `OnboardingView` fires its own `requestAuthorization` in `.task`, and
    /// firing both within milliseconds races the system permission prompt: iOS
    /// times it out and the user can grant nothing at all on first install. The
    /// belt-and-suspenders guard in `HealthKitManager` exists too, but not
    /// double-firing is the actual fix.
    ///
    /// A long settle delay does not help: on an iPhone 11 doing CloudKit
    /// sync-state load, archive migrations and sleep queries at once, the
    /// prompt arrived after iOS had already deprioritized it. So: a short
    /// 200 ms delay — enough for the splash and first frame to commit — plus
    /// one retry on "Authorization session timed out" after 1.5 s.
    /// The retry is the part that matters: the first attempt almost always
    /// fires while iOS is busy, and the second lands cleanly.
    /// Not after "Skip for now" on onboarding's Apple Health page. That
    /// choice used to last until the next launch, which put the Health
    /// sheet in front of the user with no context. Access is then asked
    /// for only from something the user taps: the dashboard's Get started
    /// row, Settings → Wearables, or Settings → Permissions.
    private func requestHealthKitAuthorizationIfOnboarded() {
        guard settingsManager.settings.hasCompletedOnboarding else { return }
        guard !collector.healthKit.isAccessSkipped else { return }
        Task(priority: .userInitiated) {
            await sleepQuietly(200_000_000, context: "requestHealthKitAuthorizationIfOnboarded")
            guard collector.healthKit.isHealthKitAvailable else { return }
            await requestHealthKitAuthorizationWithRetry(collector: collector)
        }
    }

    /// Pre-fetch road context at launch so the first
    /// workout tap doesn't have to wait for the geocoding pipeline.
    ///
    /// User report: "geocoding. that's your problem … why do that to
    /// start the walk and not do it when the app loads in the background
    /// so the person is located?" Diagnostic confirmed: at workout
    /// start the first GPS fix can take 20–30 s on a cold daemon, then
    /// the tile-search + CLGeocoder + cross-street pipeline adds another
    /// 10–15 s of staged timeouts before `current` is populated. Moving
    /// that work to a delayed Task here means by the time the user is
    /// ready to start a walk, `AppDependencies.current.location.roadGeocodingService.current`
    /// already holds a fresh `RoadContext` and the workout ticker's
    /// first `refreshIfNeeded` no-ops on the time/movement gate.
    private func prewarmRoadContext(powerMultiplier: Double) {
        Task(priority: .utility) {
            await sleepQuietly(UInt64(4_000_000_000 * powerMultiplier), context: "prewarmRoadContext")
            guard await shouldPrewarmRoadContext() else { return }
            NSLog("[App][bg] road context prewarm — start")
            await Self.fetchRoadContext()
        }
    }

    /// Gated on `enableAIAssistant`. The road context
    /// is consumed ONLY by the AI coach (so it can say "you're on
    /// Benelli Dr" instead of speaking raw lat/lon). With the
    /// assistant disabled, every byte of the geocoding pipeline
    /// is wasted work — no caller reads `.current`. User direction:
    /// "this shouldn't run unless the AI is turned on. and then
    /// only as a warm up behind the introduction on another thread."
    ///
    /// Also gated on auth: a silent no-op if location permission isn't
    /// granted (we don't prompt at launch for this — the workout start path
    /// remains the user-facing auth ask).
    ///
    /// Skipped when we already have a recent fix.
    /// `AppDependencies.current.location.roadGeocodingService.current` survives across foregrounds; if
    /// it was populated less than 15 min ago we don't need a fresh
    /// CoreLocation cold-start (which takes 8–25 s on a stale GPS daemon —
    /// a field launch log showed 12.1 s). The on-demand `refreshIfNeeded`
    /// path picks up a fresher fix when the user actually does something that
    /// needs it.
    private func shouldPrewarmRoadContext() async -> Bool {
        guard settingsManager.settings.enableAIAssistant else {
            NSLog("[App][bg] road context prewarm — skipped (AI assistant disabled)")
            return false
        }
        let status = CLLocationManager().authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            NSLog("[App][bg] road context prewarm — skipped (location not authorized)")
            return false
        }
        if let cached = await MainActor.run(body: { AppDependencies.current.location.roadGeocodingService.current }),
           Date().timeIntervalSince(cached.observedAt) < 900 {
            NSLog("[App][bg] road context prewarm — skipped (cache fresh \(Int(Date().timeIntervalSince(cached.observedAt)))s ago)")
            return false
        }
        return true
    }

    /// The timeout is 8 s, deliberately short.
    /// Background `.utility` priority means a longer timeout
    /// doesn't visibly block the user, but it does keep
    /// CoreLocation warm + drains battery for a feature the
    /// user may not invoke this launch. 8 s is enough to
    /// succeed on a cellular-cached fix (~1–3 s typical);
    /// beyond that we accept the miss and let the on-demand
    /// refresh path populate the cache later. Failures here
    /// are non-fatal — the AI just doesn't pre-know the
    /// user's street.
    private static func fetchRoadContext() async {
        do {
            let location = try await LocationFinder.detachedFirstUsableLocation(timeoutSec: 8)
            // `prewarm` is @MainActor-isolated but not `async`; the
            // implicit actor hop is enough — no explicit `await` needed.
            await MainActor.run {
                AppDependencies.current.location.roadGeocodingService.prewarm(at: location)
            }
            NSLog("[App][bg] road context prewarm — done")
        } catch {
            NSLog("[App][bg] road context prewarm — failed: \(error)")
        }
    }

    /// Pre-warm the workout-start audio graph.
    ///
    /// Without this, tapping Start hung the app for up to a minute on a cold
    /// first attempt; force-quitting then re-starting worked. The sync
    /// BLE/CL/AV blockers in `WorkoutRecorder.start()` are deferred,
    /// but the first announce Task still held the main actor for ~500–800 ms
    /// while `AVAudioSession.setActive(true)` and the first-ever
    /// `AVSpeechSynthesizer.speak()` prepared their audio graphs. Pre-warming
    /// both at launch moves that cost off the workout-start critical path: the
    /// user pays it once during the app launch window, when nothing else is
    /// waiting on them, instead of every time they tap Start. Idempotent; safe
    /// if the user never starts a workout this launch.
    private func prewarmWorkoutAudio(powerMultiplier: Double) {
        Task(priority: .utility) {
            await sleepQuietly(UInt64(2_000_000_000 * powerMultiplier), context: "prewarmWorkoutAudio")
            NSLog("[App][bg] workout audio pre-warm — start")
            Self.activateAudioSession()
            await Self.speakWarmupUtterance()
            await Self.prepareHaptics()
            NSLog("[App][bg] workout audio pre-warm — done")
        }
    }

    /// `AVAudioSession.setActive` MUST run on a main-thread context, but
    /// nothing blocking awaits its completion. Fire-and-forget on the main
    /// actor; idempotent if already active.
    private static func activateAudioSession() {
        Task { @MainActor in
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                NSLog("[App][bg] workout audio pre-warm — setActive failed: \(error.localizedDescription)")
            }
        }
    }

    /// Speak a near-silent warm-up utterance against a COMPACT voice, OFF the
    /// main actor. AVSpeechSynthesizer is thread-safe; if the speech daemon
    /// hangs on first use, this absorbs the wait while the rest of launch
    /// stays responsive.
    ///
    /// Using a compact voice (quality == .default) avoids the iOS 17+ bug
    /// where speaking against an enhanced/premium voice that isn't yet
    /// downloaded blocks the calling thread for up to 60 s while iOS pulls the
    /// file.
    ///
    /// `localCompactVoice` is lock-protected and caches its
    /// result, so this MainActor.run hop both warms the speech daemon AND
    /// seeds the cache that `announceStart` consumes at workout start. After
    /// this fires, the first workout's `announceStart` does NOT re-call
    /// `speechVoices()` — the prime suspect for a 14.6 s synchronous stall
    /// seen in a field debug log.
    ///
    /// Uses a real word ("Ready") at volume 0 instead of a lone
    /// space. Empty / whitespace-only utterances have been observed to
    /// short-circuit before the daemon fully wakes its audio engine;
    /// pronouncing a real (silent) word forces the full pipeline through.
    /// Still inaudible because volume == 0.
    ///
    /// Note: this deliberately does NOT touch `AVAudioSession`. The brief
    /// earlier experiment with `setCategory + setActive(true)` blocked the
    /// calling thread synchronously when the audio service was in a
    /// post-interruption recovery state, freezing the workout-start UI for
    /// tens of seconds. AVSpeechSynthesizer manages its own session; let it.
    private static func speakWarmupUtterance() async {
        let warmup = AVSpeechUtterance(string: "Ready")
        warmup.volume = 0
        warmup.rate = AVSpeechUtteranceMaximumSpeechRate
        let lang = await MainActor.run { Locale.current.language.languageCode?.identifier ?? "en" }
        warmup.voice = await MainActor.run { WorkoutStartCue.localCompactVoice(forLanguage: lang) }
        WorkoutStartCue.announceSynthesizer.speak(warmup)
    }

    /// Pre-warm the Taptic Engine. `UINotificationFeedbackGenerator` and
    /// `UIImpactFeedbackGenerator` need a `.prepare()` call to spin up the
    /// haptic hardware; cold-fire on the start path has been measured at
    /// 100–400 ms even on fast devices and has been seen in the wild at
    /// multi-second on iPhone 11 / Low Power Mode. The generators are STATIC
    /// on `WorkoutRecorder` so the same warmed instances are reused at
    /// workout-start time.
    private static func prepareHaptics() async {
        await MainActor.run {
            WorkoutStartCue.notificationFeedback.prepare()
            WorkoutStartCue.impactFeedback.prepare()
        }
    }

    /// Launch housekeeping is ordered by LaunchCoordinator (phase-gated,
    /// QoS-correct, bounded) instead of hand-tuned sleep delays. `run(...)`
    /// falls back to the exact legacy behavior when the flag is off.
    private func scheduleLaunchHousekeeping() {
        AppDependencies.current.analysis.trainingMetricsCache.configure(healthKit: collector.healthKit)
        let powerMultiplier = AppDependencies.current.services.powerStatePolicy.launchDelayMultiplier
        let skipPeriodic = AppDependencies.current.services.powerStatePolicy.shouldSkipPeriodicRefresh
        if powerMultiplier > 1.0 {
            NSLog("[App][bg] Low Power Mode — delays ×\(powerMultiplier), periodic refresh \(skipPeriodic ? "SKIPPED" : "kept")")
        }
        let lowPower = powerMultiplier > 1.0
        AppDependencies.current.app.launchCoordinator.begin()
        scheduleMigrationJobs(powerMultiplier: powerMultiplier, lowPower: lowPower)
        prewarmRoadContext(powerMultiplier: powerMultiplier)
        prewarmWorkoutAudio(powerMultiplier: powerMultiplier)
        scheduleTrainingJobs(powerMultiplier: powerMultiplier, lowPower: lowPower)
        scheduleSyncJob(powerMultiplier: powerMultiplier, lowPower: lowPower)
    }

    /// Archive migrations, in the launch coordinator's housekeeping phase —
    /// after the dashboard's first load lands (or its 6 s ceiling), at
    /// background priority. These walk every archived session and may rewrite
    /// metadata, so they wait for the dashboard to render first. The
    /// file-protection walk leads them for the same reason. Always runs (not
    /// periodic — they self-terminate via UserDefaults flag). The one-shot
    /// session-data repairs that follow are each gated by a UserDefaults flag
    /// after a successful run.
    private func scheduleMigrationJobs(powerMultiplier: Double, lowPower: Bool) {
        // Sendable locals for the detached launch jobs (avoid capturing the
        // non-Sendable App `self`).
        let archiveRef = collector.archive
        let collectorJob = collector
        let coord = AppDependencies.current.app.launchCoordinator
        coord.run(phase: .housekeeping, priority: .background, skipInLowPower: false, lowPower: lowPower) {
            NSLog("[App][bg] archive migrations — start")
            archiveRef.upgradeExistingFileProtection()
            archiveRef.runDeferredMigrations()
            NSLog("[App][bg] archive migrations — done")
        }
        coord.run(phase: .housekeeping, priority: .background, skipInLowPower: false, lowPower: lowPower) {
            NSLog("[App][bg] session migrations — start")
            await collectorJob.runDeferredSessionMigrationsIfNeeded()
            NSLog("[App][bg] session migrations — done")
        }
        scheduleBackupReconcile(coord: coord, archive: archiveRef, backup: collector.rawBackup, lowPower: lowPower)
    }

    /// Correct backups still flagged unarchived whose session the archive
    /// already holds.
    ///
    /// The flag is set on each successful archive path, so it is right for
    /// anything that completed in one go and wrong for anything that reached
    /// the archive another way — a CloudKit pull, a launch recovery, a merge
    /// under a different session id. Those entries stay flagged forever, and
    /// the Data settings page renders them as a red "Unarchived recordings"
    /// count for a user whose data is safely archived. A field log shows the
    /// same fifteen at every launch across five days.
    ///
    /// Housekeeping, not launch-critical: the count is a diagnostic, and being
    /// right one second later costs nothing.
    private func scheduleBackupReconcile(
        coord: LaunchCoordinator, archive: SessionArchive, backup: RawRRBackup, lowPower: Bool
    ) {
        coord.run(phase: .housekeeping, priority: .background, skipInLowPower: false, lowPower: lowPower) {
            let archived = Set(archive.entries.map(\.sessionId))
            let corrected = backup.reconcileArchived(against: archived)
            guard corrected > 0 else { return }
            NSLog("[App][bg] backup reconcile — %d backup(s) were already archived", corrected)
        }
    }

    /// Retroactive route-history TRIMP backfill, LPM-gated: on an
    /// iPhone 11 in Low Power Mode the archive scan + FTP estimate
    /// contributed to a multi-second launch stall on older
    /// hardware. Both are one-shot, self-throttled tasks — they
    /// can wait for a launch when the user isn't actively
    /// conserving battery.
    ///
    /// The training-metrics cache warm-up (delay 3s) is likewise SKIPPED in
    /// Low Power Mode — the dashboard shows stale-but-valid cached metrics and
    /// the user can pull-to-refresh for fresh ones.
    private func scheduleWorkoutLoadBackfill(powerMultiplier: Double, lowPower: Bool) {
        let archiveForBackfill = collector.archive
        AppDependencies.current.app.launchCoordinator.run(
            phase: .housekeeping, priority: .background, skipInLowPower: true, lowPower: lowPower
        ) {
            NSLog("[App][bg] workout load backfill — start")
            await WorkoutLoadBackfill.runIfNeeded(
                archive: archiveForBackfill,
                savedRouteStore: AppDependencies.current.location.savedRouteStore
            )
            await MainActor.run {
                FTPAutoEstimator.recomputeIfNeeded(archive: archiveForBackfill)
            }
            await AppDependencies.current.analysis.trainingMetricsCache.refresh()
            // Wait for the 400-day historical Banister series
            // HERE, in background, so the first AI send doesn't have to.
            await AppDependencies.current.analysis.trainingMetricsCache.awaitHistoricalSeries()
            NSLog("[App][bg] workout load backfill — done")
        }
    }

    private func scheduleTrainingJobs(powerMultiplier: Double, lowPower: Bool) {
        scheduleWorkoutLoadBackfill(powerMultiplier: powerMultiplier, lowPower: lowPower)
        scheduleTempAsymmetryRescore(powerMultiplier: powerMultiplier, lowPower: lowPower)
        AppDependencies.current.app.launchCoordinator.run(phase: .housekeeping, priority: .background, skipInLowPower: true, lowPower: lowPower) {
            NSLog("[App][bg] training cache refresh — start")
            await AppDependencies.current.analysis.trainingMetricsCache.refresh()
            NSLog("[App][bg] training cache refresh — done")
        }
    }

    /// Temp-asymmetry score-rescore migration. Two design points, both
    /// from an iPhone-11/LPM field log:
    ///   1. LPM gate. Reanalyzing every session at launch is the
    ///      single biggest perf hit on older hardware; skip it
    ///      entirely when the user is conserving battery.
    ///   2. Chunked + cursor. Without this the migration fires
    ///      for every session in one pass — on a 36-session
    ///      archive × ~29 K beats each, that's 2–4 minutes of
    ///      heavy CPU. iOS routinely cancels the background task
    ///      before completion, so `hasFixedTempAsymmetry` never
    ///      flips, and the next launch restarts from session 0 —
    ///      an endless loop. So: process up to
    ///      `Self.tempAsymmetryChunkSize` sessions per launch,
    ///      persist a cursor of processed UUIDs, flip the done
    ///      flag only when every session in the current archive
    ///      is covered. Crash-safe across launches.
    private func scheduleTempAsymmetryRescore(powerMultiplier: Double, lowPower: Bool) {
        guard !settingsManager.settings.hasFixedTempAsymmetry else { return }
        let collectorJob = collector
        AppDependencies.current.app.launchCoordinator.run(
            phase: .housekeeping, priority: .background, skipInLowPower: true, lowPower: lowPower
        ) {
            NSLog("[App][bg] temp-asymmetry rescore — start (running until cancellation or completion)")
            let result = await Self.runTempAsymmetryRescoreChunk(collector: collectorJob)
            NSLog("[App][bg] temp-asymmetry rescore — processed=\(result.processed) totalDone=\(result.totalDone)/\(result.total) complete=\(result.complete)")
            guard result.complete else { return }
            await MainActor.run {
                AppDependencies.current.app.settingsManager.settings.hasFixedTempAsymmetry = true
            }
        }
    }

    /// iCloud sync — delay 8s (32s in LPM). NEVER skipped, even in
    /// LPM. Reason: a beta tester had a
    /// CloudKit zone-not-found death spiral going — every sync
    /// cycle was failing with "Zone does not exist" for 20 pending
    /// sessions, hammering CPU + battery. The zone-recreate fix
    /// (CloudKitSyncManager.recreateZoneAfterNotFound) needs to
    /// actually RUN to heal that state. If we skip sync entirely
    /// in LPM, the zone stays broken forever and the app stays
    /// slow forever. So: run sync once at launch even in LPM, just
    /// delay it longer so the UI is responsive first. After the
    /// heal, future syncs are cheap (no errors to retry).
    private func scheduleSyncJob(powerMultiplier: Double, lowPower: Bool) {
        let syncManagerJob = syncManager
        AppDependencies.current.app.launchCoordinator.run(
            phase: .housekeeping, priority: .background, skipInLowPower: false, lowPower: lowPower
        ) {
            NSLog("[App][bg] iCloud sync — start (LPM=\(lowPower))")
            await syncManagerJob.performFullSyncIfNeeded(minInterval: 30 * 60)
            NSLog("[App][bg] iCloud sync — done")
        }
    }

    /// The launch housekeeping it schedules is staggered + delayed so the UI
    /// can render and become responsive before heavy I/O kicks in. iPhone 11
    /// with 20 pending CloudKit sessions hit a worst case where everything
    /// fired simultaneously and the app was unresponsive for many seconds
    /// (a field report).
    ///
    /// Low Power Mode awareness: in LPM all delays are
    /// multiplied by 4× (so 4s → 16s) AND the periodic refreshes are skipped
    /// entirely (training-metrics refresh, iCloud sync). User report: the app
    /// was draining the battery whenever foreground, even with no session
    /// active — these housekeeping tasks were the culprit. So LPM gets a
    /// truly idle app: housekeeping only runs when explicitly asked
    /// (pull-to-refresh, session start, tab navigation).
    func loadDataAndContinue() {
        NSLog("[App][launch] loadDataAndContinue() entered (dataLoaded=\(dataLoaded))")
        debugLog("[App][launch] loadDataAndContinue() entered, dataLoaded=\(dataLoaded)", level: .info)
        guard !dataLoaded else {
            debugLog("[App][launch] loadDataAndContinue() skipped — already loaded", level: .info)
            return
        }
        dataLoaded = true
        // Flip the launch screen off FIRST, synchronously, using the
        // already-persisted purchase state and settings. The dashboard
        // renders whatever data it already has cached while background
        // tasks finish their network / HealthKit chores.
        NSLog("[App][launch] loadDataAndContinue — flipping isLoading=false")
        debugLog("[App][launch] flipping isLoading=false (hasCompletedOnboarding=\(settingsManager.settings.hasCompletedOnboarding), isPurchased=\(storeKitManager.isPurchased))", level: .info)
        isLoading = false
        prepareEntitlementGate()
        presentLaunchModal()
        NSLog("[App][launch] loadDataAndContinue — exit (activeModal=\(activeModal.map { String(describing: $0.id) } ?? "nil"))")
        refreshPurchaseEntitlementsInBackground()
        requestHealthKitAuthorizationIfOnboarded()
        scheduleLaunchHousekeeping()
    }

    /// When the paywall is on, the gate routes to it only when
    /// every bypass has been exhausted: an actual purchase, a grandfathered
    /// beta tester, a developer install, or an active free trial. See
    /// `StoreKitManager.paywallEnabled`.
    ///
    /// This promotes the durable entitlement anchor into its fast tier BEFORE
    /// the gate reads it. `loadDataAndContinue` is reached from the FIRST
    /// `.task` on the root view, whereas the anchor is otherwise reconciled in
    /// `runDeferredBoot()` → `storeKitManager.boot()`, which is the SECOND. A
    /// beta tester who has reinstalled, or restored onto a new phone, carries
    /// their status only in the synchronizable keychain at this point — so
    /// without this the gate would read an empty UserDefaults cache and show
    /// them a paywall before boot ever ran. `resolvedForGate` is free when the
    /// anchor is already populated. The legacy TestFlight flag is
    /// carried across for the same reason.
    ///
    /// The trial is not started here. Guideline 3.1.1 wants the user told the
    /// trial's length, what locks when it ends, and the price before it
    /// begins, so it starts only from the paywall's "Start Free Trial". A user
    /// who has onboarded and has no other route in therefore meets that offer
    /// at launch, which is a paywall they can walk straight through.
    private func prepareEntitlementGate() {
        let gateNow = Date()
        EntitlementAnchor.resolvedForGate(wallClock: gateNow)
        storeKitManager.migrateLegacyTestFlightFlag(now: gateNow)
        storeKitManager.grandfatherExistingUserIfNeeded(hasHistory: !collector.archive.index.isEmpty, now: gateNow)
        NSLog("[App][launch] access check: paywallEnabled=\(StoreKitManager.paywallEnabled) isPurchased=\(storeKitManager.isPurchased) trialDaysRemaining=\(settingsManager.trialDaysRemaining)")
    }

    /// Onboarding, then the paywall, then the trial reminder, then the
    /// one-time score-architecture disclosure — first gate that applies wins.
    ///
    /// The score-architecture disclosure fires after the
    /// onboarding/paywall/trial gates are satisfied so a brand-new user never
    /// sees it (their first score is computed under the new architecture
    /// directly — onboarding completion sets the ack flag).
    private func presentLaunchModal() {
        guard settingsManager.settings.hasCompletedOnboarding else {
            debugLog("[App][launch] presenting onboarding modal", level: .info)
            activeModal = .onboarding
            return
        }
        if let gated = paywallModal() {
            activeModal = gated
            return
        }
        if !settingsManager.settings.hasAcknowledgedScoreArchitectureChange {
            debugLog("[App][launch] presenting score-architecture change disclosure", level: .info)
            activeModal = .scoreArchitectureChange
        } else {
            debugLog("[App][launch] no modal needed — checking for interrupted session", level: .info)
        }
        checkForInterruptedSession()
    }

    /// The paywall itself, or the once-a-day trial reminder — nil when the
    /// user is past both gates.
    ///
    /// `-UITests-ForcePaywall` overrides the ship kill switch as well as the
    /// entitlement. Overriding only the entitlement leaves the guard below as
    /// the first thing the gate hits, so with `paywallEnabled` off the screen
    /// becomes unreachable and its three UI tests fail on a product decision
    /// rather than a regression — which is how they failed. The paywall is
    /// code that ships in the binary and will be switched on; it has to stay
    /// provable while it is off. The argument is compiled out of Release.
    private func paywallModal() -> LaunchModal? {
        guard StoreKitManager.paywallEnabled || UITestLaunchArguments.forcesPaywall else { return nil }
        let modal = PaywallGatePolicy.launchModal(
            hasAccess: hasAccess,
            hasPermanentAccess: storeKitManager.hasPermanentAccess,
            isInTrial: settingsManager.isInTrialPeriod,
            trialDaysRemaining: settingsManager.trialDaysRemaining,
            reminderShownToday: settingsManager.hasShownTrialReminderToday)
        switch modal {
        case .paywall:
            debugLog("[App][launch] presenting paywall modal (no purchase, not a beta tester, not in trial)", level: .info)
        case .trialReminder:
            debugLog("[App][launch] presenting trial reminder modal", level: .info)
        default:
            break
        }
        return modal
    }

    /// Every way past the paywall: a purchase, TestFlight, a grandfathered
    /// beta tester, a developer install, or an active trial.
    private var hasAccess: Bool {
        if UITestLaunchArguments.forcesPaywall { return false }
        return storeKitManager.isPurchased
            || StoreKitManager.isTestFlight
            || StoreKitManager.isGrandfatheredBetaTester
            || StoreKitManager.isDeveloperInstall
            || settingsManager.isInTrialPeriod
    }

    /// The sleep observer starts at launch, not only
    /// during an active overnight recording. Without this, an Apple
    /// Watch sync while the app is open (but no recording running)
    /// never bumped `sleepDataVersion`, so the morning sleep didn't
    /// auto-update — the user had to open the Sleep section and tap
    /// "Refresh". Combined with the scenePhase-active re-pull in
    /// MainTabView, the morning sleep self-corrects.
    ///
    /// The observer is started before the authorization request as well as
    /// after it. When a release adds read types, the request waits for a
    /// permission sheet — which a background launch cannot show — so an
    /// observer started only once the request returns never starts in that
    /// process. Sleep read access granted earlier is unaffected by the new
    /// types, and the restart after a successful request picks up anything the
    /// sheet grants.
    func requestHealthKitAuthorizationWithRetry(collector: RRCollector) async {
        collector.healthKit.startObservingSleepData()
        for attempt in 1 ... 2 {
            if await authorizeHealthKitOnce(collector: collector, attempt: attempt) { return }
            await sleepQuietly(1_500_000_000, context: "requestHealthKitAuthorizationWithRetry")
        }
    }

    /// True when the loop should stop — either authorization returned, or the
    /// failure isn't a retryable timeout.
    private func authorizeHealthKitOnce(collector: RRCollector, attempt: Int) async -> Bool {
        NSLog("[App][hk] requesting authorization (attempt \(attempt))")
        do {
            try await collector.healthKit.requestAuthorization()
            NSLog("[App][hk] authorization request returned (attempt \(attempt))")
            collector.healthKit.startObservingSleepData()
            return true
        } catch {
            return !Self.isRetryableAuthTimeout(error, attempt: attempt)
        }
    }

    /// Only the iOS-internal "Authorization session timed out" is worth a
    /// second attempt; everything else is terminal for this launch.
    private static func isRetryableAuthTimeout(_ error: Error, attempt: Int) -> Bool {
        let nsError = error as NSError
        let isTimeout = nsError.domain == "com.apple.healthkit"
            && nsError.localizedDescription.lowercased().contains("timed out")
        NSLog("[App][hk] authorization request failed on attempt \(attempt): \(error.localizedDescription)")
        debugLog("[App] HealthKit authorization request failed (attempt \(attempt)): \(error)", level: .warning)
        return isTimeout && attempt < 2
    }

    // MARK: - Temp-asymmetry rescore (chunked + cursor)
    //
    // There is deliberately no per-launch session ceiling: one sized
    // to fit inside iOS's 30 s background-task budget on iPhone 11
    // would unnecessarily cap progress on launches where iOS gives
    // more time. The cursor saves after EVERY session,
    // so a launch-task cancellation never loses more than one
    // session's work. So: run until either
    //   • all sessions migrated, OR
    //   • `Task.isCancelled` fires (iOS hit its budget)
    // The number below is the LOG-cadence chunk — how often we
    // emit a progress line — not a per-launch ceiling.
    private static let tempAsymmetryLogEvery: Int = 5

    /// UserDefaults key for the JSON-encoded list of session UUIDs
    /// already processed by the temp-asymmetry rescore migration.
    /// Persisting the cursor across launches is what makes the
    /// migration crash-safe — iOS can cancel the background task
    /// at any time and progress is preserved.
    private static let tempAsymmetryCursorKey = "FlowRecovery.tempAsymmetryRescore.processedIds"

    /// Run the temp-asymmetry rescore until completion OR
    /// `Task.isCancelled`. Returns:
    ///   processed: how many sessions this run touched
    ///   totalDone: cumulative count across all runs so far
    ///   total: archive size at run start
    ///   complete: true when totalDone covers every session in the
    ///     current archive (the caller flips `hasFixedTempAsymmetry`)
    ///
    /// Not capped at `chunkSize` sessions per launch: the cursor is
    /// persisted after every session, so cancellation loses at most ONE
    /// session of work. Running until cancellation lets every launch
    /// make maximum progress — a 36-session migration converges in
    /// 1–2 non-LPM launches instead of 8.
    /// Cancellation is checked at every iteration — iOS background budget
    /// exhaustion stops the walk there, with the cursor current. The cursor is
    /// persisted after EACH session so even a mid-run cancellation preserves
    /// what's done, and a periodic progress line lets the user see motion in a
    /// debug-log export.
    /// One chunk's worth of rescore progress. `complete` is true once every
    /// archived session has been visited, which retires the cursor.
    struct RescoreChunk {
        let processed: Int
        let totalDone: Int
        let total: Int
        let complete: Bool
    }

    private static func runTempAsymmetryRescoreChunk(
        collector: RRCollector
    ) async -> RescoreChunk {
        // Load the cursor (set of UUIDs already rescored).
        var processed = Self.loadTempAsymmetryCursor()
        // Snapshot the archive entries (newest-first by default).
        // Iterating newest-first means the dashboard-visible session
        // gets rescored FIRST, so even if iOS cancels us mid-run,
        // the user's currently-displayed score is the corrected one.
        let allEntries = await MainActor.run { collector.archive.entries }
        let unprocessed = allEntries.filter { !processed.contains($0.sessionId) }
        guard !unprocessed.isEmpty else {
            return RescoreChunk(processed: 0, totalDone: processed.count, total: allEntries.count, complete: true)
        }
        let processedThisRun = await rescoreAll(unprocessed, into: &processed, of: allEntries.count, collector: collector)
        return RescoreChunk(
            processed: processedThisRun, totalDone: processed.count, total: allEntries.count,
            complete: allEntries.allSatisfy { processed.contains($0.sessionId) }
        )
    }

    private static func rescoreAll(
        _ unprocessed: [SessionArchiveEntry], into processed: inout Set<UUID>, of total: Int, collector: RRCollector
    ) async -> Int {
        var processedThisRun = 0
        for entry in unprocessed {
            if Task.isCancelled { break }
            await rescoreForTempAsymmetry(entry.sessionId, collector: collector)
            processed.insert(entry.sessionId)
            processedThisRun += 1
            Self.saveTempAsymmetryCursor(processed)
            if processedThisRun % Self.tempAsymmetryLogEvery == 0 {
                NSLog("[App][bg] temp-asymmetry rescore — progress \(processed.count)/\(total)")
            }
        }
        return processedThisRun
    }

    /// Rescore one session, or skip it. A session that can't be retrieved is
    /// skipped rather than retried indefinitely — the user can repair it via
    /// Archive Diagnostics. A manual window is preserved (the same gate
    /// `reanalyzeAllSessions` uses internally), and a session with no rrSeries
    /// has nothing to reanalyse.
    ///
    /// The read is a full decrypt and decode — the whole beat series — and
    /// this runs once per session while the user is already using the app, so
    /// it runs detached rather than on the main thread. The archive serializes
    /// its own access.
    private static func rescoreForTempAsymmetry(_ sessionId: UUID, collector: RRCollector) async {
        let archive = collector.archive
        let read = Task.detached(priority: .background) { try archive.retrieve(sessionId) }
        guard let session = try? await read.value,
              session.windowUserAdjusted != true,
              let rr = session.rrSeries, !rr.points.isEmpty
        else { return }
        _ = await collector.reanalysisService.reanalyzeSession(session, preserveManualWindows: true)
    }

    private static func loadTempAsymmetryCursor() -> Set<UUID> {
        guard let data = UserDefaults.standard.data(forKey: tempAsymmetryCursorKey),
              let strings = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }

    private static func saveTempAsymmetryCursor(_ ids: Set<UUID>) {
        let strings = ids.map { $0.uuidString }
        if let data = attempt("launch.stringsCache.encode", { try JSONEncoder().encode(strings) }) {
            UserDefaults.standard.set(data, forKey: Self.tempAsymmetryCursorKey)
        }
    }
}
