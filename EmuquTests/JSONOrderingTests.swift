@testable import Emuqu
import XCTest

/// JSON-ordering discipline.
///
/// `JSONEncoder` gives no key order by default, and the vendors' prompt
/// caches match on byte-identical prefixes, so an unsorted body silently
/// misses the cache on every turn. Every provider builds its request through
/// `ProviderHTTP.streamRequest`, which encodes with `.sortedKeys`. These
/// tests build requests through each provider's production builder
/// (`AnthropicProvider.makeRequest`, `GeminiProvider.makeRequest`,
/// `OpenAICompatibleStreamer.requestFor`) and fail if the body is not sorted.
final class JSONOrderingTests: XCTestCase {
    private var sortedEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    // MARK: - The production request encoders

    /// The body `AnthropicProvider.makeRequest` sends is exactly the
    /// `.sortedKeys` encoding of the body it was given. A plain `JSONEncoder`
    /// writes each object's keys in hash order, which changes with the
    /// process's hash seed, so a `makeRequest` without `.sortedKeys` differs
    /// from the sorted bytes unless every object happens to come out sorted.
    func testAnthropicRequestBodyIsEncodedWithSortedKeys() throws {
        let body = AnthropicProvider.RequestBody(
            model: "claude-test", max_tokens: 1024,
            system: AnthropicProvider.cacheAwareSystemBlocks("rules"),
            messages: [.init(role: "user", content: .plain("How did I sleep?"))],
            stream: true, tools: nil
        )
        let url = try XCTUnwrap(URL(string: "https://example.invalid/v1/messages"))
        let request = try AnthropicProvider.makeRequest(url: url, apiKey: "test-key", body: body)
        let sorted = sortedEncoder

        XCTAssertEqual(request.httpBody, try sorted.encode(body), "makeRequest no longer encodes with .sortedKeys")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    /// `GeminiProvider.makeRequest` sends the `.sortedKeys` encoding of the
    /// body to the model's streaming endpoint (`streamEndpoint`), with the
    /// key in its own header and never in the URL. The body carries a tool
    /// declaration and a function-call round, so it has many objects whose
    /// hash-ordered keys would almost never all come out sorted by chance.
    func testGeminiRequestBodyIsEncodedWithSortedKeys() throws {
        let call = GeminiProvider.RequestBody.FunctionCall(
            name: "sleep_summary", args: AnyJSON(["night": "last", "detail": true, "limit": 3])
        )
        let response = GeminiProvider.RequestBody.FunctionResponse(
            name: "sleep_summary", response: AnyJSON(["score": 81, "hours": 7.5, "note": "steady"])
        )
        let body = GeminiProvider.RequestBody(
            systemInstruction: .init(parts: [.init(text: "rules")]),
            contents: [
                .init(role: "user", parts: [.init(text: "How did I sleep?")]),
                .init(role: "model", parts: [.init(functionCall: call, thoughtSignature: "sig")]),
                .init(role: "user", parts: [.init(functionResponse: response)])
            ],
            tools: [.init(functionDeclarations: [
                .init(name: "sleep_summary", description: "Last night's sleep", parameters: nil)
            ])]
        )
        let model = GeminiProvider.models[0]
        let url = try GeminiProvider.streamEndpoint(for: model)
        let request = try GeminiProvider.makeRequest(url: url, apiKey: "test-key", body: body)
        let sorted = sortedEncoder

        XCTAssertEqual(request.httpBody, try sorted.encode(body), "makeRequest no longer encodes with .sortedKeys")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        let sent = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertEqual(request.url, url)
        XCTAssertTrue(sent.contains("models/\(model.apiID):streamGenerateContent?alt=sse"), sent)
        XCTAssertFalse(sent.contains("test-key"), sent)
    }

    /// `OpenAICompatibleStreamer.requestFor` builds the DeepSeek / OpenAI
    /// request. Its body type is private, so the check is on the bytes: the
    /// body declares model, messages, stream, stream_options in that order,
    /// and only a sorted encoding puts "messages" before "model" and
    /// "stream" before "stream_options".
    func testOpenAICompatibleRequestBodyIsEncodedWithSortedKeys() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://example.invalid/chat/completions"))
        let call = OpenAICompatibleStreamer.StreamCall(
            providerID: .deepseek, endpoint: endpoint, reasoning: DeepSeekProvider.reasoning,
            messages: [ChatTurn(role: .user, text: "How did I sleep?")],
            model: DeepSeekProvider.models[0], contextRendered: "", systemPrompt: "rules",
            tools: [], toolRounds: []
        )
        let body = try XCTUnwrap(OpenAICompatibleStreamer.requestFor(call, apiKey: "test-key").httpBody)
        let text = try XCTUnwrap(String(bytes: body, encoding: .utf8))
        let messages = try XCTUnwrap(text.range(of: #""messages":"#)).lowerBound
        let model = try XCTUnwrap(text.range(of: #""model":"#)).lowerBound
        let stream = try XCTUnwrap(text.range(of: #""stream":"#)).lowerBound
        let streamOptions = try XCTUnwrap(text.range(of: #""stream_options":"#)).lowerBound

        XCTAssertLessThan(messages, model, "requestFor no longer encodes with .sortedKeys")
        XCTAssertLessThan(stream, streamOptions, "requestFor no longer encodes with .sortedKeys")
        let request = try OpenAICompatibleStreamer.requestFor(call, apiKey: "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }
}
