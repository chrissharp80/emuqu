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
        let split = ProviderHTTP.splitOnCacheMarker(systemPrompt)
        return makeSystemBlocks(stable: split.stable, variable: split.variable)
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
    ///
    /// A send with no tools (the summarizer, fact extraction, a voice
    /// interjection) gets no declarations at all, the server search
    /// included: those sends are not meant to search, and a billed search
    /// would also run into their short collect timeouts.
    static func toolDeclarations(for tools: [ToolSpec]) -> [RequestBody.ToolDecl]? {
        guard !tools.isEmpty else { return nil }
        let webSearchOn = AppDependencies.current.app.settingsManager.settingsSnapshot.enableWebSearch
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
    /// We track open blocks by index and emit .toolUse on stop. A stream that
    /// ends before `message_stop` was cut: it is reported as a dropped
    /// connection, not delivered as a complete reply. A cancelled task whose
    /// sequence ended cleanly throws `CancellationError` first, so Stop
    /// reads as cancellation.
    ///
    /// A reply that fails after `message_start` still records the usage that
    /// event carried, so tokens billed for a reply that never completed are
    /// not lost from the telemetry: `flushUsage` runs on every exit, and
    /// records nothing again once `message_delta` or `message_stop` has.
    ///
    /// Only `data:` payloads are parsed; comment lines (`:` keep-alives) are
    /// skipped. Takes the line sequence rather than the URL session's bytes
    /// so tests can feed it a reply.
    ///
    /// Returns the reply's content blocks when it stopped with `pause_turn`
    /// (no `.done` was yielded; `continuingPausedTurns` sends it back), nil
    /// when it completed.
    @discardableResult
    static func consumeSSE<Lines: AsyncSequence>(
        _ lines: Lines,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws -> PausedTurn? where Lines.Element == String {
        var lastEventName: String?
        var state = StreamState()
        defer { flushUsage(&state, final: nil, to: continuation) }
        for try await line in lines {
            try Task.checkCancellation()
            if line.isEmpty || line.hasPrefix("event:") {
                // A blank line ends an event; an event: line names the next one.
                lastEventName = line.isEmpty ? nil : line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, let data = payload.data(using: .utf8) else { continue }
            try handle(eventName: lastEventName, data: data, state: &state, continuation: continuation)
        }
        try Task.checkCancellation()
        guard state.messageStopped else { throw URLError(.networkConnectionLost) }
        return state.paused ? PausedTurn(content: state.content.orderedBlocks) : nil
    }
}

// MARK: - Paused turns
//
// With the server-side web search on, Anthropic runs the search loop on its
// side; a turn that reaches that loop's iteration limit stops with
// `pause_turn`. The reply is not finished: the client sends the same request
// again with the reply so far appended as the assistant's message (its raw
// blocks, `server_tool_use` and `web_search_tool_result` included, and no
// extra user message), and the model carries on from there.

extension AnthropicProvider {
    /// How many times a paused reply is sent back before it is ended with
    /// the truncation marker. Each continuation is a billed request that
    /// may run more searches.
    static let maxPauseContinuations = 3

    /// The content blocks of a reply that stopped with `pause_turn`.
    struct PausedTurn {
        let content: [[String: Any]]
    }

    /// Runs `body` through `perform` and, while the reply pauses, sends it
    /// again with everything the model has produced so far appended as one
    /// assistant message, so the chat layer sees one continuous reply. After
    /// `maxPauseContinuations` continuations a reply that still pauses ends
    /// with "…" and `.done`, as a token-cap stop does. `perform` is the
    /// network request in the app and a canned reply in tests.
    static func continuingPausedTurns(
        _ body: RequestBody,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation,
        perform: (RequestBody) async throws -> PausedTurn?
    ) async throws {
        var pausedContent: [[String: Any]] = []
        var request = body
        for _ in 0 ... maxPauseContinuations {
            guard let paused = try await perform(request) else { return }
            pausedContent.append(contentsOf: paused.content)
            request = body.resending(pausedContent: pausedContent)
        }
        debugLog("[Anthropic] reply still paused after \(maxPauseContinuations) continuations", level: .warning)
        continuation.yield(.textDelta("…"))
        continuation.yield(.done)
    }

    /// The raw content blocks of one reply, rebuilt from its stream events
    /// by index: each block as `content_block_start` opened it, with text,
    /// citations and partial JSON input added from the deltas.
    struct ReplyContent {
        private var byIndex: [Int: [String: Any]] = [:]
        private var partialInput: [Int: String] = [:]

        /// The blocks in order. Empty text blocks are left out: the API
        /// rejects them.
        var orderedBlocks: [[String: Any]] {
            byIndex.sorted { $0.key < $1.key }.map { $0.value }.filter { block in
                !((block["type"] as? String) == "text" && ((block["text"] as? String) ?? "").isEmpty)
            }
        }

        /// One stream event: the content-block events update the blocks,
        /// every other event is ignored.
        mutating func record(_ json: [String: Any]) {
            switch json["type"] as? String {
            case "content_block_start": start(json)
            case "content_block_delta": apply(json)
            case "content_block_stop": stop(json)
            default: break
            }
        }

        /// `content_block_start`: the block as first sent.
        private mutating func start(_ json: [String: Any]) {
            guard let index = json["index"] as? Int,
                  let block = json["content_block"] as? [String: Any] else { return }
            byIndex[index] = block
        }

        /// `content_block_delta`: text and thinking are appended, a citation
        /// joins the block's citations, and partial JSON input is held until
        /// the block stops.
        private mutating func apply(_ json: [String: Any]) {
            guard let index = json["index"] as? Int, byIndex[index] != nil,
                  let delta = json["delta"] as? [String: Any] else { return }
            switch delta["type"] as? String {
            case "text_delta": append(delta["text"], to: "text", at: index)
            case "thinking_delta": append(delta["thinking"], to: "thinking", at: index)
            case "signature_delta": append(delta["signature"], to: "signature", at: index)
            case "input_json_delta": partialInput[index, default: ""] += (delta["partial_json"] as? String) ?? ""
            case "citations_delta":
                guard let citation = delta["citation"] else { return }
                byIndex[index]?["citations"] = ((byIndex[index]?["citations"] as? [Any]) ?? []) + [citation]
            default: break
            }
        }

        /// `content_block_stop`: held partial JSON becomes the block's
        /// `input` object; input that does not parse leaves it as sent.
        private mutating func stop(_ json: [String: Any]) {
            guard let index = json["index"] as? Int,
                  let raw = partialInput.removeValue(forKey: index), !raw.isEmpty,
                  let input = attempt("anthropic.pausedInput.parse", { try JSONSerialization.jsonObject(with: Data(raw.utf8)) }),
                  input is [String: Any] else { return }
            byIndex[index]?["input"] = input
        }

        private mutating func append(_ value: Any?, to field: String, at index: Int) {
            guard let piece = value as? String else { return }
            byIndex[index]?[field] = ((byIndex[index]?[field] as? String) ?? "") + piece
        }
    }
}

extension AnthropicProvider.RequestBody {
    /// This request again with `pausedContent` appended as the assistant's
    /// reply so far, for the model to continue a paused turn.
    func resending(pausedContent: [[String: Any]]) -> AnthropicProvider.RequestBody {
        AnthropicProvider.RequestBody(
            model: model, max_tokens: max_tokens, system: system,
            messages: messages + [Message(role: "assistant", content: .blocks(pausedContent.map(ContentBlock.raw)))],
            stream: stream, tools: tools
        )
    }
}
