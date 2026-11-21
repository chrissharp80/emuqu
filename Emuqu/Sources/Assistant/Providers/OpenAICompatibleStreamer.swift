import Foundation

/// Shared SSE streamer for providers that implement the OpenAI Chat Completions
/// API surface (OpenAI, xAI Grok, DeepSeek, and several others). Same request
/// shape, same `data: { ... }` event format, same `[DONE]` sentinel.
///
/// The provider classes are thin: they own the model catalog, endpoint URL
/// and reasoning setting, and `OpenAICompatibleProvider` routes their `send`
/// through this helper.
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
            return AsyncThrowingStream { $0.finish(throwing: ProviderHTTP.badEndpoint) }
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
        let split = ProviderHTTP.splitOnCacheMarker(systemPrompt)
        let liveStateBlock = ProviderHTTP.liveStateEnvelope(variableSystem: split.variable, contextRendered: contextRendered)
        var mapped: [MessageShape] = [.system(split.stable)]
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

    /// Builds the POST for a chat-completions call through
    /// `ProviderHTTP.streamRequest`, with the key as a bearer token.
    ///
    /// Kept out of `stream`, alongside `buildMessages`, to hold it
    /// under the body-length budget.
    ///
    /// The sorted-key body matters here: DeepSeek's prompt cache hinges on
    /// byte-identical prefixes across turns.
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
        return try ProviderHTTP.streamRequest(url: endpoint, body: body, headers: ["Authorization": "Bearer \(apiKey)"])
    }

    private static func stream(
        _ call: StreamCall,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws {
        guard let apiKey = AppDependencies.current.providers.apiKeyStore.key(for: call.providerID) else {
            throw AIProviderError.missingKey(call.providerID)
        }
        let request = try requestFor(call, apiKey: apiKey)
        let lines = try await ProviderHTTP.openStream(request, provider: call.providerID) { status, body in
            statusFailure(status, body: body, providerID: call.providerID)
        }
        try await consumeSSE(lines, providerID: call.providerID, continuation: continuation)
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

    /// Per-request SSE state: tool calls still being assembled, and the
    /// choice's `finish_reason` once a chunk has carried one.
    private struct StreamState {
        var openToolCalls: [Int: PendingToolCall] = [:]
        var finishReason: String?
    }

    /// Reads the SSE lines of one reply. Tool calls accumulate by index
    /// across chunks and flush on `finish_reason == "tool_calls"` or at the
    /// end of the reply.
    ///
    /// The reply is complete only after a terminal signal: the `[DONE]`
    /// sentinel, or a chunk whose choice carries a non-null `finish_reason`
    /// (OpenAI, xAI and DeepSeek send that chunk, then a usage chunk, then
    /// `[DONE]`; a compatible server that leaves `[DONE]` out still sends
    /// the finish reason). A stream that closes with neither was cut, like
    /// an Anthropic stream without `message_stop`: it throws
    /// `URLError(.networkConnectionLost)`, which `ProviderStream` reports as
    /// a dropped connection, and any open tool-call fragments are not run.
    /// A cancelled task whose sequence ended cleanly throws
    /// `CancellationError` first, so Stop reads as cancellation.
    ///
    /// Only `data:` lines are read; comments (`:` keep-alives), blank lines
    /// and `event:` lines are skipped. Takes the line sequence rather than
    /// the URL session's bytes so tests can feed it a reply.
    static func consumeSSE<Lines: AsyncSequence>(
        _ lines: Lines,
        providerID: ProviderID,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws where Lines.Element == String {
        var state = StreamState()
        for try await event in SSEEvents(lines) {
            if event.data == "[DONE]" {
                try finishReply(&state, continuation: continuation)
                return
            }
            try handleChunk(event.data, providerID: providerID, state: &state, continuation: continuation)
        }
        try Task.checkCancellation()
        guard state.finishReason != nil else { throw URLError(.networkConnectionLost) }
        try finishReply(&state, continuation: continuation)
    }

    /// The end of a complete reply: any tool calls still open are flushed
    /// (a server may finish with "stop" and leave them to the end), then
    /// `.done`.
    private static func finishReply(
        _ state: inout StreamState,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) throws {
        try flushToolCalls(&state.openToolCalls, continuation: continuation)
        continuation.yield(.done)
    }

    /// One `data:` chunk: a payload that is not a JSON object throws
    /// (`ProviderHTTP.eventObject`), an error object mid-stream throws it;
    /// otherwise the choice half and the usage half are handled.
    private static func handleChunk(
        _ payload: String,
        providerID: ProviderID,
        state: inout StreamState,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) throws {
        let json = try ProviderHTTP.eventObject(Data(payload.utf8), provider: providerID)
        if let failure = ProviderHTTP.streamFailure(in: json, provider: providerID) { throw failure }
        try handleChoice(json, providerID: providerID, state: &state, continuation: continuation)
        yieldUsage(json["usage"] as? [String: Any], to: continuation)
    }

    /// The `choices[0]` half of a chunk: a text delta, tool-call fragments,
    /// and the finish reason when the chunk carries one. Only the first
    /// finish reason is acted on: a server that repeats it in a later chunk
    /// must not add a second "…" or flush twice.
    private static func handleChoice(
        _ json: [String: Any],
        providerID: ProviderID,
        state: inout StreamState,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) throws {
        guard let first = (json["choices"] as? [[String: Any]])?.first else { return }
        if let delta = first["delta"] as? [String: Any] {
            if let content = delta["content"] as? String, !content.isEmpty {
                continuation.yield(.textDelta(content))
            }
            for tc in delta["tool_calls"] as? [[String: Any]] ?? [] {
                accumulate(tc, into: &state.openToolCalls)
            }
        }
        if let reason = first["finish_reason"] as? String, state.finishReason == nil {
            try applyFinishReason(reason, providerID: providerID, state: &state, continuation: continuation)
        }
    }

    /// Records the finish reason, which marks the reply complete, and acts
    /// on it:
    ///   • `tool_calls`: the calls are complete, so they flush.
    ///   • `length`: the reply hit the token cap. Text ends with "…", as
    ///     Anthropic's `max_tokens` does. Tool-call arguments still open
    ///     were cut, so the round fails rather than run them.
    ///   • `content_filter`: the vendor's safety filter stopped the reply,
    ///     which throws `AIProviderError.blockedReply`.
    ///   • `insufficient_system_resource` (DeepSeek): the server cut the
    ///     reply for lack of capacity, which throws the same overloaded
    ///     error as a 5xx.
    ///   • anything else (`stop`): the reply finished normally.
    private static func applyFinishReason(
        _ reason: String,
        providerID: ProviderID,
        state: inout StreamState,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) throws {
        state.finishReason = reason
        switch reason {
        case "tool_calls":
            try flushToolCalls(&state.openToolCalls, continuation: continuation)
        case "length":
            debugLog("[AIStreamer] \(providerID.rawValue) reply stopped early: finish_reason=length", level: .warning)
            guard state.openToolCalls.isEmpty else {
                throw AIProviderError.invalidResponse("the reply hit its length limit inside a tool call")
            }
            continuation.yield(.textDelta("…"))
        case "content_filter":
            throw AIProviderError.blockedReply(provider: providerID, reason: reason)
        case "insufficient_system_resource":
            throw AIProviderError.modelUnavailable(ProviderHTTP.overloadedMessage(for: providerID))
        default:
            break
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
        ProviderHTTP.yieldUsage(input: input, output: output, cached: cached, to: continuation)
    }

    /// Emit one `.toolUse` per accumulated tool_call in deterministic index
    /// order. Clears the dict so a [DONE] sentinel doesn't double-emit.
    ///
    /// Every call's arguments are checked before any is emitted: arguments
    /// that do not parse as a JSON object were cut or garbled, and running
    /// the tool on them would run it with default scope, so the round
    /// throws `.invalidResponse` and none of the calls run.
    private static func flushToolCalls(
        _ calls: inout [Int: PendingToolCall],
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) throws {
        let ordered = calls.values.sorted { $0.index < $1.index }.filter { !$0.name.isEmpty }
        calls.removeAll(keepingCapacity: false)
        let ready = ordered.map { (call: $0, args: $0.arguments.isEmpty ? "{}" : $0.arguments) }
        if let broken = ready.first(where: { !ProviderHTTP.isJSONObject($0.args) }) {
            throw ProviderHTTP.incompleteArguments(toolName: broken.call.name)
        }
        for item in ready {
            continuation.yield(.toolUse(id: item.call.id, name: item.call.name, inputJSON: item.args))
        }
    }

    /// The error a non-2xx reply becomes. Credit failures and every status
    /// but 400 map through `ProviderHTTP.statusFailure`. A 400 with an
    /// `{"error":{...}}` envelope is most often a model-config problem
    /// ("not a chat model", "max_tokens > context"): `param` "model" means
    /// the model is missing or not open to this key, which reads as
    /// `.modelUnavailable` with the vendor's message; any other parameter
    /// is `.invalidResponse` with that message. A 400 without a readable
    /// message maps through the shared path like any other status.
    static func statusFailure(_ status: Int, body: Data, providerID: ProviderID) -> AIProviderError {
        ProviderHTTP.statusFailure(status, body: body, provider: providerID) { status, body, _ in
            guard status == 400, let message = ProviderHTTP.errorMessage(from: body) else { return nil }
            return errorParam(in: body) == "model"
                ? .modelUnavailable(String(localized: "Model unavailable: \(message)", bundle: LanguageManager.appBundle))
                : .invalidResponse(message)
        }
    }

    /// `error.param` of an OpenAI-style error envelope: the request field
    /// the vendor rejected. Nil when the body is not JSON or names none.
    private static func errorParam(in body: Data) -> String? {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: body) } catch { return nil }
        let error = (object as? [String: Any])?["error"] as? [String: Any]
        return error?["param"] as? String
    }
}

/// A provider that speaks the OpenAI Chat Completions API (OpenAI, xAI
/// Grok, DeepSeek). The conforming class supplies its catalog, `id`,
/// endpoint and reasoning setting; key handling comes from
/// `KeyedCloudProvider`, and `send` streams through
/// `OpenAICompatibleStreamer`.
protocol OpenAICompatibleProvider: KeyedCloudProvider {
    /// The provider's chat-completions URL, nil when it does not parse.
    static var endpoint: URL? { get }
    /// The reasoning fields every request to this provider carries.
    static var reasoning: OpenAICompatibleStreamer.Reasoning { get }
}

extension OpenAICompatibleProvider {
    func send(
        messages: [ChatTurn],
        model: ModelOption,
        contextRendered: String,
        systemPrompt: String,
        tools: [ToolSpec],
        toolRounds: [[ToolExchange]]
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        OpenAICompatibleStreamer.send(
            providerID: id,
            endpoint: Self.endpoint,
            reasoning: Self.reasoning,
            messages: messages,
            model: model,
            contextRendered: contextRendered,
            systemPrompt: systemPrompt,
            tools: tools,
            toolRounds: toolRounds
        )
    }
}
