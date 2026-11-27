import Combine
import Foundation
import os
import WatchConnectivity

extension Notification.Name {
    /// Posted on the main actor when the Watch app requests a workout
    /// start. UserInfo `["sport": Sport.rawValue]`, plus `"targetZone"` when
    /// the Watch picker set one. `AppLaunchTasks`' app-level listener
    /// drives the shared `WorkoutRecorder`; no other listener should act on
    /// this (double-start would be a UX bug).
    static let watchRequestedWorkoutStart = Notification.Name("FlowRecoveryWatchRequestedWorkoutStart")

    /// Posted when the Watch requests a stop, with the tap's time under
    /// `WatchConnectivityBridge.stopTappedAtKey` when the Watch stamped one.
    /// `AppLaunchTasks` listens and calls `recorder.stop(requestedStop:)`. We use a notification rather
    /// than a direct recorder hook so the single owner of the recorder
    /// (the app's `RecorderBox`) stays the only stop path.
    static let watchRequestedWorkoutStop = Notification.Name("FlowRecoveryWatchRequestedWorkoutStop")

    /// Posted when the Watch requests pause, with the tap's time under
    /// `WatchConnectivityBridge.stopTappedAtKey` when the Watch stamped one.
    static let watchRequestedWorkoutPause = Notification.Name("FlowRecoveryWatchRequestedWorkoutPause")

    /// Posted when the Watch requests resume, with the tap's time under
    /// `WatchConnectivityBridge.stopTappedAtKey` when the Watch stamped one.
    static let watchRequestedWorkoutResume = Notification.Name("FlowRecoveryWatchRequestedWorkoutResume")

    /// Posted when the user taps Save & Done on the Watch summary.
    /// `AppLaunchTasks` listens and calls `recorder.acknowledgeFinished()`
    /// so the post-workout sheet on the phone is dismissed too.
    static let watchAcknowledgedFinished = Notification.Name("FlowRecoveryWatchAcknowledgedFinished")
}

// MARK: - Watch Connectivity Bridge (iOS side)
//
// Runs on the iOS app. Sends live workout state (HR, pace, distance, α1, band)
// to the paired Watch app so it can render a glanceable live screen during a
// workout. Receives HR fallback samples from the Watch when the Polar strap
// drops mid-session or during the HRR capture window.
//
// Protocol is message-based (no background file transfer) — small JSON
// payloads over the active WC session. The Watch app is a thin observer, so
// traffic is one-way dominant (iOS → Watch) with occasional replies.
//
// Message keys are stringly typed on purpose: they stay stable across Watch
// target recompiles without requiring codegen.
@Observable
@MainActor
final class WatchConnectivityBridge: NSObject {
    enum MessageKey: String {
        case type
        case displayOnlyMode  // Bool. iOS pushes the user's
                              // `watchDisplayOnlyMode` setting so the Watch
                              // can hide pairing UI / strap pills when the
                              // phone owns the strap. Default true on both
                              // sides so a missing payload is treated as
                              // display-only.
        case heartRate
        case peakHR
        case userMaxHR
        case hrPercentOfMax
        case elapsedSec
        case distanceMeters
        /// Pace rendered on the iOS side using the user's unit preference.
        /// Example values: "5:12 /mi", "3:14 /km". Watch displays the
        /// string as-is so unit drift can't happen.
        case paceDisplay
        /// Pace as a number, so the Watch writes it in its own language with
        /// the unit `units` names. `paceDisplay` stays for Watch builds that
        /// predate it.
        case paceSecPerKm
        case alpha1
        /// The α1 band in the iPhone's app language, for Watch builds that
        /// predate `bandCode`.
        case band
        /// The α1 band as a `LiveDFAAnalyzer.Band` raw value, which the Watch
        /// names in its own language.
        case bandCode
        /// Why α1 is or is not shown: a `LiveDFAAnalyzer.Status.code`
        /// ("ok", "warmup", "stalled", "fitFailed", "tooManyArtifacts"). The
        /// Watch shows `alpha1` only with "ok", so a value never reads as
        /// current when the phone has stopped computing it.
        case alpha1Status
        case sport
        case cadenceSpm
        case elevationGainMeters
        case targetZone
        case units
        case isRecording
        case isPaused
        case autoPaused
        case event
        // Strap-state push
        case strapConnected
        case strapDeviceName
        case strapBatteryPct
        /// Reply-handler payloads use these. `error` is the phone's wording
        /// of a refusal, for Watch builds that predate `errorCode`;
        /// `errorCode` is a `WatchControlRefusal` raw value, which the Watch
        /// words in its own language.
        case ok
        case error
        case errorCode
    }

    enum MessageType: String {
        case liveState             // iOS → Watch live metrics snapshot
        case strapState            // iOS → Watch Polar strap status (connected / battery / name) — pushed independently of workout pipeline so the Watch's pre-workout UI can show "strap ready"
        case startWorkout          // iOS → Watch "begin HKWorkoutSession for HR fallback"
        case stopWorkout           // iOS → Watch "end session"
        case watchHRSample         // Watch → iOS incoming HR sample (fallback)
        case watchStrapSample      // Watch → iOS direct-BLE strap sample (HR + RR intervals). Sent by `WatchStrapConnector` whenever the Watch is paired directly to a chest strap.
        case startVoiceChat        // Watch → iOS "user tapped Talk on my wrist; start AI chat on the phone"
        case startWorkoutFromWatch // Watch → iOS "user tapped Start on my wrist; launch the workout here"
        case stopWorkoutFromWatch  // Watch → iOS "user tapped Stop on my wrist; end the current workout"
        case pauseWorkoutFromWatch  // Watch → iOS "user tapped Pause on my wrist"
        case resumeWorkoutFromWatch // Watch → iOS "user tapped Resume on my wrist"
        case acknowledgeFinishedFromWatch // Watch → iOS "user tapped Save & Done on the Watch summary"
        case requestStrapState     // Watch → iOS "send me the current strap status now" (Watch fires on activation so it never has to wait for the next iOS-pushed change)
        case requestCurrentState   // Watch → iOS "send me the current live workout snapshot now" (Watch fires on activation / foreground so a relaunch mid-workout restores the live session instead of offering a new one). Reply IS the liveState payload.
        case coachAlert            // iOS → Watch "play a wrist haptic for a coach alert" (`urgent`, `firedAt`); a late one is dropped on the Watch
        case workoutSaveState      // iOS → Watch "the workout that just ended was not saved" (`notSaved`): an accidental start the summary offers to save
        // There is no voice-trigger (iOS → Watch) or stop-voice-chat
        // (Watch → iOS) message: the Watch has no UI for either. Add them
        // with both a sender and a handler if it grows one.
    }

