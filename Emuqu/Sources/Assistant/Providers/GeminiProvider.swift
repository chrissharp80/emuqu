import Foundation

/// Streams responses from Google's Gemini API.
/// https://ai.google.dev/gemini-api/docs/text-generation
/// https://ai.google.dev/gemini-api/docs/function-calling
///
/// Tool use: Gemini models `tools` as an array of `functionDeclarations`. The
/// model replies with parts containing either `text` OR `functionCall`. We
/// return results via parts with `functionResponse` blocks.
final class GeminiProvider: AIProvider, Sendable {
    /// Same tuned session pattern as
    /// `OpenAICompatibleStreamer` and `AnthropicProvider`. Not
    /// `URLSession.shared`, which fails fast on
    /// cellular handoffs and surfaces "Gemini cannot connect" the
    /// instant a tower hands the radio off.
    private static let streamSession: URLSession = {
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

    static let models: [ModelOption] = [
        ModelOption(
            providerID: .gemini,
            apiID: "gemini-3.1-flash-lite",
            displayName: "3.1 Flash-Lite",
            blurb: "Cheapest — budget",
            contextWindow: 1_000_000,
            inputPricePerMTok: 0.10,
            outputPricePerMTok: 0.40,
            isDefault: false
        ),
        ModelOption(
            providerID: .gemini,
            apiID: "gemini-3-flash",
            displayName: "3 Flash",
            blurb: "Balanced — recommended",
            contextWindow: 1_000_000,
            inputPricePerMTok: 0.30,
            outputPricePerMTok: 2.50,
            isDefault: true
        ),
        ModelOption(
            providerID: .gemini,
            apiID: "gemini-3.1-pro",
            displayName: "3.1 Pro",
            blurb: "Best reasoning",
            contextWindow: 2_000_000,
            inputPricePerMTok: 2.0,
            outputPricePerMTok: 15.0,
            isDefault: false
        )
    ]

    let id: ProviderID = .gemini
    var availableModels: [ModelOption] {
        Self.models
    }

    var requiresKey: Bool {
        true
    }

    var isAvailable: Bool {
        AppDependencies.current.providers.apiKeyStore.hasKey(for: .gemini)
    }

    func send(
        messages: [ChatTurn],
        model: ModelOption,
        contextRendered: String,
        systemPrompt: String,
        tools: [ToolSpec],
        toolRounds: [[ToolExchange]]
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.streamAndFinish(
                    messages: messages, model: model, contextRendered: contextRendered,
                    systemPrompt: systemPrompt, tools: tools, toolRounds: toolRounds,
                    continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Runs the provider stream and closes the continuation exactly once —
    /// normally, as `.cancelled` when the task was cancelled, or with the
    /// underlying error.
    private func streamAndFinish(
        messages: [ChatTurn],
        model: ModelOption,
        contextRendered: String,
        systemPrompt: String,
        tools: [ToolSpec],
        toolRounds: [[ToolExchange]],
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async {
        do {
            try await stream(
                messages: messages, model: model, contextRendered: contextRendered,
                systemPrompt: systemPrompt, tools: tools, toolRounds: toolRounds,
                continuation: continuation
            )
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: AIProviderError.cancelled)
        } catch {
            continuation.finish(throwing: error)
        }
    }

    // MARK: - Request body

    struct RequestBody: Encodable {
        struct Part: Encodable {
            let text: String?
            let functionCall: FunctionCall?
            let functionResponse: FunctionResponse?

            init(text: String) {
                self.text = text
                functionCall = nil
                functionResponse = nil
            }

            init(functionCall: FunctionCall) {
                text = nil
                self.functionCall = functionCall
                functionResponse = nil
            }

            init(functionResponse: FunctionResponse) {
                text = nil
                functionCall = nil
                self.functionResponse = functionResponse
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
            /// type". OpenAI/Anthropic tolerate it, which is why only Gemini
            /// broke. The ~15 no-argument `.fixed` fact tools carry exactly that
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
    /// responses.
    private static func toolRoundContents(_ round: [ToolExchange]) -> [RequestBody.Content] {
        let callParts: [RequestBody.Part] = round.map { exchange in
            let argsObj = (try? JSONSerialization.jsonObject(with: Data(exchange.inputJSON.utf8))) as? [String: Any] ?? [:]
            return .init(functionCall: .init(name: exchange.toolName, args: AnyJSON(argsObj)))
        }
        let responseParts: [RequestBody.Part] = round.map { exchange in
            let resultObj = (try? JSONSerialization.jsonObject(with: Data(exchange.resultJSON.utf8))) ?? [String: Any]()
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

    /// SSE endpoint for a streaming `generateContent` call.
    private static func streamEndpoint(for model: ModelOption) throws -> URL {
        var urlComponents = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model.apiID):streamGenerateContent")
        urlComponents?.queryItems = [
            URLQueryItem(name: "alt", value: "sse")
        ]
        guard let url = urlComponents?.url else {
            throw AIProviderError.invalidResponse("bad endpoint")
        }
        return url
    }

    private func stream(
        messages: [ChatTurn],
        model: ModelOption,
        contextRendered: String,
        systemPrompt: String,
        tools: [ToolSpec],
        toolRounds: [[ToolExchange]],
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws {
        guard let apiKey = AppDependencies.current.providers.apiKeyStore.key(for: .gemini) else { throw AIProviderError.missingKey(.gemini) }
        let split = Self.splitOnCacheMarker(systemPrompt)
        let body = RequestBody(
            systemInstruction: .init(parts: [.init(text: split.stable)]),
            contents: buildContents(
                messages: messages,
                toolRounds: toolRounds,
                liveStateBlock: Self.liveStateBlock(variableSystem: split.variable, contextRendered: contextRendered)
            ),
            tools: Self.toolDeclarations(for: tools)
        )
        let request = try Self.makeRequest(url: Self.streamEndpoint(for: model), apiKey: apiKey, body: body)
        let (bytes, response) = try await Self.streamSession.bytes(for: request)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            try await Self.throwForStatus(http.statusCode, bytes: bytes)
        }
        try await Self.consumeSSE(bytes, continuation: continuation)
        continuation.yield(.done)
    }

    /// Split on the cache marker so the stable prefix
    /// can live in `systemInstruction` (byte-stable across turns,
    /// eligible for Gemini's explicit caching API and for any
    /// automatic prefix reuse within a conversation) and the
    /// variable suffix rides on the last user message instead,
    /// where per-turn drift is already expected. Same pattern as
    /// AnthropicProvider's `<live_state>` splice and
    /// OpenAICompatibleStreamer. A per-second `nowSnapshot` inside
    /// `systemInstruction` breaks Gemini's prefix-reuse heuristics on
    /// every send.
    private static func splitOnCacheMarker(_ systemPrompt: String) -> (stable: String, variable: String) {
        let marker = AssistantSystemPrompt.Composed.cacheSplitMarker
        let parts = systemPrompt.components(separatedBy: marker)
        let variable = parts.count > 1 ? parts.dropFirst().joined(separator: marker) : ""
        return (parts.first ?? systemPrompt, variable)
    }

    /// The `<live_state>` envelope appended to the last user message, or an
    /// empty string when there's nothing per-turn to carry.
    private static func liveStateBlock(variableSystem: String, contextRendered: String) -> String {
        let body = [variableSystem, contextRendered].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return body.isEmpty ? "" : "\n\n<live_state>\n\(body)\n</live_state>"
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

    /// `.sortedKeys` for cache-stable prefix serialisation.
    private static func makeRequest(url: URL, apiKey: String, body: RequestBody) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// Gemini emits functionCall parts atomically — the whole call is in
    /// one part, not streamed. We synthesise a stable ID from name+index
    /// since Gemini doesn't supply one.
    private static func consumeSSE(
        _ bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws {
        var toolUseCounter = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for part in Self.contentParts(in: json) {
                yieldPart(part, counter: &toolUseCounter, continuation: continuation)
            }
            yieldUsage(json["usageMetadata"] as? [String: Any], to: continuation)
        }
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
        continuation.yield(.toolUse(id: "gemini_call_\(counter)", name: name, inputJSON: argsJSON))
    }

    /// Gemini's implicit cache reports via `cachedContentTokenCount`.
    private static func yieldUsage(
        _ usage: [String: Any]?,
        to continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) {
        guard let usage else { return }
        let input = usage["promptTokenCount"] as? Int ?? 0
        let output = usage["candidatesTokenCount"] as? Int ?? 0
        let cached = usage["cachedContentTokenCount"] as? Int ?? 0
        guard input > 0 || output > 0 || cached > 0 else { return }
        continuation.yield(.usage(
            inputTokens: input, outputTokens: output,
            cachedInputTokens: cached, cacheCreationInputTokens: 0
        ))
    }

    private static func throwForStatus(_ status: Int, bytes: URLSession.AsyncBytes) async throws -> Never {
        var collected = Data()
        for try await byte in bytes {
            collected.append(byte)
            if collected.count >= 4096 { break }
        }
        let bodyText = redactAPIKeys(String(data: collected, encoding: .utf8) ?? "")
        switch status {
        case 401, 403: throw AIProviderError.authFailed
        case 429: throw AIProviderError.rateLimited
        case 404: throw AIProviderError.modelUnavailable(bodyText)
        default: throw AIProviderError.invalidResponse("HTTP \(status): \(bodyText)")
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
