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
    /// The clock (`nowSnapshot`) must not live inside the cached
    /// `systemPrompt`: that blows the cache
    /// prefix on every call (user's debug log: `cacheCreate=25814
    /// hit_ratio=0.00` repeated for every send). The composer
    /// splits its output around `cacheSplitMarker` — stable prefix
    /// before, variable suffix after. We carve them apart here and
    /// mark only the stable prefix as ephemeral.
    ///
    /// Anthropic's cache prefix runs tools → system → messages, so nothing
    /// in the system role can disturb the 1h tools cache, but every system
    /// block AFTER the stable breakpoint is part of the prefix for any later
    /// breakpoint (conversation history). The variable suffix is not static:
    /// the composer puts the clock (per minute), today's training load, the
    /// live-workout marker and pending hallucination corrections there, so
    /// it changes at least every minute and a history breakpoint behind it
    /// rarely hits.
    ///
    /// `contextRendered` is kept out of the system role for that reason:
    /// `spliceLiveState` moves it into the tail of the last user message as
    /// a `<live_state>…</live_state>` envelope the system prompt tells the
    /// model to read first. The variable suffix stays in the system role,
    /// uncached, because it carries system-level guidance (corrections,
    /// the live-workout marker) as well as data.
    static func cacheAwareSystemBlocks(_ systemPrompt: String) -> [RequestBody.SystemBlock] {
        let marker = AssistantSystemPrompt.Composed.cacheSplitMarker
        let parts = systemPrompt.components(separatedBy: marker)
        let stable = parts.first ?? systemPrompt
        let variable = parts.count > 1 ? parts.dropFirst().joined(separator: marker) : ""
        return makeSystemBlocks(stable: stable, variable: variable)
    }

    /// Cache the tool catalog with the 1-hour
    /// TTL beta. The catalog is the compact tool schema (read tools
    /// plus the allowed action tools); it changes only when the
    /// registry is rebuilt, so it is essentially stable for the
    /// lifetime of the process. 1h cache writes cost 2× the
    /// base input rate but amortize across all subsequent reads
    /// for the next 60 minutes — for a typical user with multi-
    /// turn coaching sessions, one write covers dozens of reads
    /// at ~10% input cost.
    ///
    /// Append Anthropic's server-side
    /// `web_search_20250305` tool when web search is enabled.
    /// No Tavily key needed; Anthropic resolves the search on
    /// its end and returns results in the response stream. The
    /// server tool is always named `web_search`, so the app's own
    /// Tavily-based `web_search` tool is left out of the request
    /// while it is on (Anthropic rejects duplicate tool names with
    /// HTTP 400); other providers still get the Tavily tool. Both
    /// are gated by the same `enableWebSearch` toggle. Server-side
    /// searches are capped per turn — same cost philosophy as the
    /// action tool's once-per-turn rule, since Anthropic bills them
    /// as a separate line item — and skip the same sites Tavily's
    /// searches exclude.
    static func toolDeclarations(for tools: [ToolSpec]) -> [RequestBody.ToolDecl]? {
        let webSearchOn = AppDependencies.current.app.settingsManager.settingsSnapshot.enableWebSearch
        guard !tools.isEmpty || webSearchOn else { return nil }
        let customTools = webSearchOn ? tools.filter { $0.name != serverWebSearchToolName } : tools
        var combined: [RequestBody.ToolDecl] = customTools.map { tool in
            .custom(name: tool.name, description: tool.description, schema: tool.inputSchema, cache: nil)
        }
        if webSearchOn {
            combined.append(.serverWebSearch(maxUses: 3, blockedDomains: WebSearchService.excludeDomains, cache: nil))
        }
        guard let last = combined.last else { return nil }
        combined[combined.count - 1] = cacheTagged(last)
        return combined
    }

    /// The name Anthropic gives its server-side web search tool.
    static let serverWebSearchToolName = "web_search"

    /// Cache breakpoint goes on the LAST element so everything before it
    /// caches as one prefix. Server-tools encode just as cleanly as customs.
    static func cacheTagged(_ decl: RequestBody.ToolDecl) -> RequestBody.ToolDecl {
        let cache = RequestBody.SystemBlock.CacheControl(type: "ephemeral", ttl: "1h")
        switch decl {
        case let .custom(name, description, schema, _):
            return .custom(name: name, description: description, schema: schema, cache: cache)
        case let .serverWebSearch(maxUses, blockedDomains, _):
            return .serverWebSearch(maxUses: maxUses, blockedDomains: blockedDomains, cache: cache)
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
