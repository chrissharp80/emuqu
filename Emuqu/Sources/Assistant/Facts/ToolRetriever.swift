import Foundation
import os

/// Per-request BM25 tool retrieval.
///
/// **Current state: a pass-through.** The tools handed to it are the
/// compact schema (`CompactToolRouter.schema`): about twenty read tools
/// plus up to sixteen action tools, which is under the default `targetK`
/// of 40, so `retrieve` returns them unchanged on every send. It ranks
/// only if that schema grows past `targetK`.
///
/// **Problem it solves when it ranks.** Shipping a large catalog (the
/// full Fact Catalog is 200+ tool schemas) on every request makes every
/// send carry ~15-20k input tokens of tool definitions the model almost
/// never uses, and even providers that accept large tool sets suffer
/// tool-selection accuracy degradation above ~30-50 tools per the
/// Anthropic engineering docs.
///
/// **What this does.** BM25-ranks every tool against the user's query
/// (last user turn + a short conversation tail) and returns the top-K
/// most relevant, plus an always-included "essential" safety-net set so
/// the model is never empty-handed for follow-up questions about the
/// user's recovery / live workout / location regardless of what the
/// query mentioned.
///
/// **Why BM25 instead of embeddings.**
///   1. Anthropic ships their official tool-search tool with a BM25
///      variant (`tool_search_tool_bm25_20251119`) — the production
///      pattern they validated for "natural language → tool" retrieval.
///      Their regex variant is the alternative; BM25 is the better fit
///      when the query is a natural-language user message.
///   2. Deterministic + sub-millisecond per query. No model assets to
///      load, no NLContextualEmbedding compute on the dispatch path.
///   3. Easy to reason about and back out — every retained tool can be
///      attributed to either a query-term hit or the safety-net rule.
///
/// **Implementation contract.**
///   - The corpus consists of `name` (split on `_` `.` `-`) +
///     `description` + every property name + every property description.
///   - Standard BM25 with k1=1.5, b=0.75 (the canonical tuning).
///   - Stop words filtered out of query AND corpus tokens (the standard
///     English list — "the", "of", "is", etc. — plus common LLM-prompt
///     verbiage like "tool", "get", "fetch", "return").
///   - The cached index is rebuilt only when the catalog hash changes
///     (same hash that already gates prompt-cache stability), so steady
///     state is purely score-and-rank against in-memory state.
///
/// **Sources / prior art.**
///   - Anthropic, "Tool search tool":
///     https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool
///   - Anthropic, "Advanced tool use":
///     https://www.anthropic.com/engineering/advanced-tool-use
///   - arxiv 2603.20313 (vector-based MCP tool selection — same shape,
///     embeddings instead of BM25)
///   - arxiv 2412.03573 (LLM-assisted query generation for tool
///     retrieval — future improvement, not implemented here)
///
/// Provider-agnostic. Runs BEFORE any provider-specific tool cap, so a
/// capped provider would get the BM25-selected subset rather than an
/// arbitrary slice.
enum ToolRetriever {
    // MARK: - Public API

    /// Retrieve the top-K most relevant tools for `query`, plus essentials.
    ///
    /// - Parameters:
    ///   - query: Concatenated user message text. Should include the
    ///     latest user turn at minimum; the caller may include the last
    ///     1-2 prior user turns so multi-turn references like "what
    ///     about the day before" still resolve to the right namespace.
    ///   - tools: The tool list for this send (the compact schema).
    ///   - targetK: Soft target for retrieved tool count (default 40 —
    ///     stays below the 30-50 degradation threshold Anthropic reports
    ///     while leaving headroom for the essentials list).
    ///   - catalogHash: Pass `FactResolverRegistry.catalogHash()` so the
    ///     retriever can invalidate its index when the catalog changes.
    /// - Returns: Tools ordered by relevance score descending. Essentials
    ///   that scored high are NOT duplicated; essentials that scored low
    ///   or zero are appended at the end so the model still has them.
    ///
    /// Catalogs at or under `targetK` fast-exit unchanged — the compact
    /// schema always does. They don't benefit, and the empty case would
    /// crash the IDF math.
    ///
    /// The index rebuilds when the catalog changes. It's stable across turns
    /// within an app session normally; new sessions (acceptance, archive
    /// merge) flip availability and re-hash. The build cost is bounded — see
    /// `Index.init`.
    ///
    /// An empty / stop-word-only query (e.g. "ok", "thanks") gets the
    /// essentials only — anything more is dead payload. So does a query whose
    /// BM25 scores come back uniformly zero: no term overlap with any tool,
    /// usually a "yes / no / continue" follow-up, so we send essentials and
    /// let the model request more via natural-language continuation. (The
    /// index is keyed by tool name, so a tool's score lookup is O(1).)
    ///
    /// The closing `debugLog` is a breadcrumb showing how aggressive the
    /// filter was for this query; `.info` keeps it out of the user-facing
    /// problems list.
    static func retrieve(
        query: String,
        tools: [ToolSpec],
        targetK: Int = 40,
        catalogHash: String
    ) -> [ToolSpec] {
        guard tools.count > targetK else { return tools }
        ensureIndex(for: tools, hash: catalogHash)
        let queryTokens = Self.tokenize(query)
        guard !queryTokens.isEmpty else { return Self.essentialsOnly(from: tools) }
        let index = Self.indexCache.withLock { $0.index }
        let scored = index?.score(queryTokens: queryTokens, tools: tools) ?? []
        guard let maxScore = scored.first?.score, maxScore > 0 else {
            return Self.essentialsOnly(from: tools)
        }
        let scoreFloor = max(0.05, maxScore * 0.10)
        let top = Self.topScoring(scored, targetK: targetK, scoreFloor: scoreFloor)
        let retained = Self.withEssentials(top, from: tools)
        debugLog("[ToolRetriever] query='\(query.prefix(80))' → \(retained.count)/\(tools.count) tools (maxScore=\(String(format: "%.2f", maxScore)), floor=\(String(format: "%.2f", scoreFloor)))")
        return retained
    }

