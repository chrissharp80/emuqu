@testable import Emuqu
import XCTest

/// How a cloud provider's failure reaches the chat. Anthropic, Gemini and
/// the OpenAI-compatible streamer (OpenAI, Grok, DeepSeek) all build their
/// streams with `ProviderStream.make`, so these cases hold for every client.
final class ProviderStreamTests: XCTestCase {
    private enum Unrelated: Error { case failure }

    /// Drains `stream` and returns the error it finished with, or nil.
    private func finishingError(of stream: AsyncThrowingStream<AIStreamEvent, Error>) async -> Error? {
        do {
            for try await _ in stream {}
            return nil
        } catch {
            return error
        }
    }

    private func failure(thrown: any Error & Sendable) async -> Error? {
        await finishingError(of: ProviderStream.make { _ in throw thrown })
    }

    /// Offline: the error is `.network`, which the fallback chain acts on,
    /// not the system's bare URLError text.
    func testOfflineBecomesAFallbackableNetworkError() async throws {
        let error = await failure(thrown: URLError(.notConnectedToInternet))
        let providerError = try XCTUnwrap(error as? AIProviderError)
        guard case .network = providerError else { return XCTFail("offline mapped to \(providerError)") }
        XCTAssertTrue(providerError.isFallbackable)
    }

    func testTimeoutAndDroppedConnectionBecomeNetworkErrors() async {
        for code in [URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost] {
            let error = await failure(thrown: URLError(code))
            guard case .network = error as? AIProviderError else {
                XCTFail("\(code.rawValue) mapped to \(String(describing: error))")
                continue
            }
        }
    }

    /// Stop cancels the URL load; that is `.cancelled`, never shown as a failure.
    func testCancelledURLLoadBecomesCancelled() async {
        let error = await failure(thrown: URLError(.cancelled))
        guard case .cancelled = error as? AIProviderError else {
            return XCTFail("URLError.cancelled mapped to \(String(describing: error))")
        }
    }

    func testTaskCancellationBecomesCancelled() async {
        let error = await failure(thrown: CancellationError())
        guard case .cancelled = error as? AIProviderError else {
            return XCTFail("CancellationError mapped to \(String(describing: error))")
        }
    }

    /// A provider's own error (bad key, rate limit, …) passes through as it is.
    func testProviderErrorsPassThrough() async {
        let error = await failure(thrown: AIProviderError.rateLimited)
        guard case .rateLimited = error as? AIProviderError else {
            return XCTFail("rateLimited mapped to \(String(describing: error))")
        }
        let other = await failure(thrown: Unrelated.failure)
        XCTAssertEqual(other as? Unrelated, .failure)
    }

    /// A cloud vendor's safety stop stands, like Apple's guardrail: it is
    /// never handed to another provider.
    func testBlockedReplyIsNotFallbackable() {
        for provider in [ProviderID.anthropic, .openai, .gemini, .grok, .deepseek] {
            let blocked = AIProviderError.blockedReply(provider: provider, reason: "SAFETY")
            XCTAssertFalse(blocked.isFallbackable, "\(provider)")
            XCTAssertTrue(blocked.isBlockedReply)
            XCTAssertFalse(blocked.isAppleGuardrail)
        }
    }

    func testEventsThenNormalFinish() async throws {
        let stream = ProviderStream.make { continuation in
            continuation.yield(.textDelta("hi"))
            continuation.yield(.done)
        }
        var texts: [String] = []
        for try await event in stream {
            if case let .textDelta(text) = event { texts.append(text) }
        }
        XCTAssertEqual(texts, ["hi"])
    }

    /// When the consumer stops listening, the provider's request task is cancelled.
    func testConsumerLeavingCancelsTheRequest() async {
        let cancelled = expectation(description: "operation cancelled")
        let consumer = Task {
            let stream = ProviderStream.make { _ in
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    cancelled.fulfill()
                    throw error
                }
            }
            for try await _ in stream {}
        }
        consumer.cancel()
        await fulfillment(of: [cancelled], timeout: 5)
    }
}

/// The error a non-2xx reply becomes, through each provider's production
/// mapping (`statusFailure`), which all run the shared
/// `ProviderHTTP.statusFailure`.
final class ProviderStatusFailureTests: XCTestCase {
    /// A body with no readable `error.message` reaches the chat as at most
    /// `ProviderHTTP.errorExcerptLength` characters, for every provider.
    func testRawBodyIsCappedForEveryProvider() {
        let body = Data(String(repeating: "x", count: 4000).utf8)
        let excerpt = String(repeating: "x", count: ProviderHTTP.errorExcerptLength)
        let failures = [
            AnthropicProvider.statusFailure(418, body: body),
            GeminiProvider.statusFailure(418, body: body),
            OpenAICompatibleStreamer.statusFailure(418, body: body, providerID: .openai)
        ]
        for failure in failures {
            guard case let .invalidResponse(message) = failure else { return XCTFail("418 mapped to \(failure)") }
            XCTAssertEqual(message, "HTTP 418: \(excerpt)")
        }
        let notFound = OpenAICompatibleStreamer.statusFailure(404, body: body, providerID: .deepseek)
        guard case let .modelUnavailable(notFoundText) = notFound else { return XCTFail("404 mapped to \(notFound)") }
        XCTAssertEqual(notFoundText, excerpt)
    }

