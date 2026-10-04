import Foundation

/// Two decisions about whose turn it is in a spoken conversation: whether a
/// recognition failure should be retried, and whether the assistant may
/// interrupt with a proactive trigger.
///
/// ## Why this exists
///
/// Both encode reported bugs, and both lived inside the audio pipeline where
/// nothing could reach them — `VoiceConversationController+Pipeline.swift` and
/// `+Control.swift` sit at near-zero coverage, because reaching
/// them means driving `AVAudioEngine` and the speech recogniser.
///
///  * **Restarting recognition while TTS is playing thrashes AVAudio.** Every
///    restart re-arms the mic loop, which competes with the synthesiser for the
///    audio session and can cut playback off mid-sentence.
///  * **A trigger firing mid-dictation wipes the user's sentence.** Speaking a
///    proactive alert clears `partialTranscript`; the user reported it as
///    "alerts wipe out my message."
///
/// Every input is app-owned, so the decisions were always separable — only the
/// audio plumbing around them was not.
enum VoiceTurnPolicy {
    /// What the voice loop can see of the assistant's stream: whether one is
    /// running, and which one. `AssistantViewModel.dispatch()` bumps the
    /// generation every time it starts a stream, and `cancel()` bumps it too.
    struct StreamEdge: Equatable, Sendable {
        let isStreaming: Bool
        let generation: Int
    }

    /// Whether the turn queued behind an in-flight stream has started.
    ///
    /// The view model finishes the in-flight stream and drains the queued send
    /// in one main-actor run, so an observer sees `isStreaming` go
    /// `true → false → true` as a single delivery of `true`. The generation
    /// changes across that drain even though the Bool does not; comparing it
    /// with the generation seen at wiring time is what makes the queued turn
    /// visible. Otherwise the reply lands as text with no speech.
    static func queuedTurnStarted(wiredTo wired: StreamEdge, now: StreamEdge) -> Bool {
        now.isStreaming && now.generation != wired.generation
    }

    /// Whether the response the voice loop is speaking has finished: either the
    /// stream stopped, or a different stream has replaced it in the same
    /// collapsed delivery. Both mean the spoken remainder must drain and the
    /// mic must reopen; waiting for a bare `false` would leave voice wedged in
    /// `.speaking` whenever a follow-up was queued during the reply.
    static func spokenResponseFinished(wiredTo wired: StreamEdge, now: StreamEdge) -> Bool {
        !now.isStreaming || now.generation != wired.generation
    }

    /// The recogniser errors that mean "the task died, but the session is
    /// healthy" — the only ones worth restarting for.
    ///
    /// Everything else is either fatal or better handled by the long-idle,
    /// first-partial and stalled-transcript watchdogs in `+Audio.swift`, which
    /// can tell a dead task from a healthy-but-quiet one.
    static let restartableRecognitionErrors: Set<String> = [
        "kAFAssistantErrorDomain:1110",
        "kLSRErrorDomain:301"
    ]

    /// Whether a recognition failure should be retried.
    ///
    /// Restricted to `.listening` deliberately. Restarting while the assistant
    /// is speaking re-arms the mic against the synthesiser and can interrupt it
    /// mid-sentence; the natural `.speaking` → `.listening` transition at TTS
    /// end re-arms recognition cleanly on its own.
    static func shouldRestartRecognition(
        errorDomain: String,
        errorCode: Int,
        state: VoiceConversationController.State
    ) -> Bool {
        guard restartableRecognitionErrors.contains("\(errorDomain):\(errorCode)") else { return false }
        return state == .listening
    }

    /// Whether the user is mid-turn, so a proactive trigger must wait.
    ///
    /// - Parameters:
    ///   - state: where the conversation is.
    ///   - hasInFlightLLMTask: a response is being generated.
    ///   - isStreamingResponse: tokens are arriving.
    ///   - synthesizerIsSpeaking: the synthesiser has audio out.
    ///   - hasPartialTranscript: the user has said something not yet committed.
    static func isBusyWithUserResponse(
        state: VoiceConversationController.State,
        hasInFlightLLMTask: Bool,
        isStreamingResponse: Bool,
        synthesizerIsSpeaking: Bool,
        hasPartialTranscript: Bool
    ) -> Bool {
        // A trigger line still playing, or an AI interjection still being
        // generated, finishes first; once both are done the queue drains into
        // the next trigger instead of waiting behind the trigger state.
        if state == .triggerSpeaking { return hasInFlightLLMTask || synthesizerIsSpeaking }
        if hasInFlightLLMTask || isStreamingResponse { return true }
        if synthesizerIsSpeaking, state == .speaking { return true }
        // The reported bug: interrupting here wipes the sentence in progress.
        if state == .listening, hasPartialTranscript { return true }
        if state == .thinking { return true }
        return false
    }
}
