import CoreMotion
import Foundation
import UIKit

// `start()` and its helpers. The state it resets lives in the recorder's
// owned pieces; pause and resume live in `WorkoutPauseControl`.

extension WorkoutSessionLifecycle {
    // MARK: - Public control

    /// Which heart-rate source drives this workout.
    ///
    /// **Strap** (Polar H10 / Verity Sense): beat-to-beat RR intervals. Enables
    ///   every HRV-grade metric (RMSSD, SDNN, pNN50, DFA α1, LF/HF, Pa:Hr
    ///   decoupling at precision). This is the *canonical* source and the
    ///   default when a strap is connected.
    ///
    /// **Apple Watch**: 1 Hz wrist HR via HKWorkoutSession. Apple Watch
    ///   Series 4+ optical HR is clinically validated for workout HR within
    ///   ±5 bpm under good skin contact. Gets you HR, zones, calories,
    ///   workout log, HRR — **but not HRV**, because there's no RR stream.
    ///   If the user picks this and asks for DFA α1 later, the app shows
    ///   "not available — requires chest strap."
    ///
    /// **None**: track-only (time, distance, GPS, cadence, steps). No HR
    ///   data. Useful for quick walks where the user hasn't put a strap on
    ///   and doesn't care about HR.
    enum HRSource: String, Equatable {
        case strap
        case watch
        case none
    }

    /// Start a workout session with an explicit HR source.
    /// - `strap`: requires a connected, not-already-busy Polar strap.
    /// - `watch`: starts the Watch's HKWorkoutSession as the primary; no
    ///   strap needed.
    /// - `none`: no HR at all; pure motion tracking.
    /// - `intervalPlan`: optional structured plan. When provided, the recorder
    ///   drives an `IntervalController` that advances through each step by
    ///   time/distance and announces transitions via the voice coach.
    ///
    /// Per-step diagnostic logs make a hang during start() pinpointable from
    /// the debug log. start() does a lot synchronously on the
    /// main thread (Polar streaming start, BLE peripheral broadcaster, GPS,
    /// pedometer, foot-pod reconnect, disk write). Without an entry
    /// log before the first observable side effect, a hang shows up as a long
    /// stretch of silence with no entry point.
    ///
    /// The correlation scope spans the whole workout, from this entry to
    /// `stop()`. It deliberately uses begin/end rather than the scoped helper:
    /// the interesting lines are emitted long after `start()` returns, from BLE
    /// delegate callbacks, GPS updates, and pedometer ticks that are not
    /// children of this call. `start()` can throw after the scope opens — an
    /// idle-guard bail, or a source that will not resolve — and a leaked scope
    /// would then tag every later line in the process with a workout that never
    /// began, so the scope is closed on any exit that is not a successful start.
    func start(
        sport: Sport,
        source: HRSource = .strap,
        intervalPlan: IntervalPlan? = nil,
        thresholds: [WorkoutThreshold] = [],
        route: Route? = nil
    ) throws {
        services.workoutStartLatencyTracker.recordStartEntry()
        lifecycle.beginWorkoutCorrelation()
        var startCompleted = false
        defer { if !startCompleted { abandonFailedStart() } }
        debugLog("[Recorder.start] entry sport=\(sport.rawValue) source=\(source.rawValue) hasPlan=\(intervalPlan != nil) thresholds=\(thresholds.count) hasRoute=\(route != nil)")
        var stamps = StartStamps()
        try guardStartablePhase()
        let effectiveSource = try resolveEffectiveSource(requested: source)
        stamps.mark("preflight")
        let session = Self.makeStartingSession(sport: sport, provenance: makeStartProvenance(effectiveSource: effectiveSource))
        stamps.mark("session")
        try beginPolarStreamingOrDefer(effectiveSource: effectiveSource, workoutId: session.id)
        applyStartParameters(thresholds: thresholds, route: route)
        stamps.mark("polarStream")
        bringUpRecording(session: session, sport: sport, effectiveSource: effectiveSource, intervalPlan: intervalPlan, stamps: &stamps)
        debugLog("[Recorder.start] sync-breakdown " + stamps.breakdown())
        services.workoutStartLatencyTracker.recordStartReturned()
        startCompleted = true
    }

    /// A start that threw: close its correlation scope and drop its latency
    /// stamps, so neither tags nor measures a later start.
    private func abandonFailedStart() {
        lifecycle.endWorkoutCorrelation()
        services.workoutStartLatencyTracker.recordStartAbandoned()
    }

    /// Per-block timing inside the synchronous body of `start()`, so a
    /// multi-second start shows exactly which block ate the time instead of
    /// leaving it to be inferred from the spacing of per-step debugLog calls.
    struct StartStamps {
        private let t0 = Date()
        private var marks: [(name: String, at: Date)] = []

        mutating func mark(_ name: String) { marks.append((name, Date())) }

        /// `"preflight=12ms session=3ms … TOTAL=…"` — each span measured from
        /// the previous mark, plus the wall-clock total.
        func breakdown() -> String {
            var parts: [String] = []
            var prev = t0
            for mark in marks {
                parts.append("\(mark.name)=\(Self.ms(prev, mark.at))ms")
                prev = mark.at
            }
            parts.append("TOTAL=\(Self.ms(t0, prev))ms")
            return parts.joined(separator: " ")
        }