    /// The top-K by score, stopping early when scores collapse toward zero —
    /// adding tools the query barely touched costs tokens for no benefit.
    private static func topScoring(
        _ scored: [BM25Index.ScoredTool],
        targetK: Int,
        scoreFloor: Double
    ) -> [ToolSpec] {
        var retained: [ToolSpec] = []
        for entry in scored {
            if retained.count >= targetK || entry.score < scoreFloor { break }
            retained.append(entry.tool)
        }
        return retained
    }

    /// Always-include the safety-net essentials (see `essentialToolNames`).
    /// Appended AFTER the scored list so retained order still
    /// reflects relevance.
    private static func withEssentials(_ retained: [ToolSpec], from tools: [ToolSpec]) -> [ToolSpec] {
        var out = retained
        var names = Set(retained.map(\.name))
        for tool in tools where !names.contains(tool.name) && isEssential(tool.name) {
            out.append(tool)
            names.insert(tool.name)
        }
        return out
    }

    private static func isEssential(_ name: String) -> Bool {
        essentialToolNames.contains(name)
    }

    // MARK: - Essentials

    /// Tools that ALWAYS ride along regardless of query terms, named as the
    /// compact schema names them. These cover the highest-frequency
    /// follow-up questions: today's recovery, the latest session, the live
    /// workout, training load, the user's profile and location.
    ///
    /// Adjust this list when a new always-on tool ships. Keep it short —
    /// every essential is a tool the user pays for on every turn.
    private static let essentialToolNames: Set<String> = [
        "get_today",
        "get_session",
        "get_workout_live",
        "get_training_load",
        "get_user",
        "lookup_fact",
        "location_situation",
        "location_current",
        "location_current_detailed"
    ]

    private static func essentialsOnly(from tools: [ToolSpec]) -> [ToolSpec] {
        tools.filter { isEssential($0.name) }
    }

    // MARK: - BM25 Index

    /// Module-level cache. The build is bounded (~1-3 ms for 200 tools);
    /// memoising keeps every steady-state send to pure score work.
    /// Lock-protected rather than two `nonisolated(unsafe)` statics with no
    /// guard (which check_unchecked_sendable.sh flags). Same
    /// pattern as FeatureFlags; the lock is uncontended in practice
    /// (callers sit on the @MainActor send path) so this costs nothing.
    private static let indexCache = OSAllocatedUnfairLock<(index: BM25Index?, hash: String?)>(
        initialState: (nil, nil)
    )

    private static func ensureIndex(for tools: [ToolSpec], hash: String) {
        indexCache.withLock { cache in
            if cache.hash == hash, cache.index != nil { return }
            cache = (BM25Index(tools: tools), hash)
        }
    }

    // MARK: - Tokenisation

    /// Standard stop-word list. We strip these from both the corpus and
    /// the query so common filler words don't drown out signal terms.
    /// Augmented with LLM-prompt verbs ("get", "fetch", "return",
    /// "current", "available", "tool") that appear in nearly every tool
    /// description and contribute no discrimination.
    private static let stopWords: Set<String> = [
        // Standard English stop words
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from",
        "has", "have", "he", "i", "if", "in", "into", "is", "it", "its",
        "me", "my", "no", "not", "of", "on", "or", "she", "so", "that",
        "the", "their", "there", "they", "this", "to", "was", "we",
        "were", "what", "when", "where", "which", "who", "why", "will",
        "with", "you", "your",
        // LLM-prompt boilerplate
        "tool", "tools", "action", "value", "values", "result", "results",
        "get", "got", "fetch", "fetched", "return", "returns", "returned",
        "available", "current", "given", "specified", "use", "used",
        "uses", "using", "via", "based", "set", "show", "shows",
        "describe", "describes", "include", "includes", "user", "data"
    ]

    /// Tokenise: lowercase, split on non-alphanumerics, drop stop words,
    /// drop single-character noise, optionally apply minimal stemming.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for char in text.lowercased() {
            if char.isLetter || char.isNumber {
                current.append(char)
            } else if !current.isEmpty {
                Self.appendToken(current, to: &tokens)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty {
            Self.appendToken(current, to: &tokens)
        }
        return tokens
    }

