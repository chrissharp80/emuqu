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
        var endedWithDone = false
        var error: Error?

        var asProviderError: AIProviderError? {
            error as? AIProviderError
        }

        var invalidResponseMessage: String? {
            guard case let .invalidResponse(message) = asProviderError else { return nil }
            return message
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
                case .usage:
                    break
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

    func testContentFilterIsABlockedReply() async {
        let outcome = await replay([textChunk("Partial", finish: "content_filter"), "data: [DONE]"])
        XCTAssertEqual(outcome.invalidResponseMessage, "ChatGPT blocked the reply (content_filter)")
        XCTAssertFalse(outcome.endedWithDone)
    }

    func testToolCallCutByALengthStopDoesNotRun() async {
        let outcome = await replay([toolFragment(#"{"days":"#), toolFragment("", finish: "length"), "data: [DONE]"])
        XCTAssertTrue(outcome.toolNames.isEmpty)
        XCTAssertNotNil(outcome.invalidResponseMessage)
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
            XCTAssertEqual(outcome.invalidResponseMessage, "Gemini blocked the reply (\(reason))")
            XCTAssertEqual(outcome.text, "Partial ", "the blocked chunk's text must not be shown")
            XCTAssertFalse(outcome.endedWithDone)
        }
    }

    func testMalformedFunctionCallDoesNotRunATool() async {
        let outcome = await replay([#"data: {"candidates":[{"content":{"role":"model","parts":[]},"finishReason":"MALFORMED_FUNCTION_CALL"}]}"#])
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
        XCTAssertEqual(outcome.invalidResponseMessage, "Claude blocked the reply (refusal)")
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
}
