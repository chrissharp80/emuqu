import Foundation

/// On-device telemetry surface for LLM prompt-cache health.
///
/// The research note says verifying cache hit rate in production is
/// the #1 open blocker for sizing the wider migration. Today's path
/// already logs every `.usage` event via `debugLog` (visible in the
/// runtime-logger ring buffer), but there's no settings-surface
/// summary. This adds a rolling counter exposed in
/// **Settings → Troubleshooting → AI cache health**.
///
/// **Privacy.** All counters are in-memory only. Resets on app
/// relaunch and on `DataPurgeService.purgeAllUserData()`. Never
/// transmitted off-device.
///
/// **Concurrency.** `@MainActor` — every `record(...)` call comes
/// from the AssistantViewModel's `.usage` handler which runs on
/// MainActor; no locking needed.
@Observable
@MainActor
final class LLMCacheTelemetry {
    static let shared = LLMCacheTelemetry()

    /// Rolling totals across all providers since app launch.
    /// A single struct rather than five separate observed properties,
    /// so each `record(...)` triggers exactly one observer notification
    /// rather than five (otherwise the cache-health card and any future
    /// observers re-render five times per turn).
    /// Public API preserved via computed properties below.
    struct Totals: Equatable {
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cachedReadTokens: Int = 0
        var cacheCreateTokens: Int = 0
        var turns: Int = 0
    }

    private(set) var totals: Totals = .init()

    /// Backwards-compatible accessors. Settings → Troubleshooting →
    /// AI cache health card reads these. SwiftUI re-evaluates the
    /// view body on `totals` changes, so the computed properties
    /// stay in lock-step.
    var totalInputTokens: Int { totals.inputTokens }
    var totalOutputTokens: Int { totals.outputTokens }
    var totalCachedReadTokens: Int { totals.cachedReadTokens }
    var totalCacheCreateTokens: Int { totals.cacheCreateTokens }
    var totalTurns: Int { totals.turns }

    /// Last 50 turns (rolling) for the recent-history readout.
    private struct TurnRecord {
        let provider: String
        let timestamp: Date
        let inputTokens: Int
        let outputTokens: Int
        let cachedReadTokens: Int
        let cacheCreateTokens: Int

        var hitRatio: Double {
            // Hit rate = cached / total prompt tokens processed.
            // `inputTokens` is ONLY the new uncached portion billed at full
            // rate, separate from `cache_read` (cached prefix) and
            // `cache_creation` (just-cached). Anthropic reports it that way;
            // OpenAI, DeepSeek and Gemini count cached tokens inside their
            // prompt total, and their streamers subtract them before
            // emitting `.usage`. So the total prompt size = input +
            // cache_read + cache_create. Dividing by `inputTokens` alone
            // produced wildly-over-100% values (e.g. 11857%) on the
            // cache-health card.
            let totalProcessed = inputTokens + cachedReadTokens + cacheCreateTokens
            guard totalProcessed > 0 else { return 0 }
            return Double(cachedReadTokens) / Double(totalProcessed)
        }
    }
    private var recent: [TurnRecord] = []
    private static let recentCap = 50

    private init() {}

    /// Called from `AssistantViewModel`'s `.usage` event handler.
    func record(provider: String, input: Int, output: Int, cachedRead: Int, cacheCreate: Int) {
        var next = totals
        next.inputTokens += input
        next.outputTokens += output
        next.cachedReadTokens += cachedRead
        next.cacheCreateTokens += cacheCreate
        next.turns += 1
        totals = next // single notification per record() call
        recent.append(TurnRecord(
            provider: provider,
            timestamp: Date(),
            inputTokens: input,
            outputTokens: output,
            cachedReadTokens: cachedRead,
            cacheCreateTokens: cacheCreate
        ))
        if recent.count > Self.recentCap {
            recent.removeFirst(recent.count - Self.recentCap)
        }
    }

    /// Cumulative cache hit ratio across all turns. Healthy target:
    /// > 0.75 once warmup turns have settled (per the research note's
    /// acceptance criteria). Lower means the cache prefix is changing
    /// per turn — usually a sign that dynamic content is leaking into
    /// the cacheable zone.
    ///
    /// Denominator is `(input + cache_read + cache_create)`
    /// (total prompt size), not `input` alone. `input` is the
    /// uncached-billed portion only (the streamers normalise every
    /// provider to that); the cached prefix lives in `cache_read` and
    /// just-cached bytes in `cache_create`. Dividing by
    /// `inputTokens` only produces 11857%-style nonsense.
    var cumulativeHitRatio: Double {
        let totalProcessed = totalInputTokens + totalCachedReadTokens + totalCacheCreateTokens
        guard totalProcessed > 0 else { return 0 }
        return Double(totalCachedReadTokens) / Double(totalProcessed)
    }

    /// Hit ratio over the last N recorded turns. Useful for catching
    /// regressions that don't show up in the cumulative number when
    /// most of the session was healthy.
    func recentHitRatio(turns: Int = 10) -> Double {
        let slice = recent.suffix(turns)
        let inputs = slice.reduce(0) { $0 + $1.inputTokens }
        let cached = slice.reduce(0) { $0 + $1.cachedReadTokens }
        let creates = slice.reduce(0) { $0 + $1.cacheCreateTokens }
        let totalProcessed = inputs + cached + creates
        guard totalProcessed > 0 else { return 0 }
        return Double(cached) / Double(totalProcessed)
    }

    /// Per-provider breakdown.
    func perProviderSummary() -> [(provider: String, turns: Int, hitRatio: Double)] {
        let grouped = Dictionary(grouping: recent, by: \.provider)
        return grouped.map { provider, turns in
            let inputs = turns.reduce(0) { $0 + $1.inputTokens }
            let cached = turns.reduce(0) { $0 + $1.cachedReadTokens }
            let creates = turns.reduce(0) { $0 + $1.cacheCreateTokens }
            let totalProcessed = inputs + cached + creates
            let hr = totalProcessed > 0 ? Double(cached) / Double(totalProcessed) : 0
            return (provider: provider, turns: turns.count, hitRatio: hr)
        }.sorted { $0.turns > $1.turns }
    }

    /// Reset all counters. Called by `DataPurgeService.purgeAllUserData()`.
    func reset() {
        totals = .init()
        recent.removeAll()
    }

    /// One-line debug summary for the runtime logger.
    var debugSummary: String {
        let pct = String(format: "%.0f%%", cumulativeHitRatio * 100)
        return "turns=\(totalTurns) inputs=\(totalInputTokens) cached=\(totalCachedReadTokens) (\(pct))"
    }
}
