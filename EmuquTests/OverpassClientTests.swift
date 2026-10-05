@testable import Emuqu
import XCTest

/// The Overpass request shape, status handling and endpoint order shared by
/// trail search and road awareness, and how trail search turns a failure into
/// what the sheet shows.
final class OverpassClientTests: XCTestCase {
    private let interpreter = URL(string: "https://overpass-api.de/api/interpreter")

    func testMainInstanceIsAskedFirstAndPermissiveMirrorSecond() {
        XCTAssertEqual(OverpassClient.endpoints.map { $0.host }, ["overpass-api.de", "overpass.private.coffee"])
    }

    func testUserAgentNamesAppVersionAndContact() {
        XCTAssertTrue(OverpassClient.userAgent.hasPrefix("Emuqu/\(Bundle.main.appVersion) "))
        XCTAssertTrue(OverpassClient.userAgent.contains("@"), "Operators need a contact to reach the author.")
    }

    func testRequestIsFormPostCarryingQueryInDataField() throws {
        let url = try XCTUnwrap(interpreter)
        let request = OverpassClient.request(query: "way[name](around:10,1.0,2.0);", to: url, timeout: 8)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 8)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), OverpassClient.userAgent)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = try XCTUnwrap(String(bytes: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.hasPrefix("data="))
        XCTAssertEqual(String(body.dropFirst(5)).removingPercentEncoding, "way[name](around:10,1.0,2.0);")
    }

    /// `+` and `&` would be read as a space and a field separator if sent bare.
    func testFormEncodingEscapesFormSeparators() {
        let encoded = OverpassClient.formEncoded("a+b&c=d \"e\"")
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("&"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(encoded.removingPercentEncoding, "a+b&c=d \"e\"")
    }

    func testStatusMapping() throws {
        let url = try XCTUnwrap(interpreter)
        XCTAssertNil(failure(for: 200, url: url))
        XCTAssertEqual(failure(for: 429, url: url), .busy)
        XCTAssertEqual(failure(for: 504, url: url), .busy)
        XCTAssertEqual(failure(for: 403, url: url), .refused(403))
        XCTAssertEqual(failure(for: 500, url: url), .refused(500))
    }

    func testTrailSearchErrorsForEachFailure() {
        XCTAssertEqual(searchError(.busy), .rateLimited)
        XCTAssertEqual(searchError(.refused(403)), .unavailable)
        XCTAssertEqual(searchError(.unreachable("offline")), .network("offline"))
        XCTAssertTrue(TrailDiscoveryService.searchError(for: .cancelled) is CancellationError)
    }

    func testBlockedSearchSaysUnavailableNotCheckConnection() {
        let message = TrailDiscoveryService.SearchError.unavailable.errorDescription ?? ""
        XCTAssertFalse(message.isEmpty)
        XCTAssertNotEqual(message, TrailDiscoveryService.SearchError.network("x").errorDescription)
    }

    private func failure(for status: Int, url: URL) -> OverpassClient.Failure? {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            XCTFail("HTTPURLResponse did not build")
            return nil
        }
        do {
            try OverpassClient.checkStatus(response, host: "overpass-api.de")
            return nil
        } catch {
            return error
        }
    }

    private func searchError(_ failure: OverpassClient.Failure) -> TrailDiscoveryService.SearchError? {
        TrailDiscoveryService.searchError(for: failure) as? TrailDiscoveryService.SearchError
    }
}
