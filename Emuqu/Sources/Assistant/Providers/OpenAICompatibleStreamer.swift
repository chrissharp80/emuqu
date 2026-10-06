import Foundation

/// Shared SSE streamer for providers that implement the OpenAI Chat Completions
/// API surface (OpenAI, xAI Grok, DeepSeek, and several others). Same request
/// shape, same `data: { ... }` event format, same `[DONE]` sentinel.
///
/// The provider classes are thin: they own the model catalog + endpoint URL,
/// and delegate the streaming/parse to this helper.
///
/// Tool use follows OpenAI's `tools` + `tool_calls` + `role:"tool"` protocol:
///   • outbound: `tools: [{type:"function", function:{...}}]` at top level
///   • response stream: `choices[0].delta.tool_calls[{index, id, function:{name, arguments}}]`
///     where `arguments` is a streaming string of partial JSON fragments.
///     We accumulate per index and emit a single `.toolUse` event when the
///     final chunk arrives (finish_reason = "tool_calls").
///   • continuation: assistant message with `tool_calls` + `content:null`,
///     followed by one `role:"tool"` message per call carrying
///     `tool_call_id` + the resolver's result JSON.
enum OpenAICompatibleStreamer {
    /// The chat-completions endpoint of each provider that speaks this API.
    ///
    /// Parsed once here rather than force-unwrapped at each call site: these
    /// are constants the app ships, so a failure would be a typo caught on the
    /// first request, but `!` in shipping code is a crash the user takes. A
    /// provider whose URL does not parse simply has no endpoint, and the
    /// request reports that like any other unavailable provider.
    enum Endpoint {
        static let openAI = URL(string: "https://api.openai.com/v1/chat/completions")
        static let grok = URL(string: "https://api.x.ai/v1/chat/completions")
        static let deepSeek = URL(string: "https://api.deepseek.com/chat/completions")
    }

    /// Dedicated URLSession for AI streaming requests
    /// that survives the brief network blips you get on cellular
    /// while walking. `URLSession.shared` uses iOS defaults which
    /// fail a request the moment the radio drops; user report
    /// ("Flo cannot connect to Grok when I'm walking") matches that
    /// exactly — tower handoffs during a walk are a common cause.
    ///
    /// Config choices:
    ///   • `waitsForConnectivity = true` — iOS holds the request and
    ///     retries transparently when connectivity returns, up to
    ///     `timeoutIntervalForResource`. A 5-second tower handoff
    ///     stops looking like a failure to the caller.
    ///   • `timeoutIntervalForRequest = 30` — fail fast on the
    ///     initial connect (so the fallback provider chain kicks
    ///     in before the user gives up). The wait-for-connectivity
    ///     path is the long-tail handler; this is the short-tail.
    ///   • `timeoutIntervalForResource = 180` — caps streaming
    ///     response time at 3 min. Long enough for a verbose
    ///     reasoning turn, short enough that a wedged stream
    ///     surfaces as an error eventually.
    ///   • `allowsCellularAccess = true`, `allowsConstrainedNetworkAccess = true`
    ///     — explicit (also the defaults) so iOS knows we want the
    ///     request on a metered or constrained link rather than
    ///     pretending we're offline.
    ///   • `httpMaximumConnectionsPerHost = 4` — small ceiling
    ///     keeps the session from holding extra connections open
    ///     while idle, but high enough that overlapping tool-use
    ///     turns don't queue.
    /// `URLSession` is `Sendable`, so no isolation annotation is needed.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        config.allowsCellularAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.httpMaximumConnectionsPerHost = 4
        // No URLCache — these are POSTs against a per-request body
        // anyway. Saves disk + memory.
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Request fields that set how much a model reasons before it answers.
    /// Flo's tool loop sends back only each round's tool calls and results,
    /// so a model whose API needs its reasoning echoed between tool rounds
    /// is run with reasoning off.
    enum Reasoning: Equatable, Sendable {
        /// Sends no reasoning field; the model's documented default applies.
        case modelDefault
        /// `reasoning_effort: "none"`. OpenAI's Chat Completions accepts
        /// function calling on gpt-6-luna only at this effort.
        case effortNone
        /// `thinking: {"type": "disabled"}`. DeepSeek's models think by
        /// default, and a thinking turn that called tools must have its
        /// `reasoning_content` passed back in every later request.
        case thinkingDisabled
    }

