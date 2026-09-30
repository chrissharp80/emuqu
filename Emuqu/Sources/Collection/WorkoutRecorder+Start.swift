import Foundation
import UIKit

// `start()` and its helpers. The recorder's stored state, sub-observables and
// pause/resume live in `WorkoutRecorder.swift`.

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
    /// - `none`: no HR at all; pure recorder.motion tracking.
    /// - `intervalPlan`: optional structured plan. When provided, the recorder
    ///   drives an `IntervalController` that advances through each step by
    ///   time/distance and announces transitions via the voice coach.
    ///
    /// Per-step diagnostic logs make a hang during start() pinpointable from
    /// the debug log. start() does a lot synchronously on the
    /// main thread (Polar streaming start, BLE peripheral broadcaster, GPS,
    /// recorder.pedometer, foot-pod reconnect, disk write). Without an entry
    /// log before the first observable side effect, a hang shows up as a long
    /// stretch of silence with no entry point.
    ///
    /// The correlation scope spans the whole workout, from this entry to
    /// `stop()`. It deliberately uses begin/end rather than the scoped helper:
    /// the interesting lines are emitted long after `start()` returns, from BLE
    /// delegate callbacks, GPS updates, and recorder.pedometer ticks that are not
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
        AppDependencies.current.collection.workoutStartLatencyTracker.recordStartEntry()
        recorder.beginWorkoutCorrelation()
        var startCompleted = false
        defer { if !startCompleted { recorder.endWorkoutCorrelation() } }
        debugLog("[Recorder.start] entry sport=\(sport.rawValue) source=\(source.rawValue) hasPlan=\(intervalPlan != nil) thresholds=\(thresholds.count) hasRoute=\(route != nil)")
        var stamps = StartStamps()
        try applyStartParametersAndGuardIdle(thresholds: thresholds, route: route)
        let effectiveSource = try resolveEffectiveSource(requested: source)
        let provenance = makeStartProvenance(effectiveSource: effectiveSource)
        stamps.mark("preflight")
        let session = Self.makeStartingSession(sport: sport, provenance: provenance)
        stamps.mark("session")
        try beginPolarStreamingOrDefer(effectiveSource: effectiveSource)
        stamps.mark("polarStream")
        bringUpRecording(session: session, sport: sport, effectiveSource: effectiveSource, intervalPlan: intervalPlan, stamps: &stamps)
        debugLog("[Recorder.start] sync-breakdown " + stamps.breakdown())
        AppDependencies.current.collection.workoutStartLatencyTracker.recordStartReturned()
        startCompleted = true
    }

    /// Per-block timing inside the synchronous body of `start()`.
    /// Multi-second gaps in user debug logs (14.65 s and 9.55 s) had to be
    /// inferred from the spacing of per-step debugLog calls. With these
    /// stamps a repro shows exactly which block ate the budget; without them
    /// we'd be back to inference.
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

    /// Everything after the Polar stream starts: per-workout state, the recorder.phase
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
        // HR subscription sits immediately after `recorder.phase = .recording`
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
        recorder.resetCachedBaselinesAndLaunchBaselineTask(sport: sport)
        deferLocationTrackingStart(sport: sport)
        deferPedometerStart(sport: sport)
        reconnectOrDisconnectSecondarySensors(sport: sport)
        persistRecordingStateOffMain(session: session, startDate: session.startDate, sport: sport)
        startKeepAlives(sport: sport, hasIntervalPlan: intervalPlan != nil)
        launchStartTailTask(sport: sport, startDate: session.startDate, intervalPlan: intervalPlan)
    }

    /// start() — parameter capture + idle guard (first slice of the sync-breakdown `preflight` span).
    func applyStartParametersAndGuardIdle(thresholds: [WorkoutThreshold], route: Route?) throws {
        recorder.userThresholds = thresholds
        recorder.thresholdBreachSec.removeAll()
        recorder.plannedRoute = route
        recorder.plannedRouteWasAutoDetected = false
        recorder.routeDetectionAttempted = false
        guard case .idle = recorder.phase else {
            debugLog("[Recorder.start] BAIL — already recording (phase=\(recorder.phase))", level: .warning)
            throw WorkoutRecorderError.alreadyRecording
        }
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
    /// strap connected" is the confusion they reported. Downgrading lets the
    /// workout proceed and the post-summary notes the missing HR source.
    func resolveEffectiveSource(requested source: HRSource) throws -> HRSource {
        guard source == .strap else { return source }
        stopStaleStreamIfIdle()
        // The cascade itself lives in `WorkoutHRSourceResolver` — pure, and
        // tested. Everything below is the side effects it decided on.
        let resolution = currentSourceResolution(requested: source)
        WorkoutHRSourceResolver.log(resolution)
        switch resolution {
        case .strapBusy:
            throw WorkoutRecorderError.strapBusy
        case .reconnectThenUseStrap:
            recorder.core.polarManager.connectToLastDevice()
            return .strap
        case let .use(resolved):
            return resolved
        }
    }

    /// Reads what is actually attached right now and asks the resolver. The
    /// live reads are here; the decision they feed is pure and tested.
    private func currentSourceResolution(requested source: HRSource) -> WorkoutHRSourceResolver.Resolution {
        WorkoutHRSourceResolver.resolve(
            requested: source,
            strapIsRecordingOnDevice: recorder.core.polarManager.isRecordingOnDevice,
            strapIsConnected: recorder.core.polarManager.connectionState == .connected,
            hasKnownDevices: !recorder.core.polarManager.knownDevices.isEmpty,
            isWatchPaired: AppDependencies.current.services.watchConnectivityBridge.isWatchPaired
        )
    }

    /// `isStreaming` true with our own recorder idle = a lingering
    /// post-workout stream the HRR-capture detached task hasn't torn down yet.
    /// Don't bounce the user — stop the stale stream inline and proceed.
    /// `acknowledgeFinished` already does this on summary dismiss; this guard
    /// catches the path where the user starts a new workout from a surface
    /// that doesn't go through the summary (e.g. the Watch's Start button, or
    /// hitting Start before the post-summary has rendered).
    private func stopStaleStreamIfIdle() {
        guard recorder.core.polarManager.isStreaming else { return }
        debugLog("[Recorder.start] stale Polar stream detected with recorder idle — stopping inline before new session")
        _ = recorder.core.polarManager.stopStreaming()
    }

    /// start() — device-provenance construction from the post-downgrade source (sync-breakdown `preflight` span).
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
                recorder.core.polarManager.connectedDeviceId ?? "unknown",
                recorder.core.polarManager.connectedDeviceType?.displayName ?? "Polar device"
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
    func beginPolarStreamingOrDefer(effectiveSource: HRSource) throws {
        recorder.lifecycle.strapNotice = nil
        guard effectiveSource == .strap else { return }
        debugLog("[Recorder.start] step=polar.startStreaming (link: \(recorder.core.polarManager.connectionState))")
        try recorder.core.polarManager.startStreaming()
        debugLog("[Recorder.start] step=polar.startStreaming done")
        recorder.startDeviceInternalBackupIfPossible()
    }

    /// start() — per-workout state resets (sync-breakdown `resets+providers` span).
    func resetPerWorkoutState(session: HRVSession, startDate: Date, effectiveSource: HRSource) {
        recorder.lifecycle.activeHRSource = effectiveSource

        recorder.lifecycle.currentSession = session
        recorder.sessionStartDate = startDate
        recorder.collectedPoints = []
        recorder.lifecycle.elapsedSeconds = 0
        recorder.workoutHR.reset()
        recorder.lastIngestedPointCount = 0
        recorder.workoutSamples = []
        recorder.lastSampleDistance = 0
        recorder.lastSampleAt = nil
        recorder.footPodStartDistanceMeters = nil
        recorder.powerSampleSum = 0
        recorder.powerSampleCount = 0
        recorder.maxPowerObserved = 0
        recorder.motion.powerWatts = nil
        recorder.motion.footPodActive = false
        recorder.lastStrapHRAt = nil
        recorder.dfa.reset(sessionStart: startDate)
        recorder.voiceCoach.reset()
    }

    /// start() — owns `step=invalidateAIContext` plus the AI snapshot/samples providers (sync-breakdown `resets+providers` span).
    func installAIContextProviders() {
        installConversationContextProviders()
        // Drop the AI context cache so the very next Assistant message the
        // user sends rebuilds with live workout state included. Belt-and-
        // braces to complement the liveWorkout overlay — in case anything
        // else in the cache goes stale while a workout is active.
        debugLog("[Recorder.start] step=invalidateAIContext")
        AppDependencies.current.assistant.assistantContextSource.invalidate()
        installLiveWorkoutSamplesProvider()
    }

    /// Hand the recorder.conversation controller a closure that returns the current
    /// factual workout snapshot on each turn. This is what lets the AI
    /// answer "what's my HR?" with the real value rather than guessing.
    ///
    /// Also exposes the structured snapshot for the
    /// pre-speech hallucination guard. MetricsVerifier
    /// uses this to cross-check numeric claims against authoritative
    /// values before TTS speaks the line.
    private func installConversationContextProviders() {
        recorder.conversation.contextSnapshotProvider = { [weak recorder] in
            guard let recorder, let sport = recorder.currentSession?.sport else { return nil }
            return recorder.buildContext(sport: sport).asFactSheet()
        }
        recorder.conversation.liveWorkoutSnapshotProvider = { [weak recorder] in
            guard let recorder, let sport = recorder.currentSession?.sport else { return nil }
            return recorder.buildContext(sport: sport)
        }
    }

    /// Registers a samples provider with
    /// the broker so the AI's `workout.live.timeline` tool can pull
    /// recent correlated HR / elevation / pace / power samples on
    /// demand without us shipping the buffer through the broker every
    /// tick. `recorder.samplesView` is @MainActor-isolated; the AI fact
    /// resolver runs on the main actor too, so assumeIsolated is
    /// safe. Cleared at stop via broker.clear().
    private func installLiveWorkoutSamplesProvider() {
        AppDependencies.current.assistant.liveWorkoutBroker.registerSamplesProvider { [weak recorder] in
            MainActor.assumeIsolated {
                recorder?.samplesView ?? []
            }
        }
    }

    /// start() — owns `step=recorder.phase=.recording` and the probe-pre / probe-post main-actor latency probes (sync-breakdown `phaseFlip` span).
    ///
    /// Main-actor responsiveness probes. Every observable side effect of
    /// start() runs off the synchronous path, yet user debug logs have shown
    /// the queued Tasks not running for
    /// ~2.9 s after start() returned. SwiftUI's render of
    /// FitnessRecordingView is the prime suspect (heavy view body, 8
    /// ObservedObjects). These probes time-stamp BEFORE recorder.phase=.recording
    /// and AFTER recorder.phase=.recording so the debug log shows
    ///   (a) baseline main-actor latency (probe-pre)  and
    ///   (b) the post-recorder.phase render gap (probe-post).
    /// If (b) is multi-second while (a) is sub-100 ms, the view body is
    /// the cause and we have a concrete number to target.
    func flipPhaseToRecordingWithProbes() {
        Self.probeMainActorLatency(label: "probe-pre")
        recorder.lifecycle.phase = .recording
        debugLog("[Recorder.start] step=phase=.recording")
        AppDependencies.current.collection.workoutStartLatencyTracker.recordPhaseFlip()
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
    /// User report: "exercise almost never starts the first time —
    /// appears to start but no voice 'started' and no HR; force-quitting fixes
    /// it." Cause: when the announce Task and HR subscription are queued from
    /// much later in start(), AFTER 300+ lines of synchronous cold-start work
    /// (BLE reconnects, CLLocation setup, AVAudioSession activation, disk
    /// write), a cold first start keeps the main thread busy long enough that
    /// the announce Task can't run and the user perceives nothing happening,
    /// then force-quits. Both are wired up immediately after the recorder.phase flip so
    /// they survive whatever slowdown follows.
    ///
    /// `effectiveSource` (post-downgrade) is used, not the caller-supplied
    /// `source`. If the strap dropped between the ready screen and `start()`,
    /// `effectiveSource` is `.watch`/`.none` and the Polar publisher has no
    /// data — subscribing here would wire a sink to a dead publisher, a real
    /// cause of "no HR despite the UI saying recording."
    ///
    /// The announce path is not called inline here. A user log showed a 14.65 s
    /// gap between `recorder.phase.recording → announce.fire` and the next synchronous
    /// start() log line, with `announceStart` the only meaningful work in that
    /// gap. Root cause was `AVSpeechSynthesisVoice.speechVoices()` IPC stalling
    /// after an audio-session interruption; a secondary contributor was
    /// first-use Taptic Engine spin-up via a
    /// fresh `UINotificationFeedbackGenerator()`. Both are mitigated upstream
    /// (voice is cached via `_voiceCacheLookup`; haptic generators are
    /// pre-warmed at app launch), and announce itself is hopped into a
    /// `Task { @MainActor }` by `queueStartAnnouncement`. `recordAnnounceFire`
    /// stays stamped synchronously so the tap-to-voice metric remains
    /// comparable to historical logs.
    func wireEarlyHRObservationAndStampAnnounce(effectiveSource: HRSource) {
        if effectiveSource == .strap {
            recorder.observeHeartRate()
        }
        AppDependencies.current.collection.workoutStartLatencyTracker.recordAnnounceFire()
    }

    /// start() — queues the announceStart Task (sync-breakdown `announceQueue` span).
    func queueStartAnnouncement(sport: Sport) {
        // When this Task fires tells us whether MainActor
        // was free or contended after recorder.phase=.recording. A "1 minute"
        // start would show this Task delayed N seconds, naming the cause.
        let _announceScheduledAt = Date()
        Task { @MainActor in
            let delayMs = Int(Date().timeIntervalSince(_announceScheduledAt) * 1000)
            if delayMs > 250 {
                debugLog("[Recorder.start] ⚠️ announceStart Task delayed \(delayMs)ms after schedule — MainActor was contended", level: .warning)
            }
            WorkoutStartCue.announceStart(sport: sport)
        }
    }

    /// start() — owns `step=zwiftBroadcaster.start (deferred)` and the deferred geocoding reset (sync-breakdown `geocodingReset` span).
    func deferZwiftBroadcastAndGeocodingReset() {
        deferZwiftBroadcast()
        deferGeocodingReset()
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
    /// so it can't block the start path even when the radio is wedged.
    private func deferZwiftBroadcast() {
        guard recorder.settingsProvider().enableZwiftBroadcast else { return }
        debugLog("[Recorder.start] step=zwiftBroadcaster.start (deferred)")
        Task { @MainActor in
            let t0 = Date()
            AppDependencies.current.collection.zwiftPeripheralBroadcaster.startBroadcasting()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            debugLog("[Recorder.start] step=zwiftBroadcaster.start deferred done (\(ms)ms)")
        }
    }

    /// start() — owns `step=recorder.location.startTracking (deferred)` (sync-breakdown `tail` span).
    ///
    /// Deferred by exactly one run-loop hop, and no further. A deferral that
    /// waits until SwiftUI has finished mounting `FitnessRecordingView`
    /// defends against one rare iOS-26 race where CLLocationManager setters
    /// hung for 17 s on the main thread after a BLE power-cycle, but it makes
    /// EVERY workout wait ~11–12 s (beta user logs) before GPS begins
    /// tracking. Net: a once-in-many bug avoided, an
    /// always-in-every-workout 12 s GPS delay introduced. Bad trade. The
    /// fine-grained `step=1…8` logs inside `startTracking()` pinpoint any
    /// future hang at exactly the setter that blocks, so
    /// re-fixing if needed is mechanical.
    ///
    /// The one hop exists because user logs captured
    /// `recorder.location.startTracking done (3083ms)` for a walk start, with the
    /// "exceeded 250ms threshold" warning firing every time. 3 s of main-thread block between
    /// the user's tap and the recording UI is the "exercise was super slow to
    /// start" complaint. `CLLocationManager.startUpdatingLocation` is
    /// documented as non-blocking, but its first call after an authorization
    /// change / cold start synchronously prompts CoreLocation to negotiate
    /// accuracy + delivery cadence with locationd, which is what eats the 3 s.
    /// The first recorder.location fix doesn't arrive for ~5-15 s anyway, so a one-hop
    /// deferral loses no data — it just unblocks the user-tap path.
    /// `recorder.phase.recording` is already flipped, so the UI renders immediately and
    /// the GPS metrics tile fills in whenever the first fix lands.
    func deferLocationTrackingStart(sport: Sport) {
        guard sport.usesGPS else { return }
        debugLog("[Recorder.start] step=location.startTracking (deferred)")
        Task { @MainActor [weak recorder] in
            let lt0 = Date()
            recorder?.location.startTracking()
            let ltMs = Int(Date().timeIntervalSince(lt0) * 1000)
            debugLog("[Recorder.start] step=location.startTracking deferred done (\(ltMs)ms)")
        }
    }

    /// start() — owns `step=recorder.pedometer.start (deferred)` (sync-breakdown `tail` span).
    ///
    /// Pedometer runs for every recorder.motion-based sport. CMPedometer works
    /// indoors (no GPS) and is the source of truth for walk/run distance
    /// when GPS is unavailable or unreliable.
    ///
    /// Deferred as belt-and-braces.
    /// Even though recorder.pedometer.start logs ~2 ms,
    /// CMPedometer.startUpdates makes
    /// an XPC roundtrip to coremotion under the hood and that has
    /// been observed to stall when the recorder.motion subsystem is contended
    /// (post-app-launch, post-Watch-handoff). Belt-and-braces — the
    /// first recorder.pedometer sample doesn't arrive for ~1 s anyway, so
    /// moving the call off the sync path costs nothing if it's fast
    /// and saves us if it's slow.
    func deferPedometerStart(sport: Sport) {
        guard sport == .walk || sport == .run || sport == .trailRun || sport == .hike || sport == .treadmill else {
            return
        }
        debugLog("[Recorder.start] step=pedometer.start (deferred)")
        Task { @MainActor [weak recorder] in
            let pt0 = Date()
            recorder?.pedometer.start()
            let ptMs = Int(Date().timeIntervalSince(pt0) * 1000)
            debugLog("[Recorder.start] step=pedometer.start deferred done (\(ptMs)ms)")
            if ptMs > 100 {
                debugLog("[Recorder.start] ⚠️ pedometer.start exceeded 100ms threshold", level: .warning)
            }
        }
    }

    /// start() — owns `step=footpod.reconnectLast` / `step=footpod.disconnect` / `step=concept2.reconnectLast` (sync-breakdown `tail` span).
    ///
    /// Auto-reconnect previously-paired secondary sensors at workout start.
    /// Without this, the foot pod / FTMS bike trainer / PM5 rower stay
    /// disconnected even when the user paired them previously — they'd have to
    /// dig through Settings every time. Fire-and-forget per device: the connect
    /// callback updates the manager's published state, which feeds the live
    /// snapshot. If the device isn't in range / dead battery, the manager
    /// simply stays disconnected and the workout proceeds without it.
    ///
    /// Same deferral pattern as recorder.location/recorder.pedometer. Foot-pod and
    /// Concept2 reconnects are synchronous CoreBluetooth calls that can stall
    /// the main thread on cold-start, contributing to the "first start has no
    /// voice and no HR" report. The reconnect doesn't need to finish before
    /// `start()` returns — the manager publishes state when the device comes
    /// online.
    ///
    /// Scope: this handles the rower and the foot pod only. Cycling
    /// power meters (FTMS / Cycling Power Service) are **not** auto-connected
    /// for `.bike` / `.indoorBike`, because Emuqu has no BLE module for them —
    /// there is no `CyclingPowerManager` to reconnect to, so there is nothing
    /// to gate on here. Adding one means writing that manager first; the
    /// sport-gated reconnect block below is then the shape to copy.
    func reconnectOrDisconnectSecondarySensors(sport: Sport) {
        manageFootPod(for: sport)
        guard sport == .row,
              !AppDependencies.current.collection.concept2Manager.knownDevices.isEmpty,
              AppDependencies.current.collection.concept2Manager.connectionState == .disconnected
        else { return }
        debugLog("[Recorder.start] step=concept2.reconnectLast (deferred)")
        Task { @MainActor in
            AppDependencies.current.collection.concept2Manager.reconnectLast()
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
    /// A user debug log showed a 9.55 s gap between the
    /// synchronous footpod-defer log and the next synchronous log
    /// (SystemDiagnostics) with this `save()` as the only meaningful
    /// call in the window — circumstantial but the symptom matches a
    /// cfprefsd-contention stall. Persistence completes within ~50 ms
    /// of recorder.phase=.recording on the background queue, which is fine for
    /// crash recovery (we only need the record on disk before iOS
    /// SIGKILLs, not synchronously in the start path).
    func persistRecordingStateOffMain(session: HRVSession, startDate: Date, sport: Sport) {
        let state = PersistedRecordingState(
            sessionId: session.id,
            startTime: startDate,
            sessionType: .workout,
            phase: "workout:\(sport.rawValue)",
            useDeviceInternalBackup: nil
        )
        Task.detached(priority: .utility) {
            let t0 = Date()
            PersistedRecordingState.save(state)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if ms > 50 {
                debugLog("[Recorder.start] PersistedRecordingState.save took \(ms)ms (off-main)")
            }
        }
    }

    /// start() — feature-justified background sessions (sync-breakdown `tail` span).
    ///
    /// Shaped by App Store guideline 2.5.4 (the prior-rejection
    /// area). Background modes must serve a user-visible feature:
    ///   - LOCATION: started only for GPS sports, where the workout is
    ///     actively recording a route. Starting it for indoor sports
    ///     purely to stay scheduled is the same
    ///     keep-alive abuse that overnight avoids.
    ///   - AUDIO: started only for indoor sports WITH audible coach
    ///     content enabled (coach alerts, mile markers, or an interval
    ///     plan — the features that actually speak through this
    ///     session). Silent audio with nothing to say is the textbook
    ///     2.5.4 pattern reviewers screen for.
    /// Indoor sessions without audible coaching ride on
    /// `bluetooth-central` like overnight does: the strap / foot pod /
    /// erg streams continuously, and each delivery wakes the process
    /// (see the architecture note in startOvernightStreaming).
    ///
    /// Same main-thread-protection pattern as the rest of
    /// start(): both managers are slow on first call after launch, so
    /// they're deferred to a @MainActor Task and start() returns
    /// immediately.
    func startKeepAlives(sport: Sport, hasIntervalPlan: Bool) {
        Task { @MainActor [weak recorder] in
            guard let recorder, case .recording = recorder.lifecycle.phase else { return }
            if sport.usesGPS {
                AppDependencies.current.location.backgroundLocationManager.startBackgroundLocation(reason: .workoutRecording)
            }
            if !sport.usesGPS, Self.hasAudibleCoachContent(
                hasIntervalPlan: hasIntervalPlan,
                hasThresholds: !recorder.userThresholds.isEmpty,
                settings: recorder.settingsProvider()
            ) {
                AppDependencies.current.collection.backgroundAudioManager.startBackgroundAudio()
                recorder.didStartBackgroundAudio = true
            }
        }
    }

    /// True when something in this workout will actually speak — the only
    /// justification for holding an audio background session.
    ///
    /// Coach alerts alone are not enough: they default on, and the one alert
    /// rule that speaks is a threshold breach, which needs a threshold the user
    /// set for this workout. Every other rule is silent. Gating on the setting
    /// alone held a silent audio loop through every default indoor workout
    /// with nothing ever to say.
    static func hasAudibleCoachContent(hasIntervalPlan: Bool, hasThresholds: Bool, settings: UserSettings) -> Bool {
        (settings.coachAlertsEnabled && hasThresholds)
            || settings.enableMileMarkerNotifications
            || hasIntervalPlan
    }

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
    /// regresses; it bails early on recorder.phase if the user already stopped the
    /// workout before the Task got to run.
    func launchStartTailTask(sport: Sport, startDate: Date, intervalPlan: IntervalPlan?) {
        Task { @MainActor [weak recorder] in
            guard let recorder else { return }
            guard case .recording = recorder.lifecycle.phase else { return }
            var stamps = StartStamps()
            AppDependencies.current.app.systemDiagnosticsManager.startSamplingDuringRecording()
            stamps.mark("diag")
            // Kick the paired Watch into its own HKWorkoutSession so the wrist
            // HR is dense (1 Hz) and forwarded back here if the strap drops.
            // No-op if no Watch is paired or reachable.
            if !recorder.settingsProvider().watchDisplayOnlyMode {
                recorder.watchBridge.startWatchWorkoutSession(sport: sport)
            }
            stamps.mark("watch")
            recorder.session.loadIntervalPlan(intervalPlan, startAt: startDate)
            stamps.mark("intervals")
            recorder.startTicker()
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
            recorder.intervalController.clear()
            return
        }
        recorder.intervalController.onStepChange = { [weak recorder] step, stepNum, total in
            let target = Self.speakableTarget(step.target)
            let line = "Step \(stepNum) of \(total): \(step.label), \(target) for " +
                Self.speakableDuration(step: step)
            recorder?.conversation.speakAIResponse(toPrompt:
                "Announce this interval step in one short, calm sentence for a runner wearing AirPods, no more than 15 words, keep it conversational: \(line)."
            )
        }
        recorder.intervalController.onFinish = { [weak recorder] in
            recorder?.conversation.speakAIResponse(toPrompt:
                "Tell the runner their structured interval block is complete in one brief calm sentence."
            )
        }
        recorder.intervalController.load(plan: plan, startAt: startDate)
    }
    // MARK: - Pause / resume
    //
    // The recorder stays in `.recording` while paused — pause is a soft
    // gate inside the ticker, not a separate recorder.phase. This keeps every
    // other subsystem (strap, GPS, broker, Watch bridge) running so
    // samples are ready to flow the instant we resume; a hard recorder.phase
    // transition would force those to tear down + re-init each time,
    // which would lose the first few seconds of the resumed segment.

    /// Pause the active workout. No-op if not currently recording, or
    /// already paused. `isAuto = true` flags this pause as system-
    /// initiated so the auto-resume path knows it may re-enable the
    /// clock; user-initiated pauses can only be resumed by the user.
    func pause(isAuto: Bool = false) {
        guard case .recording = recorder.phase, !recorder.lifecycle.isPaused else { return }
        recorder.lifecycle.isPaused = true
        recorder.lifecycle.autoPaused = isAuto
        recorder.autoPause.reset()
        debugLog("[WorkoutRecorder] paused (auto=\(isAuto))")
    }

    /// Resume the active workout. No-op if not paused.
    func resume() {
        guard case .recording = recorder.phase, recorder.lifecycle.isPaused else { return }
        recorder.lifecycle.isPaused = false
        recorder.lifecycle.autoPaused = false
        recorder.autoPause.reset()
        debugLog("[WorkoutRecorder] resumed")
    }
}

// MARK: - File-scope helpers
//
// Each names no member of WorkoutRecorder and calls nothing inside it, so
// none needs to be a member. `private` at file scope is fileprivate, so
// every call site in this file resolves.

@MainActor
/// Reset reverse-geocoding state so the new workout starts with a clean
/// failure counter and no stale road context cached from a workout that
/// ended hours ago in a different town.
///
/// Deferred for the same reason as the Zwift broadcaster. Logs put this at
/// ~0 ms, but the "up to 1 minute" worst-case start reports include paths
/// that don't reproduce locally. The reset writes to the
/// @MainActor-isolated state of the service; if MainActor is contended,
/// even a quick property setter can wait. Deferring removes the dependency.
private func deferGeocodingReset() {
    Task { @MainActor in
        let t0 = Date()
        AppDependencies.current.location.roadGeocodingService.reset()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if ms > 50 {
            debugLog("[Recorder.start] step=geocodingReset deferred done (\(ms)ms) — slower than expected", level: .warning)
        }
    }
}

@MainActor
/// Sport-gated. User report: 'the type of exercise should tell
/// it what meters/externals/wearables to be aware of and looking for'.
/// Waking the foot pod over BLE for every sport is useless on
/// bike/row, and for the user it surfaces as 'why is the strap busy
/// reconnecting some sensor I'm not using?'. Foot pods are only useful for
/// foot sports (cadence/pace from a shoe-mounted accelerometer); skip the
/// BLE traffic on bike / indoor bike / row.
///
/// For non-foot sports we proactively DISCONNECT a connected foot pod so it
/// doesn't deliver stale cadence/pace into the workout context (a bike's
/// pedal cadence ≠ run cadence).
private func manageFootPod(for sport: Sport) {
    let footPodSports: Set<Sport> = [.run, .trailRun, .walk, .hike, .treadmill]
    let pod = AppDependencies.current.collection.footPodManager
    if footPodSports.contains(sport) {
        guard !pod.knownDevices.isEmpty, pod.connectionState == .disconnected else { return }
        debugLog("[Recorder.start] step=footpod.reconnectLast (deferred, sport=\(sport.rawValue))")
        Task { @MainActor in
            AppDependencies.current.collection.footPodManager.reconnectLast()
            debugLog("[Recorder.start] step=footpod.reconnectLast done")
        }
    } else {
        guard pod.connectionState == .connected else { return }
        debugLog("[Recorder.start] step=footpod.disconnect (deferred, sport=\(sport.rawValue) doesn't use foot pod)")
        Task { @MainActor in
            AppDependencies.current.collection.footPodManager.disconnect()
            debugLog("[Recorder.start] step=footpod.disconnect done")
        }
    }
}