    // MARK: - Cross-process hooks

    /// Called on the main actor when the Watch requests a voice-chat action.
    /// Set by the app wiring layer to point at the shared
    /// `VoiceConversationController`; left as a closure so this bridge stays
    /// decoupled from the voice stack (bridge is networking, voice is audio).
    ///
    /// Returns nil when the request was accepted, or why it was refused, for
    /// the Watch to surface: the wiring in `EmuquApp` refuses a user the
    /// paywall would stop on the phone, as it does a Watch Start.
    var onStartVoiceChatFromWatch: (() -> WatchControlRefusal?)?

    /// Called when the Watch sends `requestStrapState` (typically right
    /// after WCSession activation on the Watch side). Set by
    /// `mirrorStrapState(from:)` so the Watch gets the latest strap state
    /// immediately on activation, even when no Polar event has fired since
    /// iOS launched.
    var onRequestStrapStateFromWatch: (() -> Void)?

    /// Called when the iOS-side WCSession finishes activating with the
    /// Watch reachable. Set by `mirrorStrapState(from:)` so the very
    /// first thing iOS does after the connection is live is push the
    /// current strap snapshot — without this, the change observation
    /// might never fire (strap is stable, no events) and the Watch
    /// would sit in "no strap" forever even when iOS knows otherwise.
    var onWCSessionActivated: (() -> Void)?

    /// Called on the main actor when the Watch asks us to start a workout.
    /// `sportRaw` is the `Sport.rawValue` string ("run", "walk", "bike",
    /// "treadmill", etc.; `Sport` raw values) selected by the user on the Watch. `targetZone`
    /// is optional — if the Watch picker set one, carry it through so
    /// zones configured on the wrist are honoured on the phone.
    /// Wired at app-launch so a wrist tap can begin a phone-tracked
    /// workout even when the iOS app is suspended (iOS wakes the app
    /// to deliver the WC message — as long as the user hasn't
    /// force-quit it).
    ///
    /// Returns nil when the request was accepted, or why it was refused, for
    /// the Watch to surface (the wiring in `EmuquApp` refuses a sport it
    /// cannot parse, and a user the paywall would stop on the phone). The
    /// start itself runs asynchronously, so a recorder failure is logged on
    /// the phone, not sent back.
    var onStartWorkoutFromWatch: ((_ sportRaw: String, _ targetZone: Int?) -> WatchControlRefusal?)?

    /// The `watchRequestedWorkoutStop`, `watchRequestedWorkoutPause` and
    /// `watchRequestedWorkoutResume` userInfo key for the `Date` the End,
    /// Pause or Resume was tapped on the wrist.
    nonisolated static let stopTappedAtKey = "tappedAt"

    /// Called on the main actor when the Watch asks us to stop the active
    /// workout, with when the End was tapped on the wrist (the message's
    /// `ts`; nil when it carries none). A queued End reaches the phone long
    /// after the tap, and the workout ends at the tap. Same reply-contract as
    /// start; the wiring only posts a notification, so it always returns nil.
    var onStopWorkoutFromWatch: ((_ tappedAt: Date?) -> WatchControlRefusal?)?

    /// Called on the main actor when the Watch asks us to pause the
    /// active workout, with when the Pause was tapped (the message's `ts`;
    /// nil when it carries none): a live send that failed is queued and
    /// arrives after the tap, and the workout pauses at the tap.
    /// Reply-contract matches start/stop.
    var onPauseWorkoutFromWatch: ((_ tappedAt: Date?) -> WatchControlRefusal?)?

    /// Called on the main actor when the Watch asks us to resume the
    /// active workout, with when the Resume was tapped (the message's `ts`;
    /// nil when it carries none): a queued Resume arrives after the tap, and
    /// the workout resumes at the tap. Reply-contract matches the others.
    var onResumeWorkoutFromWatch: ((_ tappedAt: Date?) -> WatchControlRefusal?)?

    /// Called on the main actor when the user taps Save & Done on the
    /// Watch summary. The workout has already been archived at stop
    /// time; this is just the "dismiss the post-workout sheet on the
    /// phone so it's not sitting there next time you pick it up" hook.
    /// Reply-contract matches the other control messages.
    var onAcknowledgeFinishedFromWatch: (() -> WatchControlRefusal?)?

    // MARK: Published

    /// True when a Watch is paired to this iPhone. Independent of
    /// `WCSession.isReachable` (which is true only while the Watch app is in
    /// the foreground). `isWatchPaired` reads `WCSession.isPaired`,
    /// which iOS sets the moment a Watch is paired in the iOS Watch
    /// app — it stays true even when the Watch is asleep or
    /// disconnected. Use this as the "should I fall back to Watch
    /// wrist HR when no strap is paired?" signal.
    nonisolated var isWatchPaired: Bool {
        guard WCSession.isSupported() else { return false }
        return WCSession.default.isPaired
    }
    /// Latest HR sample received from the Watch (fallback when strap is gone).
    /// Setting it stamps `latestWatchHRAt`; clearing it clears the stamp.
    var latestWatchHR: Int? {
        didSet { latestWatchHRAt = latestWatchHR == nil ? nil : Date() }
    }
    /// When the Watch last sent `latestWatchHR`. Nil before the first sample
    /// and after the Watch becomes unreachable, so a Watch that stopped
    /// sending reads as stale rather than leaving its last reading behind.
    private(set) var latestWatchHRAt: Date?

