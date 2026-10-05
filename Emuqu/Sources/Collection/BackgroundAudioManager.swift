import AVFoundation
import os

/// The audio session for spoken workout cues: the start announcement, coach
/// alerts, mile markers and interval steps.
///
/// Nothing plays between cues. `beginCue()` claims mixable playback through
/// the `AudioSessionCoordinator` and activates the session just before an
/// utterance; `endCue()` — called from the synthesizer's finish and cancel
/// callbacks through `CueAudioSessionReleaser` — releases the claim and
/// deactivates the session with `.notifyOthersOnDeactivation`, so another
/// app's audio carries on at full volume.
///
/// Background delivery (App Store 2.5.4): the app holds no audio keep-alive.
/// During a workout with a strap, foot pod or erg the process stays scheduled
/// on `bluetooth-central`, as overnight recording does: each BLE notification
/// wakes it, and the `audio` background mode lets it activate this mixable
/// session from the background to speak a cue. A workout with no sensor has
/// no background keep-alive; its cues play while the app is on screen.
///
/// Thread-safe: cues may begin and end on any thread, so the blocking
/// `setActive(true)` can run off the main actor.
final class BackgroundAudioManager: Sendable {
    static let shared = BackgroundAudioManager()

    private struct State {
        var activeCues = 0
        var wasInterrupted = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let observers = NotificationTokens()

    /// True while at least one spoken cue holds the session.
    var isRunning: Bool { state.withLock { $0.activeCues > 0 } }

    /// True when a call or alarm interrupted the session while a cue held it.
    /// Cleared when the next cue begins.
    var wasInterrupted: Bool { state.withLock { $0.wasInterrupted } }

    private init() {
        setupInterruptionObserver()
    }

    deinit {
        observers.removeAll()
    }

    // MARK: - Cues

    /// Claim mixable playback and activate the session for one cue. Call it
    /// just before `speak`, and pair it with exactly one `endCue()`.
    func beginCue() {
        let isFirst = state.withLock { (state: inout State) -> Bool in
            state.activeCues += 1
            if state.activeCues == 1 { state.wasInterrupted = false }
            return state.activeCues == 1
        }
        guard isFirst else { return }
        AppDependencies.current.services.audioSessionCoordinator.claim(.workoutCue, mode: .playback)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            debugLog("BackgroundAudioManager: activating the session for a cue failed - \(error.localizedDescription)")
        }
    }

    /// Release one cue's hold. When the last cue ends, drop the claim and
    /// deactivate the session. A call with no cue held does nothing.
    func endCue() {
        let wasLast = state.withLock { (state: inout State) -> Bool in
            guard state.activeCues > 0 else { return false }
            state.activeCues -= 1
            return state.activeCues == 0
        }
        guard wasLast else { return }
        releaseAudioSession()
    }

    /// End every cue still holding the session, for when the workout ends.
    func stopBackgroundAudio() {
        let held = state.withLock { (state: inout State) -> Bool in
            let held = state.activeCues > 0
            state.activeCues = 0
            state.wasInterrupted = false
            return held
        }
        guard held else { return }
        releaseAudioSession()
    }

    // MARK: - Session

    /// Release the coordinator claim FIRST so a still-active voice chat keeps
    /// its `.playAndRecord` claim. Then deactivate the audio session ONLY if
    /// no one else still holds a claim (voice chat, dictation, the breathing
    /// guide): calling `setActive(false)` under them would kill their audio —
    /// a mid-recording mic tap included.
    private func releaseAudioSession() {
        AppDependencies.current.services.audioSessionCoordinator.release(.workoutCue)
        guard !AppDependencies.current.services.audioSessionCoordinator.hasActiveClaims() else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            debugLog("BackgroundAudioManager: Error deactivating audio session - \(error.localizedDescription)")
        }
    }

    /// A call or alarm that cuts into a cue ends every cue's hold: iOS has
    /// already deactivated the session, so the claim is dropped and nothing is
    /// resumed afterwards. A late finish callback for the cut utterance then
    /// finds no cue held and does nothing.
    private func setupInterruptionObserver() {
        observers.add(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let typeValue, AVAudioSession.InterruptionType(rawValue: typeValue) == .began else { return }
            self?.endCuesForInterruption()
        })
    }

    private func endCuesForInterruption() {
        let held = state.withLock { (state: inout State) -> Bool in
            let held = state.activeCues > 0
            state.activeCues = 0
            if held { state.wasInterrupted = true }
            return held
        }
        guard held else { return }
        releaseAudioSession()
    }
}

/// Ends a cue's hold on the audio session when its utterance finishes or is
/// cancelled. Set it as the delegate of a synthesizer whose `speak` calls are
/// each preceded by `BackgroundAudioManager.beginCue()`. A synthesizer keeps
/// its delegate weakly, so the owner retains this object.
final class CueAudioSessionReleaser: NSObject, AVSpeechSynthesizerDelegate, Sendable {
    private let manager: BackgroundAudioManager

    init(manager: BackgroundAudioManager) {
        self.manager = manager
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        manager.endCue()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        manager.endCue()
    }
}
