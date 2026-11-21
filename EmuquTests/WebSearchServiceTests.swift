@testable import Emuqu
import XCTest

/// The Tavily client's request building, status mapping and reply parsing,
/// driven through an injected transport so no test reaches the network.
final class WebSearchServiceTests: XCTestCase {
    /// Two results: a complete one, and one without a URL that must be dropped.
    private let reply = Data("""
    {
      "results": [
        {
          "title": "HRV and training load", "url": "https://pubmed.ncbi.nlm.nih.gov/1",
          "content": "Excerpt", "score": 0.9, "published_date": "2024-05-01"
        },
        { "title": "No URL", "content": "Dropped" }
      ]
    }
    """.utf8)

    func testSearchPostsToTavilyWithTheKeyAndParsesCompleteResults() async throws {
        let stub = StubHTTPTransport(body: reply)
        let service = WebSearchService(transport: stub.transport)
        let results = try await service.send(query: "hrv", intent: .research, maxResults: 3, apiKey: "test-key")
        let sent = await stub.requests
        let request = try XCTUnwrap(sent.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://api.tavily.com/search")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(body["query"] as? String, "hrv")
        XCTAssertEqual(body["max_results"] as? Int, 3)
        XCTAssertEqual(body["include_domains"] as? [String], WebSearchService.researchAuthorityDomains)
        XCTAssertEqual(results, [WebSearchService.Result(
            title: "HRV and training load", url: "https://pubmed.ncbi.nlm.nih.gov/1",
            content: "Excerpt", score: 0.9, publishedDate: "2024-05-01"
        )])
    }

    func testHTTP429IsReportedAsRateLimited() async {
        let stub = StubHTTPTransport(status: 429, body: Data())
        let service = WebSearchService(transport: stub.transport)
        do {
            _ = try await service.send(query: "hrv", intent: .general, maxResults: 5, apiKey: "test-key")
            XCTFail("A 429 must throw")
        } catch {
            guard case WebSearchService.SearchError.rateLimited = error else {
                return XCTFail("Expected rateLimited, got \(error)")
            }
        }
    }
}
