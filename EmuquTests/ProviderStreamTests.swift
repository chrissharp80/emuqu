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
