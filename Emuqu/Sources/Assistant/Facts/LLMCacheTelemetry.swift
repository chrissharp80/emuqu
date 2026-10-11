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
    var totalCachedReadTokens: Int { totals.cachedReadTokens }
    var totalCacheCreateTokens: Int { totals.cacheCreateTokens }
    var totalTurns: Int { totals.turns }

    /// Last 50 recorded requests (rolling) for the recent-history readout.
    private struct TurnRecord {
        let provider: String
        let timestamp: Date
        let inputTokens: Int
        let outputTokens: Int
        let cachedReadTokens: Int
        let cacheCreateTokens: Int
    }
    private var recent: [TurnRecord] = []
    private static let recentCap = 50

    private init() {}

    /// Called from `AssistantViewModel`'s `.usage` event handler, once per
    /// provider REQUEST: a turn with tool rounds sends one request per round
    /// and is recorded once per round, so `totalTurns` and the per-provider
    /// counts are request counts.
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
        Self.hitRatio(input: totalInputTokens, cachedRead: totalCachedReadTokens, cacheCreate: totalCacheCreateTokens)
    }

    /// Hit rate = cached / total prompt tokens processed. The one copy of
    /// the formula; every reader of cache health uses it.
    ///
    /// `input` is ONLY the new uncached portion billed at full rate, separate
    /// from `cache_read` (cached prefix) and `cache_creation` (just-cached).
    /// Anthropic reports it that way; OpenAI, DeepSeek and Gemini count
    /// cached tokens inside their prompt total, and their streamers subtract
    /// them before emitting `.usage`. So the total prompt size = input +
    /// cache_read + cache_create. Dividing by `input` alone produced
    /// wildly-over-100% values (e.g. 11857%) on the cache-health card.
    nonisolated static func hitRatio(input: Int, cachedRead: Int, cacheCreate: Int) -> Double {
        let totalProcessed = input + cachedRead + cacheCreate
        guard totalProcessed > 0 else { return 0 }
        return Double(cachedRead) / Double(totalProcessed)
    }

    /// Hit ratio over the last N recorded turns. Useful for catching
    /// regressions that don't show up in the cumulative number when
    /// most of the session was healthy.
    func recentHitRatio(turns: Int = 10) -> Double {
        Self.hitRatio(of: recent.suffix(turns))
    }

    /// Per-provider breakdown.
    func perProviderSummary() -> [(provider: String, turns: Int, hitRatio: Double)] {
        let grouped = Dictionary(grouping: recent, by: \.provider)
        return grouped.map { provider, turns in
            (provider: provider, turns: turns.count, hitRatio: Self.hitRatio(of: turns))
        }.sorted { $0.turns > $1.turns }
    }

    /// `hitRatio` over a run of records.
    private static func hitRatio(of records: some Collection<TurnRecord>) -> Double {
        hitRatio(
            input: records.reduce(0) { $0 + $1.inputTokens },
            cachedRead: records.reduce(0) { $0 + $1.cachedReadTokens },
            cacheCreate: records.reduce(0) { $0 + $1.cacheCreateTokens }
        )
    }

    /// Reset all counters. Called by `DataPurgeService.purgeAllUserData()`.
    func reset() {
        totals = .init()
        recent.removeAll()
    }
}
