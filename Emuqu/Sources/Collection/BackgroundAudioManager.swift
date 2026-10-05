import AVFoundation
import os

/// The audio session for spoken workout cues: the start announcement, coach
/// alerts, mile markers and route lines.
///
/// The session is active only while a cue is audible. `beginCue()` claims
/// mixable playback through the `AudioSessionCoordinator` and activates the
/// session just before an utterance, and returns a `CueToken` for that one
/// cue. `endCue(_:)` — called with the token from the synthesizer's finish and
/// cancel callbacks through `CueAudioSessionReleaser` — ends that cue's hold.
/// When the last held cue ends, the `.workoutCue` claim is released and, unless
/// another claimant (voice chat, dictation, the breathing guide) still holds
/// the session, it is deactivated with `.notifyOthersOnDeactivation`, so
/// another app's audio carries on at full volume.
///
/// Background delivery (App Store 2.5.4): the app holds no audio keep-alive.
/// During a workout with a strap, foot pod or erg the process stays scheduled
/// on `bluetooth-central`, as overnight recording does: each BLE notification
/// wakes it, and the `audio` background mode lets it activate this mixable
/// session from the background to speak a cue. A workout with no sensor has
/// no background keep-alive; its cues play while the app is on screen.
///
/// Thread-safe. Every session transition (claim, activate, release,
/// deactivate) runs in order on one serial queue, and whether a transition is
/// needed is decided on that queue, so a cue ending on one thread can never
/// release the session a cue beginning on another has just activated.
/// `beginCue()` waits for its activation (the utterance must not start before
/// the session is up), so call it off the main actor: `setActive(true)` can
/// block for seconds after a phone-call interruption. Every other transition
/// is queued without waiting, so the main actor never waits behind one.
final class BackgroundAudioManager: Sendable {
    static let shared = BackgroundAudioManager()

    /// One cue's hold on the session. Only the cue that began with a token can
    /// end it, so a late finish or cancel callback for an earlier utterance
    /// can't release a later cue's hold.
    struct CueToken: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    private struct State {
        var heldCues: Set<UInt64> = []
        var lastTokenID: UInt64 = 0
        var wasInterrupted = false

        /// Hold a new cue. Returns its id and whether it is the only one held.
        mutating func holdNewCue() -> (id: UInt64, isFirst: Bool) {
            lastTokenID += 1
            let isFirst = heldCues.isEmpty
            if isFirst { wasInterrupted = false }
            heldCues.insert(lastTokenID)
            return (lastTokenID, isFirst)
        }

        /// End one cue's hold. True when it was held and was the last.
        mutating func endHold(_ id: UInt64) -> Bool {
            heldCues.remove(id) != nil && heldCues.isEmpty
        }

        /// End every hold for an interruption. True when any cue was held.
        mutating func endAllHoldsForInterruption() -> Bool {
            let held = !heldCues.isEmpty
            heldCues.removeAll()
            if held { wasInterrupted = true }
            return held
        }
    }

    private let session: any CueAudioSession
    /// Guards the cue set so `isRunning` reads without waiting on the queue.
    /// Written only from blocks on `transitions`.
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let transitions = DispatchQueue(label: "com.emuqu.cue-audio-session", qos: .userInitiated)
    private let observers = NotificationTokens()

    /// True while at least one spoken cue holds the session.
    var isRunning: Bool { state.withLock { !$0.heldCues.isEmpty } }

    /// True when a call or alarm interrupted the session while a cue held it.
    /// Cleared when the next cue begins or the workout ends.
    var wasInterrupted: Bool { state.withLock { $0.wasInterrupted } }

    /// `session` is the shared audio session in the app; tests pass a
    /// recording stand-in and skip the system interruption observer.
    init(session: any CueAudioSession = SystemCueAudioSession(), observesInterruptions: Bool = true) {
        self.session = session
        if observesInterruptions { setupInterruptionObserver() }
    }

    deinit {
        observers.removeAll()
    }

    // MARK: - Cues

    /// Claim mixable playback and activate the session for one cue. Call it
    /// off the main actor just before `speak`, and end the returned token
    /// exactly once — through `CueAudioSessionReleaser`, or with `endCue(_:)`
    /// when the utterance is never queued.
    func beginCue() -> CueToken {
        transitions.sync {
            let hold = state.withLock { $0.holdNewCue() }
            if hold.isFirst { activateForCues() }
            return CueToken(id: hold.id)
        }
    }

    /// End one cue's hold. When it was the last, release the claim and
    /// deactivate the session unless another claimant holds it. A token that
    /// no longer holds the session (already ended, or cleared by an
    /// interruption) does nothing.
    func endCue(_ token: CueToken) {
        transitions.async { [self] in
            if state.withLock({ $0.endHold(token.id) }) { releaseWhenIdle() }
        }
    }

    /// The workout ended. A cue still speaking keeps its hold and releases the
    /// session when it finishes. With none speaking, the cue claim is dropped
    /// and the session deactivated unless another claimant holds it, so
    /// nothing keeps the session active after the workout.
    func stopBackgroundAudio() {
        transitions.async { [self] in
            let idle = state.withLock { (state: inout State) -> Bool in
                state.wasInterrupted = false
                return state.heldCues.isEmpty
            }
            if idle { releaseWhenIdle() }
        }
    }

