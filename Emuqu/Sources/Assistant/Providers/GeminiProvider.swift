import Foundation

/// Streams responses from Google's Gemini API.
/// https://ai.google.dev/gemini-api/docs/text-generation
/// https://ai.google.dev/gemini-api/docs/function-calling
///
/// Tool use: Gemini models `tools` as an array of `functionDeclarations`. The
/// model replies with parts containing either `text` OR `functionCall`. We
/// return results via parts with `functionResponse` blocks.
final class GeminiProvider: KeyedCloudProvider, Sendable {
    /// Checked against ai.google.dev/gemini-api/docs/models, /pricing and
    /// /deprecations. `ProviderModelCatalogTests` pins this list.
    ///
    /// gemini-3.5-flash-lite replaces gemini-3.1-flash-lite, which Google
    /// shuts down on 7 May 2027. gemini-3.8-flash is the newest stable Flash;
    /// its price is the standing rate from 1 January 2027, and Google charges
    /// half that through 31 December 2026. Google publishes no stable Pro model, so
    /// Pro is the preview gemini-3.1-pro-preview: preview models can change
    /// and get shorter shutdown notice, and a removed ID answers 404, which
    /// reaches the chat as `.modelUnavailable`. Prices are for prompts up to
    /// 200k tokens.
    static let models: [ModelOption] = [
        ModelOption(
            providerID: .gemini,
            apiID: "gemini-3.5-flash-lite",
            displayName: "3.5 Flash-Lite",
            blurb: "Cheapest — budget",
            contextWindow: 1_048_576,
            inputPricePerMTok: 0.30,
            outputPricePerMTok: 2.50,
            isDefault: false
        ),
        ModelOption(
            providerID: .gemini,
            apiID: "gemini-3.8-flash",
            displayName: "3.8 Flash",
            blurb: "Balanced — recommended",
            contextWindow: 1_048_576,
            inputPricePerMTok: 1.50,
            outputPricePerMTok: 7.50,
            isDefault: true
        ),
        ModelOption(
            providerID: .gemini,
            apiID: "gemini-3.1-pro-preview",
            displayName: "3.1 Pro Preview",
            blurb: "Best reasoning",
            contextWindow: 1_048_576,
            inputPricePerMTok: 2.0,
            outputPricePerMTok: 12.0,
            isDefault: false
        )
    ]

    let id: ProviderID = .gemini
    let services: AIProviderServices