    /// Latest direct-BLE strap sample relayed from the Watch — HR plus
    /// the RR intervals from that notification. Source: `watchStrapSample`
    /// messages sent by the Watch's `WatchStrapConnector` whenever the
    /// user paired a chest strap directly to the wrist. Consumers (the
    /// workout recorder pipeline) can fold these in as a fallback when
    /// iOS's own PolarManager isn't holding a strap connection.
    var latestWatchStrapHR: Int?
    var latestWatchStrapAt: Date?
    /// Accumulating queue of un-consumed RR samples, each beat with the time
    /// it ended by the Watch's clock (`WatchStrapBeat`). The
    /// recorder ticks at 1 Hz; the Watch may forward 2-3 samples per
    /// tick during dense beat periods. Reading only `latestWatchStrap…`
    /// drops samples in that window. The recorder calls
    /// `drainPendingWatchStrapRR()` on each tick to claim everything
    /// queued since the last drain.
    var pendingWatchStrapRR: [WatchStrapBeat] = []
    let pendingWatchStrapRRLock = NSLock()

    /// Pop all queued Watch-routed RR intervals. Returned in arrival
    /// order. Called by the workout ticker's
    /// `consumeWatchRoutedStrapFallback` whenever a Watch strap sample is
    /// under 10 s old (the beats are used only while the phone's own strap
    /// is silent, but drained either way), and at workout start
    /// (`StartBaselines`), which discards what queued before the workout.
    func drainPendingWatchStrapRR() -> [WatchStrapBeat] {
        pendingWatchStrapRRLock.lock()
        defer { pendingWatchStrapRRLock.unlock() }
        let drained = pendingWatchStrapRR
        pendingWatchStrapRR.removeAll(keepingCapacity: true)
        return drained
    }

    /// Highest `ts` field we've already processed from a queued Watch intent
    /// (applicationContext or transferUserInfo). `acceptsQueuedIntent` drops
    /// one not newer than it, so a context delivered again — the framework
    /// re-delivers the latest on activation — does not run (e.g.) two
    /// startWorkoutFromWatch calls in a row. The live `didReceiveMessage`
    /// path does not record it: the Watch sends each intent on one channel.
    @MainActor var lastProcessedContextTimestamp: Double = 0

    /// When the workout now recording began, worked out from its first live
    /// tick (that tick's time minus its elapsed seconds); nil when no workout
    /// is recording. A queued Watch stop, pause or resume stamped before it
    /// was meant for an earlier workout and is dropped.
    @ObservationIgnored @MainActor var liveWorkoutStartedAt: Date?

    // MARK: Config

    /// The settings whose `watchDisplayOnlyMode` is mirrored to the Watch.
    private let settingsManager: SettingsManager
    /// The chat, whose disclaimer a Watch Talk request checks.
    let assistantViewModel: @MainActor () -> AssistantViewModel
    /// The voice controller a Watch Talk request reports the state of.
    let voiceConversation: @MainActor () -> VoiceConversationController

