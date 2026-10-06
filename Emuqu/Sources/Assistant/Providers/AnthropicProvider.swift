import Foundation

/// Streams responses from Anthropic's Messages API (Claude).
/// https://docs.claude.com/en/api/messages-streaming
final class AnthropicProvider: AIProvider, Sendable {
    /// Dedicated session matching the one
    /// `OpenAICompatibleStreamer` uses, rather than
    /// `URLSession.shared`, which lacks `waitsForConnectivity` — a single
    /// tower handoff during a walk would fail the request immediately and
    /// surface as "Anthropic dropped" to the user. With the configured
    /// session the request is held until connectivity returns, up to the
    /// resource timeout. Same `httpMaximumConnectionsPerHost = 4` cap
    /// and 30 s request / 180 s resource timeouts so behaviour matches
    /// the OpenAI-family providers.
    static let streamSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        config.allowsCellularAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    // MARK: - Static catalog

    /// Checked against platform.claude.com/docs/en/about-claude/models and
    /// /model-deprecations. `ProviderModelCatalogTests` pins this list.
    ///
    /// Every Claude API ID is a pinned snapshot. All three are Active and
    /// none is deprecated; Anthropic gives at least 60 days' notice before
    /// it retires a model, and Haiku 4.5 retires no sooner than 15 October 2026.
    /// Sonnet 5.5 and Opus 5.5 are not listed: they always think,
    /// and a tool round on them must send the turn's thinking blocks back,
    /// which `ToolExchange` does not carry.
    ///
    /// Prices per million tokens: Haiku 4.5 $1 / $5, Sonnet 4.6 $3 / $15,
    /// Opus 4.7 $5 / $25. Context window: Haiku 4.5 200k; Sonnet 4.6 and
    /// Opus 4.7 1M.
    static let models: [ModelOption] = [
        ModelOption(
            providerID: .anthropic,
            apiID: "claude-haiku-4-5-20251001",
            displayName: "Haiku 4.5",
            blurb: "Fast & cheap",
            contextWindow: 200_000,
            inputPricePerMTok: 1.0,
            outputPricePerMTok: 5.0,
            isDefault: false
        ),
        ModelOption(
            providerID: .anthropic,
            apiID: "claude-sonnet-4-6",
            displayName: "Sonnet 4.6",
            blurb: "Balanced — recommended",
            contextWindow: 1_000_000,
            inputPricePerMTok: 3.0,
            outputPricePerMTok: 15.0,
            isDefault: true
        ),
        ModelOption(
            providerID: .anthropic,
            apiID: "claude-opus-4-7",
            displayName: "Opus 4.7",
            blurb: "Deepest reasoning",
            contextWindow: 1_000_000,
            inputPricePerMTok: 5.0,
            outputPricePerMTok: 25.0,
            isDefault: false
        )
    ]

    // MARK: - AIProvider conformance

    let id: ProviderID = .anthropic
    var availableModels: [ModelOption] {
        Self.models
    }

    var requiresKey: Bool {
        true
    }

    var isAvailable: Bool {
        AppDependencies.current.providers.apiKeyStore.hasKey(for: .anthropic)
    }

    func send(
        messages: [ChatTurn],
        model: ModelOption,
        contextRendered: String,
        systemPrompt: String,
        tools: [ToolSpec],
        toolRounds: [[ToolExchange]]
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        ProviderStream.make { continuation in
            try await self.stream(
                messages: messages, model: model, contextRendered: contextRendered,
                systemPrompt: systemPrompt, tools: tools, toolRounds: toolRounds,
                continuation: continuation
            )
        }
    }

    // MARK: - Private

