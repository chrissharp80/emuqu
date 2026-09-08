import Foundation

/// Buffers streaming text and emits complete sentences ready for TTS.
///
/// Split out from `VoiceConversationController` so the sentence-boundary
/// logic (plus markdown stripping for speech) is a pure, testable unit
/// with zero audio dependencies.
///
/// **Contract.** LLM provider deltas land here via `append(delta:)`.
/// When the buffer contains at least one sentence-ending character
/// (`.`, `!`, `?`, `\n`) the chunker peels everything up to the last
/// ender, strips speech-hostile markdown, and returns it as a single
/// chunk ready to hand to `AVSpeechSynthesizer`. The un-terminated tail
/// remains buffered for the next delta. On turn end, `finalize()` flushes
/// the remainder.
///
/// This mirrors the prior in-class behavior exactly — callers that fed
/// deltas and flushed at sentence boundaries get identical chunks.
final class SpokenTextChunker {
    /// Set of characters that mark sentence boundaries for chunking.
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "\n"]

    /// Internal text buffer. Exposed for tests; callers should not mutate.
    private(set) var pendingBuffer: String = ""

    /// Whether there's any buffered content waiting to be emitted.
    var hasPendingContent: Bool { !pendingBuffer.isEmpty }

    /// Append a delta. Returns a speakable chunk if the buffer now
    /// contains at least one sentence-ender; otherwise nil.
    ///
    /// The returned chunk has markdown stripped (so the synthesiser
    /// doesn't read `**bold**` as "asterisk asterisk bold asterisk
    /// asterisk"). The un-terminated tail stays buffered.
    func append(delta: String) -> String? {
        pendingBuffer += delta
        return drainCompletedSentence()
    }

    /// Flush everything still buffered. Returns the (markdown-stripped)
    /// remainder if non-empty, else nil. Buffer is emptied either way.
    func finalize() -> String? {
        let remainder = pendingBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingBuffer = ""
        guard !remainder.isEmpty else { return nil }
        let speakable = Self.stripMarkdownForSpeech(remainder)
        return speakable.isEmpty ? nil : speakable
    }

    /// Clear the buffer without emitting.
    func reset() {
        pendingBuffer = ""
    }

    private func drainCompletedSentence() -> String? {
        guard let lastEnder = pendingBuffer.lastIndex(where: { Self.sentenceEnders.contains($0) }) else {
            return nil
        }
        let cutoff = pendingBuffer.index(after: lastEnder)
        let raw = String(pendingBuffer[..<cutoff]).trimmingCharacters(in: .whitespacesAndNewlines)
        pendingBuffer = String(pendingBuffer[cutoff...])
        guard !raw.isEmpty else { return nil }
        let speakable = Self.stripMarkdownForSpeech(raw)
        return speakable.isEmpty ? nil : speakable
    }

    /// Strip markdown syntax that `AVSpeechSynthesizer` would otherwise
    /// read aloud as literal punctuation.
    ///
    /// Intentionally narrow: only the markdown LLMs commonly emit. URLs
    /// and citations are left intact — TTS handles them gracefully.
    static func stripMarkdownForSpeech(_ text: String) -> String {
        // Bold + italic emphasis. Order matters — strip ** before *.
        var s = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "") // inline code
        for (pattern, replacement) in Self.markdownPatterns {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return s
    }

    /// Regex rewrites, in order:
    ///   • single `*` / `_` as emphasis, only between word chars so math like
    ///     "5 * 3" survives
    ///   • leading list markers ("- foo", "* foo", "+ foo")
    ///   • numbered list markers ("1. ", "2) ")
    ///   • ATX headers (#, ##, ###)
    ///   • markdown links: [label](url) → label
    private static let markdownPatterns: [(String, String)] = [
        (#"(?<=\w)\*(?=\w)"#, ""),
        (#"(?<=\w)_(?=\w)"#, ""),
        (#"(?m)^\s*[-*+]\s+"#, ""),
        (#"(?m)^\s*\d+[.)]\s+"#, ""),
        (#"(?m)^\s*#{1,6}\s+"#, ""),
        (#"\[([^\]]+)\]\([^)]+\)"#, "$1")
    ]
}