        private static func ms(_ a: Date, _ b: Date) -> Int { Int(b.timeIntervalSince(a) * 1000) }
    }

    private static func makeStartingSession(sport: Sport, provenance: DeviceProvenance?) -> HRVSession {
        var session = HRVSession(
            startDate: Date(),
            tags: [],
            sessionType: .workout,
            deviceProvenance: provenance
        )
        session.workoutMetadata = WorkoutMetadata(sport: sport)
        return session
    }

    /// Everything after the Polar stream starts: per-workout state, the phase
    /// flip, HR observation, and the deferred (off-main / next-runloop) work.
    private func bringUpRecording(
        session: HRVSession,
        sport: Sport,
        effectiveSource: HRSource,
        intervalPlan: IntervalPlan?,
        stamps: inout StartStamps
    ) {
        resetPerWorkoutState(session: session, startDate: session.startDate, effectiveSource: effectiveSource)
        installAIContextProviders()
        stamps.mark("resets+providers")
        flipPhaseToRecordingWithProbes()
        stamps.mark("phaseFlip")
        // HR subscription sits immediately after `lifecycle.phase = .recording`
        // so it survives slow cold-start work. For watch / none sources the Polar publisher has no
        // data anyway; `currentHR` is driven from the Watch bridge in the tick
        // loop.
        wireEarlyHRObservationAndStampAnnounce(effectiveSource: effectiveSource)
        stamps.mark("observeHR")
        queueStartAnnouncement(sport: sport)
        stamps.mark("announceQueue")
        deferZwiftBroadcastAndGeocodingReset()
        stamps.mark("geocodingReset")
        launchDeferredStartWork(session: session, sport: sport, intervalPlan: intervalPlan)
        stamps.mark("tail")
    }

    private func launchDeferredStartWork(session: HRVSession, sport: Sport, intervalPlan: IntervalPlan?) {
        resetCachedBaselinesAndLaunchBaselineTask(sport: sport)
        deferLocationTrackingStart(sport: sport)
        requestMotionAccessIfUndetermined(sport: sport)
        deferPedometerStart(sport: sport)
        reconnectOrDisconnectSecondarySensors(sport: sport)
        persistRecordingStateOffMain(session: session, startDate: session.startDate, sport: sport)
        launchStartTailTask(sport: sport, startDate: session.startDate, intervalPlan: intervalPlan)
    }

    /// start() — phase guard (first slice of the sync-breakdown `preflight` span).
    /// A second start while a workout records or finalizes (a Watch Start, a
    /// double tap) is refused. `.finished` and `.failed` mean the last
    /// workout's summary or error is still up; a start from a surface that
    /// does not dismiss it first (the Watch's Start, which
    /// `AppLaunchTasks.startWorkoutFromWatch` lets through) goes ahead, and
    /// `applyStartParameters` clears the old summary once the start can no
    /// longer fail.
    func guardStartablePhase() throws {
        switch lifecycle.phase {
        case .idle, .finished, .failed:
            return
        case .recording, .finalizing:
            debugLog("[Recorder.start] BAIL — already recording (phase=\(lifecycle.phase))", level: .warning)
            throw WorkoutRecorderError.alreadyRecording
        }
    }

    /// start() — parameter capture, after every step that can throw, so a
    /// refused start (busy strap, a Polar throw) leaves the recorder's
    /// thresholds, route and last summary as they were.
    func applyStartParameters(thresholds: [WorkoutThreshold], route: Route?) {
        lifecycle.finishedSession = nil
        lifecycle.saveOutcome = nil
        coaching.thresholds = WorkoutThresholdWatch(thresholds: thresholds)
        routeGuidance.planned = route
        routeGuidance.savedRouteId = nil
        routeGuidance.wasAutoDetected = false
        routeGuidance.nextDetectionAtMeters = 0
        routeGuidance.places.reset()
        coaching.gradeMemo = nil
    }

    /// start() — source-conditional pre-flight + strap downgrade cascade (sync-breakdown `preflight` span).
    ///
    /// Only the strap path checks Polar — watch / none users don't need the
    /// strap connected and shouldn't be blocked on it. Watch-only sessions
    /// capture no RR, so HRV-grade metrics (RMSSD, SDNN, DFA α1, LF/HF) won't
    /// be computed; the UI warns the user of this before `start()`.
    ///
    /// For `.strap`: if the strap dropped out between the user tapping the
    /// start button on the ready screen and this `start()` running (BLE
    /// disconnect, app backgrounded briefly, strap fell off), we downgrade
    /// rather than throw. The user expected to start a workout — failing the
    /// start with "Not connected" after they JUST saw "ready to start with
    /// strap connected" is confusing. Downgrading lets the
    /// workout proceed and the post-summary notes the missing HR source.
    func resolveEffectiveSource(requested source: HRSource) throws -> HRSource {
        guard source == .strap else { return source }
        try stopOwnStaleStreamOrRefuse()
        // The cascade itself lives in `WorkoutHRSourceResolver` — pure, and
        // tested. Everything below is the side effects it decided on.
        let resolution = currentSourceResolution(requested: source)
        WorkoutHRSourceResolver.log(resolution)
        // The source to record comes from the resolver too; nil is a busy strap.
        guard let resolved = WorkoutHRSourceResolver.provenanceSource(for: resolution) else {
            throw WorkoutRecorderError.strapBusy
        }
        if case .reconnectThenUseStrap = resolution {
            core.strapDiscovery.connectToLastDevice()
        }
        return resolved
    }

