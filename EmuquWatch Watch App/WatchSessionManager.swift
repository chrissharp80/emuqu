import Combine
import Foundation
import os
@preconcurrency import WatchConnectivity

// Watch-side counterpart to iOS `WatchConnectivityBridge`. Receives the live
// state snapshot, unpacks it for the UI, and forwards workout-control
// messages to the HKWorkoutSession manager.
//
// @MainActor stays off the class itself — it conflicts with @StateObject's
// default init. Mutations of @Published properties happen inside Tasks that
// hop to @MainActor explicitly.
final class WatchSessionManager: NSObject, ObservableObject {
    /// Process-wide instance used by background helpers
    /// (`WatchStrapConnector` for direct-BLE samples) that need to push
    /// data into the same view-model the SwiftUI `@StateObject` is
    /// observing. SwiftUI tree-roots only ever construct one
    /// `WatchSessionManager` so this is the same object the @StateObject
    /// path holds.
    static let shared = WatchSessionManager()
    // MARK: Live metrics (pushed from phone)

    @Published var heartRate: Int?
    @Published var peakHR: Int = 0
    @Published var hrPercentOfMax: Int?
    @Published var elapsedSeconds: Int = 0
    @Published var distanceMeters: Double = 0
    /// iPhone-rendered pace string using the user's unit preference so
    /// we can't drift (e.g. show /km when the user prefers /mi). Nil
    /// when the runner is stationary / warming up.
    @Published var paceDisplay: String?
    @Published var alpha1: Double?
    @Published var band: String = "—"
    @Published var sportLabel: String = String(localized: "Workout")
    @Published var cadenceSpm: Double?
    @Published var elevationGainMeters: Double = 0
    @Published var targetZone: Int?
    /// "metric" or "imperial" — used for distance/elevation formatting on
    /// the Watch. Pace is pre-formatted on iPhone.
    @Published var unitsPreference: String = "metric"
    /// True while iOS is actively recording. Drives Stop-button visibility.
    @Published var isRecording: Bool = false
    /// True while the iPhone workout is paused (manual or auto).
    @Published var isPaused: Bool = false
    /// True when the current pause was auto-triggered. Lets the Watch
    /// distinguish "I paused this" from "the app paused for me."
    @Published var autoPaused: Bool = false
    /// True immediately after `isRecording` flips true → false. Drives
    /// the Save & Done completion screen. Cleared when the user taps
    /// Save & Done or the next workout starts.
    @Published var justCompleted: Bool = false

    /// True from the moment the user taps Start on the Watch until iOS
    /// confirms the workout actually began (`isRecording` flips true)
    /// OR the safety timeout expires. Drives a "Starting…" overlay on
    /// the Start screen and disables the Start button so the user
    /// can't tap repeatedly thinking nothing happened.
    ///
    /// Without this gate the Start button looks dead and gets tapped
    /// repeatedly: WCSession reachability can be flaky, and the message
    /// takes a few seconds to land, iOS to fire the recorder, and the next
    /// live-state push to flip `isRecording`.
    @Published var startWorkoutRequestInFlight: Bool = false

    /// True from the moment the user taps "Talk to AI" until iOS
    /// confirms the voice controller transitioned out of `.idle`, or
    /// the safety timeout expires. Same UX rationale as
    /// `startWorkoutRequestInFlight`.
    @Published var voiceChatRequestInFlight: Bool = false

    /// Latest voice-chat state pushed by iOS (idle / starting /
    /// listening / thinking / speaking). Lets the Watch's Talk button
    /// switch label and color while a session is live so the user
    /// can see at a glance whether iOS is paying attention.
    @Published var voiceChatStateLabel: String = "idle"

    private var startWorkoutTimeoutTask: Task<Void, Never>?
    private var voiceChatTimeoutTask: Task<Void, Never>?

    // MARK: Connection state