    struct RequestBody: Encodable {
        /// A message whose content can be either a plain string (the simple
        /// user/assistant turns) OR an array of content blocks (needed when
        /// we're continuing after a tool_use round — assistant must carry
        /// the `tool_use` block verbatim and the next user message carries
        /// the matching `tool_result`). Encoded polymorphically to match
        /// Anthropic's wire format.
        ///
        /// The `cachedBlocks` variant exists for the
        /// conversation-history cache breakpoint. When we want to mark
        /// the tail of a message as a cache point, we send it as
        /// cachedBlocks so the encoder writes cache_control on the
        /// last block. Functionally identical wire format to .blocks
        /// when no breakpoint is set.
        enum MessageContent: Encodable {
            case plain(String)
            case blocks([ContentBlock])
            case cachedBlocks([CachedContentBlock])

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .plain(let s): try container.encode(s)
                case .blocks(let b): try container.encode(b)
                case .cachedBlocks(let b): try container.encode(b)
                }
            }
        }

        enum ContentBlock: Encodable {
            case text(String)
            case toolUse(id: String, name: String, inputJSON: String)
            case toolResult(toolUseID: String, content: String)

        }

        /// Wrapper that adds optional `cache_control` to a ContentBlock
        /// at encode time without changing the enum API. Used for the
        /// conversation-history cache breakpoint.
        struct CachedContentBlock: Encodable {
            let block: ContentBlock
            let cacheControl: SystemBlock.CacheControl?

        }

        struct Message: Encodable {
            let role: String
            let content: MessageContent
        }

        struct SystemBlock: Encodable {
            let type: String
            let text: String
            let cache_control: CacheControl?

            /// `ttl` lets us opt the tool
            /// catalog (rarely changes — only when fact registry is
            /// rebuilt at app launch) into the 1-hour cache beta.
            /// 1h cache writes cost 2× input vs 1.25× for 5-minute,
            /// but a single user session typically has 10-50+ turns
            /// over 30+ minutes; one write amortizes across all of
            /// them. Conversation-history breakpoints stick with
            /// 5-minute (default ttl) since the last-message tail
            /// changes every turn anyway.
        }

        /// Tool declaration per Anthropic's tools spec.
        /// `cache_control` lets us mark the
        /// last tool in the catalog as a cache breakpoint. Anthropic
        /// caches everything BEFORE a marker, so one breakpoint at
        /// the tail of the tools array effectively caches the whole
        /// (~30K-token) catalog. Reads at 10% input cost.
        /// Anthropic supports two tool flavors at the same `tools[]` array
        /// level: client-side custom tools (we resolve, return result back)
        /// and server-side built-in tools (Anthropic resolves on its end).
        /// We currently use one of each: the catalog tools (custom) + the
        /// `web_search_20250305` server-side tool when web search is on.
        /// The server-tool variant gives users
        /// real web search without a Tavily key.
        enum ToolDecl: Encodable {
            case custom(name: String, description: String, schema: ToolSpec.InputSchema, cache: SystemBlock.CacheControl?)
            case serverWebSearch(maxUses: Int, blockedDomains: [String], cache: SystemBlock.CacheControl?)

        }

        let model: String
        let max_tokens: Int
        let system: [SystemBlock]
        let messages: [Message]
        let stream: Bool
        let tools: [ToolDecl]?
    }

    /// Convert a Message to its cached-blocks form with cache_control
    /// set on its tail block. Handles all three current `MessageContent`
    /// variants (.plain, .blocks, .cachedBlocks).
    private func applyCacheControl(to message: RequestBody.Message) -> RequestBody.Message {
        switch message.content {
        case .plain(let s):
            // Promote the plain text to a single cached text block.
            return Self.cachedMessage(role: message.role, blocks: [.text(s)])
        case .blocks(let raw):
            guard !raw.isEmpty else { return message }
            return Self.cachedMessage(role: message.role, blocks: raw)
        case .cachedBlocks(let existing):
            // Already cached — re-mark the tail in case the caller wants to
            // update. Idempotent, but cheap to re-stamp.
            guard !existing.isEmpty else { return message }
            return Self.cachedMessage(role: message.role, blocks: existing.map(\.block))
        }
    }

    /// Wrap each block, with `cache_control` on the last one only — that's the
    /// breakpoint Anthropic caches up to.
    static func cachedMessage(
        role: String,
        blocks: [RequestBody.ContentBlock]
    ) -> RequestBody.Message {
        let breakpoint = RequestBody.SystemBlock.CacheControl(type: "ephemeral")
        let wrapped = blocks.enumerated().map { idx, block in
            RequestBody.CachedContentBlock(
                block: block,
                cacheControl: idx == blocks.count - 1 ? breakpoint : nil
            )
        }
        return RequestBody.Message(role: role, content: .cachedBlocks(wrapped))
    }

    /// Assemble the message history Anthropic expects.
    ///
    /// Prior turns are plain text. When continuing after tool-use rounds, each
    /// round becomes an assistant message carrying all its `tool_use` blocks,
    /// immediately followed by a user message carrying the matching
    /// `tool_result` blocks — Anthropic enforces that pairing, and every
    /// `tool_use` must be answered before the model speaks again.
    ///
    /// The conversation-history cache breakpoint lives here
    /// too. Marking the last content block of the second-to-last message with
    /// `cache_control: ephemeral` makes Anthropic cache everything up to that
    /// point: system blocks, tools, and every prior turn. The next send matches
    /// the cached prefix and pays 10% on those tokens. It is only worth doing
    /// with two or more messages; below that the system and tools breakpoints
    /// already cover everything worth caching.
    private func buildMessageHistory(
        messages: [ChatTurn],
        toolRounds: [[ToolExchange]]
    ) -> [RequestBody.Message] {
        var mapped: [RequestBody.Message] = messages.map { turn in
            RequestBody.Message(
                role: turn.role == .user ? "user" : "assistant",
                content: .plain(turn.text)
            )
        }
        for round in toolRounds where !round.isEmpty {
            mapped.append(contentsOf: Self.toolRoundMessages(round))
        }
        if mapped.count >= 2 {
            let cacheIdx = mapped.count - 2 // second-to-last
            mapped[cacheIdx] = applyCacheControl(to: mapped[cacheIdx])
        }
        return mapped
    }

    /// One tool round as the assistant/user message pair Anthropic requires.
    static func toolRoundMessages(_ round: [ToolExchange]) -> [RequestBody.Message] {
        let toolUseBlocks = round.map {
            RequestBody.ContentBlock.toolUse(id: $0.toolUseID, name: $0.toolName, inputJSON: $0.inputJSON)
        }
        let toolResultBlocks = round.map {
            RequestBody.ContentBlock.toolResult(toolUseID: $0.toolUseID, content: $0.resultJSON)
        }
        return [
            RequestBody.Message(role: "assistant", content: .blocks(toolUseBlocks)),
            RequestBody.Message(role: "user", content: .blocks(toolResultBlocks))
        ]
    }

    /// The system role: a cacheable stable prefix, plus the variable suffix
    /// as a second, uncached block when the composer emitted one.
    ///
    /// Only the stable block carries `cache_control` — that is the whole
    /// point of the split. See the note at the call site for why the variable
    /// suffix stays in the system role rather than riding the user tail.
    static func makeSystemBlocks(stable: String, variable: String) -> [RequestBody.SystemBlock] {
        var blocks = [
            RequestBody.SystemBlock(type: "text", text: stable, cache_control: .init(type: "ephemeral"))
        ]
        if !variable.isEmpty {
            blocks.append(RequestBody.SystemBlock(type: "text", text: variable, cache_control: nil))
        }
        return blocks
    }

    /// Splices `contextRendered` into the LAST user message, wrapped in
    /// `<live_state>…</live_state>`.
    ///
    /// If there is no user message yet (shouldn't happen — Anthropic requires
    /// at least one) the live state goes into a system block instead, so the
    /// model still sees it.
    ///
    /// Extracted from `stream` to keep that method inside the body-length and
    /// cyclomatic-complexity budgets; this content-shape switch is the bulk
    /// of both.
    static func spliceLiveState(
        _ contextRendered: String,
        into mapped: inout [RequestBody.Message],
        systemBlocks: inout [RequestBody.SystemBlock]
    ) {
        guard !contextRendered.isEmpty else { return }
        let liveBlock = "\n\n<live_state>\n\(contextRendered)\n</live_state>"
        guard let idx = mapped.lastIndex(where: { $0.role == "user" }) else {
            systemBlocks.append(RequestBody.SystemBlock(
                type: "text", text: contextRendered, cache_control: nil
            ))
            return
        }
        let original = mapped[idx]
        mapped[idx] = RequestBody.Message(
            role: original.role,
            content: appending(liveBlock, to: original.content)
        )
    }

    /// The three `MessageContent` cases each rebuild differently, and which one
    /// applies depends on where the conversation cache breakpoint landed.
    static func appending(
        _ liveBlock: String,
        to content: RequestBody.MessageContent
    ) -> RequestBody.MessageContent {
        switch content {
        case .plain(let s):
            return .plain(s + liveBlock)
        case .blocks(let bs):
            var rebuilt = bs
            if case .text(let trailing) = bs.last {
                rebuilt[bs.count - 1] = .text(trailing + liveBlock)
            } else {
                rebuilt.append(.text(liveBlock))
            }
            return .blocks(rebuilt)
        case .cachedBlocks(let cbs):
            // Rarely hit — when the conversation cache breakpoint is on the
            // second-to-last user message and that happens to be the last
            // too. Append as a fresh text block alongside the cached ones.
            return .cachedBlocks(cbs + [RequestBody.CachedContentBlock(block: .text(liveBlock), cacheControl: nil)])
        }
    }

    /// `spliceLiveState` folds `contextRendered` into the LAST user message
    /// wrapped in `<live_state>…</live_state>`, falling back to a system block
    /// when there is no user message yet (which Anthropic shouldn't allow).
    private func stream(
        messages: [ChatTurn],
        model: ModelOption,
        contextRendered: String,
        systemPrompt: String,
        tools: [ToolSpec],
        toolRounds: [[ToolExchange]],
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws {
        guard let apiKey = AppDependencies.current.providers.apiKeyStore.key(for: .anthropic) else {
            throw AIProviderError.missingKey(.anthropic)
        }
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw AIProviderError.invalidResponse("bad endpoint")
        }
        var mapped = buildMessageHistory(messages: messages, toolRounds: toolRounds)
        var systemBlocks = Self.cacheAwareSystemBlocks(systemPrompt)
        Self.spliceLiveState(contextRendered, into: &mapped, systemBlocks: &systemBlocks)
        let body = RequestBody(
            model: model.apiID, max_tokens: 2048, system: systemBlocks,
            messages: mapped, stream: true, tools: Self.toolDeclarations(for: tools)
        )
        let request = try Self.makeRequest(url: url, apiKey: apiKey, body: body)
        let (bytes, response) = try await Self.streamSession.bytes(for: request)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            try await Self.throwForStatus(http.statusCode, bytes: bytes)
        }
        try await Self.consumeSSE(bytes, continuation: continuation)
    }

    /// Accumulator for a streaming tool_use content block. Anthropic sends
    /// `input` as a series of partial_json deltas — we concatenate until the
    /// matching content_block_stop arrives, then emit one `.toolUse` event
    /// with the fully assembled args.
    struct PendingToolUse {
        let id: String
        let name: String
        var inputJSON: String = ""
    }

    /// Per-request SSE state: open tool-use blocks, and `message_start`'s
    /// usage held until `message_delta` brings the final output count, so
    /// each request records ONE usage event. Recording both doubled the
    /// cache-telemetry turn count.
    struct StreamState {
        var openToolUses: [Int: PendingToolUse] = [:]
        var startUsage: [String: Any]?
        var usageRecorded = false
    }

    /// Emits a `.usage` event from an Anthropic usage payload, when it
    /// carries at least one non-zero counter.
    static func yieldUsage(
        _ usage: [String: Any]?,
        to continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) {
        guard let usage else { return }
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
        guard input > 0 || output > 0 || cacheRead > 0 || cacheCreate > 0 else { return }
        continuation.yield(.usage(
            inputTokens: input,
            outputTokens: output,
            cachedInputTokens: cacheRead,
            cacheCreationInputTokens: cacheCreate
        ))
    }

    static func handle(
        eventName: String?,
        data: Data,
        state: inout StreamState,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch (json["type"] as? String) ?? eventName ?? "" {
        case "content_block_start":
            openBlock(json, into: &state.openToolUses)
        case "content_block_delta":
            handleDelta(json, openToolUses: &state.openToolUses, continuation: continuation)
        case "content_block_stop":
            closeBlock(json, openToolUses: &state.openToolUses, continuation: continuation)
        case "message_delta":
            flushUsage(&state, final: json["usage"] as? [String: Any], to: continuation)
        case "message_start":
            state.startUsage = (json["message"] as? [String: Any])?["usage"] as? [String: Any]
        case "message_stop":
            finishMessage(&state, continuation: continuation)
        case "error":
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "Anthropic stream error"
            throw AIProviderError.invalidResponse(message)
        default:
            break // ping — ignore
        }
    }

    /// `message_stop`: record usage if no delta did, then end the stream.
    static func finishMessage(
        _ state: inout StreamState,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) {
        flushUsage(&state, final: nil, to: continuation)
        continuation.yield(.done)
    }

    /// One usage event from `message_start`'s counters overlaid with the
    /// final (cumulative) `message_delta` ones. Fires once per request: the
    /// `message_stop` call is the fallback for a stream whose delta carried
    /// no usage.
    static func flushUsage(
        _ state: inout StreamState,
        final: [String: Any]?,
        to continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) {
        guard !state.usageRecorded, state.startUsage != nil || final != nil else { return }
        state.usageRecorded = true
        yieldUsage((state.startUsage ?? [:]).merging(final ?? [:]) { _, new in new }, to: continuation)
    }

    /// `content_block_start` — begin tracking a `tool_use` block by index.
    static func openBlock(_ json: [String: Any], into openToolUses: inout [Int: PendingToolUse]) {
        guard let index = json["index"] as? Int,
              let block = json["content_block"] as? [String: Any],
              (block["type"] as? String) == "tool_use",
              let id = block["id"] as? String,
              let name = block["name"] as? String
        else { return }
        openToolUses[index] = PendingToolUse(id: id, name: name)
    }

    /// `content_block_delta` — either a chunk of tool-input JSON for an open
    /// block, or a chunk of assistant text.
    static func handleDelta(
        _ json: [String: Any],
        openToolUses: inout [Int: PendingToolUse],
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) {
        guard let delta = json["delta"] as? [String: Any] else { return }
        if (delta["type"] as? String) == "input_json_delta",
           let index = json["index"] as? Int,
           let partial = delta["partial_json"] as? String,
           openToolUses[index] != nil {
            openToolUses[index]?.inputJSON.append(partial)
        } else if let text = delta["text"] as? String, !text.isEmpty {
            continuation.yield(.textDelta(text))
        }
    }

    /// `content_block_stop` — a completed `tool_use` block becomes a `.toolUse`
    /// event. An empty accumulator means the tool takes no arguments.
    static func closeBlock(
        _ json: [String: Any],
        openToolUses: inout [Int: PendingToolUse],
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) {
        guard let index = json["index"] as? Int,
              let pending = openToolUses.removeValue(forKey: index)
        else { return }
        let args = pending.inputJSON.isEmpty ? "{}" : pending.inputJSON
        continuation.yield(.toolUse(id: pending.id, name: pending.name, inputJSON: args))
    }

    static func throwForStatus(_ status: Int, bytes: URLSession.AsyncBytes) async throws -> Never {
        // Drain a bounded portion of the body for diagnostics.
        var collected = Data()
        for try await byte in bytes {
            collected.append(byte)
            if collected.count >= 4096 { break }
        }
        let bodyText = redactAPIKeys(String(data: collected, encoding: .utf8) ?? "")
        if ProviderAccountReply.isCreditExhausted(status: status, body: bodyText) {
            throw AIProviderError.outOfCredit(.anthropic)
        }
        throw statusError(status, message: errorMessage(from: collected) ?? String(bodyText.prefix(300)))
    }

    /// Maps an HTTP failure to the error the chat banner shows. 529
    /// (Anthropic's "overloaded") and other 5xx are transient on their
    /// side, so the user gets a plain "try again" instead of a status dump.
    static func statusError(_ status: Int, message: String) -> AIProviderError {
        switch status {
        case 401, 403: return .authFailed
        case 429: return .rateLimited
        case 404: return .modelUnavailable(message)
        case 500...599:
            return .modelUnavailable(String(
                localized: "Anthropic is overloaded right now. Try again in a moment.",
                bundle: LanguageManager.appBundle
            ))
        default: return .invalidResponse("HTTP \(status): \(message)")
        }
    }

    /// Pulls `error.message` out of Anthropic's JSON error envelope
    /// (`{"type":"error","error":{"type":"...","message":"..."}}`) so the
    /// banner shows one readable sentence instead of raw JSON.
    static func errorMessage(from data: Data) -> String? {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch { return nil }
        guard let json = object as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String, !message.isEmpty
        else { return nil }
        return redactAPIKeys(message)
    }
}