    /// Reads what is actually attached right now and asks the resolver. The
    /// live reads are here; the decision they feed is pure and tested.
    private func currentSourceResolution(requested source: HRSource) -> WorkoutHRSourceResolver.Resolution {
        WorkoutHRSourceResolver.resolve(
            requested: source,
            strapIsRecordingOnDevice: core.strapRecording.isRecordingOnDevice,
            strapIsConnected: core.strapLink.connectionState == .connected,
            hasKnownDevices: !core.strapPairings.knownDevices.isEmpty,
            isWatchPaired: services.watchConnectivityBridge.isWatchPaired
        )
    }

    /// A live Polar stream while no workout records is either this recorder's
    /// own lingering post-workout stream (the HRR capture keeps it open up to
    /// 120 s) or another session's: RRCollector's overnight and quick
    /// streaming buffer on the same manager, and a Verity Sense overnight, an
    /// overnight without the strap's internal backup, or a quick reading is
    /// not `isRecordingOnDevice`, so the resolver does not see it. Our own
    /// stream (the start stamp this recorder took) is stopped inline so the
    /// user is not bounced; this catches starts that skip the summary's
    /// `acknowledgeFinished` (the Watch's Start, or Start before the summary
    /// has rendered). Any other stream refuses the start with `strapBusy`
    /// rather than discard that session's buffered beats.
    private func stopOwnStaleStreamOrRefuse() throws {
        let stream = core.strapStream
        guard stream.isStreaming else { return }
        guard let ownStart = lifecycle.ownedStrapStreamStart, stream.streamingStartTime == ownStart else {
            debugLog("[Recorder.start] BAIL — the strap is buffering for another session", level: .warning)
            throw WorkoutRecorderError.strapBusy
        }
        debugLog("[Recorder.start] stale Polar stream detected with recorder idle — stopping inline before new session")
        _ = stream.stopStreaming()
    }

    /// start() — device-provenance construction from the post-downgrade source (sync-breakdown `session` span).
    ///
    /// Provenance reflects the chosen source so downstream analysis (and
    /// the post-summary) knows which fields are trustworthy. Use the
    /// post-downgrade `effectiveSource` so a strap-was-requested-but-
    /// disconnected workout records as `.none` and the analyzer doesn't
    /// expect HRV-grade data that was never captured.
    func makeStartProvenance(effectiveSource: HRSource) -> DeviceProvenance {
        let identity: (id: String, model: String)
        switch effectiveSource {
        case .strap:
            identity = (
                core.strapLink.connectedDeviceId ?? "unknown",
                core.strapLink.connectedDeviceType?.displayName ?? "Polar device"
            )
        case .watch:
            identity = ("apple-watch", "Apple Watch")
        case .none:
            identity = ("none", "No HR Source")
        }
        return DeviceProvenance.current(
            deviceId: identity.id,
            deviceModel: identity.model,
            firmwareVersion: nil,
            recordingMode: .streaming
        )
    }

    /// start() — owns `step=polar.startStreaming` (sync-breakdown `polarStream` span).
    ///
    /// Strap-only: start buffering the strap's beats. Watch / none don't need it.
    ///
    /// This never waits for the strap. Buffering starts whether or not the
    /// strap is linked yet — `resolveEffectiveSource` has already asked a
    /// disconnected strap to reconnect — and the link delivers beats as soon as
    /// the strap is ready. If it never comes, the tick's `HRArbitration` tells
    /// the user why there is no heart rate; the workout is never blocked.
    func beginPolarStreamingOrDefer(effectiveSource: HRSource, workoutId: UUID) throws {
        lifecycle.strapNotice = nil
        guard effectiveSource == .strap else { return }
        debugLog("[Recorder.start] step=polar.startStreaming (link: \(core.strapLink.connectionState))")
        try core.strapStream.startStreaming()
        lifecycle.ownedStrapStreamStart = core.strapStream.streamingStartTime
        debugLog("[Recorder.start] step=polar.startStreaming done")
        startDeviceInternalBackupIfPossible(workoutId: workoutId)
    }