    init(services: AIProviderServices) {
        self.services = services
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

    // MARK: - Request body

    struct RequestBody: Encodable {
        struct Part: Encodable {
            let text: String?
            let functionCall: FunctionCall?
            let functionResponse: FunctionResponse?
            /// Echo of the signature Gemini 3 attaches to a `functionCall`
            /// part; the continuation request is rejected without it.
            let thoughtSignature: String?

            init(text: String) {
                self.text = text
                functionCall = nil
                functionResponse = nil
                thoughtSignature = nil
            }

            init(functionCall: FunctionCall, thoughtSignature: String? = nil) {
                text = nil
                self.functionCall = functionCall
                functionResponse = nil
                self.thoughtSignature = thoughtSignature
            }

            init(functionResponse: FunctionResponse) {
                text = nil
                functionCall = nil
                self.functionResponse = functionResponse
                thoughtSignature = nil
            }
        }

        struct FunctionCall: Encodable {
            let name: String
            let args: AnyJSON
        }

        struct FunctionResponse: Encodable {
            let name: String
            let response: AnyJSON
        }

        struct Content: Encodable {
            let role: String
            let parts: [Part]
        }

        struct SystemInstruction: Encodable {
            let parts: [Part]
        }

        struct Tool: Encodable {
            let functionDeclarations: [FunctionDeclaration]
        }

        struct FunctionDeclaration: Encodable {
            let name: String
            let description: String
            /// Gemini rejects a `parameters` object of `type:"object"` with an
            /// empty `properties` map — HTTP 400 "should be non-empty for OBJECT
            /// type". OpenAI/Anthropic tolerate it. The ~15 no-argument `.fixed` fact
            /// tools carry exactly that
            /// empty schema, so we OMIT `parameters` entirely for them. A nil
            /// here means "no-arg tool"; a present value always has properties.
            let parameters: ToolSpec.InputSchema?

        }

        let systemInstruction: SystemInstruction
        let contents: [Content]
        let tools: [Tool]?
    }

    // MARK: - Stream

    /// Assemble the `contents` array Gemini expects.
    ///
    /// The live-state block is spliced onto the LAST user message rather than
    /// sent as its own turn, so the stable system prefix stays byte-identical
    /// across turns and remains cacheable. When there is no user message at all,
    /// it becomes a standalone user turn so the model still sees it.
    private func buildContents(
        messages: [ChatTurn],
        toolRounds: [[ToolExchange]],
        liveStateBlock: String
    ) -> [RequestBody.Content] {
        let lastUserMessageIndex = messages.lastIndex { $0.role == .user }
        var contents: [RequestBody.Content] = messages.enumerated().map { idx, turn in
            let splice = turn.role == .user && idx == lastUserMessageIndex && !liveStateBlock.isEmpty
            return RequestBody.Content(
                role: turn.role == .user ? "user" : "model",
                parts: [.init(text: splice ? turn.text + liveStateBlock : turn.text)]
            )
        }
        // Fallback: dispatch invariant guarantees a user message exists,
        // but if the conversation ever shows up empty (recovery edge
        // case, programmatic test), drop the live state into a synthesized
        // user turn so the model still sees it.
        if lastUserMessageIndex == nil, !liveStateBlock.isEmpty {
            contents.insert(.init(role: "user", parts: [.init(text: liveStateBlock)]), at: 0)
        }
        for round in toolRounds where !round.isEmpty {
            contents.append(contentsOf: Self.toolRoundContents(round))
        }
        return contents
    }

    /// One tool round as the model/user pair every provider requires: a model
    /// turn carrying the function calls, then a user turn carrying the matching
    /// responses. A result that is not JSON (a plain-text resolver error) is
    /// sent as the text itself rather than dropped.
    private static func toolRoundContents(_ round: [ToolExchange]) -> [RequestBody.Content] {
        let callParts: [RequestBody.Part] = round.map { exchange in
            let argsObj = (try? JSONSerialization.jsonObject(with: Data(exchange.inputJSON.utf8))) as? [String: Any] ?? [:]
            return .init(
                functionCall: .init(name: exchange.toolName, args: AnyJSON(argsObj)),
                thoughtSignature: thoughtSignature(fromToolUseID: exchange.toolUseID)
            )
        }
        let responseParts: [RequestBody.Part] = round.map { exchange in
            let resultObj = (try? JSONSerialization.jsonObject(with: Data(exchange.resultJSON.utf8))) ?? exchange.resultJSON
            // Gemini wants `response: { ... }` — wrap the resolver's JSON
            // under a synthetic `result` key so Gemini's type checker
            // accepts it (functionResponse.response must be an object).
            let wrapped: [String: Any] = ["result": resultObj]
            return .init(functionResponse: .init(name: exchange.toolName, response: AnyJSON(wrapped)))
        }
        return [
            .init(role: "model", parts: callParts),
            .init(role: "user", parts: responseParts)
        ]
    }

    /// Separator between the synthesised call id and the call's thought
    /// signature. The id is opaque to the rest of the app and comes back
    /// unchanged in `ToolExchange.toolUseID`, so it carries the signature to
    /// the continuation request without widening the shared stream types.
    private static let signatureSeparator = "#sig:"

    private static func toolUseID(counter: Int, thoughtSignature: String?) -> String {
        let base = "gemini_call_\(counter)"
        guard let thoughtSignature, !thoughtSignature.isEmpty else { return base }
        return base + signatureSeparator + thoughtSignature
    }

    private static func thoughtSignature(fromToolUseID id: String) -> String? {
        guard let range = id.range(of: signatureSeparator) else { return nil }
        return String(id[range.upperBound...])
    }

    /// SSE endpoint for a streaming `generateContent` call.
    static func streamEndpoint(for model: ModelOption) throws -> URL {
        var urlComponents = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model.apiID):streamGenerateContent")
        urlComponents?.queryItems = [
            URLQueryItem(name: "alt", value: "sse")
        ]
        guard let url = urlComponents?.url else {
            throw ProviderHTTP.badEndpoint
        }
        return url
    }