// The wire-format members below live in extensions purely so the declaration
// nesting stays two deep — `AnthropicProvider.RequestBody.ContentBlock` is
// already two levels in, and its `CodingKeys` would be a third. Same types,
// same encoded JSON; only the declaration site differs.

extension AnthropicProvider.RequestBody.ContentBlock {
        private enum CodingKeys: String, CodingKey {
            case type, text, id, name, input, tool_use_id, content
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let s):
                try c.encode("text", forKey: .type)
                try c.encode(s, forKey: .text)
            case .toolUse(let id, let name, let inputJSON):
                try c.encode("tool_use", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(name, forKey: .name)
                try c.encode(Self.inputObject(inputJSON), forKey: .input)
            case .toolResult(let id, let content):
                try c.encode("tool_result", forKey: .type)
                try c.encode(id, forKey: .tool_use_id)
                try c.encode(content, forKey: .content)
            }
        }

        /// `input` is an object in Anthropic's schema, not a string. Parse
        /// the model's emitted JSON and encode as an object so the wire
        /// shape is correct; an unparseable payload becomes `{}`.
        private static func inputObject(_ inputJSON: String) -> AnyJSON {
            let data = inputJSON.data(using: .utf8) ?? Data("{}".utf8)
            guard let obj = try? JSONSerialization.jsonObject(with: data),
                  let any = obj as? [String: Any] else { return AnyJSON([:] as [String: Any]) }
            return AnyJSON(any)
        }
}

