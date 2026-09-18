import AVFoundation
import CoreLocation
import os.signpost
import SwiftUI

/// Cold-start signpost log: makes the launch-path
/// init cost measurable in Instruments → App Launch / Logging templates.
/// The deeper deferral (move PolarManager / WatchBridge / VoiceConversation
/// off the synchronous launch path) is intentionally NOT done here — it
/// requires device profiling to validate and per-singleton refactoring of
/// what's safe to defer.
private let coldStartLog = OSLog(subsystem: "com.chrissharp.flowrecovery", category: "ColdStart")

@inline(__always)
private func signpostStart(_ name: StaticString) -> OSSignpostID {
    let id = OSSignpostID(log: coldStartLog)
    os_signpost(.begin, log: coldStartLog, name: name, signpostID: id)
    return id
}

@inline(__always)
private func signpostEnd(_ name: StaticString, _ id: OSSignpostID) {
    os_signpost(.end, log: coldStartLog, name: name, signpostID: id)
}

/// Which full-screen modal is currently presented (only one at a time).
enum LaunchModal: Identifiable {
    case disclaimer
    case onboarding
    case paywall
    case trialReminder
    /// One-time disclosure for the recovery-score
    /// architecture change (HRV/Sleep/Training → HRV/Sleep/Vitals).
    /// Triggered once for upgrading users via the
    /// `hasAcknowledgedScoreArchitectureChange` flag in UserSettings.
    case scoreArchitectureChange

    var id: String {
        switch self {
        case .disclaimer: return "disclaimer"
        case .onboarding: return "onboarding"
        case .paywall: return "paywall"
        case .trialReminder: return "trialReminder"
        case .scoreArchitectureChange: return "scoreArchitectureChange"
        }
    }
}

/// Info about a session that was in progress when the app was killed.
struct InterruptedSessionInfo {
    let sessionId: UUID
    let startTime: Date
    let sessionType: SessionType

    /// Resume only makes sense if the session is recent enough to continue.
    /// After the threshold, the recording gap is too large to produce a meaningful merged result.
    ///
    /// Workouts always route to the non-resumable alert: true resume
    /// would require re-binding live sensors (Polar reconnect, GPS
    /// restart, background audio, foot-pod, voice coach), which the
    /// post-crash launch path can't reliably reconstruct without going
    /// through the live `WorkoutRecorder.start()` pipeline. The user is
    /// offered "Save what was captured" instead — a much smaller
    /// surface area, and the partial session lands in the dashboard
    /// the same way a normal completion would.
    var isResumable: Bool {
        guard sessionType != .workout else { return false }
        return Date().timeIntervalSince(startTime) < SessionConstants.maxResumableSessionAge
    }
}

// Cold-launch init strategy: the heavy singletons do no I/O in `init()`. Each
// has a lightweight `init()` (assign properties; no BLE / CloudKit / StoreKit /
// WCSession work) plus a `func boot()` that performs the hardware / network
// setup AFTER the first frame paints. `boot()` is fired from the root `.task`
// in `body` (see the boot cascade lower down): `watchBridge`, `collector`,
// `syncManager`, `storeKitManager`, `voiceChat`. `PolarManager` defers its
// CoreBluetooth build to `ensureApiReady()`, which runs on the first scan or
// connect — never at launch (see `RRCollector.boot()` for why). `collector`,
// `settingsManager`, and `languageManager` stay eager because the first frame
// needs them.
//
// Synchronous BLE / CKContainer / WCSession work inside the singleton inits
// once hung the launch before first paint; the `os_signpost` instrumentation
// on every init (category `ColdStart`) is the measurement surface for
// time-to-first-frame.
struct EmuquApp: App {
    @State var collector = makeLoggedDefault()
    @State var syncManager = makeSyncManager()
    @State var settingsManager = makeSettingsManager()
    @State var storeKitManager = makeStoreKitManager()
    @State var languageManager = makeLanguageManager()
    /// App-wide voice chat controller. Lives at the root so any surface
    /// (Fitness, Assistant tab, Dashboard) can invoke the same conversation.
    /// Uses the `.shared` singleton — the class owns hardware resources (mic,
    /// synth) that can't be duplicated, and the Watch-trigger path targets
    /// the singleton by design.
    @State var voiceChat = makeVoiceChat()
    /// Watch bridge singleton — held here so the Watch-triggered voice-chat
    /// closure is wired before any Watch message can arrive.
    @State var watchBridge = makeWatchBridge()
    /// Observed at app root so the auto Coach Report
    /// (and any other staged email draft) pops the composer no matter
    /// which tab is active. AssistantChatView still observes for the
    /// chat-tab-local case; the sheet item binding is single-fire and
    /// the bridge is shared, so two `.sheet(item:)` modifiers across
    /// the tree behave correctly — only one presents at a time.
    @State private var emailBridge = AssistantEmailBridge.shared
    @State var isLoading = true
    @State var activeModal: LaunchModal?
    @State var dataLoaded = false
    @State var interruptedSessionAlert: InterruptedSessionInfo?
    @State var recoveryResultMessage: String?
    /// Captures the user's choice in the score-
    /// architecture disclosure sheet so the dismissal handler knows
    /// whether to kick off the one-shot batch reanalyze. Reset to
    /// `.undecided` after the action runs.
    @State var migrationRecomputeChoice: ScoreArchitectureChangeSheet.RecomputeChoice = .undecided
    @Environment(\.scenePhase) private var scenePhase