    /// True once WCSession has finished activating on this Watch.
    @Published var isActivated = false
    /// True when iOS app is reachable (foreground-ish on phone).
    @Published var isReachable = false
    /// Diagnostic: number of live-state messages received from iOS.
    @Published var messagesReceived: Int = 0
    /// Diagnostic: last error / status line, shown on the watch when
    /// something is wrong ("No phone reachable", etc.)
    @Published var statusLine: String = String(localized: "Starting…")

    /// Watch behavior mode (display-only vs legacy
    /// strap-pair-on-wrist). True = the iPhone owns the strap and the
    /// workout session; the Watch just shows live stats and never
    /// starts an HKWorkoutSession on its own. Defaults to true so a
    /// missing payload keeps the simpler behavior. Updated from each
    /// iOS push.
    @Published var displayOnlyMode: Bool = true

    /// When display-only mode is on, the iPhone owns the
    /// Polar strap and the Watch needs the iPhone's BLE state to drive
    /// the Start button's color + hint. iOS pushes this via the
    /// `strapState` payload's `strapConnected` field. nil = no
    /// strap-state push received yet (Watch just woke up); treated as
    /// false for the tint until iOS reports.
    @Published var phoneStrapConnected: Bool = false
    @Published var phoneStrapDeviceName: String?

    // There is deliberately no iOS-mirrored strap state surface (`strapConnected`,
    // `strapDeviceName`, `strapBatteryPercent`, plus `refreshStrapStateNow`
    // and a `requestStrapState` ↔ `strapState` round-trip).
    //
    // The Polar BLE SDK's `deviceDisconnected` callback was unreliable on
    // physical strap removal (the link could stay alive for ~30–60s),
    // and the Watch had no staleness eviction, so the pre-workout pill
    // showed stale "Connected" indefinitely after the user took the
    // strap off. The fix was to delete the duplicate surface and have
    // the Watch own its own BLE link via `WatchStrapConnector`, which
    // sees disconnects in real time. See `WatchStrapPairingView`.

    // Direct Watch-to-strap BLE.
    //
    // `directStrapHeartRate` is the most recent HR sample read directly
    // from a chest strap paired to the Watch (via `WatchStrapConnector`),
    // independent of whatever the iPhone has been doing. When this is
    // non-nil and fresh it takes precedence over `heartRate` (which is
    // the iPhone-pushed live state). The Watch UI prefers a real strap
    // beat over an iPhone-derived value when both are available.
    @Published var directStrapHeartRate: Int?
    @Published var directStrapHeartRateAt: Date?

    /// HR source the Watch is currently displaying. Drives the small
    /// "via Watch BLE" / "via iPhone" tag in the UI so the user knows
    /// where the number is coming from.
    enum DisplayedHRSource { case directStrap, iPhoneRelay, none }
    var displayedHRSource: DisplayedHRSource {
        // Prefer a direct-strap reading less than 4 seconds old.
        // After that we assume the strap is silent and fall back to
        // the phone's relay (wrist HR or iPhone-side strap).
        if let stamp = directStrapHeartRateAt,
           Date().timeIntervalSince(stamp) < 4,
           directStrapHeartRate != nil {
            return .directStrap
        }
        if heartRate != nil { return .iPhoneRelay }
        return .none
    }

    /// What the UI should actually show as the live HR — direct strap
    /// when fresh, iPhone relay otherwise. Lets the existing
    /// `heartRate` binding stay simple while we layer the new source on.
    var displayedHeartRate: Int? {
        switch displayedHRSource {
        case .directStrap: return directStrapHeartRate
        case .iPhoneRelay, .none: return heartRate
        }
    }

    /// Pushed by `WatchStrapConnector` on every Heart Rate Measurement
    /// notification from a Watch-paired strap. Updates the displayed-HR
    /// source state — actual relay back to the iPhone happens in the
    /// connector itself (it has the WCSession and the RR list).
    @MainActor
    func applyDirectStrapHR(_ bpm: Int) {
        directStrapHeartRate = bpm
        directStrapHeartRateAt = Date()
    }

    private let log = Logger(subsystem: "com.chrissharp.flowrecovery", category: "WatchSessionManager")
    private var workoutManager: WatchWorkoutManager?