    /// start() — per-workout state resets (sync-breakdown `resets+providers` span).
    func resetPerWorkoutState(session: HRVSession, startDate: Date, effectiveSource: HRSource) {
        lifecycle.activeHRSource = effectiveSource

        lifecycle.currentSession = session
        lifecycle.sessionStartDate = startDate
        capture.collectedPoints = []
        resetClockAndPauseState()
        workoutHR.reset()
        capture.lastIngestedPointCount = 0
        capture.workoutSamples = []
        signals.livePace.reset()
        sensors.footPodOdometer = FootPodOdometer()
        capture.power = WorkoutPowerTally()
        capture.distanceAtEarlyStop = nil
        motion.powerWatts = nil
        motion.footPodActive = false
        signals.lastStrapHRAt = nil
        dfa.reset(sessionStart: startDate)
        voiceCoach.reset()
    }

    /// The pause flags too: a workout stopped while paused left them set, and
    /// the next one started paused, its clock frozen.
    private func resetClockAndPauseState() {
        lifecycle.elapsedSeconds = 0
        lifecycle.isPaused = false
        lifecycle.autoPaused = false
        lifecycle.pausedMotion = PausedMotionLedger()
        lifecycle.pauseTimeline = PauseTimeline()
        lifecycle.deviceBackupArmedAt = nil
        lifecycle.liveSnapshotAtStop = nil
        // A workout that ended standing still must not carry its stationary
        // count into this one and auto-pause on the first still tick.
        pauseControl.autoPause.reset()
    }

    /// start() — installs the AI snapshot/samples providers (sync-breakdown `resets+providers` span).
    func installAIContextProviders() {
        installConversationContextProviders()
        installLiveWorkoutSamplesProvider()
    }

    /// Hand the conversation controller a closure that returns the current
    /// factual workout snapshot on each turn. This is what lets the AI
    /// answer "what's my HR?" with the real value rather than guessing.
    ///
    /// Also exposes the structured snapshot for the
    /// pre-speech hallucination guard. MetricsVerifier
    /// uses this to cross-check numeric claims against authoritative
    /// values before TTS speaks the line.
    private func installConversationContextProviders() {
        conversation.contextSnapshotProvider = { [weak self] in
            guard let self, let sport = lifecycle.currentSession?.sport else { return nil }
            return aiContext.buildContext(sport: sport).asFactSheet()
        }
        conversation.liveWorkoutSnapshotProvider = { [weak self] in
            guard let self, let sport = lifecycle.currentSession?.sport else { return nil }
            return aiContext.buildContext(sport: sport)
        }
    }

    /// Registers a samples provider with
    /// the broker so the AI's `workout.live.timeline` tool can pull
    /// recent correlated HR / elevation / pace / power samples on
    /// demand without us shipping the buffer through the broker every
    /// tick. `capture.workoutSamples` is @MainActor-isolated and the broker
    /// may be asked from any thread (the fact resolver and the system-prompt
    /// builder), so the buffer is read only on the main thread; a caller on
    /// another thread gets no samples instead of an isolation trap. Cleared
    /// at stop via broker.clear().
    private func installLiveWorkoutSamplesProvider() {
        services.liveWorkoutBroker.registerSamplesProvider { [weak capture] in
            guard Thread.isMainThread else { return [] }
            return MainActor.assumeIsolated {
                capture?.workoutSamples ?? []
            }
        }
    }

    /// start() — owns `step=phase=.recording` and the probe-pre / probe-post main-actor latency probes (sync-breakdown `phaseFlip` span).
    ///
    /// Main-actor responsiveness probes. Every observable side effect of
    /// start() runs off the synchronous path, yet user debug logs have shown
    /// the queued Tasks not running for
    /// ~2.9 s after start() returned. SwiftUI's render of
    /// FitnessRecordingView is the prime suspect (heavy view body, 8
    /// ObservedObjects). These probes time-stamp BEFORE phase=.recording
    /// and AFTER phase=.recording so the debug log shows
    ///   (a) baseline main-actor latency (probe-pre)  and
    ///   (b) the post-phase render gap (probe-post).
    /// If (b) is multi-second while (a) is sub-100 ms, the view body is
    /// the cause and we have a concrete number to target.
    func flipPhaseToRecordingWithProbes() {
        Self.probeMainActorLatency(label: "probe-pre")
        lifecycle.phase = .recording
        debugLog("[Recorder.start] step=phase=.recording")
        services.workoutStartLatencyTracker.recordPhaseFlip()
        Self.probeMainActorLatency(label: "probe-post (after phase=.recording)")
    }

    /// Stamp now, then log how long the main actor took to get around to the
    /// queued Task. Scheduled synchronously so the stamp reflects the caller's
    /// position in start(), not the Task's.
    private static func probeMainActorLatency(label: String) {
        let scheduledAt = Date()
        Task { @MainActor in
            let ms = Int(Date().timeIntervalSince(scheduledAt) * 1000)
            debugLog("[Recorder.start] \(label) fired after \(ms)ms")
        }
    }

