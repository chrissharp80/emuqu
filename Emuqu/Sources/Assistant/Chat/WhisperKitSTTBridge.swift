// `@preconcurrency` on AVFoundation: silences two
// Swift 6 strict-concurrency warnings that aren't real bugs at our
// usage shape:
//   1. AVFAudio types (AVAudioPCMBuffer, AVAudioConverter) are
//      pre-Swift-Concurrency Apple frameworks; their `Sendable`
//      annotations are inferred conservatively. We pre-existed the
//      checker.
//   2. The `AVAudioConverterInputBlock` closure passed to
//      `converter.convert(to:error:withInputFrom:)` is typed
//      `@Sendable` by the framework but executes SYNCHRONOUSLY on
//      the calling thread inside `convert(...)` — so the
//      `AVAudioPCMBuffer` capture (from the for-loop variable) is
//      never crossed across actors in practice. Adding
//      `@preconcurrency` accepts the framework's own concurrency
//      typing rather than re-asserting it on our side.
@preconcurrency import AVFoundation
import Foundation
// `@preconcurrency`: the WhisperKit pipeline object predates Sendable.
@preconcurrency import WhisperKit

// MARK: - WhisperKit STT bridge
//
// Open-source on-device speech-to-text backed by Argmax's CoreML port
// of OpenAI Whisper (`https://github.com/argmaxinc/WhisperKit`).
//
// Architectural shape:
//
//   • The AVAudioEngine tap in `VoiceConversationController` already
//     captures PCM buffers at the device's input format. When the user
//     has selected `STTProviderKind.whisperKit`, those buffers are
//     forwarded HERE (via `appendAudio(_:)`) instead of going into
//     `SFSpeechAudioBufferRecognitionRequest.append`.
//
//   • Whisper's transcription model is per-utterance, not streaming.
//     We accumulate buffers across the user's spoken turn, and on
//     end-of-turn (VAD silence triggers `transcribeAndReset()`) we
//     write the accumulated audio to a temp WAV, hand it to
//     WhisperKit, and return the final string.
//
//   • The model loads lazily on first transcription. The first
//     session per app install pays a download cost (~100 MB for
//     `base.en`); subsequent sessions reuse the cached model.
//     Loading runs on a background actor so the audio capture path
//     is never blocked.
//
//   • Apple's `SFSpeechRecognizer` remains the fallback. If WhisperKit
//     fails to load OR transcribe, the controller silently falls
//     through to Apple's path — voice mode never goes dark.
//
// Limitations vs Apple:
//
//   • No live partial transcripts. The user sees "[transcribing…]"
//     during the WhisperKit await, then the full result lands at once.
//     For a 6-second utterance the wait is typically ~0.5–1.5 s on an
//     A14+ device with the `base.en` model.
//   • No per-word timing. The fact catalog's transcript-stamping
//     features (which Apple provides via
//     `SFSpeechRecognitionResult.bestTranscription.segments`) are
//     unavailable on the WhisperKit path.
//
// Privacy: all transcription happens on-device. No audio leaves the
// phone. The model itself is downloaded from Hugging Face on first
// use.

@MainActor
final class WhisperKitSTTBridge {
    static let shared = WhisperKitSTTBridge()

    /// True once the model has loaded successfully. Callers can use
    /// this to decide whether to surface a "downloading model…" UI.
    private(set) var modelReady: Bool = false
    /// Last human-readable status line ("ready" / "downloading model…"
    /// / "transcribing…" / "load failed: …") for the diagnostics UI.
    private(set) var statusLine: String = "idle"

    /// Which Whisper model to use. `base.en` is the right tradeoff for
    /// a phone-on-arm fitness app: ~74 MB download, real-time on
    /// A14+, English-only. Multilingual users can later pick `base`
    /// (no `.en` suffix) but the additional download isn't worth it
    /// without a UI surface.
    private let modelVariant: String = "base.en"

    /// The loaded WhisperKit pipeline. Nil until the first
    /// `prepareModel()` succeeds.
    private var pipeline: WhisperKit?