    /// Activate WCSession as early as possible — at @StateObject init time,
    /// well before the first view appears. Activating in `.onAppear` leaves
    /// a window where the user can tap a button (Start workout, voice chat)
    /// before the session is active; the `sendMessage` calls then fail
    /// silently and the Watch appears dead. The workout manager isn't
    /// owned by the session manager so
    /// that's wired separately by `attach(workoutManager:)` from the view's
    /// `.onAppear` handler.
    override init() {
        super.init()
        guard WCSession.isSupported() else {
            statusLine = String(localized: "WatchConnectivity unavailable")
            return
        }
        let session = WCSession.default
        // Set the delegate BEFORE activate() so the activation reply can't
        // race past us — Apple's docs are explicit on this ordering.
        session.delegate = self
        session.activate()
        log.info("[WatchSession] init() activated WCSession")
        statusLine = String(localized: "Connecting to phone…")
    }

    /// Wire the workout manager once the view exists. Safe to call repeatedly
    /// (e.g. on every .onAppear); only the first call sticks.
    func attach(workoutManager: WatchWorkoutManager) {
        if self.workoutManager == nil {
            self.workoutManager = workoutManager
            // If we relaunched straight into a running workout
            // (a restored applicationContext already flipped `isRecording`
            // true before the view wired up the manager), start the
            // keep-alive HKWorkoutSession now. Without it watchOS re-suspends
            // the app the instant the wrist drops and the session is lost
            // again. `start()` is idempotent, so a later isRecording-driven
            // start is a no-op.
            if isRecording {
                workoutManager.start()
            }
        }
    }

    // MARK: Derived helpers for the UI