    /// start() — early HR subscription + announce stamp (sync-breakdown `observeHR` span).
    ///
    /// When the announce Task and HR subscription are queued from late in
    /// start(), AFTER 300+ lines of synchronous cold-start work (BLE
    /// reconnects, CLLocation setup, AVAudioSession activation, disk write), a
    /// cold first start keeps the main thread busy long enough that the
    /// announce Task can't run: no "started" voice and no HR, and the user
    /// perceives nothing happening. Both are wired up immediately after the
    /// phase flip so they survive whatever slowdown follows.
    ///
    /// `effectiveSource` (post-downgrade) is used, not the caller-supplied
    /// `source`. If the strap dropped between the ready screen and `start()`,
    /// `effectiveSource` is `.watch`/`.none` and the Polar publisher has no
    /// data — subscribing here would wire a sink to a dead publisher, a real
    /// cause of "no HR despite the UI saying recording."
    ///
    /// The announce path is not called inline here. Inline, it can stall
    /// start() for seconds: `AVSpeechSynthesisVoice.speechVoices()` IPC can
    /// stall after an audio-session interruption, and first-use Taptic Engine
    /// spin-up via a fresh `UINotificationFeedbackGenerator()` adds to it.
    /// Both are mitigated upstream
    /// (voice is cached via `_voiceCacheLookup`; haptic generators are
    /// pre-warmed at app launch), and announce itself is hopped into a
    /// `Task { @MainActor }` by `queueStartAnnouncement`. `recordAnnounceFire`
    /// stays stamped synchronously so the tap-to-voice metric remains
    /// comparable to historical logs.
    func wireEarlyHRObservationAndStampAnnounce(effectiveSource: HRSource) {
        if effectiveSource == .strap {
            ticker.observeHeartRate()
        }
        services.workoutStartLatencyTracker.recordAnnounceFire()
    }

    /// start() — queues the announceStart Task (sync-breakdown `announceQueue` span).
    func queueStartAnnouncement(sport: Sport) {
        // When this Task fires tells us whether MainActor
        // was free or contended after phase=.recording. A "1 minute"
        // start would show this Task delayed N seconds, naming the cause.
        let _announceScheduledAt = Date()
        Task { @MainActor [services] in
            let delayMs = Int(Date().timeIntervalSince(_announceScheduledAt) * 1000)
            if delayMs > 250 {
                debugLog("[Recorder.start] ⚠️ announceStart Task delayed \(delayMs)ms after schedule — MainActor was contended", level: .warning)
            }
            WorkoutStartCue.announceStart(sport: sport, audio: services.backgroundAudioManager)
        }
    }

    /// start() — owns `step=zwiftBroadcaster.start (deferred)` and the deferred geocoding reset (sync-breakdown `geocodingReset` span).
    func deferZwiftBroadcastAndGeocodingReset() {
        deferZwiftBroadcast()
        deferGeocodingReset(services.roadGeocodingService)
    }

    /// Start advertising HR + power as a BLE peripheral if the user opted in.
    /// Per-tick updates are pushed from `incrementalBackupTick`; here we only
    /// flip on the advertisement so trainer apps can pair the moment the
    /// workout begins.
    ///
    /// Deferred because `CBPeripheralManager.startAdvertising`
    /// blocks on first call when the BLE radio is cold-starting (post-reboot,
    /// post-Airplane-mode toggle, or after an iOS Bluetooth daemon recycle).
    /// Zwift pairing isn't needed in the first second of the workout — deferred
    /// so it can't block the start path even when the radio is wedged. A
    /// workout stopped before the deferred task runs has already stopped the
    /// broadcast, so the task re-checks that the workout is still recording.
    ///
    /// The setting alone is not enough: it comes back from the iCloud settings
    /// backup on a new device, where the disclosure was never shown. Only a
    /// device that accepted it (`BroadcasterDisclosure`) broadcasts.
    private func deferZwiftBroadcast() {
        guard BroadcasterDisclosure.allowsBroadcast(settingEnabled: settingsProvider().enableZwiftBroadcast) else { return }
        debugLog("[Recorder.start] step=zwiftBroadcaster.start (deferred)")
        Task { @MainActor [weak self] in
            guard let self, case .recording = lifecycle.phase else { return }
            let t0 = Date()
            services.zwiftPeripheralBroadcaster.startBroadcasting()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            debugLog("[Recorder.start] step=zwiftBroadcaster.start deferred done (\(ms)ms)")
        }
    }

    /// start() — owns `step=sensors.location.startTracking (deferred)` (sync-breakdown `tail` span).
    ///
    /// Deferred by exactly one run-loop hop, and no further. A deferral that
    /// waits until SwiftUI has finished mounting `FitnessRecordingView`
    /// defends against one rare iOS-26 race where CLLocationManager setters
    /// hung for 17 s on the main thread after a BLE power-cycle, but it makes
    /// EVERY workout wait ~11–12 s before GPS begins tracking: a rare hang
    /// avoided at the cost of a GPS delay on every workout. The
    /// fine-grained `step=1…8` logs inside `startTracking()` pinpoint any
    /// hang at exactly the setter that blocks.
    ///
    /// The one hop exists because inline,
    /// `sensors.location.startTracking` can take about 3 s on a walk start,
    /// main-thread block between the user's tap and the recording UI that
    /// makes the workout feel slow to start. `CLLocationManager.startUpdatingLocation` is
    /// documented as non-blocking, but its first call after an authorization
    /// change / cold start synchronously prompts CoreLocation to negotiate
    /// accuracy + delivery cadence with locationd, which is what eats the 3 s.
    /// The first location fix doesn't arrive for ~5-15 s anyway, so a one-hop
    /// deferral loses no data — it just unblocks the user-tap path.
    /// `lifecycle.phase` is already `.recording`, so the UI renders immediately and
    /// the GPS metrics tile fills in whenever the first fix lands.
    ///
    /// The hop re-checks that the workout is still recording (a stop in
    /// between has already called `stopTracking`), and re-applies a pause
    /// taken in between, since `startTracking` starts unpaused.
    func deferLocationTrackingStart(sport: Sport) {
        guard sport.usesGPS else { return }
        debugLog("[Recorder.start] step=location.startTracking (deferred)")
        Task { @MainActor [weak self] in
            guard let self, case .recording = lifecycle.phase else { return }
            let lt0 = Date()
            sensors.location.startTracking()
            sensors.location.isPaused = lifecycle.isPaused
            let ltMs = Int(Date().timeIntervalSince(lt0) * 1000)
            debugLog("[Recorder.start] step=location.startTracking deferred done (\(ltMs)ms)")
        }
    }