    /// Buffers collected during the current spoken turn. Cleared on
    /// `transcribeAndReset()`. Buffers are kept in their original
    /// AVAudioPCMBuffer form (preserved sample rate + channel
    /// layout) until transcription time, when they are mixed-down
    /// to mono 16 kHz and written as WAV.
    private var pendingBuffers: [AVAudioPCMBuffer] = []

    private init() {}

    // MARK: - Lifecycle

    /// Kick off the model load if it hasn't started. Idempotent. Safe
    /// to call from the audio path — the actual download happens on
    /// a background task.
    func prepareModelIfNeeded() {
        guard pipeline == nil, !isLoading else { return }
        isLoading = true
        statusLine = "downloading model…"
        Task { @MainActor in
            do {
                let pipe = try await WhisperKit(model: modelVariant)
                self.pipeline = pipe
                self.modelReady = true
                self.statusLine = "ready"
                debugLog("[WhisperKit] model '\(modelVariant)' loaded")
            } catch {
                self.statusLine = "load failed: \(error.localizedDescription)"
                debugLog("[WhisperKit] model load failed: \(error)", level: .warning)
            }
            self.isLoading = false
        }
    }

    private var isLoading = false

    // MARK: - Audio collection

    /// Forward a PCM buffer from the AVAudioEngine tap. No-op when the
    /// model isn't loaded yet — the user's first turn after enabling
    /// WhisperKit gets dropped on the floor while the model
    /// downloads, then subsequent turns work normally. The
    /// controller surfaces this via `statusLine` so the user knows
    /// what's happening.
    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        guard modelReady, pipeline != nil else { return }
        // AVAudioPCMBuffer can't be safely held across actor hops
        // unless we copy it — the underlying audio data lives in a
        // memory pool the engine can recycle.
        if let copy = buffer.deepCopy() {
            pendingBuffers.append(copy)
            capPendingBuffers()
        }
    }

    /// Bound accumulated audio to ~60s. End-of-turn VAD normally drains
    /// `pendingBuffers` well before this, but if VAD never fires (sustained
    /// wind/noise — the exact condition WhisperKit targets) the buffer would
    /// grow without limit at ~192 KB/s and jetsam-kill the app mid-turn. The
    /// Apple path bounds this with `maxTurnDurationSec`; this mirrors it.
    private func capPendingBuffers() {
        let maxFrames: AVAudioFrameCount = 48_000 * 60
        var total = pendingBuffers.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        while total > maxFrames, pendingBuffers.count > 1 {
            total -= pendingBuffers.removeFirst().frameLength
        }
    }

    /// Drop any pending buffers without transcribing. Call when the
    /// user starts a fresh turn or when voice mode tears down.
    func reset() {
        pendingBuffers.removeAll()
    }

    /// Transcribe everything collected since the last reset, return
    /// the text, and clear the buffer. Throws if the model isn't
    /// loaded or if WhisperKit returns an error. Caller is expected
    /// to fall back to the Apple path on throw.
    func transcribeAndReset() async throws -> String {
        guard let pipeline else {
            throw STTBridgeError.modelNotLoaded
        }
        let buffersSnapshot = pendingBuffers
        pendingBuffers.removeAll()
        guard !buffersSnapshot.isEmpty else {
            return ""
        }
        statusLine = "transcribing…"
        defer { Task { @MainActor in statusLine = "ready" } }
        // Mix-down + downsample on a background queue. WAV write to
        // /tmp; WhisperKit reads the file path. Temp file is deleted
        // after transcription completes.
        let wavURL = try Self.writeMonoWav(at16k: buffersSnapshot)
        defer { _ = attempt("WhisperKitSTTBridge.remove") { try FileManager.default.removeItem(at: wavURL) } }
        let results = try await pipeline.transcribe(audioPath: wavURL.path)
        let text = results.first?.text ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private — WAV mixdown
    //
    // WhisperKit accepts PCM audio at 16 kHz mono. Our AVAudioEngine
    // tap delivers whatever the device's input format is (typically
    // 44.1 or 48 kHz, 1–2 channels). Convert with AVAudioConverter
    // into the target format, then write a minimal WAV header so
    // WhisperKit's audio loader (which uses AVAudioFile under the
    // hood) can decode without surprises.

    /// No force-unwrap on the AVAudioFormat init.
    /// The hard-coded Whisper format (Float32, 16 kHz, mono,
    /// non-interleaved) is universally supported, but
    /// `AVAudioFormat.init?` is documented to return nil and
    /// a boundary must not force-unwrap it. Throw a
    /// typed error instead so the bridge degrades to the Apple
    /// recognizer fallback rather than crashing the process.
    private static func writeMonoWav(at16k buffers: [AVAudioPCMBuffer]) throws -> URL {
        guard let firstFormat = buffers.first?.format else { throw STTBridgeError.emptyAudio }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ) else { throw STTBridgeError.converterUnavailable }
        guard let converter = AVAudioConverter(from: firstFormat, to: targetFormat) else {
            throw STTBridgeError.converterUnavailable
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperkit-utterance-\(Int(Date().timeIntervalSince1970)).wav")
        let file = try AVAudioFile(
            forWriting: url,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        for input in buffers {
            guard let output = try convert(input, with: converter, to: targetFormat) else { continue }
            if output.frameLength > 0 { try file.write(from: output) }
        }
        return url
    }

    /// Convert one captured buffer to the Whisper format. The output buffer is
    /// allocated at the input's capacity: Whisper input is 16 kHz and our tap
    /// is up to 48 kHz, so the converted size is bounded by the input size.
    /// Nil when that allocation fails.
    ///
    /// `@preconcurrency import` does not hide this
    /// one: the input-block parameter is `@Sendable` in the SDK
    /// and captures `input` (AVAudioPCMBuffer, not Sendable) plus
    /// `didFeed` (mutated across calls). Both are wrapped in an
    /// explicitly-unchecked-Sendable box. The closure runs
    /// SYNCHRONOUSLY on the calling thread inside `convert(...)`,
    /// so there's no real concurrency to police — the unchecked
    /// box just acknowledges that for the type checker.
    private static func convert(
        _ input: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: input.frameCapacity
        ) else { return nil }
        var error: NSError?
        let feeder = UnsafeAVConverterFeeder(buffer: input)
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            feeder.next(outStatus)
        }
        if status == .error { throw error ?? STTBridgeError.conversionFailed }
        return output
    }
}

