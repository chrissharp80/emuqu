import Foundation
#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Verbatim context
/// compaction for Apple Intelligence's 4,096-token window.
///
/// Apple's `LanguageModelSession` enforces a hard 4K-combined-token
/// ceiling (system + transcript + tools + response). Without
/// compaction, a 20-turn voice conversation will hit the wall
/// somewhere around turn 12-15 and the framework throws
/// `.exceededContextWindowSize`. The cloud providers don't have
/// this problem (Anthropic 200K, OpenAI 400K, Gemini 1M).
///
/// **Strategy.** Verbatim deletion of older turns once the
/// transcript approaches 70% of the budget — keep the system
/// prompt, drop the oldest user/assistant pairs in chronological
/// order until we're back under the threshold. The research note's
/// citation (CogCanvas, arxiv.org/pdf/2601.00821) reports verbatim
/// compaction beats LLM-summarized compaction 19% → 93% on
/// fact-preservation in coaching dialog. We stay verbatim.
///
/// **Why not LLM-summarize.** Summarization would call Apple
/// Intelligence to compress its own context — which means a
/// recursive call to the very model we're trying to fit context
/// for. Verbatim drop has zero overhead, deterministic behaviour,
/// and preserves quoted preferences ("call me Chris", "I run
/// 50 km/week") that summaries blur.
///
/// **Token estimation.** ASCII text counts at ~4 characters per
/// token; every non-ASCII character counts as a whole token, since
/// Japanese, Korean and Chinese run close to one token per character
/// and other scripts sit between the two. Both lean high, the safe
/// direction for a hard window.
///
/// Not `@MainActor` because the AppleFoundation
/// provider's stream task runs off-actor. Methods are pure
/// (string math + array transforms), no shared state, so
/// nonisolated access is safe.
enum AppleContextCompactor {
    /// Apple's hard ceiling per WWDC25 session 248.
    static let contextWindow: Int = 4096

    /// Trip the compaction at 70% of the window. Leaves 30%
    /// headroom for the response generation itself plus tools
    /// schema (when tool wiring is enabled).
    static let compactionThreshold: Double = 0.70

    /// Estimate token count for a string. Conservative
    /// (over-estimates) to avoid edge-case overruns.
    static func estimateTokens(_ text: String) -> Int {
        var ascii = 0
        var nonASCII = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { nonASCII += 1 }
        }
        // English is ~4 chars per token on average. Multiply by
        // 1.05 to over-estimate by 5% (safe direction).
        // Each step annotated: as one expression the literal-heavy Double
        // arithmetic inside `Int(ceil(...))` cost 143 ms to type-check.
        let charsPerToken: Double = 4.0
        let overEstimate: Double = 1.05
        let asciiEstimate: Double = Double(ascii) / charsPerToken * overEstimate
        return Int(ceil(asciiEstimate)) + nonASCII
    }

    /// Compact a transcript by dropping oldest user/assistant
    /// pairs until estimated token count is under the threshold.
    /// Returns the trimmed transcript + a flag indicating whether
    /// any compaction occurred.
    ///
    /// `systemPromptTokens` is the size of the static prefix that
    /// can't be trimmed (Apple's `instructions:` parameter to
    /// `LanguageModelSession`). The remaining budget for the
    /// transcript is `contextWindow * compactionThreshold − systemPromptTokens`.
    ///
    /// A non-positive budget means the system prompt alone exceeds the
    /// threshold — the caller is in trouble regardless, so we return an empty
    /// transcript apart from the user's latest turn, which at least has room.
    static func compact(
        _ messages: [ChatTurn],
        systemPromptTokens: Int
    ) -> (compacted: [ChatTurn], didCompact: Bool) {
        let budget = Int(Double(contextWindow) * compactionThreshold) - systemPromptTokens
        guard budget > 0 else { return (Array(messages.suffix(1)), true) }
        let (keep, used) = newestTurnsFitting(messages, budget: budget)
        let didCompact = keep.count < messages.count
        if didCompact {
            let dropped = messages.count - keep.count
            debugLog("[AppleCompactor] dropped \(dropped) oldest turns (kept \(keep.count), \(used)/\(budget) tokens used)")
        }
        return (keep, didCompact)
    }

    /// Walk newest → oldest, including each turn until the budget is
    /// exhausted. The most recent turn is always included — the model needs
    /// the question it's answering.
    private static func newestTurnsFitting(
        _ messages: [ChatTurn],
        budget: Int
    ) -> (keep: [ChatTurn], used: Int) {
        var keep: [ChatTurn] = []
        var used = 0
        for turn in messages.reversed() {
            let cost = estimateTokens(turn.text) + 8 // role marker overhead
            if used + cost > budget, !keep.isEmpty { break }
            keep.insert(turn, at: 0)
            used += cost
        }
        return (keep, used)
    }

    /// Convenience: compact + return prompt-ready transcript for
    /// `AppleFoundationProvider.buildPrompt(from:)`. Pure function
    /// — caller is responsible for the actual session call.
    static func compactedPromptInput(
        messages: [ChatTurn],
        systemPromptTokens: Int
    ) -> [ChatTurn] {
        compact(messages, systemPromptTokens: systemPromptTokens).compacted
    }
}