    /// The prompt is split on the cache marker so the stable prefix can live
    /// in `systemInstruction` (byte-stable across turns, eligible for
    /// Gemini's explicit caching API and for automatic prefix reuse) and the
    /// variable suffix rides on the last user message instead, where per-turn
    /// drift is already expected. A per-second `nowSnapshot` inside
    /// `systemInstruction` breaks Gemini's prefix-reuse heuristics.
    private func stream(
        messages: [ChatTurn],
        model: ModelOption,
        contextRendered: String,
        systemPrompt: String,
        tools: [ToolSpec],
        toolRounds: [[ToolExchange]],
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws {
        guard let apiKey = services.apiKeyStore.key(for: .gemini) else { throw AIProviderError.missingKey(.gemini) }
        let split = ProviderHTTP.splitOnCacheMarker(systemPrompt)
        let body = RequestBody(
            systemInstruction: .init(parts: [.init(text: split.stable)]),
            contents: buildContents(
                messages: messages,
                toolRounds: toolRounds,
                liveStateBlock: ProviderHTTP.liveStateEnvelope(variableSystem: split.variable, contextRendered: contextRendered)
            ),
            tools: Self.toolDeclarations(for: tools)
        )
        let request = try Self.makeRequest(url: Self.streamEndpoint(for: model), apiKey: apiKey, body: body)
        let lines = try await ProviderHTTP.openStream(request, provider: .gemini, failure: Self.statusFailure(_:body:))
        try await Self.consumeSSE(lines, continuation: continuation)
    }

    private static func toolDeclarations(for tools: [ToolSpec]) -> [RequestBody.Tool]? {
        guard !tools.isEmpty else { return nil }
        return [.init(functionDeclarations: tools.map {
            .init(
                name: $0.name,
                description: $0.description,
                parameters: $0.inputSchema.properties.isEmpty ? nil : $0.inputSchema
            )
        })]
    }

    /// The streaming POST for one `streamGenerateContent` call, built by
    /// `ProviderHTTP.streamRequest` (sorted keys, so the prefix is
    /// byte-stable for caching) with the key in `x-goog-api-key`. Throws
    /// what encoding the body throws.
    static func makeRequest(url: URL, apiKey: String, body: RequestBody) throws -> URLRequest {
        try ProviderHTTP.streamRequest(url: url, body: body, headers: ["x-goog-api-key": apiKey])
    }

    /// Per-request SSE state. `toolUseCounter` numbers the synthesised call
    /// ids. Every chunk repeats the running `usageMetadata`; only the last
    /// one is the request's total, so it is held here and recorded once,
    /// after the stream. `finished` records that a candidate carried a
    /// `finishReason`, so a stream cut before it is not taken for a complete
    /// reply.
    struct StreamState {
        var toolUseCounter = 0
        var lastUsage: [String: Any]?
        var finished = false
    }

    /// Reads the SSE lines of one reply, then records usage and yields
    /// `.done`. The reply is complete only when a candidate carried a
    /// `finishReason`; a stream that closes before one was cut, like an
    /// Anthropic stream without `message_stop`, and throws
    /// `URLError(.networkConnectionLost)` (a dropped connection in
    /// `ProviderStream`). A cancelled task whose sequence ended cleanly
    /// throws `CancellationError` first, so Stop reads as cancellation.
    ///
    /// Usage is recorded on a failure too, from the last `usageMetadata` seen
    /// (the chunk that threw included), so tokens billed for a reply that
    /// never completed are not lost from the telemetry.
    ///
    /// Only `data:` lines are read; comments, blank lines and `event:` lines
    /// are skipped. Takes the line sequence rather than the URL session's
    /// bytes so tests can feed it a reply.
    static func consumeSSE<Lines: AsyncSequence>(
        _ lines: Lines,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws where Lines.Element == String {
        var state = StreamState()
        do {
            try await readChunks(lines, state: &state, continuation: continuation)
        } catch {
            yieldUsage(state.lastUsage, to: continuation)
            throw error
        }
        yieldUsage(state.lastUsage, to: continuation)
        try Task.checkCancellation()
        guard state.finished else { throw URLError(.networkConnectionLost) }
        continuation.yield(.done)
    }

    /// Each non-empty `data:` payload `SSEEvents` reads, parsed and handed
    /// to `handleChunk`. Throws what reading, cancellation, parsing or a
    /// chunk throws.
    private static func readChunks<Lines: AsyncSequence>(
        _ lines: Lines,
        state: inout StreamState,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws where Lines.Element == String {
        for try await event in SSEEvents(lines) {
            let json = try ProviderHTTP.eventObject(Data(event.data.utf8), provider: .gemini)
            try handleChunk(json, state: &state, continuation: continuation)
        }
    }

    /// One chunk: an error object or a blocked prompt throws; a finish
    /// reason that ends the reply as a failure throws (`stopFailure`) before
    /// the chunk's parts are shown; otherwise each part becomes a text delta
    /// or a tool call, and a `MAX_TOKENS` stop ends the text with "…", as
    /// Anthropic's `max_tokens` does.
    ///
    /// Gemini emits functionCall parts atomically — the whole call is in
    /// one part, not streamed. We synthesise a stable ID from the call's
    /// index since Gemini doesn't supply one, and append the part's
    /// `thoughtSignature` when present (see `signatureSeparator`).
    private static func handleChunk(
        _ json: [String: Any],
        state: inout StreamState,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) throws {
        state.lastUsage = json["usageMetadata"] as? [String: Any] ?? state.lastUsage
        if let failure = ProviderHTTP.streamFailure(in: json, provider: .gemini) ?? blockedPrompt(in: json) { throw failure }
        let reason = finishReason(in: json)
        if let reason, let failure = stopFailure(reason) { throw failure }
        for part in Self.contentParts(in: json) {
            yieldPart(part, counter: &state.toolUseCounter, continuation: continuation)
        }
        if reason == "MAX_TOKENS" {
            debugLog("[Gemini] reply stopped early: finishReason=MAX_TOKENS", level: .warning)
            continuation.yield(.textDelta("…"))
        }
        if reason != nil { state.finished = true }
    }

    /// `candidates[0].finishReason`, or nil while the reply is still coming.
    private static func finishReason(in json: [String: Any]) -> String? {
        (json["candidates"] as? [[String: Any]])?.first?["finishReason"] as? String
    }

    /// The error a finish reason ends the reply with, or nil when it ends
    /// normally (`STOP`, `MAX_TOKENS` and any other reason). The safety
    /// stops (`SAFETY`, `RECITATION`, `BLOCKLIST`, `PROHIBITED_CONTENT`,
    /// `SPII`) are `AIProviderError.blockedReply`; `MALFORMED_FUNCTION_CALL`
    /// means the model's tool call could not be parsed, so it is an invalid
    /// response and no tool runs.
    private static func stopFailure(_ reason: String) -> AIProviderError? {
        switch reason {
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII":
            return AIProviderError.blockedReply(provider: .gemini, reason: reason)
        case "MALFORMED_FUNCTION_CALL":
            return AIProviderError.invalidResponse("Gemini sent a malformed function call")
        default:
            return nil
        }
    }

    /// A chunk that says the prompt was blocked (`promptFeedback.blockReason`
    /// with no candidates) as an error, so a blocked reply does not end as an
    /// empty success. Nil for any other chunk.
    ///
    /// Every block reason (`SAFETY`, `BLOCKLIST`, `PROHIBITED_CONTENT`,
    /// `OTHER` …) is Gemini's safety system turning the request down, so it
    /// is `AIProviderError.blockedReply` like the safety finish reasons: the
    /// refusal is shown and the request is not sent on to another provider.
    private static func blockedPrompt(in json: [String: Any]) -> AIProviderError? {
        guard json["candidates"] == nil,
              let reason = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String else { return nil }
        return .blockedReply(provider: .gemini, reason: reason)
    }

    /// The `candidates[0].content.parts` array, or empty when the chunk
    /// carries no content (usage-only chunks, keep-alives).
    private static func contentParts(in json: [String: Any]) -> [[String: Any]] {
        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return [] }
        return parts
    }

    /// One content part as a stream event: text delta or synthesised tool use.
    private static func yieldPart(
        _ part: [String: Any],
        counter: inout Int,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) {
        if let text = part["text"] as? String, !text.isEmpty {
            continuation.yield(.textDelta(text))
            return
        }
        guard let call = part["functionCall"] as? [String: Any],
              let name = call["name"] as? String else { return }
        let args = call["args"] as? [String: Any] ?? [:]
        let argsJSON = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        counter += 1
        let id = toolUseID(counter: counter, thoughtSignature: part["thoughtSignature"] as? String)
        continuation.yield(.toolUse(id: id, name: name, inputJSON: argsJSON))
    }

    /// Gemini's implicit cache reports via `cachedContentTokenCount`.
    /// `promptTokenCount` already includes the cached tokens, while
    /// `.usage`'s `inputTokens` is the uncached part (Anthropic's shape, which
    /// the cache-hit ratio assumes), so the cached count is taken out.
    /// Output is the reply plus the thinking tokens, which Gemini reports
    /// separately (`thoughtsTokenCount`) and bills as output.
    private static func yieldUsage(
        _ usage: [String: Any]?,
        to continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) {
        guard let usage else { return }
        let cachedCount = usage["cachedContentTokenCount"] as? Int ?? 0
        let input = max(0, (usage["promptTokenCount"] as? Int ?? 0) - cachedCount)
        let output = (usage["candidatesTokenCount"] as? Int ?? 0) + (usage["thoughtsTokenCount"] as? Int ?? 0)
        ProviderHTTP.yieldUsage(input: input, output: output, cached: cachedCount, to: continuation)
    }

    /// The error a non-2xx reply becomes. Gemini answers a bad API key with
    /// HTTP 400 (`INVALID_ARGUMENT`, reason `API_KEY_INVALID`), not 401, so
    /// that case is read from the body before the shared status mapping.
    static func statusFailure(_ status: Int, body: Data) -> AIProviderError {
        ProviderHTTP.statusFailure(status, body: body, provider: .gemini) { status, _, text in
            status == 400 && text.contains("API_KEY_INVALID") ? .authFailed : nil
        }
    }
}

// `CodingKeys` + `encode` live in an extension so the declaration nesting stays
// two deep — `GeminiProvider.RequestBody.FunctionDeclaration` is already two
// levels in. Same encoded JSON; only the declaration site differs.
extension GeminiProvider.RequestBody.FunctionDeclaration {
        enum CodingKeys: String, CodingKey {
            case name, description, parameters
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(description, forKey: .description)
            try container.encodeIfPresent(parameters, forKey: .parameters)
        }
}