    /// An OpenAI-style 400 whose `param` is "model" means the model is
    /// missing or closed to this key; any other 400 shows the vendor's
    /// sentence, not the JSON around it.
    func testOpenAIBadRequestReadsTheEnvelope() {
        let model = OpenAICompatibleStreamer.statusFailure(
            400, body: Data(#"{"error":{"message":"The model `gpt-x` does not exist","param":"model"}}"#.utf8),
            providerID: .openai
        )
        guard case let .modelUnavailable(text) = model else { return XCTFail("model 400 mapped to \(model)") }
        XCTAssertTrue(text.contains("The model `gpt-x` does not exist"), text)

        let other = OpenAICompatibleStreamer.statusFailure(
            400, body: Data(#"{"error":{"message":"max_tokens is too large","param":"max_tokens"}}"#.utf8),
            providerID: .grok
        )
        guard case let .invalidResponse(otherText) = other else { return XCTFail("other 400 mapped to \(other)") }
        XCTAssertEqual(otherText, "max_tokens is too large")
    }

    /// Gemini answers a bad key with 400 `API_KEY_INVALID`, which is an
    /// auth failure; another 400 is not.
    func testGeminiInvalidKeyIsAnAuthFailure() {
        let badKey = GeminiProvider.statusFailure(
            400, body: Data(#"{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#.utf8)
        )
        guard case .authFailed = badKey else { return XCTFail("API_KEY_INVALID mapped to \(badKey)") }
        let other = GeminiProvider.statusFailure(400, body: Data(#"{"error":{"message":"Invalid JSON payload"}}"#.utf8))
        guard case let .invalidResponse(text) = other else { return XCTFail("other 400 mapped to \(other)") }
        XCTAssertEqual(text, "HTTP 400: Invalid JSON payload")
    }

    /// An account with no credit is `.outOfCredit` for its own provider,
    /// whatever status the vendor sends it with, ahead of the rate-limit and
    /// auth mappings.
    func testCreditExhaustionWinsOverTheStatus() {
        let openAI = OpenAICompatibleStreamer.statusFailure(
            429, body: Data(#"{"error":{"message":"You exceeded your current quota","code":"insufficient_quota"}}"#.utf8),
            providerID: .openai
        )
        guard case .outOfCredit(.openai) = openAI else { return XCTFail("insufficient_quota mapped to \(openAI)") }
        let anthropic = AnthropicProvider.statusFailure(
            400, body: Data(#"{"error":{"message":"Your credit balance is too low to access the Anthropic API."}}"#.utf8)
        )
        guard case .outOfCredit(.anthropic) = anthropic else { return XCTFail("credit balance mapped to \(anthropic)") }
        let gemini = GeminiProvider.statusFailure(402, body: Data())
        guard case .outOfCredit(.gemini) = gemini else { return XCTFail("402 mapped to \(gemini)") }
    }

    /// The plain statuses map the same way for every provider.
    func testSharedStatusesMapAlike() {
        let body = Data(#"{"error":{"message":"nope"}}"#.utf8)
        for failure in [
            AnthropicProvider.statusFailure(401, body: body),
            GeminiProvider.statusFailure(403, body: body),
            OpenAICompatibleStreamer.statusFailure(401, body: body, providerID: .deepseek)
        ] {
            guard case .authFailed = failure else { return XCTFail("auth status mapped to \(failure)") }
        }
        guard case .rateLimited = GeminiProvider.statusFailure(429, body: body) else { return XCTFail("429") }
        guard case .modelUnavailable = AnthropicProvider.statusFailure(529, body: body) else { return XCTFail("529") }
    }
}

/// The reasoning fields each OpenAI-compatible provider sends. Flo's tool
/// rounds carry only calls and results, so a model whose API needs its
/// reasoning echoed between rounds must run with reasoning off.
final class OpenAICompatibleReasoningTests: XCTestCase {
    private func body(for reasoning: OpenAICompatibleStreamer.Reasoning) throws -> [String: Any] {
        let endpoint = try XCTUnwrap(URL(string: "https://example.invalid/chat/completions"))
        let call = OpenAICompatibleStreamer.StreamCall(
            providerID: .deepseek, endpoint: endpoint, reasoning: reasoning,
            messages: [ChatTurn(role: .user, text: "How did I sleep?")],
            model: DeepSeekProvider.models[0], contextRendered: "", systemPrompt: "rules",
            tools: [], toolRounds: []
        )
        let request = try OpenAICompatibleStreamer.requestFor(call, apiKey: "test-key")
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// DeepSeek thinks by default and then demands `reasoning_content` back
    /// on the next tool round (HTTP 400 otherwise), so it is sent thinking off.
    func testDeepSeekTurnsThinkingOff() throws {
        XCTAssertEqual(DeepSeekProvider.reasoning, .thinkingDisabled)
        let json = try body(for: DeepSeekProvider.reasoning)
        XCTAssertEqual((json["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertNil(json["reasoning_effort"])
    }

    /// gpt-6-luna takes tools on Chat Completions only at effort "none".
    func testOpenAISendsReasoningEffortNone() throws {
        XCTAssertEqual(OpenAIProvider.reasoning, .effortNone)
        let json = try body(for: OpenAIProvider.reasoning)
        XCTAssertEqual(json["reasoning_effort"] as? String, "none")
        XCTAssertNil(json["thinking"])
    }

    func testGrokSendsNoReasoningField() throws {
        XCTAssertEqual(GrokProvider.reasoning, .modelDefault)
        let json = try body(for: GrokProvider.reasoning)
        XCTAssertNil(json["thinking"])
        XCTAssertNil(json["reasoning_effort"])
    }
}

// MARK: - End of stream

/// Replays a server-sent-events reply through a provider's line reader,
/// wrapped in `ProviderStream` as the provider wraps it, and records what
/// the chat layer would receive.
enum SSEReplay {
    struct Outcome {
        var text = ""
        var toolNames: [String] = []
        var toolInputs: [String] = []
        /// One entry per `.usage` event.
        var inputTokens: [Int] = []
        var outputTokens: [Int] = []
        var endedWithDone = false
        var error: Error?

        var asProviderError: AIProviderError? {
            error as? AIProviderError
        }

        var invalidResponseMessage: String? {
            guard case let .invalidResponse(message) = asProviderError else { return nil }
            return message
        }

        /// "<provider>: <reason>" for a `.blockedReply`, or nil.
        var blockedReply: String? {
            guard case let .blockedReply(provider, reason) = asProviderError else { return nil }
            return "\(provider.rawValue): \(reason)"
        }

        var isNetworkError: Bool {
            guard case .network = asProviderError else { return false }
            return true
        }

        var isModelUnavailable: Bool {
            guard case .modelUnavailable = asProviderError else { return false }
            return true
        }
    }

    static func lines(_ lines: [String]) -> AsyncStream<String> {
        AsyncStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }

    static func run(
        _ operation: @escaping @Sendable (ProviderStream.Continuation) async throws -> Void
    ) async -> Outcome {
        var outcome = Outcome()
        do {
            for try await event in ProviderStream.make(operation) {
                switch event {
                case let .textDelta(text):
                    outcome.text += text
                case let .toolUse(_, name, inputJSON):
                    outcome.toolNames.append(name)
                    outcome.toolInputs.append(inputJSON)
                case let .usage(input, output, _, _):
                    outcome.inputTokens.append(input)
                    outcome.outputTokens.append(output)
                case .done:
                    outcome.endedWithDone = true
                }
            }
        } catch {
            outcome.error = error
        }
        return outcome
    }
}

/// OpenAI, Grok and DeepSeek share `OpenAICompatibleStreamer`: a reply is
/// complete only after `[DONE]` or a finish reason, and a cut or broken
/// stream never reads as a finished answer or runs a cut tool call.
final class OpenAICompatibleEndOfStreamTests: XCTestCase {
    private func replay(_ lines: [String], provider: ProviderID = .openai) async -> SSEReplay.Outcome {
        let feed = SSEReplay.lines(lines)
        return await SSEReplay.run { continuation in
            try await OpenAICompatibleStreamer.consumeSSE(feed, providerID: provider, continuation: continuation)
        }
    }

    private func textChunk(_ content: String, finish: String? = nil) -> String {
        let reason = finish.map { "\"\($0)\"" } ?? "null"
        return #"data: {"choices":[{"delta":{"content":"\#(content)"},"finish_reason":\#(reason)}]}"#
    }

    private func toolFragment(_ arguments: String, finish: String? = nil) -> String {
        let reason = finish.map { "\"\($0)\"" } ?? "null"
        let escaped = arguments.replacingOccurrences(of: "\"", with: "\\\"")
        return #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_sleep","arguments":"\#(escaped)"}}]},"finish_reason":\#(reason)}]}"#
    }

    func testCleanEOFWithoutATerminalSignalIsADroppedConnection() async {
        let outcome = await replay([textChunk("Your sleep was")])
        XCTAssertEqual(outcome.text, "Your sleep was")
        XCTAssertFalse(outcome.endedWithDone)
        XCTAssertTrue(outcome.isNetworkError, "\(String(describing: outcome.error))")
    }

    func testDoneSentinelCompletesTheReply() async {
        let outcome = await replay([textChunk("Slept well."), textChunk("", finish: "stop"), "data: [DONE]"])
        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.endedWithDone)
        XCTAssertEqual(outcome.text, "Slept well.")
    }

    /// A compatible server that leaves `[DONE]` out still sends the finish reason.
    func testFinishReasonWithoutDoneCompletesTheReply() async {
        let outcome = await replay([textChunk("Slept well.", finish: "stop")], provider: .deepseek)
        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.endedWithDone)
    }

    /// Keep-alive comments, blank lines and `event:` lines are not payloads.
    func testCommentsAndBlankLinesAreIgnored() async {
        let outcome = await replay([": keep-alive", "", "event: message", textChunk("Hi.", finish: "stop"), "", "data: [DONE]"])
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.text, "Hi.")
    }

    func testMalformedEventThrows() async {
        let broken = await replay([textChunk("Hi"), #"data: {"choices":[{"delta""#, "data: [DONE]"])
        XCTAssertEqual(broken.invalidResponseMessage, "malformed OpenAI stream event")
        let notAnObject = await replay(["data: 42", "data: [DONE]"], provider: .grok)
        XCTAssertEqual(notAnObject.invalidResponseMessage, "malformed xAI stream event")
    }

    func testLengthStopEndsWithTheTruncationMarker() async {
        let outcome = await replay([textChunk("Your HRV was", finish: "length"), "data: [DONE]"])
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.text, "Your HRV was…")
        XCTAssertTrue(outcome.endedWithDone)
    }

    /// A server that repeats the finish reason in a later chunk gets one
    /// marker, not two.
    func testRepeatedLengthStopAddsOneMarker() async {
        let outcome = await replay([textChunk("Your HRV was", finish: "length"), textChunk("", finish: "length"), "data: [DONE]"])
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.text, "Your HRV was…")
    }

    func testContentFilterIsABlockedReply() async {
        let outcome = await replay([textChunk("Partial", finish: "content_filter"), "data: [DONE]"])
        XCTAssertEqual(outcome.blockedReply, "openai: content_filter")
        XCTAssertFalse(outcome.endedWithDone)
    }

    func testToolCallCutByALengthStopDoesNotRun() async {
        let outcome = await replay([toolFragment(#"{"days":"#), toolFragment("", finish: "length"), "data: [DONE]"])
        XCTAssertTrue(outcome.toolNames.isEmpty)
        XCTAssertEqual(outcome.invalidResponseMessage, "the reply hit its length limit inside a tool call")
    }

    func testUnparseableToolArgumentsAtDoneDoNotRun() async {
        let outcome = await replay([toolFragment(#"{"days":"#), "data: [DONE]"])
        XCTAssertTrue(outcome.toolNames.isEmpty)
        XCTAssertEqual(outcome.invalidResponseMessage, "tool call get_sleep arrived with incomplete arguments")
    }

    func testCompleteToolCallIsEmitted() async {
        let outcome = await replay([toolFragment(#"{"days":"#), toolFragment("7}", finish: "tool_calls"), "data: [DONE]"])
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.toolNames, ["get_sleep"])
        XCTAssertEqual(outcome.toolInputs, [#"{"days":7}"#])
    }

    /// The same server condition gives the same error before and after the
    /// stream opened: a mid-stream server error and DeepSeek's out-of-capacity
    /// stop both read as the overloaded `modelUnavailable` a 5xx gives.
    func testServerFailureMidStreamIsOverloaded() async {
        let serverError = await replay([#"data: {"error":{"message":"boom","type":"server_error"}}"#])
        XCTAssertTrue(serverError.isModelUnavailable, "\(String(describing: serverError.error))")
        let noCapacity = await replay([textChunk("Hi", finish: "insufficient_system_resource")], provider: .deepseek)
        XCTAssertTrue(noCapacity.isModelUnavailable, "\(String(describing: noCapacity.error))")
    }
}

/// Gemini's reply is complete only when a candidate carries a
/// `finishReason`, and that reason decides how it ends.
final class GeminiEndOfStreamTests: XCTestCase {
    private func replay(_ lines: [String]) async -> SSEReplay.Outcome {
        let feed = SSEReplay.lines(lines)
        return await SSEReplay.run { continuation in
            try await GeminiProvider.consumeSSE(feed, continuation: continuation)
        }
    }

    private func chunk(text: String, finish: String? = nil) -> String {
        let reason = finish.map { #","finishReason":"\#($0)""# } ?? ""
        return #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":"\#(text)"}]}\#(reason)}]}"#
    }

    func testCleanEOFWithoutAFinishReasonIsADroppedConnection() async {
        let outcome = await replay([chunk(text: "Your sleep was")])
        XCTAssertEqual(outcome.text, "Your sleep was")
        XCTAssertFalse(outcome.endedWithDone)
        XCTAssertTrue(outcome.isNetworkError, "\(String(describing: outcome.error))")
    }

    func testStopCompletesTheReply() async {
        let outcome = await replay([": ping", "", chunk(text: "Slept "), chunk(text: "well.", finish: "STOP")])
        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.endedWithDone)
        XCTAssertEqual(outcome.text, "Slept well.")
    }

    func testMalformedEventThrows() async {
        let outcome = await replay([chunk(text: "Hi"), #"data: {"candidates":["#, chunk(text: "", finish: "STOP")])
        XCTAssertEqual(outcome.invalidResponseMessage, "malformed Google stream event")
        XCTAssertFalse(outcome.endedWithDone)
    }

    func testMaxTokensEndsWithTheTruncationMarker() async {
        let outcome = await replay([chunk(text: "Your HRV was", finish: "MAX_TOKENS")])
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.text, "Your HRV was…")
        XCTAssertTrue(outcome.endedWithDone)
    }

    func testSafetyStopIsABlockedReply() async {
        for reason in ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII"] {
            let outcome = await replay([chunk(text: "Partial "), chunk(text: "hidden", finish: reason)])
            XCTAssertEqual(outcome.blockedReply, "gemini: \(reason)")
            XCTAssertEqual(outcome.text, "Partial ", "the blocked chunk's text must not be shown")
            XCTAssertFalse(outcome.endedWithDone)
        }
    }

    /// A prompt Gemini's safety system blocks before any reply is a safety
    /// stop too, so the fallback chain does not send it to another vendor
    /// (`AIProviderError.isFallbackable` is false for it).
    func testBlockedPromptIsABlockedReply() async {
        for reason in ["SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "OTHER"] {
            let outcome = await replay([#"data: {"promptFeedback":{"blockReason":"\#(reason)"}}"#])
            XCTAssertEqual(outcome.blockedReply, "gemini: \(reason)")
            XCTAssertFalse(outcome.endedWithDone)
        }
        XCTAssertFalse(AIProviderError.blockedReply(provider: .gemini, reason: "SAFETY").isFallbackable)
    }

    func testMalformedFunctionCallDoesNotRunATool() async {
        let call = #"{"functionCall":{"name":"get_sleep","args":{"days":7}}}"#
        let outcome = await replay([#"data: {"candidates":[{"content":{"role":"model","parts":[\#(call)]},"finishReason":"MALFORMED_FUNCTION_CALL"}]}"#])
        XCTAssertTrue(outcome.toolNames.isEmpty)
        XCTAssertEqual(outcome.invalidResponseMessage, "Gemini sent a malformed function call")
    }

    func testFunctionCallWithAFinishReasonIsEmitted() async {
        let call = #"data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"get_sleep","args":{"days":7}}}]},"finishReason":"STOP"}]}"#
        let outcome = await replay([call])
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.toolNames, ["get_sleep"])
    }

    func testServerFailureMidStreamIsOverloaded() async {
        let outcome = await replay([#"data: {"error":{"code":503,"message":"The model is overloaded.","status":"UNAVAILABLE"}}"#])
        XCTAssertTrue(outcome.isModelUnavailable, "\(String(describing: outcome.error))")
    }

    /// Tokens billed before a failure are still reported: the last
    /// `usageMetadata` seen when a later event throws.
    func testFailureMidStreamStillReportsUsage() async {
        let withUsage = #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Partial "}]}}],"usageMetadata":{"promptTokenCount":200,"candidatesTokenCount":3}}"#
        let outcome = await replay([withUsage, #"data: {"candidates":["#])
        XCTAssertEqual(outcome.invalidResponseMessage, "malformed Google stream event")
        XCTAssertEqual(outcome.inputTokens, [200])
        XCTAssertEqual(outcome.outputTokens, [3])
    }

    /// The chunk that throws counts too: a safety stop's own usage is reported.
    func testSafetyStopReportsItsOwnUsage() async {
        let blocked = #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":"hidden"}]},"finishReason":"SAFETY"}],"usageMetadata":{"promptTokenCount":200,"candidatesTokenCount":9}}"#
        let outcome = await replay([blocked])
        XCTAssertEqual(outcome.blockedReply, "gemini: SAFETY")
        XCTAssertEqual(outcome.outputTokens, [9])
    }
}

/// Anthropic's reply is complete only after `message_stop`; its stop reason
/// and tool blocks follow the same rules as the other providers.
final class AnthropicEndOfStreamTests: XCTestCase {
    private func replay(_ lines: [String]) async -> SSEReplay.Outcome {
        let feed = SSEReplay.lines(lines)
        return await SSEReplay.run { continuation in
            try await AnthropicProvider.consumeSSE(feed, continuation: continuation)
        }
    }

    private func sseEvent(_ name: String, _ json: String) -> [String] {
        ["event: \(name)", "data: \(json)", ""]
    }

    private func textEvent(_ text: String) -> [String] {
        sseEvent("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}"#)
    }

    private func stop(_ reason: String) -> [String] {
        sseEvent("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"\#(reason)"},"usage":{"output_tokens":5}}"#)
            + sseEvent("message_stop", #"{"type":"message_stop"}"#)
    }

    private func toolBlock(input: String) -> [String] {
        let escaped = input.replacingOccurrences(of: "\"", with: "\\\"")
        return sseEvent("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_sleep","input":{}}}"#)
            + sseEvent("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\#(escaped)"}}"#)
            + sseEvent("content_block_stop", #"{"type":"content_block_stop","index":1}"#)
    }

    func testCleanEOFWithoutMessageStopIsADroppedConnection() async {
        let outcome = await replay(textEvent("Your sleep was"))
        XCTAssertEqual(outcome.text, "Your sleep was")
        XCTAssertFalse(outcome.endedWithDone)
        XCTAssertTrue(outcome.isNetworkError, "\(String(describing: outcome.error))")
    }

    func testMessageStopCompletesTheReply() async {
        let outcome = await replay([": ping"] + sseEvent("ping", #"{"type":"ping"}"#) + textEvent("Slept well.") + stop("end_turn"))
        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.endedWithDone)
        XCTAssertEqual(outcome.text, "Slept well.")
    }

    func testMalformedEventThrows() async {
        let broken = await replay(textEvent("Hi") + ["data: {\"type\":"] + stop("end_turn"))
        XCTAssertEqual(broken.invalidResponseMessage, "malformed Anthropic stream event")
        let notAnObject = await replay(["data: [1, 2]"] + stop("end_turn"))
        XCTAssertEqual(notAnObject.invalidResponseMessage, "malformed Anthropic stream event")
    }

    func testMaxTokensEndsWithTheTruncationMarker() async {
        let outcome = await replay(textEvent("Your HRV was") + stop("max_tokens"))
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.text, "Your HRV was…")
    }

    func testRefusalIsABlockedReply() async {
        let outcome = await replay(textEvent("Partial") + stop("refusal"))
        XCTAssertEqual(outcome.blockedReply, "anthropic: refusal")
        XCTAssertFalse(outcome.endedWithDone)
    }

    /// A `max_tokens` stop inside the tool input closes the block with
    /// input that does not parse; the call is never emitted.
    func testTruncatedToolInputDoesNotRun() async {
        let outcome = await replay(toolBlock(input: #"{"days":"#) + stop("max_tokens"))
        XCTAssertTrue(outcome.toolNames.isEmpty)
        XCTAssertEqual(outcome.invalidResponseMessage, "tool call get_sleep arrived with incomplete arguments")
    }

    func testCompleteToolInputIsEmitted() async {
        let outcome = await replay(toolBlock(input: #"{"days":7}"#) + stop("tool_use"))
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.toolNames, ["get_sleep"])
        XCTAssertEqual(outcome.toolInputs, [#"{"days":7}"#])
    }

    /// Anthropic's mid-stream `overloaded_error` reads as the same
    /// overloaded `modelUnavailable` its HTTP 529 gives, not raw vendor text.
    func testOverloadedErrorEventIsOverloaded() async {
        let outcome = await replay(sseEvent("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))
        XCTAssertTrue(outcome.isModelUnavailable, "\(String(describing: outcome.error))")
    }

    private var messageStart: [String] {
        sseEvent("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":120,"output_tokens":1}}}"#)
    }

    /// A stream cut after `message_start` still reports the usage that event
    /// carried, so the billed prompt is not lost from the telemetry.
    func testCutStreamStillReportsStartUsage() async {
        let outcome = await replay(messageStart + textEvent("Your sleep was"))
        XCTAssertTrue(outcome.isNetworkError, "\(String(describing: outcome.error))")
        XCTAssertEqual(outcome.inputTokens, [120])
    }

    /// A completed reply reports one usage event, with the final output count.
    func testCompletedReplyReportsUsageOnce() async {
        let outcome = await replay(messageStart + textEvent("Slept well.") + stop("end_turn"))
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.inputTokens, [120])
        XCTAssertEqual(outcome.outputTokens, [5])
    }

    // MARK: Paused turns

    /// What the chat layer received across a paused turn's requests, and
    /// each request's body as JSON.
    private struct PausedReplay {
        var text = ""
        var doneCount = 0
        var bodies: [[String: Any]] = []
    }

    /// Runs `continuingPausedTurns` with one canned reply per request (the
    /// last reply repeats) and records every request body it sends.
    private func replayPaused(_ replies: [[String]]) async throws -> PausedReplay {
        let (events, continuation) = AsyncThrowingStream<AIStreamEvent, Error>.makeStream()
        let first = AnthropicProvider.RequestBody(
            model: "claude-sonnet-4-6", max_tokens: 2048, system: [],
            messages: [.init(role: "user", content: .plain("Any news on the Boston marathon?"))],
            stream: true, tools: nil
        )
        var result = PausedReplay()
        try await AnthropicProvider.continuingPausedTurns(first, continuation: continuation) { request in
            let body = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(request)) as? [String: Any]
            result.bodies.append(body ?? [:])
            let reply = replies[min(result.bodies.count, replies.count) - 1]
            return try await AnthropicProvider.consumeSSE(SSEReplay.lines(reply), continuation: continuation)
        }
        continuation.finish()
        for try await event in events {
            if case let .textDelta(text) = event { result.text += text }
            if case .done = event { result.doneCount += 1 }
        }
        return result
    }

    private func textBlock(_ text: String, index: Int) -> [String] {
        sseEvent("content_block_start", #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}}"#)
            + sseEvent("content_block_delta", #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":"\#(text)"}}"#)
            + sseEvent("content_block_stop", #"{"type":"content_block_stop","index":\#(index)}"#)
    }

    /// A reply that searched and then paused: text, the server's search call
    /// (input streamed as partial JSON) and its result.
    private var pausedReply: [String] {
        textBlock("Searching. ", index: 0)
            + sseEvent("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}"#)
            + sseEvent("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"Boston marathon\"}"}}"#)
            + sseEvent("content_block_stop", #"{"type":"content_block_stop","index":1}"#)
            + sseEvent("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[{"type":"web_search_result","url":"https://example.com/boston","title":"Boston","encrypted_content":"opaque"}]}}"#)
            + sseEvent("content_block_stop", #"{"type":"content_block_stop","index":2}"#)
            + stop("pause_turn")
    }

    /// A paused reply is sent back with its blocks as the assistant's
    /// message, and the continuation finishes it: one reply, one `.done`, no
    /// truncation marker.
    func testPausedTurnIsContinuedWithItsContent() async throws {
        let replay = try await replayPaused([pausedReply, textBlock("Found it.", index: 0) + stop("end_turn")])
        XCTAssertEqual(replay.text, "Searching. Found it.")
        XCTAssertEqual(replay.doneCount, 1)
        XCTAssertEqual(replay.bodies.count, 2)
        XCTAssertEqual((replay.bodies.first?["messages"] as? [[String: Any]])?.count, 1)

        let messages = try XCTUnwrap(replay.bodies.last?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant"])
        let blocks = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["text", "server_tool_use", "web_search_tool_result"])
        XCTAssertEqual(blocks[0]["text"] as? String, "Searching. ")
        XCTAssertEqual((blocks[1]["input"] as? [String: Any])?["query"] as? String, "Boston marathon")
        XCTAssertEqual(blocks[1]["id"] as? String, "srvtoolu_1")
        let results = try XCTUnwrap(blocks[2]["content"] as? [[String: Any]])
        XCTAssertEqual(results.first?["encrypted_content"] as? String, "opaque")
    }

    /// A reply that keeps pausing is sent back at most
    /// `maxPauseContinuations` times, each time with all its content so far
    /// in one assistant message, and then ends with the truncation marker.
    func testPausedTurnStopsAfterTheContinuationBound() async throws {
        let replay = try await replayPaused([pausedReply])
        let limit = AnthropicProvider.maxPauseContinuations
        XCTAssertEqual(replay.bodies.count, limit + 1)
        XCTAssertTrue(replay.text.hasSuffix("…"))
        XCTAssertEqual(replay.doneCount, 1)
        let messages = try XCTUnwrap(replay.bodies.last?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual((messages.last?["content"] as? [Any])?.count, 3 * limit)
    }
}

/// Stop cancels the reader's task. A reader whose lines then end cleanly
/// reports cancellation, not a dropped connection.
final class EndOfStreamCancellationTests: XCTestCase {
    /// Runs `read` in a task that is cancelled before it reads anything,
    /// and returns what it threw.
    private func errorFromCancelledReader(
        _ read: @escaping @Sendable (ProviderStream.Continuation) async throws -> Void
    ) async -> Error? {
        let (_, continuation) = AsyncThrowingStream<AIStreamEvent, Error>.makeStream()
        let reader = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await read(continuation)
        }
        do {
            try await reader.value
            return nil
        } catch {
            return error
        }
    }

    func testCancelledReaderEndsAsCancellation() async {
        let readers: [(String, @Sendable (ProviderStream.Continuation) async throws -> Void)] = [
            ("openai", { try await OpenAICompatibleStreamer.consumeSSE(SSEReplay.lines([]), providerID: .openai, continuation: $0) }),
            ("gemini", { try await GeminiProvider.consumeSSE(SSEReplay.lines([]), continuation: $0) }),
            ("anthropic", { try await AnthropicProvider.consumeSSE(SSEReplay.lines([]), continuation: $0) })
        ]
        for (name, read) in readers {
            let error = await errorFromCancelledReader(read)
            XCTAssertTrue(error is CancellationError, "\(name): \(String(describing: error))")
        }
    }
}

// MARK: - Replies that failed partway

/// A reply whose stream failed after some text was shown: it is stored as
/// incomplete, kept out of the next request, replaced by a fallback's answer,
/// and never read for facts or summarised.
@MainActor
final class PartialReplyTests: XCTestCase {
    private func storeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A reply whose stream failed after "Your sleep was", as
    /// `handleStreamFailure` leaves it.
    private func incompleteReply() -> ChatTurn {
        var turn = ChatTurn(role: .assistant, text: "Your sleep was")
        turn.incomplete = true
        return turn
    }

    /// Transcripts written before the field existed decode, as complete.
    func testTranscriptsWrittenBeforeTheFieldDecodeAsComplete() throws {
        let legacy = Data("""
        [{"id":"\(UUID().uuidString)","role":"user","text":"How did I sleep?","createdAt":"2026-05-01T07:00:00Z"},
         {"id":"\(UUID().uuidString)","role":"assistant","text":"Seven hours.","createdAt":"2026-05-01T07:00:05Z",
          "providerID":"anthropic","modelID":"claude","localOnly":false}]
        """.utf8)
        let decoded = try storeDecoder().decode([ChatTurn].self, from: legacy)
        XCTAssertEqual(decoded.map(\.text), ["How did I sleep?", "Seven hours."])
        XCTAssertFalse(decoded.contains { $0.incomplete })
    }

    /// The mark survives the conversation store's encoding, so after a
    /// relaunch the reply still reads as cut off.
    func testTheIncompleteMarkSurvivesStorage() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try storeDecoder().decode([ChatTurn].self, from: try encoder.encode([incompleteReply()]))
        XCTAssertEqual(decoded.first?.incomplete, true)
    }

    /// An incomplete reply is not sent as if it were the model's answer,
    /// and is not handed to the summariser either.
    func testIncompleteRepliesAreWithheldFromTheOutboundHistory() {
        let history = [
            ChatTurn(role: .user, text: "How did I sleep?"),
            incompleteReply(),
            ChatTurn(role: .user, text: "And my HRV?")
        ]
        let (kept, dropped) = AssistantViewModel.truncateForSend(history, provider: .anthropic)
        XCTAssertEqual(kept.map(\.text), ["How did I sleep?", "And my HRV?"])
        XCTAssertTrue(dropped.isEmpty)
    }

    // MARK: Fallback splice

    /// The reserved turn as the fallback left it (the failed provider's
    /// partial text having been taken out first), settled after `ending`.
    private func settled(_ ending: AssistantToolRunner.FallbackEnding, fallbackText: String) -> ChatTurn {
        var turn = ChatTurn(role: .assistant, text: fallbackText, providerID: .apple, modelID: "apple-on-device")
        AssistantToolRunner.settle(&turn, after: ending, failedPartial: "Your sleep was", providerID: .anthropic, modelID: "claude-sonnet")
        return turn
    }

    /// The fallback's answer replaces the failed partial text, under the
    /// fallback's badge.
    func testAnsweredFallbackReplacesThePartialText() {
        let turn = settled(.answered, fallbackText: "You slept 7 h 40 min.")
        XCTAssertEqual(turn.text, "You slept 7 h 40 min.")
        XCTAssertEqual(turn.providerID, .anthropic)
        XCTAssertEqual(turn.modelID, "claude-sonnet")
    }

    func testStoppedFallbackKeepsWhatItShowedUnderItsBadge() {
        let turn = settled(.stopped, fallbackText: "You slept")
        XCTAssertEqual(turn.text, "You slept")
        XCTAssertEqual(turn.providerID, .anthropic)
    }

    func testStoppedFallbackWithNoTextBringsThePartialTextBack() {
        let turn = settled(.stopped, fallbackText: "")
        XCTAssertEqual(turn.text, "Your sleep was")
        XCTAssertEqual(turn.providerID, .apple)
    }

    /// A failed or refused fallback leaves none of its own text, and the
    /// failed provider's partial reply comes back under its own badge.
    func testFailedFallbackBringsThePartialTextBackUnderItsBadge() {
        for ending in [AssistantToolRunner.FallbackEnding.failed, .blocked] {
            let turn = settled(ending, fallbackText: "You slept 7")
            XCTAssertEqual(turn.text, "Your sleep was", "\(ending)")
            XCTAssertEqual(turn.providerID, .apple, "\(ending)")
            XCTAssertEqual(turn.modelID, "apple-on-device", "\(ending)")
        }
    }

    // MARK: Mutating tools and the fallback chain

    private func toolExchange(_ toolName: String) -> ToolExchange {
        ToolExchange(toolUseID: UUID().uuidString, toolName: toolName, inputJSON: "{}", resultJSON: "{}")
    }

    /// A turn that only read data may start over on another model; one that
    /// already added a contact or staged an email may not, or the fallback
    /// does it a second time.
    func testOnlyAMutatingToolKeepsTheTurnFromStartingOverElsewhere() {
        XCTAssertFalse(AssistantToolRunner.ranMutatingTool([[toolExchange("get_sleep"), toolExchange("web_search")]]))
        XCTAssertTrue(AssistantToolRunner.ranMutatingTool([[toolExchange("get_sleep")], [toolExchange("assistant_contacts_add")]]))
        XCTAssertTrue(AssistantToolRunner.ranMutatingTool([[toolExchange("assistant_email_compose")]]))
        XCTAssertFalse(AssistantToolRunner.ranMutatingTool([]))
    }

    /// The list follows the tool overlay's MUTATION TOOLS, so the model's
    /// rules and the fallback rule name the same tools.
    func testEveryMutationToolThePromptNamesIsTreatedAsMutating() {
        for name in AssistantToolRunner.mutatingToolNames where !name.hasPrefix("assistant_artifacts_") {
            XCTAssertTrue(AssistantSystemPrompt.toolOverlay.contains("`\(name)`"), name)
        }
    }

    // MARK: Summary batches

    /// After a long cloud conversation, Apple gets the dropped turns a
    /// window-sized batch at a time, oldest first, never an empty batch.
    func testSummaryBatchFitsTheProvidersHistoryBudget() {
        let budget = AssistantViewModel.conversationTokenBudget(for: .apple)
        let turns = (0 ..< 40).map { ChatTurn(role: $0.isMultiple(of: 2) ? .user : .assistant, text: String(repeating: "x", count: 400)) }
        let batch = AssistantViewModel.summaryBatch(turns, provider: .apple)
        XCTAssertFalse(batch.isEmpty)
        XCTAssertLessThan(batch.count, turns.count)
        XCTAssertEqual(batch.map(\.id), Array(turns.prefix(batch.count)).map(\.id))
        XCTAssertLessThanOrEqual(batch.map { AssistantViewModel.estimateTokens($0.text) + 4 }.reduce(0, +), budget)
    }

    /// One turn longer than the whole budget still goes, cut to it, so the
    /// summary cannot stall on it for good.
    func testAnOversizedTurnIsCutToTheBudget() {
        let budget = AssistantViewModel.conversationTokenBudget(for: .apple)
        let long = ChatTurn(role: .user, text: String(repeating: "y", count: budget * 10))
        let batch = AssistantViewModel.summaryBatch([long], provider: .apple)
        XCTAssertEqual(batch.map(\.id), [long.id])
        XCTAssertEqual(batch.first?.text.count, budget * 4)
    }

    // MARK: Fact extraction

    private var exchange: [ChatTurn] {
        [
            ChatTurn(role: .user, text: "I'm training for a marathon in May."),
            ChatTurn(role: .assistant, text: "Then this week matters.")
        ]
    }

    func testFactsAreReadFromACompletedReply() {
        let read = AssistantTurnRouter.factExtractionExchange(in: exchange, at: 1, completed: true)
        XCTAssertEqual(read?.userText, "I'm training for a marathon in May.")
        XCTAssertEqual(read?.assistantText, "Then this week matters.")
    }

    /// A stopped, refused or failed reply is not read for facts.
    func testFactsAreNotReadFromAReplyThatDidNotComplete() {
        XCTAssertNil(AssistantTurnRouter.factExtractionExchange(in: exchange, at: 1, completed: false))
    }

    func testFactsAreNeverReadFromAnIncompleteReply() {
        var turns = exchange
        turns[1].incomplete = true
        XCTAssertNil(AssistantTurnRouter.factExtractionExchange(in: turns, at: 1, completed: true))
    }

    // MARK: Background collection (summary and fact extraction)

    /// A stream that fails after some text yields nothing, so neither a
    /// partial summary nor a partial fact list is used, and the summary
    /// marker does not move past turns that were not summarised.
    func testCollectReturnsNothingForAStreamThatFailedPartway() async {
        let (stream, continuation) = AsyncThrowingStream<AIStreamEvent, Error>.makeStream()
        continuation.yield(.textDelta("The user is training for"))
        continuation.finish(throwing: AIProviderError.network("The network connection was lost."))
        let collected = await AssistantViewModel.collect(stream, timeoutSec: 5)
        XCTAssertNil(collected)
    }

    func testCollectReturnsNothingForAStreamThatTimesOut() async {
        let (stream, continuation) = AsyncThrowingStream<AIStreamEvent, Error>.makeStream()
        continuation.yield(.textDelta("The user is training for"))
        let collected = await AssistantViewModel.collect(stream, timeoutSec: 1)
        continuation.finish()
        XCTAssertNil(collected)
    }

    func testCollectReturnsTheTextOfACompletedStream() async {
        let (stream, continuation) = AsyncThrowingStream<AIStreamEvent, Error>.makeStream()
        continuation.yield(.textDelta("Training for a May marathon."))
        continuation.yield(.done)
        continuation.finish()
        let collected = await AssistantViewModel.collect(stream, timeoutSec: 5)
        XCTAssertEqual(collected, "Training for a May marathon.")
    }
}