// MARK: - Turn budget

/// What Apple's window holds besides the instructions and the transcript:
/// the tools' descriptions, the results the model reads back from them, and
/// the reply. Tool results arrive mid-generation, after the compactor has
/// sized the transcript, so they get an allowance of their own here. Without
/// one, two tool results on a fresh session took a built-in suggestion chip
/// to 4,091 of 4,096 tokens and the turn failed.
extension AppleContextCompactor {
    /// One pass at a turn. A context overflow on `.full` is retried once as
    /// `.trimmed`: a fresh session, only the latest question, fewer tools,
    /// shorter tool results and capped instructions.
    enum Attempt: Equatable {
        case full
        case trimmed

        /// Tokens the tool descriptions may take.
        var toolTokenBudget: Int { self == .full ? 1024 : 512 }

        /// Most one tool result may take.
        var toolOutputCap: Int { self == .full ? 600 : 250 }

        /// Most the instructions may take. The data section sits at their
        /// end, so a cut drops the oldest data and keeps the rules.
        var instructionTokenCap: Int { self == .full ? Int.max : 1800 }

        /// Whether earlier turns go with the question.
        var keepsHistory: Bool { self == .full }

        /// The attempt to make after this one overflows the window, if any.
        var afterOverflow: Attempt? { self == .full ? .trimmed : nil }
    }

    /// Tokens kept free for the reply.
    static let responseReserve = 512

    /// Headroom for the estimate running low: numbers and JSON tokenize
    /// denser than the four characters per token it assumes.
    static let estimateMargin = 300

    /// Least a tool result is given, so a call always returns something the
    /// model can read.
    static let minToolOutputTokens = 60

    /// Appended to a tool result that was cut to fit.
    static let toolOutputCutNote = " …[cut to fit the on-device model; answer from what is shown]"

    /// Appended to instructions that were cut to fit.
    static let instructionsCutNote = "\n…[older data cut to fit the on-device model]"

    /// Estimated tokens of a transcript, with the per-turn role overhead the
    /// compactor charges.
    static func transcriptTokens(_ messages: [ChatTurn]) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1.text) + 8 }
    }

    /// Tokens all tool results in one turn may take together: what the window
    /// has left after the fixed prefix, the transcript, the reply and the
    /// estimate margin, and never less than `minToolOutputTokens`.
    static func toolOutputBudget(fixedTokens: Int, transcriptTokens: Int) -> Int {
        let left = contextWindow - fixedTokens - transcriptTokens - responseReserve - estimateMargin
        return max(minToolOutputTokens, left)
    }

    /// `text` cut to at most `maxTokens` estimated tokens, `note` included,
    /// or unchanged when it already fits.
    static func truncate(_ text: String, toTokens maxTokens: Int, note: String) -> String {
        guard estimateTokens(text) > maxTokens else { return text }
        let room = max(0, maxTokens - estimateTokens(note))
        return prefix(of: text, fittingTokens: room) + note
    }

    /// The longest prefix whose estimate stays within `tokens`. Charges each
    /// character as `estimateTokens` does, one token short of the limit to
    /// absorb its rounding up.
    private static func prefix(of text: String, fittingTokens tokens: Int) -> String {
        let limit = Double(tokens - 1)
        var cost = 0.0
        var end = text.startIndex
        for index in text.indices {
            let charCost = text[index].unicodeScalars.reduce(0.0) { $0 + ($1.isASCII ? 1.05 / 4.0 : 1.0) }
            if cost + charCost > limit { break }
            cost += charCost
            end = text.index(after: index)
        }
        return String(text[..<end])
    }

    /// What the tool results of one turn have left to spend.
    struct ToolOutputAllowance: Equatable {
        private(set) var remaining: Int
        let perCallCap: Int

        /// The allowance before a provider has sized the turn.
        static let unsized = ToolOutputAllowance(
            remaining: AppleContextCompactor.contextWindow / 4,
            perCallCap: Attempt.full.toolOutputCap
        )

        /// Read back to the model once the allowance is spent.
        static let spentNote = FactValue.missing(
            reason: .rateLimited,
            detail: "no room left for more tool results this turn — answer with what you have"
        ).toToolResultJSON()

        init(remaining: Int, perCallCap: Int) {
            self.remaining = remaining
            self.perCallCap = perCallCap
        }

        /// The result as the model will read it: cut to the per-call cap and
        /// to what is left, then charged. Past the end of the allowance, a
        /// short note in its place.
        mutating func admit(_ output: String) -> String {
            guard remaining >= AppleContextCompactor.minToolOutputTokens else { return Self.spentNote }
            let capped = AppleContextCompactor.truncate(
                output, toTokens: min(perCallCap, remaining), note: AppleContextCompactor.toolOutputCutNote
            )
            remaining -= AppleContextCompactor.estimateTokens(capped)
            return capped
        }
    }
}