    /// `endpoint` is optional because the provider constants above are parsed,
    /// not force-unwrapped. A URL that does not parse reports the same
    /// "bad endpoint" the Anthropic path reports, instead of trapping.
    static func send(
        providerID: ProviderID,
        endpoint: URL?,
        reasoning: Reasoning,
        messages: [ChatTurn],
        model: ModelOption,
        contextRendered: String,
        systemPrompt: String,
        tools: [ToolSpec] = [],
        toolRounds: [[ToolExchange]] = []
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        guard let endpoint else {
            return AsyncThrowingStream { $0.finish(throwing: AIProviderError.invalidResponse("bad endpoint")) }
        }
        let call = StreamCall(
            providerID: providerID, endpoint: endpoint, reasoning: reasoning, messages: messages,
            model: model, contextRendered: contextRendered, systemPrompt: systemPrompt,
            tools: tools, toolRounds: toolRounds
        )
        return ProviderStream.make { continuation in
            try await stream(call, continuation: continuation)
        }
    }

    /// Everything one provider call needs, apart from the continuation it
    /// writes into. Grouped so `stream` and `requestFor` take one value
    /// rather than a nine-item argument list.
    struct StreamCall {
        let providerID: ProviderID
        let endpoint: URL
        let reasoning: Reasoning
        let messages: [ChatTurn]
        let model: ModelOption
        let contextRendered: String
        let systemPrompt: String
        let tools: [ToolSpec]
        let toolRounds: [[ToolExchange]]
    }

    // MARK: - Request body

    private enum MessageShape: Encodable {
        case plainUser(String)
        case plainAssistant(String)
        case system(String)
        /// Assistant message containing one or more tool_calls — emitted by
        /// the model in the previous round and echoed back verbatim for the
        /// continuation so the API pairs tool_calls with their tool results.
        case assistantToolCalls(calls: [OutgoingToolCall])
        /// A resolver's result for a specific tool_call_id.
        case toolResult(callID: String, content: String)

        private enum CodingKeys: String, CodingKey {
            case role, content, tool_calls, tool_call_id
        }