    var formattedElapsed: String {
        let h = elapsedSeconds / 3600
        let m = (elapsedSeconds % 3600) / 60
        let s = elapsedSeconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    var alpha1Label: String {
        guard let alpha1 else { return "—" }
        return String(format: "%.2f", alpha1)
    }

    /// Distance formatted using the phone-provided unit preference.
    var distanceDisplay: String {
        guard distanceMeters > 0 else { return "—" }
        if unitsPreference == "imperial" {
            return String(format: "%.2f mi", distanceMeters / 1609.344)
        }
        return String(format: "%.2f km", distanceMeters / 1000)
    }

    var elevationDisplay: String {
        guard elevationGainMeters >= 0 else { return "—" }
        if unitsPreference == "imperial" {
            let feet = Int((elevationGainMeters * 3.28084).rounded())
            return "\(feet) ft"
        }
        return "\(Int(elevationGainMeters.rounded())) m"
    }

    var cadenceDisplay: String? {
        guard let c = cadenceSpm, c >= 1 else { return nil }
        return "\(Int(c.rounded())) spm"
    }

    // MARK: - Voice chat trigger (Watch → phone)

    /// Ask the iPhone to open / toggle the AI voice chat. Audio (mic, TTS)
    /// runs on the phone + AirPods; the Watch is only the remote trigger.
    /// No-op if the phone isn't reachable — a short status line tells the
    /// user what happened.
    @MainActor
    func requestVoiceChatToggle() {
        guard WCSession.isSupported() else {
            statusLine = String(localized: "Watch connectivity unavailable")
            return
        }
        // A duplicate tap is dropped rather than reported — the user does not
        // need telling they tapped twice; one trip is enough.
        guard !voiceChatRequestInFlight else {
            log.info("[WatchSession] voice-chat tap ignored — request already in flight")
            return
        }
        voiceChatRequestInFlight = true
        statusLine = String(localized: "Starting on iPhone…")
        armVoiceChatTimeoutClear()
        sendVoiceChatRequest()
    }

    private func sendVoiceChatRequest() {
        let session = WCSession.default
        log.info("[WatchSession] requesting startVoiceChat (reachable=\(session.isReachable))")
        let payload: [String: Any] = ["type": "startVoiceChat", "ts": Date().timeIntervalSince1970]
        guard session.isReachable else {
            queueVoiceChatRequest(payload, on: session)
            return
        }
        sendLiveVoiceChatRequest(payload, on: session)
    }

    /// `@Sendable` so neither handler inherits this type's main-actor
    /// isolation: WatchConnectivity calls them on its own queue, and an
    /// inherited isolation is asserted at entry — a trap, not a hop. Only
    /// decoded values cross into the main-actor task.
    private func sendLiveVoiceChatRequest(_ payload: [String: Any], on session: WCSession) {
        session.sendMessage(
            payload,
            replyHandler: { @Sendable [weak self] reply in
                let label = (reply["voiceChatState"] as? String) ?? "starting"
                Task { @MainActor in self?.applyVoiceChatReply(stateLabel: label) }
            },
            errorHandler: { @Sendable [weak self] err in
                let message = err.localizedDescription
                Task { @MainActor in self?.failVoiceChatRequest(message: message) }
            }
        )
    }

    /// iOS replies synchronously confirming the toggle, so the Watch clears the
    /// pending state immediately instead of waiting out the timeout — the same
    /// contract the workout start/stop handlers use.
    private func applyVoiceChatReply(stateLabel: String) {
        voiceChatStateLabel = stateLabel
        clearVoiceChatPending()
        statusLine = String(localized: "Chat \(voiceChatStateLabel) on iPhone")
    }

    private func failVoiceChatRequest(message: String) {
        clearVoiceChatPending()
        statusLine = String(localized: "Couldn't reach iPhone: \(message)")
    }

    /// Unreachable: queue it via `applicationContext` so it survives until the
    /// iPhone picks it up. Delivery is not immediate, but the tap is no longer
    /// silently dropped.
    private func queueVoiceChatRequest(_ payload: [String: Any], on session: WCSession) {
        do {
            try session.updateApplicationContext(payload)
            statusLine = String(localized: "Queued — open iPhone to start")
        } catch {
            statusLine = String(localized: "Couldn't queue: \(error.localizedDescription)")
            clearVoiceChatPending()
        }
    }

    private func clearVoiceChatPending() {
        voiceChatRequestInFlight = false
        voiceChatTimeoutTask?.cancel()
        voiceChatTimeoutTask = nil
    }

    /// Clears the voice-chat in-flight flag if iOS hasn't confirmed
    /// within 10 s. Prevents the Watch button from being permanently
    /// disabled when the iOS-side reply gets dropped (background death,
    /// suspended app, transferUserInfo deferred-delivery race).
    @MainActor
    private func armVoiceChatTimeoutClear() {
        voiceChatTimeoutTask?.cancel()
        voiceChatTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.voiceChatRequestInFlight {
                self.voiceChatRequestInFlight = false
                self.statusLine = String(localized: "Tap again — iPhone didn't acknowledge")
            }
        }
    }

    // MARK: - Start / stop workout from Watch

    /// Ask the iPhone to start a workout. Uses the reply-handler contract
    /// so the iPhone's real error ("Strap not connected", "Already
    /// recording") surfaces back on the wrist instead of silent optimism.
    @MainActor
    func requestStartWorkout(sportRaw: String, targetZone: Int? = nil) {
        // De-dupe rapid taps. The user reported tapping Start ~3 times
        // during a walk because nothing visibly changed for several
        // seconds; the in-flight gate plus the visual "Starting…"
        // overlay on the Start screen prevents the second + third taps
        // from doing anything (and from queuing duplicate workouts).
        guard !startWorkoutRequestInFlight else {
            log.info("[WatchSession] start-workout tap ignored — request already in flight")
            return
        }
        startWorkoutRequestInFlight = true
        armStartWorkoutTimeoutClear()

        var payload: [String: Any] = ["type": "startWorkoutFromWatch", "sport": sportRaw]
        if let targetZone { payload["targetZone"] = targetZone }
        sendControlMessage(
            payload: payload,
            pendingStatus: String(localized: "Starting on iPhone…"),
            successStatus: String(localized: "Workout started")
        )
    }