    // MARK: Launch diagnostics
    //
    // A launch hang on a tester's phone left no console hint why. The
    // launch path has many @State inits
    // (each touches CloudKit, App Group disk, BLE radios) and any one
    // of them stalling silently leaves the user staring at "Loading
    // your data" forever. These wrapped factories log entry + exit so
    // we can see exactly which step ran last when a launch hangs.
    //
    // os_log so the messages survive TestFlight (Release builds drop
    // the print() in `debugLog` but DebugLogger.shared still buffers
    // in memory; if persistent logging is on it goes to disk too).
    private static func makeLoggedDefault() -> RRCollector {
        let id = signpostStart("init.collector")
        NSLog("[App][launch] @State collector — start")
        debugLog("[App][launch] @State collector init starting", level: .info)
        let c = RRCollector.makeDefault()
        NSLog("[App][launch] @State collector — done")
        debugLog("[App][launch] @State collector init complete", level: .info)
        signpostEnd("init.collector", id)
        return c
    }
    private static func makeSyncManager() -> CloudKitSyncManager {
        let id = signpostStart("init.cloudKitSyncManager")
        NSLog("[App][launch] @State syncManager — start")
        debugLog("[App][launch] @State syncManager init starting", level: .info)
        let s = CloudKitSyncManager.shared
        NSLog("[App][launch] @State syncManager — done")
        debugLog("[App][launch] @State syncManager init complete", level: .info)
        signpostEnd("init.cloudKitSyncManager", id)
        return s
    }
    private static func makeSettingsManager() -> SettingsManager {
        let id = signpostStart("init.settingsManager")
        NSLog("[App][launch] @State settingsManager — start")
        debugLog("[App][launch] @State settingsManager init starting", level: .info)
        let s = SettingsManager.shared
        NSLog("[App][launch] @State settingsManager — done")
        debugLog("[App][launch] @State settingsManager init complete", level: .info)
        signpostEnd("init.settingsManager", id)
        return s
    }
    private static func makeStoreKitManager() -> StoreKitManager {
        let id = signpostStart("init.storeKitManager")
        NSLog("[App][launch] @State storeKitManager — start")
        debugLog("[App][launch] @State storeKitManager init starting", level: .info)
        let s = StoreKitManager.shared
        NSLog("[App][launch] @State storeKitManager — done")
        debugLog("[App][launch] @State storeKitManager init complete", level: .info)
        signpostEnd("init.storeKitManager", id)
        return s
    }
    private static func makeLanguageManager() -> LanguageManager {
        let id = signpostStart("init.languageManager")
        NSLog("[App][launch] @State languageManager — start")
        debugLog("[App][launch] @State languageManager init starting", level: .info)
        let l = LanguageManager.shared
        NSLog("[App][launch] @State languageManager — done")
        debugLog("[App][launch] @State languageManager init complete", level: .info)
        signpostEnd("init.languageManager", id)
        return l
    }
    private static func makeVoiceChat() -> VoiceConversationController {
        let id = signpostStart("init.voiceChat")
        NSLog("[App][launch] @State voiceChat — start")
        debugLog("[App][launch] @State voiceChat init starting", level: .info)
        let v = VoiceConversationController.shared
        NSLog("[App][launch] @State voiceChat — done")
        debugLog("[App][launch] @State voiceChat init complete", level: .info)
        signpostEnd("init.voiceChat", id)
        return v
    }
    private static func makeWatchBridge() -> WatchConnectivityBridge {
        let id = signpostStart("init.watchBridge")
        NSLog("[App][launch] @State watchBridge — start")
        debugLog("[App][launch] @State watchBridge init starting", level: .info)
        let w = WatchConnectivityBridge.shared
        NSLog("[App][launch] @State watchBridge — done")
        debugLog("[App][launch] @State watchBridge init complete", level: .info)
        signpostEnd("init.watchBridge", id)
        return w
    }