        /// `content` must be present even for tool-call messages; some
        /// servers accept null, others require an empty string. Use "".
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .system(let s):
                try c.encode("system", forKey: .role)
                try c.encode(s, forKey: .content)
            case .plainUser(let s):
                try c.encode("user", forKey: .role)
                try c.encode(s, forKey: .content)
            case .plainAssistant(let s):
                try c.encode("assistant", forKey: .role)
                try c.encode(s, forKey: .content)
            case .assistantToolCalls(let calls):
                try c.encode("assistant", forKey: .role)
                try c.encode("", forKey: .content)
                try c.encode(calls, forKey: .tool_calls)
            case .toolResult(let id, let content):
                try c.encode("tool", forKey: .role)
                try c.encode(id, forKey: .tool_call_id)
                try c.encode(content, forKey: .content)
            }
        }
    }

    private struct OutgoingToolCall: Encodable {
        let id: String
        let type: String = "function"
        let function: Function

        struct Function: Encodable {
            let name: String
            let arguments: String // OpenAI wants arguments as a JSON STRING
        }
    }

    private struct OutgoingTool: Encodable {
        let type: String = "function"
        let function: Function

        struct Function: Encodable {
            let name: String
            let description: String
            let parameters: ToolSpec.InputSchema
        }
    }

    private struct RequestBody: Encodable {
        struct StreamOptions: Encodable {
            let include_usage: Bool
        }

        struct Thinking: Encodable {
            let type: String
        }

        let model: String
        let messages: [MessageShape]
        let stream: Bool
        let stream_options: StreamOptions
        let tools: [OutgoingTool]?
        /// Left out of the JSON when nil, like `tools`.
        let reasoning_effort: String?
        let thinking: Thinking?
    }

    // MARK: - Stream

    /// Accumulator for a streaming tool_call. `arguments` grows as partial
    /// fragments arrive across multiple chunks.
    private struct PendingToolCall {
        let index: Int
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    /// Builds the full outgoing message array: stable system block, the
    /// conversation with the live-state envelope spliced into the last user
    /// turn, then any tool rounds.
    ///
    /// Kept out of `stream` to hold its body length down. Pure: same inputs
    /// produce the same array, no network and no keychain. Stays `private`
    /// because `MessageShape` is private; making it directly testable would
    /// mean widening that type's access.
    ///
    /// Splits the composed system prompt on the cache marker and
    /// routes the two halves separately. Without this, the per-second
    /// `nowSnapshot` line and the live-workout block live INSIDE the system
    /// message, which is exactly the point where automatic prompt caches (xAI
    /// for Grok, OpenAI for GPT) break their stable-prefix detection. Same shape
    /// Anthropic gets explicitly via cache_control — done here so
    /// OpenAI-compat providers see the same shape: stable system block +
    /// variable state in the user-message tail.
    ///
    /// The splice targets the LAST user message, mirroring
    /// AnthropicProvider's pattern. If there is no user message at all
    /// (shouldn't happen — the dispatch path always reserves one before
    /// calling the provider), the live state becomes a second system block so
    /// the model still sees it.
    private static func buildMessages(
        messages: [ChatTurn],
        systemPrompt: String,
        contextRendered: String,
        toolRounds: [[ToolExchange]]
    ) -> [MessageShape] {
        let marker = AssistantSystemPrompt.Composed.cacheSplitMarker
        let parts = systemPrompt.components(separatedBy: marker)
        let variableSystem = parts.count > 1 ? parts.dropFirst().joined(separator: marker) : ""
        let liveStateBlock = liveStateEnvelope(variableSystem: variableSystem, contextRendered: contextRendered)
        var mapped: [MessageShape] = [.system(parts.first ?? systemPrompt)]
        let lastUserMessageIndex = messages.lastIndex { $0.role == .user }
        for (idx, turn) in messages.enumerated() {
            let splice = turn.role == .user && idx == lastUserMessageIndex && !liveStateBlock.isEmpty
            mapped.append(turn.role == .user
                ? .plainUser(splice ? turn.text + liveStateBlock : turn.text)
                : .plainAssistant(turn.text))
        }
        if lastUserMessageIndex == nil, !liveStateBlock.isEmpty {
            mapped.append(.system(liveStateBlock))
        }
        for round in toolRounds where !round.isEmpty {
            mapped.append(contentsOf: toolRoundMessages(round))
        }
        return mapped
    }

    /// The live-state envelope spliced into the last user message. Empty when
    /// neither half has content.
    ///
    /// For tool-mode calls (cloud providers) `contextRendered` is already
    /// empty (see AssistantViewModel.dispatch), so this just carries the
    /// variable suffix when there is one. Non-tool calls (Apple) get
    /// `contextRendered` appended too — Apple has no HTTP prompt cache anyway.
    private static func liveStateEnvelope(variableSystem: String, contextRendered: String) -> String {
        let body = [variableSystem, contextRendered].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return body.isEmpty ? "" : "\n\n<live_state>\n\(body)\n</live_state>"
    }

    /// One tool round: the assistant message carrying every call, then one
    /// `tool` message per result.
    private static func toolRoundMessages(_ round: [ToolExchange]) -> [MessageShape] {
        let calls = round.map {
            OutgoingToolCall(id: $0.toolUseID, function: .init(name: $0.toolName, arguments: $0.inputJSON))
        }
        return [.assistantToolCalls(calls: calls)] + round.map {
            .toolResult(callID: $0.toolUseID, content: $0.resultJSON)
        }
    }

    /// Builds the POST for a chat-completions call.
    ///
    /// Kept out of `stream`, alongside `buildMessages`, to hold it
    /// under the body-length budget.
    ///
    /// `.sortedKeys` is required for cache-stable payload serialisation —
    /// DeepSeek's prompt cache hinges on byte-identical prefixes across turns,
    /// and Dictionary iteration order isn't stable in Swift.
    private static func buildRequest(
        endpoint: URL,
        apiKey: String,
        model: ModelOption,
        reasoning: Reasoning,
        mapped: [MessageShape],
        tools: [ToolSpec]
    ) throws -> URLRequest {
        let outgoingTools: [OutgoingTool]? = tools.isEmpty ? nil : tools.map {
            OutgoingTool(function: .init(
                name: $0.name, description: $0.description, parameters: $0.inputSchema
            ))
        }
        let body = RequestBody(
            model: model.apiID, messages: mapped, stream: true,
            stream_options: .init(include_usage: true), tools: outgoingTools,
            reasoning_effort: reasoning == .effortNone ? "none" : nil,
            thinking: reasoning == .thinkingDisabled ? .init(type: "disabled") : nil
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)
        return request
    }

    private static func stream(
        _ call: StreamCall,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws {
        guard let apiKey = AppDependencies.current.providers.apiKeyStore.key(for: call.providerID) else {
            throw AIProviderError.missingKey(call.providerID)
        }
        let request = try requestFor(call, apiKey: apiKey)
        let (bytes, response) = try await connect(request, providerID: call.providerID)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            try await throwForStatus(http.statusCode, bytes: bytes, providerID: call.providerID)
        }
        try await consumeSSE(bytes, continuation: continuation)
    }

    /// Flatten one call into the wire request, messages included. Pure, so
    /// tests can read the body a call sends.
    static func requestFor(_ call: StreamCall, apiKey: String) throws -> URLRequest {
        try buildRequest(
            endpoint: call.endpoint,
            apiKey: apiKey,
            model: call.model,
            reasoning: call.reasoning,
            mapped: buildMessages(
                messages: call.messages,
                systemPrompt: call.systemPrompt,
                contextRendered: call.contextRendered,
                toolRounds: call.toolRounds
            ),
            tools: call.tools
        )
    }

    /// Use the dedicated session (see above) so
    /// cellular blips during walks don't immediately surface
    /// as "cannot connect."
    ///
    /// Surfaces the specific NSURLError code in the debug log so
    /// the next user report can be diagnosed without guessing
    /// (timed out vs. cancelled vs. notConnectedToInternet vs.
    /// networkConnectionLost — they have very different fixes).
    private static func connect(
        _ request: URLRequest,
        providerID: ProviderID
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do {
            return try await session.bytes(for: request)
        } catch let urlError as URLError {
            debugLog("[AIStreamer] \(providerID.rawValue) connect failed: code=\(urlError.code.rawValue) (\(urlError.localizedDescription))", level: .warning)
            throw urlError
        }
    }

    /// Accumulate tool_calls by index across chunks. Flush on
    /// `finish_reason == "tool_calls"` OR on `[DONE]`.
    private static func consumeSSE(
        _ bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws {
        var openToolCalls: [Int: PendingToolCall] = [:]
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" {
                flushToolCalls(&openToolCalls, continuation: continuation)
                continuation.yield(.done)
                return
            }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            handleChoice(json, openToolCalls: &openToolCalls, continuation: continuation)
            yieldUsage(json["usage"] as? [String: Any], to: continuation)
        }
    }

    /// The `choices[0]` half of a chunk: a text delta, tool-call fragments, or
    /// the finish reason that flushes them.
    private static func handleChoice(
        _ json: [String: Any],
        openToolCalls: inout [Int: PendingToolCall],
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) {
        guard let first = (json["choices"] as? [[String: Any]])?.first else { return }
        if let delta = first["delta"] as? [String: Any] {
            if let content = delta["content"] as? String, !content.isEmpty {
                continuation.yield(.textDelta(content))
            }
            for tc in delta["tool_calls"] as? [[String: Any]] ?? [] {
                accumulate(tc, into: &openToolCalls)
            }
        }
        if let reason = first["finish_reason"] as? String, reason == "tool_calls" {
            flushToolCalls(&openToolCalls, continuation: continuation)
        }
    }

    /// Merge one `tool_calls` delta fragment into the pending call at its index.
    /// Every field arrives incrementally, so each is applied only when non-empty.
    private static func accumulate(_ tc: [String: Any], into openToolCalls: inout [Int: PendingToolCall]) {
        guard let idx = tc["index"] as? Int else { return }
        if openToolCalls[idx] == nil { openToolCalls[idx] = PendingToolCall(index: idx) }
        if let id = tc["id"] as? String, !id.isEmpty { openToolCalls[idx]?.id = id }
        guard let fn = tc["function"] as? [String: Any] else { return }
        if let name = fn["name"] as? String, !name.isEmpty { openToolCalls[idx]?.name = name }
        if let args = fn["arguments"] as? String, !args.isEmpty {
            openToolCalls[idx]?.arguments.append(args)
        }
    }

    /// OpenAI / DeepSeek cache stats. Cache-read token counts are reported in
    /// different shapes across providers — OpenAI uses
    /// `prompt_tokens_details.cached_tokens`, DeepSeek uses
    /// `prompt_cache_hit_tokens` + `prompt_cache_miss_tokens`. Both emit 0
    /// when the other's shape is expected. `prompt_tokens` includes the cached
    /// tokens in both, while `.usage`'s `inputTokens` is the uncached part
    /// (Anthropic's shape, which the cache-hit ratio assumes), so the cached
    /// count is taken out.
    private static func yieldUsage(
        _ usage: [String: Any]?,
        to continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) {
        guard let usage else { return }
        let output = usage["completion_tokens"] as? Int ?? 0
        let details = usage["prompt_tokens_details"] as? [String: Any]
        let cached = (details?["cached_tokens"] as? Int).flatMap { $0 == 0 ? nil : $0 }
            ?? usage["prompt_cache_hit_tokens"] as? Int ?? 0
        let input = max(0, (usage["prompt_tokens"] as? Int ?? 0) - cached)
        guard input > 0 || output > 0 || cached > 0 else { return }
        continuation.yield(.usage(
            inputTokens: input, outputTokens: output,
            cachedInputTokens: cached, cacheCreationInputTokens: 0
        ))
    }

    /// Emit one `.toolUse` per accumulated tool_call in deterministic index
    /// order. Clears the dict so a [DONE] sentinel doesn't double-emit.
    private static func flushToolCalls(
        _ calls: inout [Int: PendingToolCall],
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) {
        let ordered = calls.values.sorted { $0.index < $1.index }
        for call in ordered where !call.name.isEmpty {
            let args = call.arguments.isEmpty ? "{}" : call.arguments
            continuation.yield(.toolUse(id: call.id, name: call.name, inputJSON: args))
        }
        calls.removeAll(keepingCapacity: false)
    }

    /// Maps an HTTP failure to the error the chat shows. A credit failure is
    /// checked first: OpenAI sends an empty account as 429
    /// `insufficient_quota`, DeepSeek as 402, xAI as 403/429 about credits,
    /// and none of those is a rate limit or a bad key.
    private static func throwForStatus(
        _ status: Int,
        bytes: URLSession.AsyncBytes,
        providerID: ProviderID
    ) async throws -> Never {
        var collected = Data()
        for try await byte in bytes {
            collected.append(byte)
            if collected.count >= 4096 { break }
        }
        let bodyText = redactAPIKeys(String(data: collected, encoding: .utf8) ?? "")
        if ProviderAccountReply.isCreditExhausted(status: status, body: bodyText) {
            throw AIProviderError.outOfCredit(providerID)
        }
        let parsed = parseOpenAIError(collected)
        switch status {
        case 401, 403: throw AIProviderError.authFailed
        case 429: throw AIProviderError.rateLimited
        case 404: throw AIProviderError.modelUnavailable(parsed?.message ?? bodyText)
        case 400: throw badRequestError(parsed, bodyText: bodyText, status: status)
        default:
            throw AIProviderError.invalidResponse("HTTP \(status): \(parsed?.message ?? bodyText)")
        }
    }

    /// 400 is most often a model-config problem ("not a chat model",
    /// "max_tokens > context", "invalid prompt format"). Surface a
    /// model-parameter failure as `modelUnavailable` so the chat bubble's
    /// error copy reads naturally rather than as a generic "unexpected
    /// response."
    ///
    /// OpenAI returns its errors as JSON like:
    ///   {"error":{"message":"...", "type":"invalid_request_error", "param":"model", "code":null}}
    /// Surfacing the raw body text in the chat bubble gives users a wall of
    /// JSON they can't parse. `parseOpenAIError` extracts
    /// `error.message` and `error.param`; we fall back to the raw body when it
    /// can't, so we never lose information.
    private static func badRequestError(
        _ parsed: ParsedOpenAIError?,
        bodyText: String,
        status: Int
    ) -> AIProviderError {
        guard let parsed else { return .invalidResponse("HTTP \(status): \(bodyText)") }
        // Model not found / not accessible to this key — the model id is the
        // actionable detail.
        return parsed.param == "model"
            ? .modelUnavailable(String(localized: "Model unavailable: \(parsed.message)", bundle: LanguageManager.appBundle))
            : .invalidResponse(parsed.message)
    }

    /// Extract the human-readable bits from OpenAI's
    /// (and OpenAI-compatible providers') JSON error envelope.
    private struct ParsedOpenAIError {
        let message: String
        let type: String?
        let param: String?
        let code: String?
    }

    private static func parseOpenAIError(_ data: Data) -> ParsedOpenAIError? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any]
        else { return nil }
        guard let message = error["message"] as? String, !message.isEmpty else { return nil }
        // Redacted like the Anthropic and Gemini paths: a provider can echo
        // part of the request, key included, back in its error message.
        return ParsedOpenAIError(
            message: redactAPIKeys(message),
            type: error["type"] as? String,
            param: error["param"] as? String,
            code: error["code"] as? String
        )
    }
}
