import Foundation

/// Token-overlap heuristics that decide whether recognised speech is the
/// microphone hearing the app's own text-to-speech, lifted out of
/// `VoiceConversationController`.
///
/// Three call sites in the controller ran the same comparison against three
/// different references — the in-flight response, the previous assistant
/// turn, and a spoken medical refusal — and one of them carried its own
/// inline copy of the tokeniser. A drifting copy is exactly the failure this
/// code cannot afford in either direction: too eager and a real question gets
/// swallowed as echo, too lax and the assistant answers itself.
///
/// Pure, so the thresholds can be pinned by tests rather than trusted.
enum VoiceEchoHeuristics {
    /// The one tokeniser: lowercased words as the system's word breaker finds
    /// them, in any script (so Cyrillic, Arabic and Greek count, and
    /// Japanese and Chinese, which have no spaces, are split into words).
    /// Single-character words are dropped, except in the CJK and Hangul
    /// blocks where one character is often a whole word.
    ///
    /// The two-character floor skips "a" and "I" while still keeping "hey",
    /// "stop", and "no" — the words a barge-in most often starts with.
    static func tokens(_ text: String) -> Set<String> {
        Set(words(text))
    }

    /// Count of words as `tokens` defines them, repeats included. Barge-in
    /// counts new words with this and then tests them for echo with
    /// `tokens`, so the two share one definition of a word.
    static func wordCount(_ text: String) -> Int {
        words(text).count
    }

    private static func words(_ text: String) -> [String] {
        var found: [String] = []
        let lowered = text.lowercased()
        lowered.enumerateSubstrings(in: lowered.startIndex..., options: .byWords) { word, _, _, _ in
            guard let word, word.count >= 2 || isCJKOrHangul(word) else { return }
            found.append(word)
        }
        return found
    }

    /// U+3000 and up holds the CJK, kana and Hangul blocks.
    private static func isCJKOrHangul(_ word: String) -> Bool {
        (word.unicodeScalars.first?.value ?? 0) >= 0x3000
    }

    /// Fraction of `transcript`'s tokens that also appear in `reference`.
    /// Zero for an empty transcript — nothing overlaps nothing.
    static func overlapRatio(of transcript: String, against reference: String) -> Double {
        let transcriptTokens = tokens(transcript)
        guard !transcriptTokens.isEmpty else { return 0 }
        return Double(transcriptTokens.intersection(tokens(reference)).count)
            / Double(transcriptTokens.count)
    }

    /// Barge-in guard: is this candidate the mic hearing the response that is
    /// still being spoken?
    ///
    /// Deliberately more permissive (0.65) than the post-turn guard: we would
    /// rather miss a barge-in than yank the AI mid-sentence on a false one.
    static func isEchoOfInFlightResponse(candidate: String, streamedSoFar: String) -> Bool {
        guard !streamedSoFar.isEmpty, !tokens(candidate).isEmpty else { return false }
        return overlapRatio(of: candidate, against: streamedSoFar) >= inFlightEchoThreshold
    }

    /// Post-turn guard: did the mic catch the speaker's tail audio despite the
    /// drain delay, so this "user turn" is really the assistant's last one?
    ///
    /// Short transcripts overlap by chance far more often — "yes", "okay",
    /// "thanks" are all words an assistant reply is likely to contain — so
    /// four tokens or fewer must clear a much higher bar.
    static func looksLikeEcho(transcript: String, ofLastAssistantTurn lastAssistant: String) -> Bool {
        guard !lastAssistant.isEmpty, !transcript.isEmpty else { return false }
        let transcriptTokens = tokens(transcript)
        guard !transcriptTokens.isEmpty else { return false }
        let ratio = Double(transcriptTokens.intersection(tokens(lastAssistant)).count)
            / Double(transcriptTokens.count)
        return ratio >= threshold(forTokenCount: transcriptTokens.count)
    }

    /// High enough to catch genuine echo, low enough not to eat a real
    /// follow-up that happens to reuse the assistant's vocabulary.
    static let longTranscriptEchoThreshold = 0.6

    /// Chance overlap is likely at this length, so demand near-identity.
    static let shortTranscriptEchoThreshold = 0.85

    /// At or below this many tokens, a transcript counts as short.
    static let shortTranscriptTokenCount = 4

    /// See `isEchoOfInFlightResponse`.
    static let inFlightEchoThreshold = 0.65

    static func threshold(forTokenCount count: Int) -> Double {
        count <= shortTranscriptTokenCount ? shortTranscriptEchoThreshold : longTranscriptEchoThreshold
    }
}