    init() {
        // First-line log so we have a known starting point for the
        // launch trace even when the app hangs before the body renders.
        // NSLog (vs debugLog's print) so it survives Release builds and
        // shows up in Console.app for TestFlight diagnostics.
        NSLog("[App][launch] EmuquApp.init() — entry")
        debugLog("[App][launch] EmuquApp.init() entry", level: .info)
        Self.observeMemoryWarnings()
        NSLog("[App][launch] EmuquApp.init() — exit")
        debugLog("[App][launch] EmuquApp.init() exit; the stored-property singletons are already built", level: .info)
    }

    /// Crash and system-diagnostics handlers, installed from `EmuquMain.main()`
    /// before any stored-property initialiser builds a singleton, so a crash
    /// while those load (the "hung on splash" family) still leaves a crash
    /// log for the next launch.
    ///
    /// `SystemDiagnosticsManager` wires up MetricKit plus
    /// memory/thermal sampling, so the next time iOS SIGKILLs the app we know
    /// exactly which budget was exceeded (memory pressure vs background-task
    /// assertion timeout vs CPU resource limit vs watchdog) instead of
    /// guessing. Payloads from previous terminations land here on the next
    /// launch via MXMetricManager's daily delivery.
    static func installDiagnostics() {
        CrashLogManager.shared.install()
        SystemDiagnosticsManager.shared.install()
    }