    /// Same shape as `armVoiceChatTimeoutClear` — bounded fallback so
    /// the Start button isn't permanently disabled if iOS never confirms.
    @MainActor
    private func armStartWorkoutTimeoutClear() {
        startWorkoutTimeoutTask?.cancel()
        startWorkoutTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.startWorkoutRequestInFlight, !self.isRecording {
                self.startWorkoutRequestInFlight = false
                self.statusLine = String(localized: "Tap again — iPhone didn't acknowledge")
            }
        }
    }

    /// Ask the iPhone to stop the active workout.
    @MainActor
    func requestStopWorkout() {
        sendControlMessage(
            payload: ["type": "stopWorkoutFromWatch"],
            pendingStatus: String(localized: "Stopping on iPhone…"),
            successStatus: String(localized: "Workout stopped")
        )
    }

    /// Ask the iPhone to pause (user-initiated).
    @MainActor
    func requestPauseWorkout() {
        sendControlMessage(
            payload: ["type": "pauseWorkoutFromWatch"],
            pendingStatus: String(localized: "Pausing…"),
            successStatus: String(localized: "Paused")
        )
    }

    /// Ask the iPhone to resume a paused workout.
    @MainActor
    func requestResumeWorkout() {
        sendControlMessage(
            payload: ["type": "resumeWorkoutFromWatch"],
            pendingStatus: String(localized: "Resuming…"),
            successStatus: String(localized: "Resumed")
        )
    }

    /// User tapped Save & Done on the Watch summary screen. Tells the
    /// iPhone to dismiss its post-workout sheet too and clears the
    /// Watch's `justCompleted` banner locally.
    @MainActor
    func requestAcknowledgeFinished() {
        justCompleted = false
        sendControlMessage(
            payload: ["type": "acknowledgeFinishedFromWatch"],
            pendingStatus: String(localized: "Saving…"),
            successStatus: String(localized: "Saved")
        )
    }

    @MainActor
    private func sendControlMessage(
        payload: [String: Any],
        pendingStatus: String,
        successStatus: String
    ) {
        guard WCSession.isSupported() else {
            statusLine = String(localized: "Watch connectivity unavailable")
            return
        }
        let session = WCSession.default
        // Stamp the payload so receivers can dedupe if both the live message
        // and the queued context arrive (race during foreground transition).
        var enriched = payload
        enriched["ts"] = Date().timeIntervalSince1970

        statusLine = pendingStatus

        guard session.isReachable else {
            queueControlMessage(enriched, on: session, pendingStatus: pendingStatus)
            return
        }
        sendLiveControlMessage(enriched, on: session, successStatus: successStatus)
    }

    /// The iPhone is not reachable: queue the intent via applicationContext so
    /// it is not dropped. The phone picks up the latest the moment its
    /// WCSession delegate runs again.
    @MainActor
    private func queueControlMessage(_ payload: [String: Any], on session: WCSession, pendingStatus: String) {
        do {
            try session.updateApplicationContext(payload)
            statusLine = pendingStatus + String(localized: " (open iPhone)")
        } catch {
            statusLine = String(localized: "Couldn't reach iPhone: \(error.localizedDescription)")
        }
    }

    /// `@Sendable` handlers: WatchConnectivity runs them on its own queue (see
    /// `sendVoiceChatRequest`). Only the decoded status line crosses the hop.
    private func sendLiveControlMessage(_ payload: [String: Any], on session: WCSession, successStatus: String) {
        session.sendMessage(
            payload,
            replyHandler: { @Sendable [weak self] reply in
                let status = Self.controlReplyStatus(reply, successStatus: successStatus)
                Task { @MainActor in self?.statusLine = status }
            },
            errorHandler: { @Sendable [weak self] err in
                let status = String(localized: "Couldn't reach iPhone: \(err.localizedDescription)")
                Task { @MainActor in self?.statusLine = status }
            }
        )
    }

    nonisolated private static func controlReplyStatus(_ reply: [String: Any], successStatus: String) -> String {
        guard !(reply["ok"] as? Bool ?? false) else { return successStatus }
        let err = (reply["error"] as? String) ?? String(localized: "unknown error")
        return String(localized: "iPhone: \(err)")
    }

    // MARK: - State restoration (Watch → phone)

    /// Ask the iPhone for the current live snapshot right now. Fired when
    /// the Watch's WCSession activates or regains reachability — critically
    /// after the app relaunches MID-WORKOUT (screen-dark suspension, or a
    /// watchOS reclaim). The iPhone's reply IS the live-state payload, so
    /// feeding it back through `apply()` restores `isRecording` / HR / sport
    /// in one shot and the UI jumps straight to the live screen instead of
    /// offering to start a brand-new workout. No-op when the phone isn't
    /// reachable — the persisted applicationContext restores us instead.
    @MainActor
    func requestCurrentStateFromPhone() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        let payload: [String: Any] = [
            "type": "requestCurrentState",
            "ts": Date().timeIntervalSince1970
        ]
        session.sendMessage(
            payload,
            replyHandler: { @Sendable [weak self] reply in
                let decoded = InboundMessage(reply)
                Task { @MainActor in self?.apply(decoded) }
            },
            errorHandler: { @Sendable [weak self] err in
                let message = err.localizedDescription
                Task { @MainActor in
                    self?.log.info("[WatchSession] requestCurrentState failed: \(message)")
                }
            }
        )
    }

    // MARK: - Incoming message handling

    /// Everything one inbound WCSession message carries, already decoded.
    ///
    /// The three delegate callbacks must not hand the raw
    /// `[String: Any]` across the `@MainActor` hop, which is an error under
    /// Swift 6: `Any` is not Sendable, so the dictionary could in principle be
    /// mutated behind the hop. Decoding happens in the callback and only
    /// this value crosses. `WatchMessageDecoding` is pure and typed.
    struct InboundMessage: Sendable {
        let update: WatchMessageDecoding.StateUpdate
        let command: WatchMessageDecoding.Command?
        /// Captured before the hop so the DEBUG log keeps its schema line
        /// without carrying the untyped dictionary along with it.
        let keys: [String]

        nonisolated init(_ message: [String: Any]) {
            update = WatchMessageDecoding.decode(message)
            command = WatchMessageDecoding.command(message)
            keys = message.keys.sorted()
        }
    }

    private func apply(_ message: InboundMessage) {
        messagesReceived += 1
        // Logging at info in every build would expose the WCSession
        // message schema (heartRate, alpha1, band, sport, …) to anyone
        // with sysdiagnose access. Schema is benign; pattern-of-use
        // isn't. Debug-only.
        #if DEBUG
        if messagesReceived <= 3 || messagesReceived % 10 == 0 {
            log.info("[WatchSession] received message #\(self.messagesReceived), keys=\(message.keys.joined(separator: ","))")
        }
        #endif

        applyDisplayFields(message.update)
        applyRecording(message.update)
        applyVoiceChatState(message.update)
        statusLine = String(localized: "Connected · \(messagesReceived) updates")

        guard let command = message.command else { return }
        applyCommand(command)
    }

    /// The pure display fields: absent means unchanged, in every case.
    ///
    /// Split out of `apply`, which otherwise sits at SwiftLint
    /// cyclomatic complexity 32 against a limit of 15.
    /// The three groups below are the three kinds of thing this
    /// message carries: values to show, a recording state machine, and a
    /// command verb. Splitting on that seam is why the extraction is safe —
    /// none of the assignments here reads another's result.
    private func applyDisplayFields(_ update: WatchMessageDecoding.StateUpdate) {
        applyWorkoutMetrics(update)
        applyModeAndPauseState(update)
    }

    /// What the live screen shows: the numbers coming off the current session.
    private func applyWorkoutMetrics(_ update: WatchMessageDecoding.StateUpdate) {
        if let hr = update.heartRate { heartRate = hr }
        if let pct = update.hrPercentOfMax { hrPercentOfMax = pct }
        if let peak = update.peakHR { peakHR = peak }
        if let elapsed = update.elapsedSeconds { elapsedSeconds = elapsed }
        if let dist = update.distanceMeters { distanceMeters = dist }
        if let pace = update.paceDisplay { paceDisplay = pace }
        if let a = update.alpha1 { alpha1 = a }
        if let b = update.band { band = b }
        if let cad = update.cadenceSpm { cadenceSpm = cad }
        if let gain = update.elevationGainMeters { elevationGainMeters = gain }
    }

    /// How the screen should be configured, rather than what it shows.
    private func applyModeAndPauseState(_ update: WatchMessageDecoding.StateUpdate) {
        if let sport = update.sportLabel { sportLabel = sport }
        if let zone = update.targetZone { targetZone = zone }
        if let units = update.unitsPreference { unitsPreference = units }
        // Watch behavior mode (display-only vs legacy).
        // Stays sticky: once iOS has told us, we keep that value
        // until a new push overrides it.
        if let mode = update.displayOnlyMode { displayOnlyMode = mode }
        if let paused = update.isPaused { isPaused = paused }
        if let auto = update.autoPaused { autoPaused = auto }
    }

    /// The true → false transition is what shows the Save & Done screen, with
    /// no separate "workoutFinished" message. A Watch launch that starts out
    /// not recording does not trigger it.
    private func applyRecording(_ update: WatchMessageDecoding.StateUpdate) {
        guard let rec = update.isRecording else { return }
        let wasRecording = isRecording
        justCompleted = WatchMessageDecoding.justCompleted(
            current: justCompleted, wasRecording: wasRecording, update: update
        )
        if rec { clearStartWorkoutRequest() }
        isRecording = rec
        driveKeepAliveSession(wasRecording: wasRecording, update: update)
    }

    /// The Watch must own a running `HKWorkoutSession` for the whole workout,
    /// or watchOS suspends — and may terminate — the app the moment the screen
    /// darkens: the "it went dark, dropped the session, and offered a NEW
    /// workout on reopen" report.
    ///
    /// Driven off `isRecording` rather than the mode-gated `startWorkout`
    /// message, so it re-arms after a relaunch mid-workout: the restored
    /// applicationContext, or the `requestCurrentState` reply, carries
    /// `isRecording: true` and lands here. The session is discarded on stop and
    /// never finalized into a saved workout, so it cannot duplicate the
    /// iPhone's. Runs in both display-only and legacy modes.
    private func driveKeepAliveSession(wasRecording: Bool, update: WatchMessageDecoding.StateUpdate) {
        switch WatchMessageDecoding.recordingTransition(wasRecording: wasRecording, update: update) {
        case .started: workoutManager?.start()
        case .stopped: workoutManager?.stop()
        case .none: break
        }
    }

    /// Clear the Watch's "Starting…" overlay the moment iOS
    /// confirms recording is live. Prevents a stale-spinner edge case if the
    /// user crosses back to the Start screen before the 10 s timeout fires.
    private func clearStartWorkoutRequest() {
        guard startWorkoutRequestInFlight else { return }
        startWorkoutRequestInFlight = false
        startWorkoutTimeoutTask?.cancel()
        startWorkoutTimeoutTask = nil
    }

    // iOS pushes the voice-chat lifecycle state under
    // `voiceChatState` (idle/starting/listening/thinking/speaking).
    // Update both the label and the in-flight flag so the Watch UI
    // mirrors the conversation state without polling.
    private func applyVoiceChatState(_ update: WatchMessageDecoding.StateUpdate) {
        guard let vState = update.voiceChatStateLabel else { return }
        voiceChatStateLabel = vState
        guard WatchMessageDecoding.clearsVoiceChatRequest(update: update),
              voiceChatRequestInFlight else { return }
        voiceChatRequestInFlight = false
        voiceChatTimeoutTask?.cancel()
        voiceChatTimeoutTask = nil
    }

    private func applyCommand(_ command: WatchMessageDecoding.Command) {
        switch command {
        case .startWorkout: startWorkoutIfAllowed(command)
        case .stopWorkout: workoutManager?.stop()
        case let .strapState(connected, deviceName): applyStrapState(connected, name: deviceName)
        case let .unknown(raw): noteUnrecognisedCommand(raw)
        }
    }

    /// Display-only mode does NOT start an HKWorkoutSession on the Watch. iOS
    /// gates the message too, but a stale build or a downstream bug could still
    /// deliver it — and starting one here would trigger Apple Health's "Record
    /// a workout" offer for a workout the phone is already recording.
    private func startWorkoutIfAllowed(_ command: WatchMessageDecoding.Command) {
        guard WatchMessageDecoding.shouldStartWorkout(for: command, displayOnlyMode: displayOnlyMode) else {
            return
        }
        workoutManager?.start()
    }

    /// In display-only mode this is the Watch's ONLY signal for whether the
    /// strap is paired and reachable, pushed by iOS on connect, disconnect and
    /// battery change. In legacy mode the Watch's own connector stays canonical
    /// for HR — because the Polar SDK's disconnect callback fires 30–60 s late
    /// — and this only tints the pre-workout button.
    private func applyStrapState(_ connected: Bool?, name: String?) {
        if let connected { phoneStrapConnected = connected }
        phoneStrapDeviceName = name
    }

    /// Carried, not silently dropped: a verb this build does not recognise
    /// means a newer iOS build is talking to an older Watch build, and which
    /// verb it was is the whole diagnostic.
    private func noteUnrecognisedCommand(_ raw: String) {
        #if DEBUG
            log.info("[WatchSession] unrecognised message type=\(raw)")
        #else
            _ = raw
        #endif
    }
}

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let state = activationState.rawValue
        let errDesc = error?.localizedDescription ?? "none"
        let activated = activationState == .activated
        let reachable = session.isReachable
        Task { @MainActor in
            self.log.info("[WatchSession] activationDidComplete state=\(state) error=\(errDesc)")
            self.isActivated = activated
            self.isReachable = reachable
            self.applyActivation(activated: activated, reachable: reachable)
        }
    }

    /// Activated and reachable pulls the current state at once, so a relaunch
    /// mid-workout restores the live session instead of offering to start a new
    /// one. No strap-state refresh: the Watch owns its own BLE link through
    /// `WatchStrapConnector`, so iOS has nothing to mirror here.
    @MainActor
    private func applyActivation(activated: Bool, reachable: Bool) {
        guard activated else {
            statusLine = String(localized: "Activation failed")
            return
        }
        guard reachable else {
            statusLine = String(localized: "Waiting for iPhone…")
            return
        }
        requestCurrentStateFromPhone()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.log.info("[WatchSession] reachability changed → \(reachable)")
            self.isReachable = reachable
            if !reachable, self.messagesReceived == 0 {
                self.statusLine = String(localized: "iPhone not reachable")
            }
            if reachable {
                // Connection just came back (phone woke, app
                // foregrounded, IDS re-established). Re-pull current state so
                // a mid-workout reconnect restores the live session.
                self.requestCurrentStateFromPhone()
            }
            // No strap-state refresh on reachability
            // flips. The Watch owns its BLE link directly; iOS isn't
            // a source of truth for strap state on the Watch.
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let snapshot = InboundMessage(applicationContext)
        Task { @MainActor in self.apply(snapshot) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let snapshot = InboundMessage(message)
        Task { @MainActor in self.apply(snapshot) }
    }

    /// Handle the `transferUserInfo` channel — iOS's
    /// reliable fallback for `sendMessage` when the live channel keeps
    /// timing out (`WCErrorCodeTransferTimedOut`). Routes through the
    /// same `apply` so strap state / live state / any future message
    /// type lands uniformly regardless of which transport got there.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let snapshot = InboundMessage(userInfo)
        Task { @MainActor in self.apply(snapshot) }
    }
}