    /// Holds the one-off query below until CoreMotion answers it.
    private static let motionAccessProbe = CMPedometer()

    /// Ask for Motion & Fitness access when the workout starts, so iOS shows
    /// its prompt on the recording screen rather than later (otherwise it
    /// first appears over the Workout Summary). An empty pedometer query is what
    /// raises the prompt: CoreMotion has no explicit request call. Only for
    /// sports that use motion data — the pedometer sports and GPS sports,
    /// whose elevation comes from the barometer — and only while the answer
    /// is still undetermined. Deferred like the pedometer start: the query is
    /// an XPC round trip to coremotion.
    func requestMotionAccessIfUndetermined(sport: Sport) {
        guard Self.pedometerSports.contains(sport) || sport.usesGPS,
              CMPedometer.authorizationStatus() == .notDetermined,
              CMPedometer.isStepCountingAvailable() else { return }
        Task { @MainActor in
            let now = Date()
            Self.motionAccessProbe.queryPedometerData(from: now, to: now) { @Sendable _, _ in }
        }
    }

    /// Sports whose distance and cadence come from the pedometer.
    static let pedometerSports: Set<Sport> = [.walk, .run, .trailRun, .hike, .treadmill]

    /// start() — owns `step=sensors.pedometer.start (deferred)` (sync-breakdown `tail` span).
    ///
    /// Pedometer runs for every motion-based sport. CMPedometer works
    /// indoors (no GPS) and is the source of truth for walk/run distance
    /// when GPS is unavailable or unreliable.
    ///
    /// Deferred as belt-and-braces.
    /// Even though pedometer.start logs ~2 ms,
    /// CMPedometer.startUpdates makes
    /// an XPC roundtrip to coremotion under the hood and that has
    /// been observed to stall when the motion subsystem is contended
    /// (post-app-launch, post-Watch-handoff). Belt-and-braces — the
    /// first pedometer sample doesn't arrive for ~1 s anyway, so
    /// moving the call off the sync path costs nothing if it's fast
    /// and saves us if it's slow. Like the GPS start, the hop does nothing
    /// once the workout has stopped.
    func deferPedometerStart(sport: Sport) {
        guard Self.pedometerSports.contains(sport) else { return }
        debugLog("[Recorder.start] step=pedometer.start (deferred)")
        Task { @MainActor [weak self] in
            guard let self, case .recording = lifecycle.phase else { return }
            let pt0 = Date()
            sensors.pedometer.start()
            let ptMs = Int(Date().timeIntervalSince(pt0) * 1000)
            debugLog("[Recorder.start] step=pedometer.start deferred done (\(ptMs)ms)")
            if ptMs > 100 {
                debugLog("[Recorder.start] ⚠️ pedometer.start exceeded 100ms threshold", level: .warning)
            }
        }
    }

    /// start() — owns `step=footpod.reconnect` / `step=footpod.disconnect` / `step=concept2.reconnectLast` (sync-breakdown `tail` span).
    ///
    /// Auto-reconnect previously-paired secondary sensors at workout start.
    /// Without this, the foot pod / FTMS bike trainer / PM5 rower stay
    /// disconnected even when the user paired them previously — they'd have to
    /// dig through Settings every time. Fire-and-forget per device: the connect
    /// callback updates the manager's published state, which feeds the live
    /// snapshot. If the device isn't in range / dead battery, the manager
    /// simply stays disconnected and the workout proceeds without it.
    ///
    /// Same deferral pattern as location/pedometer. Foot-pod and
    /// Concept2 reconnects are synchronous CoreBluetooth calls that can stall
    /// the main thread on cold-start, which can leave the first start with no
    /// voice and no HR. The reconnect doesn't need to finish before
    /// `start()` returns — the manager publishes state when the device comes
    /// online.
    ///
    /// Scope: the rower, and the foot-pod manager — which is also the reader
    /// for Cycling Power (0x1818) and FTMS Indoor Bike Data (0x2AD2), so a
    /// power-capable trainer (KICKR, Tacx Neo, Zwift Hub) is kept and
    /// reconnected for `.bike` / `.indoorBike` (see `manageFootPod`).
    func reconnectOrDisconnectSecondarySensors(sport: Sport) {
        manageFootPod(for: sport, pod: services.footPodManager)
        services.concept2Manager.holdLinkForWorkout(sport == .row)
        guard sport == .row,
              !services.concept2Manager.knownDevices.isEmpty,
              services.concept2Manager.connectionState == .disconnected
        else { return }
        debugLog("[Recorder.start] step=concept2.reconnectLast (deferred)")
        let concept2 = services.concept2Manager
        Task { @MainActor in
            concept2.reconnectLast()
            debugLog("[Recorder.start] step=concept2.reconnectLast done")
        }
    }

