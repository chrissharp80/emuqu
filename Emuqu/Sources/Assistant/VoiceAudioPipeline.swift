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
/// Capture and playback fight over one audio session; capture lives here
/// (`VoiceConversationController+Pipeline.swift` and `+Audio.swift`), while
/// playback — the synthesizer and its delegate — stays on the controller
/// (`VoiceConversationController+Speech.swift`).
///
/// The coupling was measured before the move rather than assumed: the
/// conversation state machine, the partial transcript, and the published
/// properties the chat view binds to. Those reads go through `controller.`.
///
/// Holds its owner strongly and is built on demand by the controller — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct VoiceAudioPipeline {
    let controller: VoiceConversationController

}