    /// Deactivate the session for a claimant that has just released its own
    /// claim (voice chat on tear-down), unless a cue still holds the session
    /// or another claimant does. Decided and done on the transition queue, so
    /// a cue beginning at the same moment is never cut off: either it holds
    /// the session by the time this runs and the session stays up, or it
    /// begins afterwards and activates the session again. `completion` runs on
    /// that queue with the deactivation error, or nil when the session was
    /// deactivated or had to stay up.
    func deactivateIfIdle(completion: @escaping @Sendable (Error?) -> Void) {
        transitions.async { [self] in
            let cueHeld = state.withLock { !$0.heldCues.isEmpty }
            guard !cueHeld, !session.hasActiveClaims else { return completion(nil) }
            do {
                try session.deactivate()
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// Blocks until every queued session transition has run, so a caller can
    /// read the state an `endCue(_:)` or `stopBackgroundAudio()` left.
    func waitForPendingTransitions() {
        transitions.sync {}
    }

    // MARK: - Session

    /// Runs on `transitions`. A failed activation still leaves the cue held:
    /// its finish or cancel callback releases it like any other.
    private func activateForCues() {
        session.claimCuePlayback()
        do {
            try session.activate()
        } catch {
            debugLog("BackgroundAudioManager: activating the session for a cue failed - \(error.localizedDescription)")
        }
    }

    /// Runs on `transitions`. Release the cue claim FIRST so a still-active
    /// voice chat keeps its `.playAndRecord` claim. Then deactivate ONLY if no
    /// one else still holds a claim (voice chat, dictation, the breathing
    /// guide): `setActive(false)` under them would kill their audio, a
    /// mid-recording mic tap included. They deactivate on their own tear-down.
    private func releaseWhenIdle() {
        session.releaseCuePlayback()
        guard !session.hasActiveClaims else { return }
        do {
            try session.deactivate()
        } catch {
            debugLog("BackgroundAudioManager: deactivating the session failed - \(error.localizedDescription)", level: .info)
        }
    }

    /// A call or alarm that cuts into a cue ends every cue's hold and drops
    /// the claim through the same release path as a finished cue; nothing is
    /// resumed afterwards. The cut utterance's late cancel callback carries a
    /// token that no longer holds the session, so it can't end a cue begun
    /// after the interruption. Queued, not waited on: the notification can
    /// arrive on any thread.
    private func setupInterruptionObserver() {
        observers.add(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let typeValue, AVAudioSession.InterruptionType(rawValue: typeValue) == .began else { return }
            self?.interruptionBegan()
        })
    }

    /// An audio interruption began. Called by the session observer.
    func interruptionBegan() {
        transitions.async { [self] in
            if state.withLock({ $0.endAllHoldsForInterruption() }) { releaseWhenIdle() }
        }
    }
}

// MARK: - Session seam

/// What `BackgroundAudioManager` does to the shared audio session. The app
/// uses `SystemCueAudioSession`; tests record the calls.
protocol CueAudioSession: Sendable {
    /// Claim `.workoutCue` playback through the coordinator.
    func claimCuePlayback()
    /// Release the `.workoutCue` claim.
    func releaseCuePlayback()
    /// Whether any claimant (voice chat, dictation, breathing guide, cues)
    /// still holds the session.
    var hasActiveClaims: Bool { get }
    func activate() throws
    /// Deactivate with `.notifyOthersOnDeactivation`.
    func deactivate() throws
}

/// The app's `AVAudioSession`, with categories applied by the
/// `AudioSessionCoordinator`.
struct SystemCueAudioSession: CueAudioSession {
    private var coordinator: AudioSessionCoordinator {
        AppDependencies.current.services.audioSessionCoordinator
    }

    func claimCuePlayback() {
        coordinator.claim(.workoutCue, mode: .playback)
    }

    func releaseCuePlayback() {
        coordinator.release(.workoutCue)
    }

    var hasActiveClaims: Bool { coordinator.hasActiveClaims() }

    func activate() throws {
        try AVAudioSession.sharedInstance().setActive(true)
    }

    func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Releaser

/// Ends a cue's hold on the audio session when its utterance finishes or is
/// cancelled. Set it as the delegate of a synthesizer, and `track` each
/// utterance with the token from `BackgroundAudioManager.beginCue()` before
/// speaking it. Callbacks for untracked utterances do nothing. A synthesizer
/// keeps its delegate weakly, so the owner retains this object.
final class CueAudioSessionReleaser: NSObject, AVSpeechSynthesizerDelegate, Sendable {
    private let manager: BackgroundAudioManager
    /// Keyed by utterance identity: the synthesizer retains a queued utterance
    /// until its finish or cancel callback, so the identity can't be reused
    /// while its entry is here.
    private let pending = OSAllocatedUnfairLock<[ObjectIdentifier: BackgroundAudioManager.CueToken]>(initialState: [:])

    init(manager: BackgroundAudioManager) {
        self.manager = manager
    }

    /// Pair `utterance` with the cue token its speech holds.
    func track(_ utterance: AVSpeechUtterance, token: BackgroundAudioManager.CueToken) {
        let key = ObjectIdentifier(utterance)
        pending.withLock { $0[key] = token }
    }

    /// End the cue `utterance` holds, if any. Called from the delegate
    /// callbacks, and directly when the utterance failed to queue.
    func release(_ utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        guard let token = pending.withLock({ $0.removeValue(forKey: key) }) else { return }
        manager.endCue(token)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        release(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        release(utterance)
    }
}
