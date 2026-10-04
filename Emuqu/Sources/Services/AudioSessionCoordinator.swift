import AVFoundation
import Foundation
import os

// MARK: - AudioSessionCoordinator
//
// Single owner of `AVAudioSession` category transitions. Five claimants
// (`Claimant`) declare what they need:
//
//   • `voice` — `VoiceConversationController`, `.playAndRecord` with a
//     live mic tap during voice chats.
//   • `dictation` — tap-to-talk in the Assistant composer, mic only.
//   • `backgroundKeepalive` — `BackgroundAudioManager`, `.playback` with
//     `.mixWithOthers`. Started only on indoor workouts with an audible
//     coach feature on, so spoken cues are delivered with the screen off.
//   • `workoutCoach` — the workout voice coach's spoken cues, playback.
//   • `breathingGuide` — the breathing guide's spoken cues, playback; the
//     one claimant that ducks other apps' audio.
//
// **The bug this prevents.** If each called `AVAudioSession.setCategory(...)`
// directly, the keep-alive starting during a voice chat would clobber
// voice's `.playAndRecord` with `.playback` — voice's mic goes silent and
// the recogniser produces "no speech detected". The keep-alive's periodic
// health check restarts its engine, so it would clobber it again even
// after voice re-claimed `.playAndRecord`.
//
// **The rule.** All category transitions go through this coordinator.
// Each claimant calls `claim(_:mode:)` / `release(_:)`; the coordinator
// applies the category that satisfies every live claim. `.playAndRecord`
// is a superset of `.playback` (the keep-alive's silent buffer plays fine
// over it with `.mixWithOthers` merged in), so while voice or dictation
// holds a record claim the playback claimants change nothing
// category-wise.

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
        /// BGAM keepalive (indoor workout) can't clobber
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

    /// Serialises resolve-and-apply. `state` guards only the claims; without
    /// this, a claim and a release racing on two threads could each read the
    /// claims and the one that read them first could apply last, leaving a
    /// stale category (`.playback` while voice holds a record claim). A
    /// recursive lock, not the unfair lock, because `setCategory` can block
    /// and a session notification can re-enter on the same thread.
    private let applyLock = NSRecursiveLock()

    private init() {}

    /// Claim a mode. Idempotent — multiple calls with the same claim
    /// are cheap (we only re-apply if the resolved category changes).
    /// Thread-safe; can be called from any actor: the claim and the category
    /// it resolves to are applied in order with every other claim/release.
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
        applyLock.withLock { applyCurrentClaims() }
    }

    /// Must be called holding `applyLock`, so the claims it reads are the
    /// ones it applies.
    private func applyCurrentClaims() {
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