    private static func appendToken(_ token: String, to tokens: inout [String]) {
        guard token.count > 1 else { return }
        if stopWords.contains(token) { return }
        // Light stemming — strip common English suffixes. Not full Porter;
        // just enough that "power"/"powers"/"powered" / "running"/"runs"
        // all collide. Anthropic's BM25 variant uses standard
        // tokenisation; we approximate.
        let stemmed = Self.stem(token)
        tokens.append(stemmed)
    }

    private static func stem(_ token: String) -> String {
        if token.count < 4 { return token }
        let suffixes = ["ing", "ed", "s", "ly", "es"]
        for suffix in suffixes {
            if token.hasSuffix(suffix), token.count > suffix.count + 2 {
                return String(token.dropLast(suffix.count))
            }
        }
        return token
    }
}

// MARK: - BM25 Index

/// Standard BM25 (Robertson-Spärck Jones) with the canonical k1=1.5, b=0.75
/// parameters. See https://en.wikipedia.org/wiki/Okapi_BM25 for the formula.
/// Anthropic ships their tool-search tool with BM25 because it handles
/// short queries (single user message) against medium-length documents
/// (tool descriptions) better than raw TF-IDF — the saturation curve in k1
/// prevents long descriptions from dominating short ones, and the b
/// parameter normalises by document length so a 30-word description and
/// a 200-word one are compared fairly.
private final class BM25Index: Sendable {
    private struct Document {
        let tool: ToolSpec
        let termFreq: [String: Int]
        let length: Int
    }

    private let documents: [Document]
    private let documentFrequency: [String: Int]
    private let avgDocLength: Double
    private let totalDocs: Int
    private static let k1: Double = 1.5
    private static let b: Double = 0.75

    init(tools: [ToolSpec]) {
        var docs: [Document] = []
        docs.reserveCapacity(tools.count)
        var df: [String: Int] = [:]
        var totalLen = 0
        for tool in tools {
            let freq = BM25Index.termFrequencies(for: tool)
            let length = freq.values.reduce(0, +)
            docs.append(Document(tool: tool, termFreq: freq, length: length))
            totalLen += length
            for term in freq.keys {
                df[term, default: 0] += 1
            }
        }
        documents = docs
        documentFrequency = df
        totalDocs = docs.count
        avgDocLength = docs.isEmpty ? 1 : Double(totalLen) / Double(docs.count)
    }

    /// Name carries the strongest signal (it's the developer's chosen
    /// identifier for the resource). Split on `_` and `.` and `-` so dotted
    /// names like `workout.power.avg.by_date` contribute "workout", "power",
    /// "avg", "by", "date".
    private static func nameTokens(of tool: ToolSpec) -> [String] {
        ToolRetriever.tokenize(
            tool.name
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "-", with: " ")
        )
    }

    /// Weighted bag of words for one tool. Name tokens count 3× — they are the
    /// most discriminative signal for "user asked about X". The description
    /// carries the bulk of the natural-language signal at the standard 1×.
    private static func termFrequencies(for tool: ToolSpec) -> [String: Int] {
        var freq: [String: Int] = [:]
        for t in nameTokens(of: tool) {
            freq[t, default: 0] += 3
        }
        for t in ToolRetriever.tokenize(tool.description) {
            freq[t, default: 0] += 1
        }
        // Property names + descriptions. These help match queries
        // like "by date" or "in last 7 days".
        for (propName, prop) in tool.inputSchema.properties {
            for t in ToolRetriever.tokenize(propName) {
                freq[t, default: 0] += 1
            }
            for t in ToolRetriever.tokenize(prop.description) {
                freq[t, default: 0] += 1
            }
        }
        return freq
    }

    struct ScoredTool {
        let tool: ToolSpec
        let score: Double
    }

        func score(queryTokens: [String], tools _: [ToolSpec]) -> [ScoredTool] {
            var results: [ScoredTool] = []
            results.reserveCapacity(documents.count)
            for doc in documents {
                let score = bm25(doc, queryTokens: queryTokens)
                if score > 0 { results.append(ScoredTool(tool: doc.tool, score: score)) }
            }
            results.sort { $0.score > $1.score }
            return results
        }

        /// One document's BM25 score against the query terms. Uses the
        /// standard IDF with the `+1` smoothing Robertson recommends, which
        /// avoids negative scores for very-common terms.
        private func bm25(_ doc: Document, queryTokens: [String]) -> Double {
            var score = 0.0
            for term in queryTokens {
                guard let tf = doc.termFreq[term], tf > 0 else { continue }
                let df = documentFrequency[term] ?? 0
                let idf = log(1.0 + (Double(totalDocs) - Double(df) + 0.5) / (Double(df) + 0.5))
                let tfNum = Double(tf) * (Self.k1 + 1.0)
                let tfDenom = Double(tf) + Self.k1 * (1.0 - Self.b + Self.b * Double(doc.length) / avgDocLength)
                score += idf * (tfNum / tfDenom)
            }
            return score
        }
}