    /// start() — off-main PersistedRecordingState save for crash recovery (sync-breakdown `tail` span).
    ///
    /// Persist recording state so a crash / force-quit / iOS kill can be
    /// recovered on next launch via SessionRecoveryService. The raw RR
    /// points written by incrementalBackupTick (below) are the actual
    /// recovery source; this record just tells the recovery service
    /// "hey, there's a workout that didn't finish cleanly".
    ///
    /// Runs off-main. `UserDefaults.standard.set` is
    /// documented as fast but in practice IPCs into `cfprefsd` and CAN
    /// stall the calling thread for seconds under daemon contention.
    /// Persistence completes within ~50 ms
    /// of phase=.recording on the background queue, which is fine for
    /// crash recovery (we only need the record on disk before iOS
    /// SIGKILLs, not synchronously in the start path).
    ///
    /// The save and the archive's clear (`retireRedundantBackups`) run in
    /// order on `recordingStateQueue`, so a slow save can never land after
    /// the clear and leave a record for a workout already in history. The
    /// key is shared with RRCollector's overnight and quick recordings, which
    /// a `.watch` or `.none` workout can run beside: their record is left in
    /// place, not overwritten, and this workout's raw backup stays
    /// recoverable without it.
    func persistRecordingStateOffMain(session: HRVSession, startDate: Date, sport: Sport) {
        let state = PersistedRecordingState(
            sessionId: session.id,
            startTime: startDate,
            sessionType: .workout,
            phase: "workout:\(sport.rawValue)",
            useDeviceInternalBackup: nil
        )
        Self.recordingStateQueue.async {
            if let held = PersistedRecordingState.load(), held.sessionType != .workout {
                debugLog("[Recorder.start] PersistedRecordingState holds a \(held.sessionType.rawValue) recording — leaving it in place")
                return
            }
            let t0 = Date()
            PersistedRecordingState.save(state)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if ms > 50 {
                debugLog("[Recorder.start] PersistedRecordingState.save took \(ms)ms (off-main)")
            }
        }
    }

    /// Serial queue for this recorder's `PersistedRecordingState` save and
    /// clear, off the main thread (both IPC into `cfprefsd`).
    static let recordingStateQueue = DispatchQueue(label: "WorkoutRecorder.persistedRecordingState", qos: .utility)

    /// start() — the deferred tail task: diagnostics sampler, Watch workout session, interval plan, ticker.
    ///
    /// Every remaining start-path
    /// callee is deferred to a
    /// `Task { @MainActor }`. Each is either non-essential to "the workout has
    /// started" (diagnostics sampler, watch bridge, ticker) or fast on warm
    /// state but slow on cold (`SystemDiagnostics` touches MetricKit/UIDevice,
    /// `startTicker`'s scheduled Timer goes through the run-loop). Hopping them
    /// lets start() return so SwiftUI can mount FitnessRecordingView — the
    /// user-perceived "the app finally responded" event — before any of this
    /// runs. Each step is timed so the debug log shows which one (if any)
    /// is slow; it bails early on phase if the user already stopped the
    /// workout before the Task got to run.
    func launchStartTailTask(sport: Sport, startDate: Date, intervalPlan: IntervalPlan?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard case .recording = lifecycle.phase else { return }
            var stamps = StartStamps()
            services.systemDiagnosticsManager.startSamplingDuringRecording()
            stamps.mark("diag")
            // Kick the paired Watch into its own HKWorkoutSession so the wrist
            // HR is dense (1 Hz) and forwarded back here if the strap drops.
            // No-op if no Watch is paired or reachable.
            if !settingsProvider().watchDisplayOnlyMode {
                watchBridge.startWatchWorkoutSession(sport: sport)
            }
            stamps.mark("watch")
            loadIntervalPlan(intervalPlan, startAt: startDate)
            stamps.mark("intervals")
            ticker.startTicker()
            stamps.mark("ticker")
            debugLog("[Recorder.start] tail-task " + stamps.breakdown())
        }
    }

    /// Load an interval plan if provided. The controller's `onStepChange` hook
    /// pipes each transition into the voice coach as an AI-spoken line so the
    /// user hears "next: 3-minute threshold, Zone 4, go" at the right moment.
    /// `onFinish` tells them the structured block is done — any time after
    /// counts as cool-down.
    @MainActor
    private func loadIntervalPlan(_ plan: IntervalPlan?, startAt startDate: Date) {
        guard let plan else {
            intervalController.clear()
            return
        }
        intervalController.onStepChange = { [weak self] step, stepNum, total in
            guard let self else { return }
            Self.announceStep(step, number: stepNum, of: total, on: conversation)
        }
        intervalController.onFinish = { [weak self] in
            guard let self else { return }
            Self.announce(
                on: conversation,
                prompt: "Tell the runner their structured interval block is complete in one brief calm sentence.",
                fallback: IntervalSpokenCue.blockComplete
            )
        }
        intervalController.load(plan: plan, startAt: startDate)
    }
    @MainActor
    private static func announceStep(_ step: IntervalStep, number: Int, of total: Int, on conversation: VoiceConversationController) {
        let line = IntervalSpokenCue.step(step, number: number, of: total)
        announce(
            on: conversation,
            prompt: "Announce this interval step in one short, calm sentence for a runner wearing AirPods, no more than 15 words, keep it conversational: \(line)",
            fallback: line
        )
    }

    /// An AI-worded interval call, or the scripted one when the AI can't be
    /// asked (Flo off, its notice not accepted, no consent for the provider),
    /// fails, replies with nothing, or has said nothing a few seconds in, so
    /// interval calls are never silent. The conversation decides which, when
    /// the call comes up (`speakAIResponse(toPrompt:fallback:)`).
    @MainActor
    private static func announce(on conversation: VoiceConversationController, prompt: String, fallback: String) {
        conversation.speakAIResponse(toPrompt: prompt, fallback: fallback)
    }
}

