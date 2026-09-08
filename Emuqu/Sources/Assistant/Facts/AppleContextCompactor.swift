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
/// **Token estimation.** Pre-iOS 26.4: chars ÷ 4 (the GPT-2-style
/// rule of thumb that overestimates English tokens by 5-10%, which
/// is the safe direction). iOS 26.4+: use `tokenCount(for:)` if
/// available (back-deployed per the research note).
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
    /// (over-estimates) to avoid edge-case overruns. Replace with
    /// `SystemLanguageModel.default.tokenCount(for:)` when the
    /// codebase moves to an iOS 26.4 baseline.
    static func estimateTokens(_ text: String) -> Int {
        // English is ~4 chars per token on average. Multiply by
        // 1.05 to over-estimate by 5% (safe direction).
        // Each step annotated: as one expression the literal-heavy Double
        // arithmetic inside `Int(ceil(...))` cost 143 ms to type-check.
        let charsPerToken: Double = 4.0
        let overEstimate: Double = 1.05
        let estimate: Double = Double(text.count) / charsPerToken * overEstimate
        return Int(ceil(estimate))
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
