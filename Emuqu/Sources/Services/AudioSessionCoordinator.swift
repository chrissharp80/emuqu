import AVFoundation
import Foundation
import os

// MARK: - AudioSessionCoordinator
//
// Single owner of `AVAudioSession` category transitions.
// The main callers that manage the audio session (the workout coach,
// dictation and the breathing guide also claim through it):
//
//   1. `VoiceConversationController` — needs `.playAndRecord, .measurement`
//      with a live mic tap. Active during voice chats. Already keeps
//      the app alive in background via its own audio session.
//   2. `BackgroundAudioManager` — needs `.playback, .mixWithOthers`
//      and a silent looping buffer. Used for indoor workouts (no GPS
//      background mode) and overnight HRV recording. The keep-alive
//      mechanism is the audio playback itself.
//
// **The bug this prevents.** If both call `AVAudioSession.setCategory(...)`
// directly, BGAM starting during a voice chat clobbers voice's
// `.playAndRecord` with `.playback` — voice's mic goes silent and the
// recogniser produces "no speech detected" forever. Worse, BGAM's periodic
// health check restarts the engine and re-applies `.playback` every 30 s,
// so even after voice re-claims `.playAndRecord` the next health tick
// clobbers it again. See `VoiceConversationController:376` for the symptom.
//
// **The rule.** All category transitions go through this coordinator.
// Voice and BGAM declare INTENT (`requestVoiceMode()` /
// `requestPlaybackMode()`); the coordinator picks the strict-superset
// category that satisfies all live claimants. Voice's
// `.playAndRecord` is a superset of BGAM's `.playback` keep-alive
// need (BGAM's silent buffer plays fine over `.playAndRecord` with
// `.mixWithOthers` options merged in), so when voice is active BGAM
// becomes a no-op category-wise — it only manages its silent player.

final class AudioSessionCoordinator: Sendable {
    static let shared = AudioSessionCoordinator()

    /// Caller identity. Used to track which subsystem is currently
    /// holding which claim so the coordinator can resolve the union.
    enum Claimant {
        /// Voice chat (mic + speaker).
        case voice
        /// Background-audio keepalive (silent .playback player).
        case backgroundKeepalive
        /// Tap-to-talk dictation in the Assistant composer (mic only).
        /// Routes through the coordinator like everything else so a live
        /// BGAM keepalive (indoor workout / overnight HRV) can't clobber
        /// the record category out from under the recognizer — the exact
        /// "mic works half the time" symptom when it grabbed `.record`
        /// on the shared session directly.
        case dictation
        /// The workout voice coach's spoken cues (playback only). Its own
        /// key, so the coach releasing its claim cannot drop the background
        /// keepalive's, or the other way round.
        case workoutCoach
        /// The breathing session's spoken "Breathe in / Breathe out" guide
        /// (playback only). The one claimant that ducks other apps' audio,
        /// so the cue is heard over music.
        case breathingGuide
    }

    /// What kind of audio access a claimant needs.
    enum Mode {
        /// Recording + playback. Required for voice chat.
        case voiceRecord
        /// Playback only — silent or audible. Used by BGAM keep-alive.
        case playback
    }

    private struct State {
        var claims: [Claimant: Mode] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private init() {}

    /// Claim a mode. Idempotent — multiple calls with the same claim
    /// are cheap (we only re-apply if the resolved category changes).
    /// Thread-safe; can be called from any actor.
    func claim(_ claimant: Claimant, mode: Mode) {
        state.withLock { $0.claims[claimant] = mode }
        applyResolvedCategory()
    }

    /// Release a claim. Coordinator re-resolves; if no claimants
    /// remain, the session is left in its last category (we don't
    /// auto-deactivate — callers' tear-down already does that).
    func release(_ claimant: Claimant) {
        _ = state.withLock { $0.claims.removeValue(forKey: claimant) }
        applyResolvedCategory()
    }

    /// Whether voice is currently a live claimant. Read by BGAM
    /// before it does any session-touching work — when voice is up,
    /// BGAM keeps its silent player but skips category manipulation.
    func isVoiceActive() -> Bool {
        state.withLock { $0.claims[.voice] != nil }
    }

    /// Whether any subsystem still holds a claim. A claimant that owns
    /// the session only transiently (dictation) checks this after its
    /// own `release()` before deactivating: if another claimant (BGAM
    /// keepalive, voice) is still live, it must leave the session active
    /// so it doesn't tear the shared session out from under them.
    func hasActiveClaims() -> Bool {
        state.withLock { !$0.claims.isEmpty }
    }

    /// Strict superset rule: if anyone wants record, the whole session must be
    /// `.playAndRecord`. Otherwise `.playback` is enough for the BGAM
    /// keep-alive use case.
    ///
    /// With no claimants left the session is untouched — callers do their own
    /// deactivation as part of tear-down.
    private func applyResolvedCategory() {
        let snapshot = state.withLock { $0.claims }
        guard !snapshot.isEmpty else { return }
        let needsRecord = snapshot.values.contains(.voiceRecord)
        let category: AVAudioSession.Category = needsRecord ? .playAndRecord : .playback
        let options = Self.categoryOptions(
            needsRecord: needsRecord,
            ducks: snapshot[.breathingGuide] != nil
        )
        // Skip if the session is already in this state — important because
        // voice's recognizer is sensitive to redundant setCategory calls
        // (they reset the engine's mic tap). Compared against the LIVE
        // session, not a record of our last call, so a category another
        // component set directly is still corrected.
        let session = AVAudioSession.sharedInstance()
        if session.category == category, session.categoryOptions == options { return }
        apply(category: category, mode: needsRecord ? .measurement : .default, options: options)
    }

    /// `.mixWithOthers` so the user's audiobook / podcast keeps playing
    /// alongside our silent keepalive. `.allowBluetoothHFP` is essential for
    /// AirPods voice; `.defaultToSpeaker` keeps TTS audible when no headphones
    /// are paired (without it the `.playAndRecord` category routes to the
    /// earpiece, which is basically inaudible). `.duckOthers` is deliberately
    /// NOT set — voice TTS shouldn't pause your podcast.
    ///
    /// `.allowBluetoothHFP` (Hands-Free Profile) is the iOS 26 SDK's name for
    /// what was `.allowBluetooth`. The semantics are unchanged; the rename
    /// clarifies that this is the SCO/HFP voice profile (low-bandwidth,
    /// mic-capable) rather than the A2DP higher-quality output-only profile.
    ///
    /// `.duckOthers` is added only for the breathing guide's playback claim,
    /// never alongside voice recording.
    private static func categoryOptions(needsRecord: Bool, ducks: Bool) -> AVAudioSession.CategoryOptions {
        if needsRecord { return [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker] }
        return ducks ? [.mixWithOthers, .duckOthers] : [.mixWithOthers]
    }

    /// A throw here is common during interruptions; the next claim/refresh
    /// cycle retries. Not actionable at this level.
    private func apply(
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) {
        do {
            try AVAudioSession.sharedInstance().setCategory(category, mode: mode, options: options)
        } catch {
            debugLog("[AudioSession] setCategory failed: \(error.localizedDescription)", level: .info)
        }
    }
}
