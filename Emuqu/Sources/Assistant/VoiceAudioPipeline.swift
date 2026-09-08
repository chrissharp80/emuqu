import Foundation

/// Getting the user's voice into text: the audio engine and its session, the
/// recogniser, the RMS voice-activity detector that decides when a turn has
/// ended, and the watchdogs that notice when a recognition task has quietly
/// died.
///
/// ## Why this is not on `VoiceConversationController`
///
/// `VoiceConversationController` is one of the largest types in the
/// codebase, and this is well over a thousand lines of it.
///
/// Capture and playback are two halves that fight over one audio session; they
/// are split here so each is small enough to hold in your head, with
/// `VoiceSpeechController` owning the other half.
///
/// The coupling was measured before the move rather than assumed: the
/// conversation state machine, the partial transcript, and the published
/// properties the sheet binds to.
///
/// The `[weak self]` captures inside — a notification observer, the silence
/// timer, the Combine sinks — now weakly hold this object. Equivalent: the
/// controller is the only strong reference, so this dies exactly when it would
/// have, and every one already no-ops on a nil self.
///
/// Holds its owner strongly and is built on demand by the controller — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct VoiceAudioPipeline {
    let controller: VoiceConversationController

}
