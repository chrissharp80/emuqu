@testable import Emuqu
import XCTest

/// JSON-ordering discipline.
///
/// Anthropic's prompt-caching docs and AWS Bedrock blog both flag a
/// Swift-specific gotcha: `JSONEncoder` randomizes key order by
/// default, which silently breaks cache hits across requests. The
/// research note made this its single highest-leverage cache fix:
/// `JSONEncoder.OutputFormatting = [.sortedKeys]` is one line per
/// encoder, and may explain a 30–50% chunk of "imaginary cache hits"
/// on its own.
///
/// The provider request encoders (`AnthropicProvider`,
/// `OpenAICompatibleStreamer`, `GeminiProvider`) set `.sortedKeys`. The
/// regression net is the "production request encoders" section below: it
/// builds requests through `AnthropicProvider.makeRequest` and
/// `OpenAICompatibleStreamer.requestFor` and fails if either drops
/// `.sortedKeys`. `GeminiProvider.makeRequest` is private and not covered.
/// The first three tests only pin the Foundation contract on local types.
final class JSONOrderingTests: XCTestCase {

    /// Test payload that exercises nested keys, arrays, and
    /// alphabetical-ordering edge cases (z, a, m). We can't import
    /// the providers' private `RequestBody` types, so this asserts
    /// the *Foundation* contract: when `.sortedKeys` is set, encode
    /// is deterministic.
    private struct Payload: Encodable {
        let zebra: String
        let apple: Int
        let middle: [String]
        let nested: Nested

        struct Nested: Encodable {
            let zee: Bool
            let alpha: Double
        }
    }

    func testEncoderWithSortedKeysIsDeterministic() throws {
        let payload = Payload(
            zebra: "z",
            apple: 1,
            middle: ["c", "b", "a"],
            nested: .init(zee: true, alpha: 0.5)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var encodings: Set<Data> = []
        for _ in 0 ..< 100 {
            let data = try encoder.encode(payload)
            encodings.insert(data)
        }

        XCTAssertEqual(
            encodings.count, 1,
            "JSONEncoder with .sortedKeys must produce byte-for-byte identical output across 100 encodes. " +
            "If this fails, prompt-cache hit rate is silently broken."
        )
    }

    /// The same payload WITHOUT `.sortedKeys` is allowed to vary —
    /// this test documents the failure mode. We assert it produces
    /// at least one variant (sometimes the runtime keeps the same
    /// hash order across all 100 calls; the test allows that), but
    /// the cache-stability guarantee only holds with `.sortedKeys`
    /// explicitly set.
    func testEncoderWithoutSortedKeysMayVary() throws {
        // Use a payload with enough keys to make hash-table ordering
        // non-trivial. The Foundation runtime is allowed to keep
        // arbitrary order; this test only documents that we're
        // RELYING on .sortedKeys for the determinism guarantee.
        let payload = Payload(
            zebra: "z",
            apple: 1,
            middle: ["c", "b", "a"],
            nested: .init(zee: true, alpha: 0.5)
        )

        let encoder = JSONEncoder()
        // Deliberately NOT setting .sortedKeys
        let first = try encoder.encode(payload)
        let firstString = String(data: first, encoding: .utf8) ?? ""
        XCTAssertFalse(
            firstString.isEmpty,
            "Sanity: encoder produces non-empty output"
        )
        // We do NOT assert non-determinism here — the runtime may or
        // may not keep order stable across calls in the same process.
        // The contract under test is that `.sortedKeys` makes it
        // deterministic, not that the absence makes it non-deterministic.
    }

    /// The Anthropic SDK's own `cache_control` block is one of the
    /// trickiest places to lose cache stability. This test asserts
    /// that re-encoding the same `cache_control` payload yields
    /// identical bytes when `.sortedKeys` is set.
    func testCacheControlSerializationIsStable() throws {
        struct CacheControl: Encodable {
            let type: String
            let ttl: String?
        }

        let cc = CacheControl(type: "ephemeral", ttl: "1h")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var encodings: Set<Data> = []
        for _ in 0 ..< 100 {
            encodings.insert(try encoder.encode(cc))
        }
        XCTAssertEqual(encodings.count, 1, "cache_control encoding must be byte-stable")
    }

    // MARK: - The production request encoders

    /// The body `AnthropicProvider.makeRequest` sends is exactly the
    /// `.sortedKeys` encoding of the body it was given. The control shows the
    /// body is order-sensitive (its declared key order is not sorted), so a
    /// `makeRequest` without `.sortedKeys` fails the second assertion.
    func testAnthropicRequestBodyIsEncodedWithSortedKeys() throws {
        let body = AnthropicProvider.RequestBody(
            model: "claude-test", max_tokens: 1024,
            system: AnthropicProvider.cacheAwareSystemBlocks("rules"),
            messages: [.init(role: "user", content: .plain("How did I sleep?"))],
            stream: true, tools: nil
        )
        let url = try XCTUnwrap(URL(string: "https://example.invalid/v1/messages"))
        let request = try AnthropicProvider.makeRequest(url: url, apiKey: "test-key", body: body)
        let sorted = JSONEncoder()
        sorted.outputFormatting = [.sortedKeys]

        XCTAssertNotEqual(try JSONEncoder().encode(body), try sorted.encode(body), "Control: the declared key order is already sorted")
        XCTAssertEqual(request.httpBody, try sorted.encode(body), "makeRequest no longer encodes with .sortedKeys")
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
        let text = String(decoding: body, as: UTF8.self)
        let messages = try XCTUnwrap(text.range(of: #""messages":"#)).lowerBound
        let model = try XCTUnwrap(text.range(of: #""model":"#)).lowerBound
        let stream = try XCTUnwrap(text.range(of: #""stream":"#)).lowerBound
        let streamOptions = try XCTUnwrap(text.range(of: #""stream_options":"#)).lowerBound

        XCTAssertLessThan(messages, model, "requestFor no longer encodes with .sortedKeys")
        XCTAssertLessThan(stream, streamOptions, "requestFor no longer encodes with .sortedKeys")
    }
}