    /// WCSession is process-wide and thread-safe. Marked `nonisolated` so
    /// the transport queue can read it without an actor hop.
    nonisolated private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }

    /// Dedicated serial queue for all WCSession transport work. Keeping the
    /// bridge @MainActor is right for publishing — SwiftUI needs
    /// `latestWatchHR` on main — but `WCSession.sendMessage`
    /// itself is thread-safe and can block briefly on XPC under load (queue
    /// backup when the Watch is unreachable but `isReachable` hasn't flipped
    /// yet, bad transport state, etc.). Running sends on this queue removes
    /// the main-thread freeze risk regardless of what the system is doing.
    nonisolated let wcQueue = DispatchQueue(
        label: "com.chrissharp.flowrecovery.watchbridge.transport",
        qos: .utility
    )

    /// Skip WCSession activation when the user
    /// has Watch connectivity disabled. Reads via the UserDefaults mirror
    /// because this class is built by the app's stored-property initialisers and may run
    /// before SettingsManager has read its JSON file from the App Group
    /// container.
    ///
    /// The delegate is wired synchronously so any incoming Watch message (which
    /// can arrive before our boot() runs if the Watch app was already
    /// foregrounded) lands on this instance. Activation itself is deferred to
    /// keep the synchronous launch path fast — see boot() below.
    ///
    /// The chat and the voice controller are resolvers, read when a Watch
    /// Talk request is answered, so building the bridge builds neither.
    init(
        settingsManager: SettingsManager,
        assistantViewModel: @escaping @MainActor () -> AssistantViewModel,
        voiceConversation: @escaping @MainActor () -> VoiceConversationController
    ) {
        NSLog("[WatchBridge] init() — entry (lightweight; activate() deferred to boot())")
        self.settingsManager = settingsManager
        self.assistantViewModel = assistantViewModel
        self.voiceConversation = voiceConversation
        super.init()
        guard let session else {
            NSLog("[WatchBridge] init() — WCSession not supported, returning")
            return
        }
        guard UserSettings.performanceFlag(.enableWatchConnectivity) else {
            NSLog("[WatchBridge] init() — Watch connectivity disabled in Settings, skipping activate()")
            return
        }
        session.delegate = self
    }

    /// Activate WCSession on a
    /// post-first-frame `.task` instead of inline in `init`. Heavy work that
    /// runs synchronously before SwiftUI can paint holds the splash, and
    /// `session.activate()` is heavy — Apple's WatchConnectivity framework
    /// touches the paired-device IPC socket and emits CoreFoundation
    /// stderr noise. Deferring removes it from the launch critical path.
    ///
    /// **Idempotent.** Safe to call from multiple `.task` modifiers; the
    /// underlying `WCSession.activate()` is itself idempotent. The local
    /// `_didActivate` flag short-circuits repeated calls so we don't pay
    /// the cost more than once per process.
    ///
    /// **Deferral is safe.** activationDidCompleteWith + the `onWCSession
    /// Activated` callback fire the same way as with eager activation —
    /// the only observable difference is a few hundred ms of delay before
    /// activation begins, which the Watch-side path tolerates because it
    /// retries pushed state on `sessionReachabilityDidChange` regardless.
    ///
    /// The delegate is set here too: `init` sets it only when Watch
    /// connectivity was on at init, and a flag turned on between the two
    /// would otherwise activate a session no callback reaches.
    func boot() {
        guard !didActivate.withLock({ $0 }) else { return }
        guard let session else { return }
        guard UserSettings.performanceFlag(.enableWatchConnectivity) else { return }
        didActivate.withLock { $0 = true }
        session.delegate = self
        // Prime the watchDisplayOnlyMode mirror so the first WCSession
        // callback doesn't see the safe-default `true` placeholder.
        // Then subscribe to settings changes to keep the mirror fresh.
        let settingsManager = settingsManager
        Self.refreshCachedWatchDisplayOnlyMode(from: settingsManager)
        Task { @MainActor in Self.armWatchDisplayModeObservation(settingsManager) }
        NSLog("[WatchBridge] boot() — calling session.activate()")
        session.activate()
        NSLog("[WatchBridge] boot() — session.activate() returned")
    }

    /// Combine subscriptions for the watchDisplayOnlyMode
    /// mirror. See `cachedWatchDisplayOnlyMode` doc-comment for why
    /// this exists.
    /// Re-arms itself: `withObservationTracking` is one-shot. `SettingsManager`
    /// is not main-actor-isolated, so this reads the settings directly instead of
    /// going through `ObservationLoop` (whose owner must be Sendable).
    @MainActor
    private static func armWatchDisplayModeObservation(_ settingsManager: SettingsManager) {
        withObservationTracking {
            _ = settingsManager.settings.watchDisplayOnlyMode
        } onChange: {
            Task { @MainActor in
                Self.refreshCachedWatchDisplayOnlyMode(from: settingsManager)
                Self.armWatchDisplayModeObservation(settingsManager)
            }
        }
    }

    /// Tracks whether boot() has run. Behind a lock so it can be read from
    /// any thread without a hop to the main actor.
    @ObservationIgnored private let didActivate = OSAllocatedUnfairLock(initialState: false)

    // MARK: - Live state push

    /// One tick of live workout state, as the Watch face needs it.
    ///
    /// A parameter object rather than a long argument list: there is exactly
    /// one caller — `WorkoutTicker+Tick.pushLiveStateToWatch` — and the
    /// arguments group naturally (`LiveTotals` carries the running totals).
    struct LiveState {
        let sport: Sport
        let heartRate: Int?
        let peakHR: Int
        let userMaxHR: Int
        let totals: LiveTotals
        let paceDisplay: String?
        let alpha1: Double?
        /// `band` in the app language, for Watch builds that read no
        /// `bandCode`.
        let band: String
        let cadenceSpm: Double?
        let targetZone: Int?
        let unitsPreference: String
        let isRecording: Bool
        let isPaused: Bool
        let autoPaused: Bool
        /// The pace `paceDisplay` shows, as a number; nil when not measured.
        var paceSecPerKm: Double?
        /// The analyzer's status for `alpha1`.
        var alpha1Status: LiveDFAAnalyzer.Status = .warmup(fractionReady: 0)

        /// The band `band` names. `LiveDFAAnalyzer` sets its `currentBand`
        /// to `Band.display(alpha1:)` whenever it sets `currentAlpha1`, and
        /// to `.unknown` whenever it clears it, so the band follows from
        /// `alpha1` alone.
        var bandCode: LiveDFAAnalyzer.Band {
            alpha1.map(LiveDFAAnalyzer.Band.display(alpha1:)) ?? .unknown
        }
    }

    /// Broadcast a live state snapshot to the Watch.
    ///
    /// Transport strategy (in order of priority):
    ///   1. If the paired Watch app is in the foreground (`isReachable`),
    ///      use `sendMessage` — immediate, realtime delivery, not throttled.
    ///      This is what keeps the live HR / DFA / distance visibly ticking.
    ///   2. Fall back to `updateApplicationContext` so the Watch gets the
    ///      most recent snapshot when it next comes to foreground.
    ///
    /// **Threading.** The main-actor caller only does cheap payload
    /// construction; everything that can block — WCSession state checks
    /// and the `sendMessage` / `updateApplicationContext` calls — hops to
    /// `wcQueue`. The workout live screen freezing at 20 min and jumping
    /// forward when the user tapped something was the main-thread
    /// fingerprint of a synchronous WC send; this removes that risk.
    ///
    /// Errors are LOGGED (not swallowed) so failures are debuggable.
    ///
    /// The payload is frozen into a `let` before it crosses the
    /// queue boundary. Every mutation happens on this thread and none after,
    /// so there is no race; but a `var` captured by an escaping closure
    /// means the next person to add a key creates one silently, and the
    /// compiler cannot prove otherwise.
    func sendLiveState(_ state: LiveState) {
        if state.isRecording, liveWorkoutStartedAt == nil {
            liveWorkoutStartedAt = Date().addingTimeInterval(-TimeInterval(state.totals.elapsedSec))
        }
        let frozen = Self.liveStatePayload(state)
        wcQueue.async { [weak self] in
            self?.transportLiveStatePayload(frozen)
        }
    }

    /// Flatten one tick into the wire dictionary. Optional metrics with no
    /// value are left out: WatchConnectivity carries property lists, which
    /// have no null. The Watch reads a metric missing from a `liveState` tick
    /// as "not measured" and clears it, so a dropped strap shows "—" rather
    /// than its last value, and zero still means zero.
    static func liveStatePayload(_ state: LiveState) -> [String: any Sendable] {
        var payload = liveStateBase(
            sport: state.sport, peakHR: state.peakHR, userMaxHR: state.userMaxHR,
            totals: state.totals, band: state.band, unitsPreference: state.unitsPreference
        )
        payload[MessageKey.isRecording.rawValue] = state.isRecording
        payload["ts"] = Date().timeIntervalSince1970
        payload[MessageKey.isPaused.rawValue] = state.isPaused
        payload[MessageKey.autoPaused.rawValue] = state.autoPaused
        addHeartRate(state.heartRate, userMaxHR: state.userMaxHR, to: &payload)
        payload[MessageKey.bandCode.rawValue] = state.bandCode.rawValue
        payload[MessageKey.alpha1Status.rawValue] = state.alpha1Status.code
        if let alpha1 = state.alpha1 { payload[MessageKey.alpha1.rawValue] = alpha1 }
        if let paceDisplay = state.paceDisplay { payload[MessageKey.paceDisplay.rawValue] = paceDisplay }
        if let pace = state.paceSecPerKm { payload[MessageKey.paceSecPerKm.rawValue] = pace }
        if let cadenceSpm = state.cadenceSpm { payload[MessageKey.cadenceSpm.rawValue] = cadenceSpm }
        if let targetZone = state.targetZone { payload[MessageKey.targetZone.rawValue] = targetZone }
        return payload
    }

    /// The running totals one live tick reports.
    struct LiveTotals {
        let elapsedSec: Int
        let distanceMeters: Double
        let elevationGainMeters: Double
    }

    /// The keys every live tick carries.
    ///
    /// The watch behavior mode goes out every tick so the Watch
    /// UI can hide its strap-pairing surface and any "tap to start"
    /// affordances when the phone owns the BLE.
    private static func liveStateBase(
        sport: Sport,
        peakHR: Int,
        userMaxHR: Int,
        totals: LiveTotals,
        band: String,
        unitsPreference: String
    ) -> [String: any Sendable] {
        [
            MessageKey.type.rawValue: MessageType.liveState.rawValue,
            MessageKey.sport.rawValue: sport.rawValue,
            MessageKey.peakHR.rawValue: peakHR,
            MessageKey.userMaxHR.rawValue: userMaxHR,
            MessageKey.elapsedSec.rawValue: totals.elapsedSec,
            MessageKey.distanceMeters.rawValue: totals.distanceMeters,
            MessageKey.elevationGainMeters.rawValue: totals.elevationGainMeters,
            MessageKey.band.rawValue: band,
            MessageKey.units.rawValue: unitsPreference,
            MessageKey.displayOnlyMode.rawValue: WatchConnectivityBridge.watchDisplayOnlyMode()
        ]
    }

    /// HR-as-%-of-max is pre-computed on the iPhone so the Watch doesn't have
    /// to know about the user-max rules (override vs the 208 − 0.7 × age fallback) —
    /// those live on the settings side.
    private static func addHeartRate(_ heartRate: Int?, userMaxHR: Int, to payload: inout [String: any Sendable]) {
        guard let heartRate else { return }
        payload[MessageKey.heartRate.rawValue] = heartRate
        guard userMaxHR > 0 else { return }
        payload[MessageKey.hrPercentOfMax.rawValue] = Int((Double(heartRate) / Double(userMaxHR) * 100).rounded())
    }

    // MARK: - Strap state (independent of workout pipeline)
    //
    // Separate channel for "is your Polar strap connected?
    // what's the battery? what's the device name?" so the Watch UI can
    // show strap readiness BEFORE a workout starts. The live-state push
    // above only runs while a workout is recording — without this
    // channel the Watch had no way to display strap status during the
    // pre-workout planning step.

    /// Mirrors the phone's strap to the Watch: once now, again on every
    /// change of connection, device or battery, and whenever the Watch asks
    /// or the session activates. Without it the Watch never hears about the
    /// phone's strap and its pre-workout hint always says none is connected.
    func mirrorStrapState(from polar: PolarManager) {
        onRequestStrapStateFromWatch = { [weak self, weak polar] in
            guard let polar else { return }
            self?.pushStrapState(of: polar)
        }
        onWCSessionActivated = onRequestStrapStateFromWatch
        ObservationLoop.observe(
            polar,
            initial: true,
            read: { StrapSnapshot(polar: $0) },
            onChange: { [weak self] _, snapshot in self?.pushStrapState(snapshot) }
        )
    }

    /// What the Watch is told about the phone's strap.
    private struct StrapSnapshot {
        let connected: Bool
        let deviceName: String?
        let batteryPercent: Int?

        @MainActor
        init(polar: PolarManager) {
            connected = polar.linkState.connectionState == .connected
            deviceName = connected ? polar.linkState.connectedDeviceType?.displayName : nil
            batteryPercent = connected ? polar.linkState.batteryLevel : nil
        }
    }

    private func pushStrapState(of polar: PolarManager) {
        pushStrapState(StrapSnapshot(polar: polar))
    }

    private func pushStrapState(_ snapshot: StrapSnapshot) {
        pushStrapState(connected: snapshot.connected, deviceName: snapshot.deviceName, batteryPercent: snapshot.batteryPercent)
    }

    /// Push the current Polar strap state to the Watch. Cheap to call
    /// repeatedly. Goes out by `sendMessage` when the Watch is reachable and
    /// by `transferUserInfo`, which the framework queues and delivers when
    /// the Watch wakes.
    ///
    /// It deliberately stays off the live-state path: that path caches the
    /// payload as the workout snapshot and writes it to the application
    /// context, so a strap update mid-workout would replace the snapshot a
    /// relaunched Watch restores from.
    func pushStrapState(connected: Bool, deviceName: String?, batteryPercent: Int?) {
        var payload: [String: any Sendable] = [
            MessageKey.type.rawValue: MessageType.strapState.rawValue,
            MessageKey.strapConnected.rawValue: connected,
            MessageKey.displayOnlyMode.rawValue: WatchConnectivityBridge.watchDisplayOnlyMode()
        ]
        if let deviceName { payload[MessageKey.strapDeviceName.rawValue] = deviceName }
        if let batteryPercent { payload[MessageKey.strapBatteryPct.rawValue] = batteryPercent }
        sendDualChannel(payload, label: "strapState")
    }

    /// Queue-isolated transport. Running on `wcQueue`, never main.
    /// Repeated sendMessage timeouts trip a short-term circuit breaker
    /// (`WatchSendTimeoutBreaker`). iOS occasionally reports
    /// `isReachable = true` for a fraction of a second when the Watch is
    /// actually unreachable (during init, after wake, when the Watch app was
    /// force-quit). Each `sendMessage` then waits the framework's full timeout
    /// and fires `WCErrorCodeTransferTimedOut` — visible in the user's console
    /// as 5–10 timeout pairs in a row, plus the framework's own internal logs
    /// we can't suppress. While the breaker is open we skip `sendMessage`
    /// entirely; the fallback `updateApplicationContext` path still gets the
    /// latest snapshot. It closes when reachability flips back to true
    /// (delegate callback resets it) or when its cooldown runs out, so a Watch
    /// that stays reachable through a long workout gets live updates again
    /// after a few scattered timeouts.
    /// Wrapped in `OSAllocatedUnfairLock` so concurrent
    /// `transportLiveStatePayload` invocations can't race on it.
    /// A per-process static; `bumpTimeoutCount` returns the new count for
    /// logging.
    nonisolated private static let timeoutBreaker = OSAllocatedUnfairLock(initialState: WatchSendTimeoutBreaker())

    nonisolated private static var isCircuitOpen: Bool {
        let now = Date()
        return timeoutBreaker.withLock { $0.isOpen(at: now) }
    }
    @discardableResult
    nonisolated private static func bumpTimeoutCount() -> Int {
        let now = Date()
        return timeoutBreaker.withLock { breaker in
            breaker.noteTimeout(at: now)
            return breaker.timeouts
        }
    }
    nonisolated static func resetTimeoutCount() {
        timeoutBreaker.withLock { $0 = WatchSendTimeoutBreaker() }
    }

    /// While a workout is recording, ALWAYS persist the snapshot
    /// to applicationContext (in addition to the fast sendMessage path), not
    /// just on the unreachable/failure branch. That is the persistent channel
    /// WCSession delivers on activation: a Watch app suspended/killed when the
    /// screen darkened restores the live session the instant it relaunches,
    /// instead of sitting on the Start screen offering a new workout.
    /// `updateApplicationContext` coalesces to the latest value, so doing it
    /// per-tick is cheap.
    ///
    /// A Watch that is asleep / backgrounded / circuit-broken can't take
    /// `sendMessage`, so it gets the context write alone. A foreground Watch
    /// gets immediate realtime delivery; `sendMessage`'s completion runs on an
    /// arbitrary thread, so the fallback hops back to `wcQueue` to stay off
    /// main.
    ///
    /// The context is written once per tick, whichever reason applies, and
    /// only while the tick is still the newest snapshot (`updateLiveStateContextIfLatest`).
    nonisolated func transportLiveStatePayload(_ payload: [String: any Sendable]) {
        guard let session else { return }
        // Cache the latest snapshot regardless of transport
        // outcome so a Watch that relaunches mid-workout can pull it on
        // demand via `requestCurrentState`. Cheap; overwrites the previous.
        Self.cacheLiveState(payload)
        guard canTransport(session) else { return }
        let isRecording = (payload[MessageKey.isRecording.rawValue] as? Bool) ?? false
        let canSend = session.isReachable && !Self.isCircuitOpen
        if isRecording || !canSend {
            updateLiveStateContextIfLatest(payload)
        }
        guard canSend else { return }
        session.sendMessage(payload, replyHandler: nil) { [weak self] error in
            self?.fallBackToContext(payload, after: error)
        }
    }

    /// A failed `sendMessage` still has to leave the Watch with the latest
    /// state, so fall back to the application-context channel.
    ///
    /// `self` is bound once at the boundary rather than read twice through a
    /// weak reference (`self?.wcQueue.async { self?.… }`): two reads can
    /// disagree, scheduling the hop off a live `self` and then doing nothing
    /// because the second read came back nil. Binding once means the
    /// fallback either runs whole or never starts.
    nonisolated private func fallBackToContext(_ payload: [String: any Sendable], after error: Error) {
        Self.logSendFailure(error)
        wcQueue.async { self.updateLiveStateContextIfLatest(payload) }
    }

    /// Writes `payload` to the application context unless a newer snapshot
    /// has been cached since (`cacheLiveState` keeps the newest by `ts`). A
    /// send error can arrive seconds after its tick; written then, a
    /// recording tick replaced the stop `stopWatchWorkoutSession` had already
    /// written, and a Watch relaunched while the phone was unreachable
    /// restored a workout that had ended.
    nonisolated private func updateLiveStateContextIfLatest(_ payload: [String: any Sendable]) {
        if let ts = payload["ts"] as? Double, let newest = Self.cachedLiveState()?["ts"] as? Double, newest > ts {
            return
        }
        updateLiveStateContextLocked(payload)
    }

    /// The OS-level WCSession emits
    /// "WCSession counterpart app not installed" + the companion
    /// `_block_invoke failed due to WCErrorCodeWatchAppNotInstalled` warning
    /// every time we try sendMessage / updateApplicationContext when the user
    /// has a paired Watch but no Watch app installed. We can't
    /// suppress those os_log lines from inside our process — but we CAN avoid
    /// issuing the call at all by checking `isWatchAppInstalled` first. That
    /// is the property WatchConnectivity itself checks before raising the
    /// error; gating on it cuts the noise to zero in that configuration.
    ///
    /// An unpaired Watch is silent too, so we don't spam logs on every tick.
    /// A session that is not activated (Watch connectivity off in Settings
    /// leaves it so for the whole process) is logged once per state, through
    /// the same once-per-message gate as the context errors.
    nonisolated private func canTransport(_ session: WCSession) -> Bool {
        guard session.activationState == .activated else {
            let message = "skipping sendLiveState — session state=\(session.activationState.rawValue)"
            if Self.noteContextError(message) { debugLog("[WatchBridge] \(message)", level: .warning) }
            return false
        }
        return session.isPaired && session.isWatchAppInstalled
    }

    /// 7007 = WCSessionReplyHandlerFailed (expected if the Watch app isn't
    /// foreground). 7003 = WCSessionNotActivated. 7012 =
    /// WCErrorCodeTransferTimedOut (Watch claims reachable but the framework
    /// gives up). Every case falls back to `updateApplicationContext` so the
    /// latest snapshot still lands when the Watch wakes up; a timeout also
    /// trips the circuit breaker so we don't spam more sends into the void.
    nonisolated private static func logSendFailure(_ error: Error) {
        let nsError = error as NSError
        guard nsError.code == 7012 else {
            #if DEBUG
                debugLog("[WatchBridge] sendMessage error \(nsError.code): \(error.localizedDescription) — falling back to applicationContext", level: .warning)
            #endif
            return
        }
        let newCount = bumpTimeoutCount()
        #if DEBUG
            debugLog("[WatchBridge] sendMessage timed out (consecutive=\(newCount)) — falling back to applicationContext", level: .warning)
        #else
            _ = newCount
        #endif
    }

    /// `updateApplicationContext` is thread-safe, but we funnel through
    /// `wcQueue` for consistency with the rest of the transport path.
    ///
    /// When the user has no Watch app installed,
    /// every per-second sample tries to push context and every push fails
    /// with "Watch app is not installed"; logging each failure once
    /// produced ~2000 identical lines in a 35-min walk —
    /// drowning the rest of the diagnostics. We log the FIRST
    /// occurrence + every transition, but suppress the steady-state
    /// repeat. The condition is sticky (per-process); a watchOS
    /// install changes the WatchBridge isCompanionAppInstalled signal
    /// and we'd resume normal logging at that point.
    nonisolated private func updateLiveStateContextLocked(_ payload: [String: any Sendable]) {
        guard let session else { return }
        // Same guard as transportLiveStatePayload.
        // Some callers reach this path directly (the `sendMessage`
        // failure fallback, `fallBackToContext`) so the guard has to be
        // local too.
        guard session.isPaired, session.isWatchAppInstalled else { return }
        do {
            try session.updateApplicationContext(payload)
            Self.lastContextErrorMessage.withLock { $0 = nil }
        } catch {
            let message = error.localizedDescription
            let shouldLog = Self.noteContextError(message)
            if shouldLog {
                debugLog("[WatchBridge] updateApplicationContext error: \(message)", level: .warning)
            }
        }
    }

    /// Sticky last-error storage so the steady-state "Watch app is not
    /// installed" failure logs once instead of per-tick. Process-local;
    /// resets on app launch.
    nonisolated private static let lastContextErrorMessage = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Records the latest context error; true when it differs from the last
    /// one, so a repeating failure logs once instead of every push.
    nonisolated private static func noteContextError(_ message: String) -> Bool {
        lastContextErrorMessage.withLock { last in
            defer { last = message }
            return last != message
        }
    }

    /// The most recent live-state snapshot pushed to the Watch,
    /// cached so we can answer the Watch's `requestCurrentState` immediately
    /// (relaunch-mid-workout restoration) without waiting for the next tick.
    /// Process-local; nil until the first live-state push of a workout.
    ///
    /// The outbound payload chain is typed `[String: any Sendable]`, which is
    /// Sendable, so the lock owns the state directly instead of a
    /// `nonisolated(unsafe) var` behind an `NSLock`: there is no mutable
    /// static for anything to reach around.
    nonisolated private static let liveStateCache =
        OSAllocatedUnfairLock<[String: any Sendable]?>(initialState: nil)

    /// An older snapshot never replaces a newer one. The stop is cached on
    /// the main thread while a live tick queued just before it is still
    /// waiting on the WatchConnectivity queue; written after, it put the
    /// cache back to "recording", and a Watch relaunched then showed a
    /// workout that had ended.
    nonisolated static func cacheLiveState(_ payload: [String: any Sendable]) {
        liveStateCache.withLock { cached in
            if let newTs = payload["ts"] as? Double, let cachedTs = cached?["ts"] as? Double, newTs < cachedTs {
                return
            }
            cached = payload
        }
    }

    nonisolated static func cachedLiveState() -> [String: any Sendable]? {
        liveStateCache.withLock { $0 }
    }

    /// Lock-protected mirror of the injected settings' `watchDisplayOnlyMode`.
    /// Avoids a `DispatchQueue.main.sync` hop, which iOS
    /// 26 flags as "Potential Structural Swift Concurrency
    /// Issue: unsafeForcedSync called from Swift Concurrent context"
    /// — `WCSession` delegate callbacks land on a background queue,
    /// and synchronously waiting for the main thread there means
    /// that if main is busy (animating, archive walking, sheet
    /// presenting) the WCSession queue blocks for that duration, and
    /// from a Swift Concurrency cooperative-pool task `main.sync`
    /// risks deadlock entirely. The mirror is read with a quick lock
    /// (microseconds, no actor hop) and refreshed on every
    /// `SettingsManager` change via the `withObservationTracking` loop
    /// that `boot()` starts.
    nonisolated private static let cachedWatchDisplayOnlyMode = OSAllocatedUnfairLock(initialState: true)

    /// Lock-protected snapshot read. Safe from any thread. Returns the
    /// last mirrored value (or the safe default `true` until the first
    /// settings refresh fires post-launch).
    nonisolated private static func watchDisplayOnlyMode() -> Bool {
        cachedWatchDisplayOnlyMode.withLock { $0 }
    }

    /// Refresh the mirror. Called from MainActor whenever the relevant
    /// SettingsManager field changes. Safe to call from anywhere
    /// MainActor-isolated.
    @MainActor
    static func refreshCachedWatchDisplayOnlyMode(from settingsManager: SettingsManager) {
        let value = settingsManager.settings.watchDisplayOnlyMode
        cachedWatchDisplayOnlyMode.withLock { $0 = value }
    }

    /// Tell the Watch to start its own HKWorkoutSession for HR fallback during
    /// our iOS-driven workout.
    ///
    /// A sendMessage-only send gated on `isReachable` is not enough: if the
    /// Watch is briefly unreachable when iOS starts the workout (just
    /// woken, BLE renegotiating, app launching) the message vanishes —
    /// the Watch's HKWorkoutSession never starts, so the app drops
    /// out mid-workout and the user has to soft-restart. Uses the
    /// same dual-channel pattern as `stopWatchWorkoutSession`: fast
    /// `sendMessage` when reachable + queued `transferUserInfo` so the
    /// Watch eventually receives it. Watch's `apply()` is idempotent on
    /// duplicates.
    func startWatchWorkoutSession(sport: Sport) {
        sendDualChannel([
            MessageKey.type.rawValue: MessageType.startWorkout.rawValue,
            MessageKey.sport.rawValue: sport.rawValue,
            "ts": Date().timeIntervalSince1970
        ], label: "startWatchWorkoutSession")
    }

    /// Dual-channel stop. A `sendMessage`-only send gated on
    /// `session.isReachable` is not enough: if the Watch is briefly
    /// unreachable when iOS finalizes the workout (the user pocketed the
    /// phone, the IDS channel was mid-renegotiate, etc.) the stop message
    /// vanishes — the Watch keeps running its HKWorkoutSession AND the live
    /// screen, and the user has to force-quit the watch app.
    ///
    /// Two safeguards:
    ///   • Include `isRecording: false` in the payload. The Watch's `apply()`
    ///     already flips `isRecording = false` and trips `justCompleted = true`
    ///     on the true→false transition, so even if the `case "stopWorkout"`
    ///     arm is reached late / out-of-order, the UI returns to the Save &
    ///     Done screen immediately.
    ///   • Send via BOTH `sendMessage` (live, fast when reachable) AND
    ///     `transferUserInfo` (queued, persistent — Apple guarantees eventual
    ///     delivery once the Watch app wakes). Same belt-and-braces pattern
    ///     the strap-state push uses. The Watch's `apply()` is idempotent, so
    ///     the duplicate is harmless if both arrive.
    ///
    /// The stopped snapshot is cached so a Watch that relaunches
    /// AFTER the workout ended answers `requestCurrentState` with
    /// isRecording:false and shows the Start screen, rather than restoring a
    /// stale "recording" state from the last live tick.
    func stopWatchWorkoutSession() {
        liveWorkoutStartedAt = nil
        let payload: [String: any Sendable] = [
            MessageKey.type.rawValue: MessageType.stopWorkout.rawValue,
            MessageKey.isRecording.rawValue: false,
            "ts": Date().timeIntervalSince1970
        ]
        Self.cacheLiveState(payload)
        sendDualChannel(payload, label: "stopWatchWorkoutSession")
        // The context still held the last live tick, which said recording.
        wcQueue.async { self.updateLiveStateContextLocked(payload) }
    }

    /// Whether the workout that just ended was left unsaved as an accidental
    /// start (`WorkoutSaveOutcome.notArchived`), so the Watch's summary says
    /// so rather than offering Save & Done; false once it is saved from the
    /// iPhone. Dual-channel, like the stop it follows.
    func sendWorkoutSaveState(notSaved: Bool) {
        sendDualChannel([
            MessageKey.type.rawValue: MessageType.workoutSaveState.rawValue,
            Self.notSavedKey: notSaved,
            "ts": Date().timeIntervalSince1970
        ], label: "sendWorkoutSaveState")
    }

    /// The `workoutSaveState` field the Watch reads.
    nonisolated static let notSavedKey = "notSaved"

    /// Fast `sendMessage` when reachable plus a queued `transferUserInfo` that
    /// lands whenever the Watch app next wakes. Issued before the session has
    /// activated (activation waits for `boot()`), the command is held and
    /// sent once it has (`sendHeldDualChannelMessages`).
    private func sendDualChannel(_ payload: [String: any Sendable], label: String) {
        wcQueue.async { [weak self] in
            guard let session = self?.session else { return }
            guard session.activationState == .activated else {
                Self.holdUntilActivated(payload, label: label)
                return
            }
            Self.sendDualChannelNow(payload, on: session, label: label)
        }
    }

    nonisolated private static func sendDualChannelNow(_ payload: [String: any Sendable], on session: WCSession, label: String) {
        guard session.isPaired, session.isWatchAppInstalled else { return }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: logSendFailure(label))
        }
        transferLatestUserInfo(payload, on: session)
    }

    /// Dual-channel commands issued before activation, oldest first; the
    /// last eight at most (a session that never activates holds no more).
    nonisolated private static let heldUntilActivation = OSAllocatedUnfairLock<[[String: any Sendable]]>(initialState: [])

    nonisolated private static func holdUntilActivated(_ payload: [String: any Sendable], label: String) {
        debugLog("[WatchBridge] \(label) before WCSession activation — held until it activates")
        heldUntilActivation.withLock { held in
            held.append(payload)
            if held.count > 8 { held.removeFirst(held.count - 8) }
        }
    }

    /// Sends what `sendDualChannel` held, in order. Called when activation
    /// completes.
    nonisolated func sendHeldDualChannelMessages() {
        let held = Self.heldUntilActivation.withLock { held -> [[String: any Sendable]] in
            defer { held.removeAll() }
            return held
        }
        guard !held.isEmpty else { return }
        wcQueue.async { [weak self] in
            guard let session = self?.session else { return }
            for payload in held { Self.sendDualChannelNow(payload, on: session, label: "held") }
        }
    }

    nonisolated private static func logSendFailure(_ label: String) -> (Error) -> Void {
        { error in
            debugLog("[WatchBridge] \(label) sendMessage failed: \(error.localizedDescription) — transferUserInfo will follow", level: .warning)
        }
    }

}
