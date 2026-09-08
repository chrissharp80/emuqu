import Combine
import Foundation
import os
import WatchConnectivity

extension Notification.Name {
    /// Posted on the main actor when the Watch app requests a workout
    /// start. UserInfo `["sport": Sport.rawValue]`. Fitness tab listens
    /// and drives its `WorkoutRecorder`; no other listener should act on
    /// this (double-start would be a UX bug).
    static let watchRequestedWorkoutStart = Notification.Name("FlowRecoveryWatchRequestedWorkoutStart")

    /// Posted when the Watch requests a stop. No userInfo. Fitness tab
    /// listens and calls `recorder.stop()`. We use a notification rather
    /// than a direct recorder hook so the single owner of the recorder
    /// (FitnessTabView's RecorderBox) stays the only stop path.
    static let watchRequestedWorkoutStop = Notification.Name("FlowRecoveryWatchRequestedWorkoutStop")

    /// Posted when the Watch requests pause (either user-driven).
    static let watchRequestedWorkoutPause = Notification.Name("FlowRecoveryWatchRequestedWorkoutPause")

    /// Posted when the Watch requests resume.
    static let watchRequestedWorkoutResume = Notification.Name("FlowRecoveryWatchRequestedWorkoutResume")

    /// Posted when the user taps Save & Done on the Watch summary.
    /// Fitness tab listens and calls `recorder.acknowledgeFinished()`
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
    /// Shared instance — the WCSession itself is process-wide, so the delegate
    /// must be too. Creating a second bridge would replace the delegate and
    /// silently break whichever subsystem set up first (discovered when the
    /// Watch Talk button stopped reaching the phone after a workout started
    /// a fresh bridge). All consumers use this singleton.
    static let shared = WatchConnectivityBridge()

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
        case alpha1
        case band
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
        /// Reply-handler payloads use these.
        case ok
        case error
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
        // Historical note: `voiceTrigger` (iOS → Watch) and `stopVoiceChat`
        // (Watch → iOS) were declared but never delivered end-to-end —
        // `voiceTrigger` was sent but the Watch had no handler; `stopVoiceChat`
        // had a receive path but no sender. Both were removed; re-introduce if
        // the Watch side grows the corresponding UI.
    }

    // MARK: - Cross-process hooks

    /// Called on the main actor when the Watch requests a voice-chat action.
    /// Set by the app wiring layer to point at the shared
    /// `VoiceConversationController`; left as a closure so this bridge stays
    /// decoupled from the voice stack (bridge is networking, voice is audio).
    var onStartVoiceChatFromWatch: (() -> Void)?

    /// Called when the Watch sends `requestStrapState` (typically right
    /// after WCSession activation on the Watch side). Wired by
    /// `WatchStrapStateMirror` to `pushCurrentSnapshot()` so the Watch
    /// gets the latest strap state immediately on activation, even when
    /// no Polar event has fired since iOS launched.
    var onRequestStrapStateFromWatch: (() -> Void)?

    /// Called when the iOS-side WCSession finishes activating with the
    /// Watch reachable. Wired by `WatchStrapStateMirror` so the very
    /// first thing iOS does after the connection is live is push the
    /// current strap snapshot — without this, the Combine subscription
    /// might never fire (strap is stable, no events) and the Watch
    /// would sit in "no strap" forever even when iOS knows otherwise.
    var onWCSessionActivated: (() -> Void)?

    /// Called on the main actor when the Watch asks us to start a workout.
    /// `sportRaw` is the `Sport.rawValue` string ("run", "walk", "bike",
    /// "indoorRun", etc.) selected by the user on the Watch. `targetZone`
    /// is optional — if the Watch picker set one, carry it through so
    /// zones configured on the wrist are honoured on the phone.
    /// Wired at app-launch so a wrist tap can begin a phone-tracked
    /// workout even when the iOS app is suspended (iOS wakes the app
    /// to deliver the WC message — as long as the user hasn't
    /// force-quit it).
    ///
    /// Returns nil on success or a short human-readable error string
    /// for the Watch to surface ("Strap not connected", "Already
    /// recording"). Reply is sent back to the Watch so the UI can show
    /// the real reason instead of silent optimism.
    var onStartWorkoutFromWatch: ((_ sportRaw: String, _ targetZone: Int?) -> String?)?

    /// Called on the main actor when the Watch asks us to stop the active
    /// workout. Same reply-contract as start: nil on success, short
    /// error string otherwise ("No workout running", etc.).
    var onStopWorkoutFromWatch: (() -> String?)?

    /// Called on the main actor when the Watch asks us to pause the
    /// active workout. Reply-contract matches start/stop.
    var onPauseWorkoutFromWatch: (() -> String?)?

    /// Called on the main actor when the Watch asks us to resume the
    /// active workout. Reply-contract matches the others.
    var onResumeWorkoutFromWatch: (() -> String?)?

    /// Called on the main actor when the user taps Save & Done on the
    /// Watch summary. The workout has already been archived at stop
    /// time; this is just the "dismiss the post-workout sheet on the
    /// phone so it's not sitting there next time you pick it up" hook.
    /// Reply-contract matches the other control messages.
    var onAcknowledgeFinishedFromWatch: (() -> String?)?

    // MARK: Published

    /// Whether a Watch is paired and the WC session is active.
    var isReachable = false

    /// True when a Watch is paired to this iPhone. Independent of
    /// `isReachable` (which is true only while the Watch app is in
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
    var latestWatchHR: Int?

    /// Latest direct-BLE strap sample relayed from the Watch — HR plus
    /// the RR intervals from that notification. Source: `watchStrapSample`
    /// messages sent by the Watch's `WatchStrapConnector` whenever the
    /// user paired a chest strap directly to the wrist. Consumers (the
    /// workout recorder pipeline) can fold these in as a fallback when
    /// iOS's own PolarManager isn't holding a strap connection.
    var latestWatchStrapHR: Int?
    var latestWatchStrapRRMillis: [Double] = []
    var latestWatchStrapAt: Date?
    /// Accumulating queue of un-consumed RR samples. The
    /// recorder ticks at 1 Hz; the Watch may forward 2-3 samples per
    /// tick during dense beat periods. Reading only `latestWatchStrap…`
    /// drops samples in that window. The recorder calls
    /// `drainPendingWatchStrapRR()` on each tick to claim everything
    /// queued since the last drain.
    var pendingWatchStrapRR: [Double] = []
    let pendingWatchStrapRRLock = NSLock()

    /// Pop all queued Watch-routed RR intervals. Returned in arrival
    /// order. Called by `WorkoutRecorder.incrementalBackupTick` when
    /// the active workout's HR source is `.strap` and the iPhone-paired
    /// Polar is silent.
    func drainPendingWatchStrapRR() -> [Double] {
        pendingWatchStrapRRLock.lock()
        defer { pendingWatchStrapRRLock.unlock() }
        let drained = pendingWatchStrapRR
        pendingWatchStrapRR.removeAll(keepingCapacity: true)
        return drained
    }

    /// Highest `ts` field we've already processed from a Watch
    /// applicationContext payload. Used by `didReceiveApplicationContext` to
    /// dedupe against the live `didReceiveMessage` path — both can fire for
    /// the same intent during a foreground transition, and we don't want
    /// (e.g.) two startWorkoutFromWatch calls in a row.
    @MainActor var lastProcessedContextTimestamp: Double = 0

    // MARK: Config

    /// WCSession is process-wide and thread-safe. Marked `nonisolated` so
    /// the transport queue can read it without an actor hop.
    nonisolated private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }

    /// Dedicated serial queue for all WCSession transport work. Keeping the
    /// bridge @MainActor is right for publishing — SwiftUI needs
    /// `isReachable` / `latestWatchHR` on main — but `WCSession.sendMessage`
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
    /// because this class is one of the @StateObjects in App init and may run
    /// before SettingsManager has read its JSON file from the App Group
    /// container.
    ///
    /// The delegate is wired synchronously so any incoming Watch message (which
    /// can arrive before our boot() runs if the Watch app was already
    /// foregrounded) lands on this instance. Activation itself is deferred to
    /// keep the synchronous launch path fast — see boot() below.
    override init() {
        NSLog("[WatchBridge] init() — entry (lightweight; activate() deferred to boot())")
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
    /// post-first-frame `.task` instead of inline in `init`. An
    /// iPhone-11 splash hang was caused by 6+ heavy `@State` inits
    /// running synchronously before SwiftUI could paint, and `session
    /// .activate()` is one of those — Apple's WatchConnectivity framework
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
    func boot() {
        guard !didActivate.withLock({ $0 }) else { return }
        guard let session else { return }
        guard UserSettings.performanceFlag(.enableWatchConnectivity) else { return }
        didActivate.withLock { $0 = true }
        // Prime the watchDisplayOnlyMode mirror so the first WCSession
        // callback doesn't see the safe-default `true` placeholder.
        // Then subscribe to settings changes to keep the mirror fresh.
        Self.refreshCachedWatchDisplayOnlyMode()
        Task { @MainActor in Self.armWatchDisplayModeObservation() }
        NSLog("[WatchBridge] boot() — calling session.activate()")
        session.activate()
        NSLog("[WatchBridge] boot() — session.activate() returned")
    }

    /// Combine subscriptions for the watchDisplayOnlyMode
    /// mirror. See `cachedWatchDisplayOnlyMode` doc-comment for why
    /// this exists.
    /// Re-arms itself: `withObservationTracking` is one-shot. `SettingsManager`
    /// is not main-actor-isolated, so this reads the global directly instead of
    /// going through `ObservationLoop` (whose owner must be Sendable).
    @MainActor
    private static func armWatchDisplayModeObservation() {
        withObservationTracking {
            _ = AppDependencies.current.app.settingsManager.settings.watchDisplayOnlyMode
        } onChange: {
            Task { @MainActor in
                Self.refreshCachedWatchDisplayOnlyMode()
                Self.armWatchDisplayModeObservation()
            }
        }
    }

    /// Tracks whether boot() has run. Marked nonisolated(unsafe) because
    /// boot() is @MainActor (this whole class is) but we want the flag
    /// readable from any actor without a hop. Single-writer (boot, on
    /// MainActor) so the unsafe is sound.
    @ObservationIgnored private let didActivate = OSAllocatedUnfairLock(initialState: false)

    // MARK: No-Watch cache (activation skip)

    /// UserDefaults key storing the timestamp at which we last confirmed
    /// no Watch counterpart was paired/installed. Presence + freshness
    /// of this value gates whether we activate WCSession on launch.
    /// `nonisolated` so the nonisolated `shouldSkipActivation` /
    /// `markNoWatchPresent` / `clearNoWatchCache` static helpers below
    /// can read it without Swift 6 strict-mode complaining about
    /// crossing the @MainActor class boundary.
    nonisolated private static let noWatchCacheKey = "wc.noWatchDetectedAt"

    /// Re-probe Watch presence at least once a week so a user who pairs
    /// a Watch + installs the companion later still gets connected.
    nonisolated private static let noWatchCacheTTL: TimeInterval = 7 * 24 * 3600

    /// True when the cached "no Watch present" flag is set AND fresh
    /// (within the TTL window). When true, init skips `session.activate()`
    /// so Apple's framework doesn't log the noise.
    nonisolated private static var shouldSkipActivation: Bool {
        guard let timestamp = UserDefaults.standard.object(forKey: noWatchCacheKey) as? Date else {
            return false  // Never confirmed — must activate at least once
        }
        return Date().timeIntervalSince(timestamp) < noWatchCacheTTL
    }

    /// Record that the activation completion handler observed no paired
    /// Watch / no companion app. Future launches within the TTL skip
    /// activation entirely.
    nonisolated private static func markNoWatchPresent() {
        UserDefaults.standard.set(Date(), forKey: noWatchCacheKey)
    }

    /// Clear the no-Watch cache when activation reveals a Watch IS
    /// present (user paired one between launches).
    nonisolated private static func clearNoWatchCache() {
        UserDefaults.standard.removeObject(forKey: noWatchCacheKey)
    }

    // MARK: - Live state push

    /// One tick of live workout state, as the Watch face needs it.
    ///
    /// A parameter object rather than a long argument list: there is exactly
    /// one caller — `WorkoutRecorder+Ticker.pushLiveStateToWatch` — and the
    /// arguments group naturally (`LiveTotals` carries the running totals).
    struct LiveState {
        let sport: Sport
        let heartRate: Int?
        let peakHR: Int
        let userMaxHR: Int
        let totals: LiveTotals
        let paceDisplay: String?
        let alpha1: Double?
        let band: String
        let cadenceSpm: Double?
        let targetZone: Int?
        let unitsPreference: String
        let isRecording: Bool
        let isPaused: Bool
        let autoPaused: Bool
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
        let frozen = Self.liveStatePayload(state)
        wcQueue.async { [weak self] in
            self?.transportLiveStatePayload(frozen)
        }
    }

    /// Flatten one tick into the wire dictionary. Optional metrics are omitted
    /// rather than sent as null so the Watch can tell "not measured" from zero.
    private static func liveStatePayload(_ state: LiveState) -> [String: any Sendable] {
        var payload = liveStateBase(
            sport: state.sport, peakHR: state.peakHR, userMaxHR: state.userMaxHR,
            totals: state.totals, band: state.band, unitsPreference: state.unitsPreference
        )
        payload[MessageKey.isRecording.rawValue] = state.isRecording
        payload[MessageKey.isPaused.rawValue] = state.isPaused
        payload[MessageKey.autoPaused.rawValue] = state.autoPaused
        addHeartRate(state.heartRate, userMaxHR: state.userMaxHR, to: &payload)
        if let alpha1 = state.alpha1 { payload[MessageKey.alpha1.rawValue] = alpha1 }
        if let paceDisplay = state.paceDisplay { payload[MessageKey.paceDisplay.rawValue] = paceDisplay }
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
    /// to know about the user-max rules (override vs 220-age fallback) —
    /// those live on the settings side.
    private static func addHeartRate(_ heartRate: Int?, userMaxHR: Int, to payload: inout [String: any Sendable]) {
        guard let heartRate else { return }
        payload[MessageKey.heartRate.rawValue] = heartRate
        guard userMaxHR > 0 else { return }
        payload[MessageKey.hrPercentOfMax.rawValue] = Int((Double(heartRate) / Double(userMaxHR)) * 100)
    }

    // MARK: - Strap state (independent of workout pipeline)
    //
    // Separate channel for "is your Polar strap connected?
    // what's the battery? what's the device name?" so the Watch UI can
    // show strap readiness BEFORE a workout starts. The live-state push
    // above only runs while a workout is recording — without this
    // channel the Watch had no way to display strap status during the
    // pre-workout planning step.

    /// Push the current Polar strap state to the Watch. Cheap to call
    /// repeatedly. Uses three channels for reliability:
    ///   1. `sendMessage` (best-effort fast — fails when iOS is throttled
    ///      and the Watch sees `WCErrorCodeTransferTimedOut`)
    ///   2. `updateApplicationContext` (latest-only, persistent across
    ///      Watch wake)
    ///   3. `transferUserInfo` (queued, persistent, eventually delivered
    ///      by Apple's framework — the dependable channel)
    ///
    /// Channel 3 exists because user logs showed sendMessage timing out
    /// repeatedly even when `isReachable == true`. transferUserInfo
    /// guarantees delivery
    /// — if the Watch is asleep, iOS waits and delivers when it wakes.
    func pushStrapState(connected: Bool, deviceName: String?, batteryPercent: Int?) {
        var payload: [String: any Sendable] = [
            MessageKey.type.rawValue: MessageType.strapState.rawValue,
            MessageKey.strapConnected.rawValue: connected,
            MessageKey.displayOnlyMode.rawValue: WatchConnectivityBridge.watchDisplayOnlyMode()
        ]
        if let deviceName { payload[MessageKey.strapDeviceName.rawValue] = deviceName }
        if let batteryPercent { payload[MessageKey.strapBatteryPct.rawValue] = batteryPercent }
        // Frozen before crossing the queue — see the note on the live-state
        // payload above.
        let frozen = payload
        wcQueue.async { [weak self] in
            self?.transportLiveStatePayload(frozen)
            self?.transportViaUserInfo(frozen)
        }
    }

    /// Reliable always-delivers channel. Used for state we MUST get to
    /// the Watch (strap state, workout-control acknowledgements). Apple's
    /// framework persists these, wakes the Watch when needed, and
    /// guarantees delivery in order. Slower than sendMessage but never
    /// drops.
    nonisolated private func transportViaUserInfo(_ payload: [String: any Sendable]) {
        guard let session else { return }
        guard session.activationState == .activated else { return }
        guard session.isPaired else { return }
        session.transferUserInfo(payload)
    }

    /// Queue-isolated transport. Running on `wcQueue`, never main.
    /// Consecutive sendMessage timeouts trip a short-term
    /// circuit breaker. iOS occasionally reports `isReachable = true` for
    /// a fraction of a second when the Watch is actually unreachable
    /// (during init, after wake, when the Watch app was force-quit). Each
    /// `sendMessage` then waits the framework's full timeout and fires
    /// `WCErrorCodeTransferTimedOut` — visible in the user's console as
    /// 5–10 timeout pairs in a row, plus the framework's own internal
    /// logs we can't suppress. After `circuitBreakerThreshold` consecutive
    /// timeouts we skip `sendMessage` entirely until reachability flips
    /// back to true (delegate callback resets the counter); the fallback
    /// `updateApplicationContext` path still gets the latest snapshot.
    /// Wrapped in `OSAllocatedUnfairLock` so concurrent
    /// `transportLiveStatePayload` invocations can't race on the counter.
    /// A per-process static counter; `bumpTimeoutCount` returns the new value
    /// for logging.
    nonisolated private static let timeoutCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
    nonisolated private static let circuitBreakerThreshold = 3

    nonisolated private static var currentConsecutiveSendTimeouts: Int {
        timeoutCounter.withLock { $0 }
    }
    @discardableResult
    nonisolated private static func bumpTimeoutCount() -> Int {
        timeoutCounter.withLock { count in
            count += 1
            return count
        }
    }
    nonisolated static func resetTimeoutCount() {
        timeoutCounter.withLock { $0 = 0 }
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
    nonisolated func transportLiveStatePayload(_ payload: [String: any Sendable]) {
        guard let session else { return }
        // Cache the latest snapshot regardless of transport
        // outcome so a Watch that relaunches mid-workout can pull it on
        // demand via `requestCurrentState`. Cheap; overwrites the previous.
        Self.cacheLiveState(payload)
        guard canTransport(session) else { return }
        if (payload[MessageKey.isRecording.rawValue] as? Bool) ?? false {
            updateLiveStateContextLocked(payload)
        }
        let circuitOpen = Self.currentConsecutiveSendTimeouts >= Self.circuitBreakerThreshold
        guard session.isReachable, !circuitOpen else {
            updateLiveStateContextLocked(payload)
            return
        }
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
        wcQueue.async { self.updateLiveStateContextLocked(payload) }
    }

    /// Seen in a real user log: the OS-level WCSession emits
    /// "WCSession counterpart app not installed" + the companion
    /// `_block_invoke failed due to WCErrorCodeWatchAppNotInstalled` warning
    /// every time we try sendMessage / updateApplicationContext when the user
    /// has a paired Watch but no FlowRecovery WatchApp installed. We can't
    /// suppress those os_log lines from inside our process — but we CAN avoid
    /// issuing the call at all by checking `isWatchAppInstalled` first. That
    /// is the property WatchConnectivity itself checks before raising the
    /// error; gating on it cuts the noise to zero in that configuration.
    ///
    /// An unpaired Watch is silent too, so we don't spam logs on every tick.
    nonisolated private func canTransport(_ session: WCSession) -> Bool {
        guard session.activationState == .activated else {
            debugLog("[WatchBridge] skipping sendLiveState — session state=\(session.activationState.rawValue)", level: .warning)
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
        // Some callers reach this path directly (the sendMessage
        // fallback at line 550) so the guard has to be local too.
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

    nonisolated static func cacheLiveState(_ payload: [String: any Sendable]) {
        liveStateCache.withLock { $0 = payload }
    }

    nonisolated static func cachedLiveState() -> [String: any Sendable]? {
        liveStateCache.withLock { $0 }
    }

    /// Lock-protected mirror of `AppDependencies.current.app.settingsManager.settings.watchDisplayOnlyMode`.
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
    /// `SettingsManager` change via a Combine subscription set up at
    /// the start of `activate()`.
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
    static func refreshCachedWatchDisplayOnlyMode() {
        let value = AppDependencies.current.app.settingsManager.settings.watchDisplayOnlyMode
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
    /// screen, and the user has to force-quit the watch app ("watch keeps
    /// it going").
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
        let payload: [String: any Sendable] = [
            MessageKey.type.rawValue: MessageType.stopWorkout.rawValue,
            MessageKey.isRecording.rawValue: false,
            "ts": Date().timeIntervalSince1970
        ]
        Self.cacheLiveState(payload)
        sendDualChannel(payload, label: "stopWatchWorkoutSession")
    }

    /// Fast `sendMessage` when reachable plus a queued `transferUserInfo` that
    /// lands whenever the Watch app next wakes.
    private func sendDualChannel(_ payload: [String: any Sendable], label: String) {
        wcQueue.async { [weak self] in
            guard let session = self?.session, session.activationState == .activated else { return }
            if session.isReachable {
                session.sendMessage(payload, replyHandler: nil, errorHandler: Self.logSendFailure(label))
            }
            session.transferUserInfo(payload)
        }
    }

    nonisolated private static func logSendFailure(_ label: String) -> (Error) -> Void {
        { error in
            debugLog("[WatchBridge] \(label) sendMessage failed: \(error.localizedDescription) — transferUserInfo will follow", level: .warning)
        }
    }

}
