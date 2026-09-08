import AVFoundation
import Foundation

// MARK: - STT provider seam
//
// The voice-conversation pipeline historically baked
// `SFSpeechRecognizer` calls directly into
// `VoiceConversationController`. That coupling was correct for v1
// (one provider, one audio engine, tightly tuned restart logic) but
// it left no room to plug in a second backend. Open-source
// WhisperKit (CoreML-on-device port of OpenAI Whisper) is an
// optional alternative — it handles wind / footfall noise better than
// Apple's default at the cost of a ~100–400 MB model download and
// per-turn (rather than streaming) transcription.
//
// `STTProviderKind` is the user-facing toggle (persisted in
// `UserSettings.preferredSTTProvider`, default `.apple` so existing
// behaviour is unchanged). The actual switch lives in
// `VoiceConversationController` — when WhisperKit is selected, the
// audio buffers from the AVAudioEngine tap are forwarded to
// `WhisperKitSTTBridge` and Apple's `recognitionRequest` is bypassed.
// Apple's path remains the fallback when the model isn't ready.

enum STTProviderKind: String, Codable, CaseIterable, Identifiable {
    /// Apple `SFSpeechRecognizer`. On-device when available (iOS 17+
    /// always honours the on-device flag). Streaming partials. Free.
    case apple
    /// WhisperKit (`base.en` model). On-device CoreML. Per-turn
    /// transcription only — no live partials. Free, but the first
    /// session pays a model-download cost.
    case whisperKit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "Apple Speech (default)"
        case .whisperKit: return "WhisperKit (open-source)"
        }
    }

    var subtitle: String {
        switch self {
        case .apple: return "On-device when supported. Real-time partials. Zero setup."
        case .whisperKit: return "Better in wind / footfall noise. ~100 MB download on first use. Per-turn (no live partials)."
        }
    }
}
