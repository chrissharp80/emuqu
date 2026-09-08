import Foundation

// MARK: - Request assembly + SSE
//
// The prompt-cache split, the tool declarations, the URLRequest, and the
// server-sent-events reader; everything here is mechanical shaping of what
// `stream` already decided.

extension AnthropicProvider {
    /// Anthropic prompt caching: mark the STABLE prefix as
    /// `ephemeral` so Anthropic caches it for ~5 minutes. Subsequent
    /// sends within that window pay ~10% of normal input-token cost
    /// for the cached portion.
    ///
    /// The per-second `nowSnapshot` must not live inside the cached
    /// `systemPrompt`: that blows the cache
    /// prefix on every call (user's debug log: `cacheCreate=25814
    /// hit_ratio=0.00` repeated for every send). The composer
    /// splits its output around `cacheSplitMarker` — stable prefix
    /// before, variable suffix after. We carve them apart here and
    /// mark only the stable prefix as ephemeral. `contextRendered`
    /// (also variable per-send when present) follows uncached.
    ///
    /// `contextRendered` and `variableSystem` are NOT appended to the
    /// system role with `cache_control: nil`. Per Anthropic's caching
    /// semantics, blocks AFTER a breakpoint are NOT cached
    /// independently, but they ARE part of the cache fingerprint
    /// for the NEXT breakpoint (in our case, the 1h tools cache).
    /// Result: every change to the per-second timestamp inside
    /// contextRendered would invalidate the 1h tools cache for one
    /// turn, even though tools didn't change.
    ///
    /// The research-recommended fix is the ProjectDiscovery
    /// 7%→74% cache-hit-rate trick: move the dynamic block OUT
    /// of the system role entirely and into the user-message
    /// tail (see `spliceLiveState`). The system role + tools become
    /// fully stable; the user message carries the per-turn live state
    /// in a structured `<live_state>…</live_state>` envelope the
    /// model is instructed (via the system prompt) to read first.
    ///
    /// `variableSystem` keeps its system-role placement because
    /// the existing splitter is conservative — when the composer
    /// emits a non-empty variable suffix it's typically a
    /// configuration override that the model needs as
    /// system-level guidance, not per-turn live data. Live data
    /// should always be authored into `contextRendered`.
    static func cacheAwareSystemBlocks(_ systemPrompt: String) -> [RequestBody.SystemBlock] {
        let marker = AssistantSystemPrompt.Composed.cacheSplitMarker
        let parts = systemPrompt.components(separatedBy: marker)
        let stable = parts.first ?? systemPrompt
        let variable = parts.count > 1 ? parts.dropFirst().joined(separator: marker) : ""
        return makeSystemBlocks(stable: stable, variable: variable)
    }

    /// Cache the tool catalog with the 1-hour
    /// TTL beta. The catalog is ~30K tokens of fact-resolver
    /// descriptions + JSON schemas; the registry is rebuilt only
    /// at app launch, so the catalog is essentially stable for
    /// the lifetime of the process. 1h cache writes cost 2× the
    /// base input rate but amortize across all subsequent reads
    /// for the next 60 minutes — for a typical user with multi-
    /// turn coaching sessions, one write covers dozens of reads
    /// at ~10% input cost.
    ///
    /// Append Anthropic's server-side
    /// `web_search_20250305` tool when web search is enabled.
    /// No Tavily key needed; Anthropic resolves the search on
    /// its end and returns results in the response stream. The
    /// Tavily-based `web.search` action stays available too as
    /// a fallback for non-Anthropic providers; both are gated
    /// by the same `enableWebSearch` toggle. Server-side searches
    /// are capped per turn — same cost philosophy as the action
    /// tool's once-per-turn rule, since Anthropic bills them as a
    /// separate line item.
    static func toolDeclarations(for tools: [ToolSpec]) -> [RequestBody.ToolDecl]? {
        let webSearchOn = AppDependencies.current.app.settingsManager.settingsSnapshot.enableWebSearch
        guard !tools.isEmpty || webSearchOn else { return nil }
        var combined: [RequestBody.ToolDecl] = tools.map { tool in
            .custom(name: tool.name, description: tool.description, schema: tool.inputSchema, cache: nil)
        }
        if webSearchOn { combined.append(.serverWebSearch(maxUses: 3, cache: nil)) }
        guard let last = combined.last else { return nil }
        combined[combined.count - 1] = cacheTagged(last)
        return combined
    }

    /// Cache breakpoint goes on the LAST element so everything before it
    /// caches as one prefix. Server-tools encode just as cleanly as customs.
    static func cacheTagged(_ decl: RequestBody.ToolDecl) -> RequestBody.ToolDecl {
        let cache = RequestBody.SystemBlock.CacheControl(type: "ephemeral", ttl: "1h")
        switch decl {
        case let .custom(name, description, schema, _):
            return .custom(name: name, description: description, schema: schema, cache: cache)
        case let .serverWebSearch(maxUses, _):
            return .serverWebSearch(maxUses: maxUses, cache: cache)
        }
    }

    /// The `anthropic-beta` header opts into the 1-hour
    /// cache TTL. The tool catalog's `cache_control` sets `ttl: "1h"`; without
    /// this header Anthropic falls back to the default 5-minute TTL, which
    /// still works but loses the longer amortization window.
    ///
    /// `.sortedKeys` is required for cache-stable payload serialisation — any
    /// non-determinism here blows Anthropic's prompt cache and every turn pays
    /// full input-token inference cost.
    static func makeRequest(url: URL, apiKey: String, body: RequestBody) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("extended-cache-ttl-2025-04-11", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// SSE parsing — anthropic emits "event: <type>" then "data: <json>" pairs.
    /// Tool-use blocks arrive as:
    ///   content_block_start { index, content_block: { type:"tool_use", id, name }}
    ///   content_block_delta { index, delta: { type:"input_json_delta", partial_json } } x N
    ///   content_block_stop { index }
    /// We track open blocks by index and emit .toolUse on stop.
    static func consumeSSE(
        _ bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws {
        var lastEventName: String?
        var openToolUses: [Int: PendingToolUse] = [:]
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.isEmpty {
                lastEventName = nil
                continue
            }
            if line.hasPrefix("event:") {
                lastEventName = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, let data = payload.data(using: .utf8) else { continue }
            try handle(eventName: lastEventName, data: data, openToolUses: &openToolUses, continuation: continuation)
        }
    }
}
