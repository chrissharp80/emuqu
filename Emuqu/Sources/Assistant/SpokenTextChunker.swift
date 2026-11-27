import Foundation

/// Buffers streaming text and emits complete sentences ready for TTS.
///
/// A separate type so the sentence-boundary
/// logic (plus markdown stripping for speech) is a pure, testable unit
/// with zero audio dependencies.
///
/// **Contract.** LLM provider deltas land here via `append(delta:)`.
/// When the buffer contains at least one sentence-ending character
/// (`.`, `!`, `?`, `\n`; a `.` that could be a decimal point waits for
/// the next character, and a `.`, `!` or `?` inside a markdown link or a
/// URL is not an ender) the chunker peels everything up to the last
/// ender, strips speech-hostile markdown, and returns it as a single
/// chunk ready to hand to `AVSpeechSynthesizer`. The un-terminated tail
/// remains buffered for the next delta. On turn end, `finalize()` flushes
/// the remainder.
///
/// A "." in "42.3" or in a link's address does not end a chunk.
final class SpokenTextChunker {
    /// Set of characters that mark sentence boundaries for chunking.
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "\n"]

    /// Internal text buffer. Exposed for tests; callers should not mutate.
    private(set) var pendingBuffer: String = ""

    /// How far the text spoken since the last `reset()` has followed one of
    /// the app's canned safety replies. `VoiceConversationController.speak`
    /// scrubs every utterance with it (`CoachVoiceGuard.scrub(_:continuing:)`),
    /// so a canned reply spoken chunk by chunk passes as the reply and its
    /// sentences said anywhere else do not. `reset()` starts it afresh.
    var safetyCopy = CoachVoiceGuard.SafetyCopyProgress()

    /// The reply spoken since the last `reset()`, as the hallucination guard
    /// passed it, one utterance per line. The guard reads it with each new
    /// utterance (`MetricsVerifier.verifyReply(_:after:against:)`): an earlier
    /// line ("Night before, November 25") can decide what a number in a later
    /// one is about. `reset()` empties it.
    var verifiedReply = ""

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

    /// Clear the buffer without emitting, and start `safetyCopy` and
    /// `verifiedReply` afresh: a reset marks the start of a new reply.
    func reset() {
        pendingBuffer = ""
        safetyCopy = CoachVoiceGuard.SafetyCopyProgress()
        verifiedReply = ""
    }

    /// Take back the last `count` characters appended, as far as they are
    /// still buffered. The voice pipeline calls this when the text it reads
    /// is rewound (a cut pre-tool lead-in, a failed reply a fallback
    /// replaces), so an unspoken tail of the withdrawn text is never spoken
    /// in front of what replaces it. Text already returned as a chunk cannot
    /// be taken back.
    func withdrawLast(_ count: Int) {
        guard count > 0 else { return }
        pendingBuffer = String(pendingBuffer.dropLast(count))
    }

    private func drainCompletedSentence() -> String? {
        guard let lastEnder = pendingBuffer.indices.last(where: { isSentenceBoundary(at: $0) }) else {
            return nil
        }
        let cutoff = pendingBuffer.index(after: lastEnder)
        let raw = String(pendingBuffer[..<cutoff]).trimmingCharacters(in: .whitespacesAndNewlines)
        pendingBuffer = String(pendingBuffer[cutoff...])
        guard !raw.isEmpty else { return nil }
        let speakable = Self.stripMarkdownForSpeech(raw)
        return speakable.isEmpty ? nil : speakable
    }

    /// A sentence ender, except a "." that may be a decimal point: one
    /// followed by a digit ("42.3"), or one after a digit that is the last
    /// buffered character (the fraction may arrive in the next delta).
    /// Cutting there would speak "42." and "3" as two utterances. A "."
    /// followed by a letter ("polar.com", "e.g") is not an ender either, and
    /// no ".", "!" or "?" inside a link or URL is (the "?" of "/a?b=1",
    /// "[Why?](…)"): cutting a markdown link inside it leaves a half link the
    /// markdown stripping does not recognise, and the voice reads the
    /// brackets and the address aloud. A newline always ends a chunk.
    private func isSentenceBoundary(at index: String.Index) -> Bool {
        let character = pendingBuffer[index]
        guard Self.sentenceEnders.contains(character) else { return false }
        guard character != "\n" else { return true }
        guard !isInsideLinkOrURL(at: index) else { return false }
        guard character == "." else { return true }
        let next = pendingBuffer.index(after: index)
        if next < pendingBuffer.endIndex { return !pendingBuffer[next].isNumber && !pendingBuffer[next].isLetter }
        guard index > pendingBuffer.startIndex else { return true }
        return !pendingBuffer[pendingBuffer.index(before: index)].isNumber
    }

    /// Whether `index` sits inside a markdown link that has not closed yet
    /// (in the label, or in the "(url" part) or inside a bare URL token.
    /// Reads back from `index` only as far as it needs (the start of the
    /// current token, the last "["), rather than splitting the whole buffer
    /// for every candidate ender.
    ///
    /// A "[" that never closes is not a link: a "[1" citation or a "[note"
    /// aside would otherwise hold back every later sentence until the reply
    /// ends. So a label still open past `maxLinkLabelLength` characters is
    /// taken as plain text, and so is a "(url" part that has reached a space,
    /// which no link address contains.
    private func isInsideLinkOrURL(at index: String.Index) -> Bool {
        let before = pendingBuffer[..<index]
        let tokenStart = before.lastIndex(where: \.isWhitespace).map { before.index(after: $0) } ?? before.startIndex
        let token = before[tokenStart...]
        if token.contains("://") || token.hasPrefix("www.") { return true }
        guard let open = before.lastIndex(of: "[") else { return false }
        let link = before[open...]
        guard let close = link.firstIndex(of: "]") else { return link.count <= Self.maxLinkLabelLength }
        let address = link[close...]
        return address.hasPrefix("](") && !address.contains(")") && !address.contains(where: \.isWhitespace)
    }

    /// The longest "[label" still read as a link being streamed. Link labels
    /// in replies are a few words ("[Polar's page]").
    private static let maxLinkLabelLength = 80

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
    ///   • a single `*` between letters, or `_` between word chars, as
    ///     emphasis; never next to a digit, so math like "5*3" and "5 * 3"
    ///     survives
    ///   • `*word*` emphasis around whole words: the asterisks hug the text
    ///     ("*really*"), which the spaced math above never does
    ///   • leading list markers ("- foo", "* foo", "+ foo")
    ///   • numbered list markers ("1. ", "2) ") keep their number, spoken as
    ///     "1, ": the chat shows the number, and a line that only looks like
    ///     a list item ("5. Nice work" after "Reps done:") must not lose it
    ///   • ATX headers (#, ##, ###)
    ///   • markdown links: [label](url) → label
    /// A list number as spoken: "3. Cool down" reads "3, Cool down".
    private static let spokenListNumber = "$1, "

    private static let markdownPatterns: [(String, String)] = [
        (#"(?<=\p{L})\*(?=\p{L})"#, ""),
        (#"(?<=\w)_(?=\w)"#, ""),
        (#"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])"#, "$1"),
        (#"(?m)^\s*[-*+]\s+"#, ""),
        (#"(?m)^\s*(\d+)[.)]\s+"#, spokenListNumber),
        (#"(?m)^\s*#{1,6}\s+"#, ""),
        (#"\[([^\]]+)\]\([^)]+\)"#, "$1")
    ]
}