/// Single-shot feeder for `AVAudioConverter.convert`'s
/// input block. Holds one source buffer and yields it once, then
/// signals end-of-stream on subsequent calls. Marked `@unchecked
/// Sendable` because the convert block is synchronous: even though
/// the SDK types the block `@Sendable`, it's invoked on the calling
/// thread inside `convert(...)` and never escapes, so the captured
/// `AVAudioPCMBuffer` is never shared concurrently in practice.
private final class UnsafeAVConverterFeeder: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var didFeed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if didFeed {
            outStatus.pointee = .endOfStream
            return nil
        }
        didFeed = true
        outStatus.pointee = .haveData
        return buffer
    }
}

// MARK: - Errors

enum STTBridgeError: LocalizedError {
    case modelNotLoaded
    case emptyAudio
    case converterUnavailable
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "WhisperKit model isn't loaded yet — try again in a moment."
        case .emptyAudio: return "No audio captured for this turn."
        case .converterUnavailable: return "Couldn't create the 16 kHz mono converter."
        case .conversionFailed: return "Audio conversion to 16 kHz failed."
        }
    }
}

// MARK: - AVAudioPCMBuffer deep copy
//
// AVAudioEngine taps reuse a buffer pool — holding the pointer past
// the closure's return is undefined behavior. `deepCopy()` allocates
// a fresh buffer of the same format and copies the floats over so
// we can safely accumulate across the spoken turn.

private extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        copy.frameLength = frameLength
        let channelCount = Int(format.channelCount)
        let frames = Int(frameLength)
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for ch in 0 ..< channelCount {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size)
            }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0 ..< channelCount {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Int16>.size)
            }
        }
        return copy
    }
}