extension AnthropicProvider.RequestBody.CachedContentBlock {
        enum CodingKeys: String, CodingKey { case cache_control }

        func encode(to encoder: Encoder) throws {
            // Encode the block's standard fields, then (if marked)
            // add cache_control.
            try block.encode(to: encoder)
            if let cacheControl {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(cacheControl, forKey: .cache_control)
            }
        }
}

extension AnthropicProvider.RequestBody.SystemBlock {
        struct CacheControl: Encodable {
            let type: String
            let ttl: String?

            init(type: String, ttl: String? = nil) {
                self.type = type
                self.ttl = ttl
            }
        }
}

extension AnthropicProvider.RequestBody.ToolDecl {
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            switch self {
            case let .custom(name, description, schema, cache):
                try c.encode(name, forKey: .init("name"))
                try c.encode(description, forKey: .init("description"))
                try c.encode(schema, forKey: .init("input_schema"))
                if let cache { try c.encode(cache, forKey: .init("cache_control")) }
            case let .serverWebSearch(maxUses, blockedDomains, cache):
                try c.encode("web_search_20250305", forKey: .init("type"))
                try c.encode("web_search", forKey: .init("name"))
                try c.encode(maxUses, forKey: .init("max_uses"))
                try c.encode(blockedDomains, forKey: .init("blocked_domains"))
                if let cache { try c.encode(cache, forKey: .init("cache_control")) }
            }
        }

        private struct AnyKey: CodingKey {
            let stringValue: String
            init(_ s: String) { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue _: Int) { nil }
        }
}