    /// Drop the DFT cache under memory pressure.
    private static func observeMemoryWarnings() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            FrequencyDomainAnalyzer.teardownDFTCache()
        }
    }

    var body: some Scene {
        WindowGroup {
            appRootView
        }
    }

    /// The app's root view, assembled in stages.
    ///
    /// ## Why this is split up
    ///
    /// This was one 455-line expression: `MainTabView(…)` followed by an
    /// unbroken chain of ten environment injections, two presentation
    /// modifiers, four `onChange` handlers, three alerts and four `task`s.
    ///
    /// Swift type-checks a member chain as a single constraint system, and the
    /// cost grows super-linearly in its length. Measured with
    /// `-warn-long-function-bodies`, this one property cost **9,766 ms** — paid
    /// by every incremental build of the app.
    ///
    /// That ceiling is not hypothetical here. Two test files had already tipped
    /// past the frontend's hard limit and failed CI with "unable to type-check
    /// this expression in reasonable time" while still compiling locally, which
    /// is the failure this shape produces once it grows a little further.
    ///
    /// Each stage below is its own statement, so the type-checker solves five
    /// small systems instead of one large one. The resulting concrete view
    /// type — and therefore SwiftUI's view identity and modifier order — is
    /// exactly what the single chain produced: `stage(x)` applies precisely the
    /// modifiers `x.…` applied, in the same order.
    private var appRootView: some View {
        let environment = environmentInjected(rootTabView)
        let presented = modalPresentations(environment)
        let observed = stateChangeHandlers(presented)
        let alerting = interruptedSessionAlerts(observed)
        return launchTasks(alerting)
    }

    /// The tab bar itself, seeded from the synchronously-loaded archive index.
    ///
    /// Always `MainTabView`, never a SwiftUI splash in front of it. A body of
    /// the form `if isLoading { splash } else { MainTabView() }` failed to
    /// swap views on a tester's iPhone 11 (iOS 18, Japanese locale): the
    /// `@State` mutation ran, but neither the splash's `onDisappear` nor the
    /// tab view's `onAppear` ever fired, and the cause was never isolated.
    /// iOS already shows the Info.plist launch image during cold launch,
    /// which is the splash from the user's perspective; the disclaimer and
    /// onboarding covers present over the tab view for new users, and the
    /// dashboard renders its own loading states for slow data.
    ///
    /// `isLoading` drives only the launch-trace logging and the safety
    /// timeout; nothing in the view tree branches on it.
    private var rootTabView: some View {
        MainTabView(
            initialSessionCount: collector.archive.entries.count,
            // Cold-start hero-score seed from the synchronously-loaded
            // index, so the ring paints the last score immediately instead
            // of blank until the async session decrypt lands.
            initialSeedScore: DashboardSessionPolicy.latestOvernightScore(
                inEntries: collector.archive.entries, calendar: .current
            ),
            // Cold-start seed for the rest of the summary (HRV/Sleep chips,
            // Recent strip) from the same synchronous index.
            initialSeedSummary: DashboardSessionPolicy.dashboardSummarySeed(
                inEntries: collector.archive.entries, today: Date(), calendar: .current
            )
        )
    }

    /// Shared objects every screen reads, plus locale and colour scheme.
    private func environmentInjected(_ content: some View) -> some View {
        content
            .environment(collector)
            .environment(collector.archiveSignal)
            .environment(collector.deviceStatus)
            .environment(collector.streamingLifecycle)
            .environment(collector.morningCoordination)
            .environment(collector.sessionState)
            .environment(syncManager)
            .environment(languageManager)
            .environment(settingsManager)
            .environment(voiceChat)
            .environment(\.locale, languageManager.currentLocale)
            .preferredColorScheme(settingsManager.settings.appearanceTheme == .light ? .light : .dark)
    }

    /// Full-screen onboarding/paywall flow and the app-level mail composer.
    private func modalPresentations(_ content: some View) -> some View {
        content
            .fullScreenCover(item: $activeModal) { launchModal($0) }
            .environment(storeKitManager)
            // App-root observer for the email bridge.
            // Lets the auto Coach Report pop the composer no
            // matter which tab is active.
            .sheet(item: $emailBridge.pendingDraft) { mailComposer(for: $0) }
    }

    /// The view behind each full-screen launch modal.
    @ViewBuilder
    private func launchModal(_ modal: LaunchModal) -> some View {
        switch modal {
        case .disclaimer:
            HealthDisclaimerView()
                .environment(settingsManager)
        case .onboarding:
            OnboardingView()
                .environment(collector)
                .environment(settingsManager)
        case .paywall:
            PaywallView(isGate: true)
        case .trialReminder:
            TrialReminderView()
                .environment(settingsManager)
        case .scoreArchitectureChange:
            ScoreArchitectureChangeSheet(
                isPresented: scoreArchitectureChangeBinding,
                recomputeChoice: $migrationRecomputeChoice
            )
            .environment(settingsManager)
        }
    }

    /// Presentation state for the score-architecture sheet.
    ///
    /// Dismissal is where the work happens, so this is a `Binding` rather than
    /// a plain `$activeModal` comparison: acknowledging the change has to be
    /// recorded whichever way the sheet closes.
    private var scoreArchitectureChangeBinding: Binding<Bool> {
        Binding(
            get: { activeModal == .scoreArchitectureChange },
            set: { isPresented in
                guard !isPresented else { return }
                settingsManager.settings.hasAcknowledgedScoreArchitectureChange = true
                activeModal = nil
                // Kick off the one-shot batch reanalyze ONLY
                // when the user explicitly chose "Recalculate now". For "Maybe
                // later" we leave `hasRunScoreHistoryRecompute` false so the
                // Settings entry remains available.
                runMigrationRecomputeIfChosen()
            }
        )
    }

    /// The mail composer the assistant's email bridge raises.
    private func mailComposer(for draft: AssistantEmailDraft) -> some View {
        MailComposerView(
            subject: draft.subject,
            body: draft.body,
            recipients: draft.recipient.map { [$0] } ?? [],
            ccRecipients: draft.ccRecipients,
            attachmentURL: draft.attachmentURL,
            onDismiss: { emailBridge.clear() }
        )
    }

    /// Reactions to state owned elsewhere: disclaimer, onboarding, purchase,
    /// and the scene phase transitions that drive sync and prewarming.
    private func stateChangeHandlers(_ content: some View) -> some View {
        content
            .onChange(of: settingsManager.hasAcceptedDisclaimer) { _, accepted in
                handleDisclaimerAcceptance(accepted)
            }
            .onChange(of: settingsManager.settings.hasCompletedOnboarding) { _, completed in
                handleOnboardingCompletion(completed)
            }
            .onChange(of: storeKitManager.isPurchased) { _, purchased in
                handlePurchaseChange(purchased)
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                handleScenePhaseChange(from: oldPhase, to: newPhase)
            }
    }

    private func handleDisclaimerAcceptance(_ accepted: Bool) {
        guard accepted else { return }
        NSLog("[App][launch] disclaimer accepted — calling loadDataAndContinue()")
        debugLog("[App][launch] disclaimer accepted — dismissing modal, calling loadDataAndContinue()", level: .info)
        // Disclaimer just accepted — dismiss it, then load data + check onboarding
        activeModal = nil
        loadDataAndContinue()
    }

    private func handleOnboardingCompletion(_ completed: Bool) {
        guard completed else { return }
        // After onboarding
        // completes, just dismiss the modal. No trial-start, no
        // purchase-refresh, no Apple sign-in.
        guard StoreKitManager.paywallEnabled, !storeKitManager.isPurchased else {
            activeModal = nil
            return
        }
        // Start the 7-day free trial for new users (see TrialPolicy.durationDays)
        settingsManager.startTrialIfNeeded()
        Task {
            await storeKitManager.refreshStatus()
            await MainActor.run { activeModal = nil }
        }
    }

    private func handlePurchaseChange(_ purchased: Bool) {
        guard StoreKitManager.paywallEnabled else { return }
        if purchased && activeModal == .paywall {
            activeModal = nil
        }
    }

    /// Everything the app does on a foreground/background transition.
    ///
    /// Each step is its own method below; they are unrelated to one another and
    /// share only a trigger.
    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        if newPhase == .background {
            autoArchivePendingSession()
            AmbientLocationService.shared.stop()
        }
        if newPhase == .active && oldPhase == .background {
            resumeSyncOnForeground()
        }
        if newPhase == .active && oldPhase != .active {
            startAmbientLocationOnForeground()
        }
        guard newPhase == .active else { return }
        rescheduleMorningNotification()
        if settingsManager.settings.hasCompletedOnboarding {
            refreshHealthKitWriteAuthorization()
        }
    }

    /// Ambient location starts at foreground, not lazily on Coach
    /// open. Beta tester report: the AI assistant had no location awareness
    /// during workouts or outside them, because the cache was never warm before
    /// he asked.
    ///
    /// The cold-launch cost this gets blamed for is the geocoder prewarm, not
    /// `startUpdatingLocation()` itself. The geocoder path now uses MKLocalSearch
    /// map tiles first (sub-second) with CLGeocoder only as fallback, and
    /// respects the cross-call 1 s rate floor. Net cost of starting the stream
    /// at foreground is the same 100 mW the workout / Get-Me-Back paths already
    /// pay — negligible. Backgrounding still tears down.
    private func startAmbientLocationOnForeground() {
        AmbientLocationService.shared.start()
    }

    /// Auto-archive a pending session when the app goes to the background, so
    /// the recording is not lost if the user forgets to accept it.
    private func autoArchivePendingSession() {
        guard collector.needsAcceptance else { return }
        Task {
            do {
                try await collector.acceptSession()
                debugLog("[App] Auto-archived pending session on background")
            } catch {
                debugLog("[App] Failed to auto-archive on background: \(error)")
            }
        }
    }

    /// Retry sync when returning to the foreground.
    ///
    /// Skipped in Low Power Mode. The user explicitly told iOS to
    /// conserve power; pulling CloudKit on every foreground transition would
    /// burn battery for housekeeping the user can trigger manually if they
    /// care.
    private func resumeSyncOnForeground() {
        guard !PowerStatePolicy.shared.shouldSkipPeriodicRefresh else { return }
        Task { await syncManager.performFullSyncIfNeeded(minInterval: 10 * 60) }
    }

    /// Plan §D11 — morning notification scheduler.
    ///
    /// Rescheduled on every foreground so the next firing's payload reflects
    /// the latest overnight reading and the user's current toggle state. Cheap
    /// (no network, no disk beyond a single archive index read), so it is safe
    /// to run on every foreground transition.
    private func rescheduleMorningNotification() {
        Task { @MainActor in
            await MorningNotificationScheduler.shared.rescheduleIfNeeded(collector: collector)
        }
    }

    /// Probe HealthKit write permissions.
    ///
    /// The single-prompt-at-onboarding model missed any write type added in a
    /// later release — `workoutType`, `activeEnergy` and `distance` all stayed
    /// `.notDetermined` for users who onboarded before those types were added
    /// to the auth set. iOS only shows the prompt for genuinely undecided
    /// types, so existing users see at most a small supplementary sheet on the
    /// next launch.
    private func refreshHealthKitWriteAuthorization() {
        Task { @MainActor in
            await collector.healthKit.ensureWriteAuthorizationFresh()
            // After (re-)granting permission, back-publish any workouts that
            // were archived locally but never reached HealthKit. Idempotent —
            // uses a per-session `healthKitExportedAt` flag to skip
            // already-published sessions. Runs in the background; the user
            // sees nothing.
            guard #available(iOS 17.0, *) else { return }
            let weight = settingsManager.settings.effectiveBodyWeightKg
            _ = await collector.healthKit.backfillWorkoutsToHealthKit(
                archive: collector.archive,
                bodyWeightKg: weight
            )
        }
    }

    /// Recovery prompts for a session that ended without being accepted.
    ///
    /// Three separate alerts rather than one with a variable button set: the
    /// resumable and non-resumable cases offer different actions and different
    /// wording, and SwiftUI cannot swap an alert's buttons while it is up.
    private func interruptedSessionAlerts(_ content: some View) -> some View {
        let resumable = resumableInterruptionAlert(content)
        let unresumable = unresumableInterruptionAlert(resumable)
        return recoveryCompleteAlert(unresumable)
    }

    /// The session can be picked back up, so offer that first.
    private func resumableInterruptionAlert(_ content: some View) -> some View {
        content.alert("Session Interrupted", isPresented: resumableInterruptionBinding) {
            Button("Resume") { resumeInterruptedSession() }
            Button("Save as Complete") { recoverInterruptedSession() }
            Button("Dismiss", role: .cancel) { dismissInterruptedSession() }
        } message: {
            if let info = interruptedSessionAlert {
                Text("Your \(info.sessionType.displayName.lowercased()) session from \(info.startTime.formatted(date: .abbreviated, time: .shortened)) was interrupted. Your data was backed up — you can resume recording or save what was captured.")
            }
        }
    }

    /// The session cannot be resumed; saving what was captured is the only
    /// thing left to offer.
    private func unresumableInterruptionAlert(_ content: some View) -> some View {
        content.alert("Session Interrupted", isPresented: unresumableInterruptionBinding) {
            Button("Save to Archive") { recoverInterruptedSession() }
            Button("Dismiss", role: .cancel) { dismissInterruptedSession() }
        } message: {
            if let info = interruptedSessionAlert {
                Text("Your \(info.sessionType.displayName.lowercased()) session from \(info.startTime.formatted(date: .abbreviated, time: .shortened)) was interrupted. Your data was backed up and can be saved to your archive.")
            }
        }
    }

    /// Reports the outcome of whichever recovery the user chose above.
    private func recoveryCompleteAlert(_ content: some View) -> some View {
        content.alert("Recovery Complete", isPresented: recoveryResultBinding) {
            Button("OK") { recoveryResultMessage = nil }
        } message: {
            if let msg = recoveryResultMessage {
                Text(msg)
            }
        }
    }

    private var resumableInterruptionBinding: Binding<Bool> {
        Binding(
            get: { interruptedSessionAlert?.isResumable == true },
            set: { if !$0 { interruptedSessionAlert = nil } }
        )
    }

    private var unresumableInterruptionBinding: Binding<Bool> {
        Binding(
            get: { interruptedSessionAlert != nil && interruptedSessionAlert?.isResumable == false },
            set: { if !$0 { interruptedSessionAlert = nil } }
        )
    }

    private var recoveryResultBinding: Binding<Bool> {
        Binding(
            get: { recoveryResultMessage != nil },
            set: { if !$0 { recoveryResultMessage = nil } }
        )
    }

    /// Work deferred until after the first frame has paint-committed.
    private func launchTasks(_ content: some View) -> some View {
        content
            .task { await runLaunchTask() }
            .task { await runPostFirstFrameSetup() }
            .task { await observeTrialPaywallRequests() }
            // Watch-initiated workout control. The Watch's
            // Start/Stop/Pause/Resume/Acknowledge gestures post these
            // notifications via WCSession → onStart/Stop/etc closures
            // wired above. The listeners USED to live on FitnessTabView,
            // which meant they only fired once the user had opened the
            // Fitness tab in the current app session — Watch gestures
            // before that point landed in NotificationCenter with no one
            // listening. Lifted to app-level here so they're always on,
            // and `RecorderBox.shared` is pre-bound at launch (next
            // Task) so the Watch's first Start gesture has a recorder
            // ready to go. FitnessTabView keeps its own copies as a
            // belt-and-braces fallback; the canStart guards make the
            // double-listener case a silent no-op.
            .task { await runWatchAndSyncWiring() }
    }

    /// Setup that must wait until the first frame is on screen.
    ///
    /// These steps are independent of one another; they are gathered here only
    /// because they share that timing constraint.
    private func runPostFirstFrameSetup() async {
        installGlobalKeyboardDismissal()
        // Cold start: kick off the deferred
        // boot() methods on the heavy singletons now that the first
        // frame has paint-committed. Each call is idempotent and
        // does the work that was previously synchronous in init.
        // Per-boot timing lives in `runDeferredBoot()` (below) — a field
        // log showed ~6.3 s of main-thread work right here on cold launch
        // with nothing instrumented, so the culprit was
        // invisible. Kept OUT of this closure to avoid tripping the
        // Swift type-checker on an already-huge `.task` body.
        runDeferredBoot()
        bootArchiveOffMain()
        prewarmSpeechVoices()
        wireWatchBridgeCallbacks()
    }

    /// Install the window-level tap recognizer that dismisses the keyboard.
    ///
    /// Global tap-outside-to-dismiss. Reported: the keyboard would
    /// not dismiss on Profile, the Reports email field, or the contact list.
    /// SwiftUI's default dismissal is unreliable; this installs a window-level
    /// tap recognizer that resigns the first responder on any tap that is NOT
    /// inside a text field. Works on every screen with no per-view modifier.
    ///
    /// 2026-08 — the keyboard prewarm is reinstated as warm-and-release (it
    /// never holds the responder slot), gated by `RemediationFlags.prewarmKeyboard`.
    ///
    /// There is no keyboard warmer. One that mounts an offscreen `UITextField`
    /// and calls `becomeFirstResponder` occupies the first-responder slot for
    /// its whole safety timeout on every launch, and on iOS 26 the keyboard
    /// daemon's cold start is fast enough that it buys nothing.
    private func installGlobalKeyboardDismissal() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            GlobalKeyboardDismissal.shared.install()
            GlobalKeyboardDismissal.shared.prewarmKeyboard()
        }
    }

    private func bootArchiveOffMain() {
        // Archive orphan reconcile + tombstone walk, run here rather
        // than in SessionArchive.init (the first @State,
        // built synchronously before first paint) so a full-directory
        // scan + per-orphan decode no longer blocks launch. Runs
        // off-main; SessionArchive is a plain class (not @MainActor).
        let archiveForBoot = collector.archive
        Task.detached(priority: .utility) { archiveForBoot.boot() }
    }

    private func prewarmSpeechVoices() {
        // Prewarm `AVSpeechSynthesisVoice.speechVoices()`
        // off-main. The first synchronous call to this API after launch
        // has been documented (WorkoutRecorder+Lifecycle.swift:529) to
        // hang ~14 s on iOS — first-time daemon IPC. Without this
        // prewarm, the user taps Start Workout and the timer doesn't
        // begin until the daemon answers. The cache wrapper hops to
        // main only for the enumeration itself; subsequent reads are
        // pure dictionary hits. We seed the user's preferred language
        // family + an English fallback so both the workout coach and
        // the assistant voice picker hit warm state.
        let prewarmLang = LanguageManager.shared.locale.identifier
        Task.detached(priority: .utility) {
            _ = await WorkoutStartCue.cachedCompactVoice(forLanguage: prewarmLang)
            if !prewarmLang.hasPrefix("en") {
                _ = await WorkoutStartCue.cachedCompactVoice(forLanguage: "en-US")
            }
        }
    }

    /// Wire every Watch → iOS trigger once, at launch.
    private func wireWatchBridgeCallbacks() {
        wireWatchVoiceChatTrigger()
        wireWatchWorkoutStartTrigger()
        wireWatchWorkoutTransportTriggers()
    }

    /// Uses the shared controllers so the closure reaches the same instance
    /// every surface (Fitness view, Assistant tab) talks to. `toggle()` is used
    /// instead of `start()` so a second tap on the Watch can also end the
    /// conversation.
    private func wireWatchVoiceChatTrigger() {
        watchBridge.onStartVoiceChatFromWatch = {
            Task { @MainActor in voiceChat.toggle() }
        }
    }

    /// When the user taps Start on the wrist, iOS wakes (if suspended, not
    /// force-quit), delivers the message, and we post a notification so the
    /// Fitness tab — which owns the `WorkoutRecorder` — can begin the session.
    /// The Watch expects the Fitness tab and its recorder to exist, so the
    /// request is surfaced as an event rather than by instantiating a second
    /// recorder here (there can only be one per app launch by design). The
    /// sport string comes from the Watch UI as `Sport.rawValue`.
    ///
    /// The return value is the error string shown back on the Watch (nil =
    /// success). We optimistically return nil when the Sport string parses —
    /// the actual start runs asynchronously on the Fitness tab and any throw
    /// there is surfaced to the phone UI; a future iteration could pass the
    /// real result back by hanging a completion off the notification.
    private func wireWatchWorkoutStartTrigger() {
        watchBridge.onStartWorkoutFromWatch = { sportRaw, targetZone in
            guard Sport(rawValue: sportRaw) != nil else {
                return "Unknown sport: \(sportRaw)"
            }
            var userInfo: [AnyHashable: Any] = ["sport": sportRaw]
            if let targetZone { userInfo["targetZone"] = targetZone }
            NotificationCenter.default.post(
                name: .watchRequestedWorkoutStart,
                object: nil,
                userInfo: userInfo
            )
            return nil
        }
    }

    /// Stop, pause, resume and acknowledge-finished all forward straight to
    /// the notification the Fitness tab listens on.
    private func wireWatchWorkoutTransportTriggers() {
        watchBridge.onStopWorkoutFromWatch = { postWatchTransport(.watchRequestedWorkoutStop) }
        watchBridge.onPauseWorkoutFromWatch = { postWatchTransport(.watchRequestedWorkoutPause) }
        watchBridge.onResumeWorkoutFromWatch = { postWatchTransport(.watchRequestedWorkoutResume) }
        watchBridge.onAcknowledgeFinishedFromWatch = { postWatchTransport(.watchAcknowledgedFinished) }
    }

    /// Forward one Watch transport gesture to the Fitness tab.
    ///
    /// The `String?` return is the error message shown back on the Watch.
    /// Posting a notification cannot fail, so it is always nil — the four
    /// transport gestures differ only in which name they post.
    private func postWatchTransport(_ name: Notification.Name) -> String? {
        NotificationCenter.default.post(name: name, object: nil)
        return nil
    }

    /// Show the paywall when the trial reminder's "Unlock Now" is tapped.
    private func observeTrialPaywallRequests() async {
        // Listen for trial reminder "Unlock Now" → show paywall
        for await _ in NotificationCenter.default.notifications(named: .showPaywallFromTrial).map({ _ in () }) {
            // Brief delay so fullScreenCover dismissal finishes first
            try? await Task.sleep(nanoseconds: 400_000_000)
            activeModal = .paywall
        }
    }

    /// Bind the recorder and push settings to iCloud, off the launch path,
    /// then install the app-level Watch workout listeners.
    private func runWatchAndSyncWiring() async {
        prebindWorkoutRecorder()
        pushSettingsToCloudAfterLaunch()
        // No strap-state mirror to the Watch: the Polar SDK's
        // `deviceDisconnected` fires late or not at all when a chest
        // strap leaves the body, so a mirrored pill shows "Connected"
        // after the strap is off. The Watch owns its own BLE link via
        // `WatchStrapConnector`, which sees disconnects in real time.
        await runAppLevelWatchWorkoutListeners()
    }

    /// Pre-bind the recorder in the background. `WorkoutRecorder.init` is heavy
    /// (BLE, audio session, threshold engine) — running it off the launch
    /// critical path means the Watch's first Start gesture is instant.
    private func prebindWorkoutRecorder() {
        Task { @MainActor in
            RecorderBox.shared.bind(core: collector, conversation: voiceChat)
        }
    }

    /// Push the user's settings to iCloud on launch so the cloud
    /// copy stays current even if the user only edits settings on a single
    /// device per session. Backed up so a crash that wipes the local file (the
    /// bug fixed in this same change set) can be recovered from
    /// Settings → Diagnostics → "Restore from iCloud".
    ///
    /// Pauses briefly first so the launch critical path is not contending with
    /// CloudKit setup; the push itself is fire-and-forget after that.
    private func pushSettingsToCloudAfterLaunch() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await CloudKitSettingsSync.shared.pushImmediately()
        }
    }
}

/// The process entry point. The UI-test fresh-install wipe and the crash
/// handlers must run before any stored-property initialiser of `EmuquApp`
/// builds a singleton that reads the settings file (the collector's default
/// arguments do exactly that), so they live here rather than in
/// `EmuquApp.init`, which runs after them.
@main
enum EmuquMain {
    static func main() {
        MainActor.assumeIsolated {
            EmuquApp.resetUITestStateIfRequested()
            EmuquApp.installDiagnostics()
        }
        EmuquApp.main()
    }
}
