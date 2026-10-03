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
// Apple's default at the cost of a one-time model download, per-turn
// (rather than streaming) transcription and English-only recognition.
//
// `STTProviderKind` is the user-facing toggle (persisted in
// `UserSettings.preferredSTTProvider`, default `.apple` so existing
// behaviour is unchanged). The actual switch lives in
// `VoiceConversationController` — when WhisperKit is selected, the
// audio buffers from the AVAudioEngine tap are forwarded to
// `WhisperKitSTTBridge` and Apple's `recognitionRequest` is bypassed.
// Apple's path remains the fallback when the model isn't ready, and is
// used outright when the app language isn't English (see `effective`).

enum STTProviderKind: String, Codable, CaseIterable, Identifiable {
    /// Apple `SFSpeechRecognizer`. On-device when available (iOS 17+
    /// always honours the on-device flag). Streaming partials. Free.
    case apple
    /// WhisperKit (`base.en` model). On-device CoreML, English only.
    /// Per-turn transcription only — no live partials. Free, but the
    /// first session pays a model-download cost.
    case whisperKit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return String(localized: "Apple Speech (default)", bundle: LanguageManager.appBundle)
        case .whisperKit: return String(localized: "WhisperKit (open-source)", bundle: LanguageManager.appBundle)
        }
    }

    var subtitle: String {
        switch self {
        case .apple: return String(localized: "On-device when supported. Real-time partials. Zero setup.", bundle: LanguageManager.appBundle)
        case .whisperKit: return String(localized: "Better in wind / footfall noise. English only. One-time model download on first use. Per-turn (no live partials).", bundle: LanguageManager.appBundle)
        }
    }

    /// Whether this provider can transcribe speech in the language with this
    /// ISO 639 code. WhisperKit runs the English-only `base.en` model, so a
    /// German speaker would get an English model's guess at German.
    func supports(languageCode: String?) -> Bool {
        switch self {
        case .apple: true
        case .whisperKit: languageCode == "en"
        }
    }

    /// The provider a voice session actually uses: the user's preference,
    /// or Apple Speech when the preference can't handle the app language.
    static func effective(preferred: STTProviderKind, languageCode: String?) -> STTProviderKind {
        preferred.supports(languageCode: languageCode) ? preferred : .apple
    }

    /// `effective(preferred:languageCode:)` for the in-app language.
    static func effective(preferred: STTProviderKind) -> STTProviderKind {
        effective(preferred: preferred, languageCode: LanguageManager.appLocale.language.languageCode?.identifier)
    }
}