// MARK: - File-scope helpers
//
// Each names no member of `WorkoutRecorder` and calls nothing on it, so
// none needs to be inside the type.

@MainActor
/// Reset reverse-geocoding state so the new workout starts with a clean
/// failure counter and no stale road context cached from a workout that
/// ended hours ago in a different town.
///
/// Deferred for the same reason as the Zwift broadcaster. The reset writes
/// to the @MainActor-isolated state of the service; if MainActor is
/// contended, even a quick property setter can wait. Deferring removes the
/// dependency.
private func deferGeocodingReset(_ geocoding: RoadGeocodingService) {
    Task { @MainActor in
        let t0 = Date()
        geocoding.reset()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if ms > 50 {
            debugLog("[Recorder.start] step=geocodingReset deferred done (\(ms)ms) — slower than expected", level: .warning)
        }
    }
}

@MainActor
/// Sport-gated: the type of exercise decides which meters and wearables to
/// look for. Waking a shoe pod over BLE for every sport is useless on bike/row, and
/// for the user it surfaces as 'why is the strap busy reconnecting some
/// sensor I'm not using?'.
///
/// The same manager reads bike trainers and power meters (Cycling Power,
/// FTMS Indoor Bike Data), so on `.bike` / `.indoorBike` a remembered
/// power-capable device is kept and reconnected: disconnecting it left an
/// indoor ride with no power, no NP/IF/power TSS, and a Zwift broadcast of
/// heart rate only. Anywhere else the linked device is DISCONNECTED so it
/// doesn't deliver stale cadence/pace into the workout context (a bike's
/// pedal cadence ≠ run cadence).
private func manageFootPod(for sport: Sport, pod: FootPodManager) {
    let usesPod = footPodManagerServes(sport, pod: pod)
    pod.holdLinkForWorkout(usesPod)
    if usesPod {
        guard let device = footPodDeviceToReconnect(for: sport, pod: pod),
              pod.connectionState == .disconnected else { return }
        debugLog("[Recorder.start] step=footpod.reconnect (deferred, sport=\(sport.rawValue))")
        Task { @MainActor in
            pod.connect(deviceId: device.id)
            debugLog("[Recorder.start] step=footpod.reconnect done")
        }
    } else {
        guard pod.connectionState == .connected else { return }
        debugLog("[Recorder.start] step=footpod.disconnect (deferred, sport=\(sport.rawValue) doesn't use foot pod)")
        Task { @MainActor in
            pod.disconnect()
            debugLog("[Recorder.start] step=footpod.disconnect done")
        }
    }
}

/// Foot sports (the pedometer sports) use a shoe pod; bike sports use the
/// manager only when a remembered device carries power (a trainer or power
/// meter), wherever it sits in the remembered list.
@MainActor
private func footPodManagerServes(_ sport: Sport, pod: FootPodManager) -> Bool {
    if WorkoutSessionLifecycle.pedometerSports.contains(sport) { return true }
    guard sport == .bike || sport == .indoorBike else { return false }
    return pod.knownDevices.contains { $0.supportsPower }
}

/// The remembered device a workout of this sport reconnects: the most recent
/// one for a foot sport (as `reconnectLast` picks), the most recent
/// power-carrying one for a bike sport. Nil when none is remembered.
@MainActor
private func footPodDeviceToReconnect(for sport: Sport, pod: FootPodManager) -> FootPodManager.KnownFootPod? {
    guard sport == .bike || sport == .indoorBike else { return pod.knownDevices.first }
    return pod.knownDevices.first { $0.supportsPower }
}
