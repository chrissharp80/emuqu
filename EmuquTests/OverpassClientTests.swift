@testable import Emuqu
import XCTest

/// The Overpass request shape, status handling, endpoint order, back-off and
/// request serialisation shared by trail search and road awareness, and how
/// trail search turns a failure into what the sheet shows.
final class OverpassClientTests: XCTestCase {
    private let interpreter = URL(string: "https://overpass-api.de/api/interpreter")

    private let coffee = "overpass.private.coffee"
    private let main = "overpass-api.de"

    /// private.coffee invites any project; overpass-api.de counts every user
    /// of an app against one budget, so it is only the fallback.
    func testPermissiveInstanceIsAskedFirstAndMainInstanceSecond() {
        XCTAssertEqual(OverpassClient.endpoints.map { $0.host }, [coffee, main])
    }

    func testOnlyBusyOrRefusedHostsAreSetAside() {
        XCTAssertGreaterThanOrEqual(OverpassClient.cooldown(after: .busy) ?? 0, 30, "The OSM wiki asks for at least 30 s after 429/504.")
        XCTAssertEqual(OverpassClient.cooldown(after: .refused(403)), OverpassClient.refusalCooldown)
        XCTAssertNil(OverpassClient.cooldown(after: .unreachable("offline")))
        XCTAssertNil(OverpassClient.cooldown(after: .cancelled))
    }

    /// Offline, then back online: the next search must reach the network at
    /// once instead of failing for minutes without trying.
    func testTransportErrorTriesNextHostAndAllowsImmediateRetry() async {
        let stub = StubOverpass([.offline, .offline])
        let client = OverpassClient(minRequestGap: 0) { try await stub.respond(to: $0) }
        let first = await postOutcome(client)
        guard case .failure(.unreachable) = first else { return XCTFail("Expected unreachable, got \(first)") }
        let second = await postOutcome(client)
        XCTAssertNotNil(second.data)
        let asked = await stub.askedHosts
        XCTAssertEqual(asked, [coffee, main, coffee])
    }

    func testBusyHostIsSkippedWhileItCoolsDown() async {
        let stub = StubOverpass([.status(429)])
        let client = OverpassClient(minRequestGap: 0) { try await stub.respond(to: $0) }
        let first = await postOutcome(client)
        let second = await postOutcome(client, query: "other")
        XCTAssertNotNil(first.data)
        XCTAssertNotNil(second.data)
        let asked = await stub.askedHosts
        XCTAssertEqual(asked, [coffee, main, main])
    }

    func testNothingIsSentWhileEveryHostRefuses() async {
        let stub = StubOverpass([.status(403), .status(403)])
        let client = OverpassClient(minRequestGap: 0) { try await stub.respond(to: $0) }
        let first = await postOutcome(client)
        let second = await postOutcome(client)
        XCTAssertEqual(first.failure, .refused(403))
        XCTAssertEqual(second.failure, .refused(403))
        let asked = await stub.askedHosts
        XCTAssertEqual(asked.count, 2)
    }

    /// Trail search and road awareness share the client; their requests must
    /// still go out one at a time.
    func testConcurrentCallersNeverOverlapRequests() async {
        let stub = StubOverpass([], delayNanoseconds: 30_000_000)
        let client = OverpassClient(minRequestGap: 0) { try await stub.respond(to: $0) }
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 4 {
                group.addTask { _ = await postOutcome(client, query: "q\(index)") }
            }
        }
        let peak = await stub.peakInFlight
        let asked = await stub.askedHosts
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(asked.count, 4)
    }

    func testTrailSearchAndRoadAwarenessShareOneClient() async {
        let location = AppDependencies().location
        let roadClient = await location.roadGraphService.overpass
        let trailClient = location.trailDiscoveryService.overpass
        XCTAssertTrue(roadClient === trailClient)
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

/// What `post` returned, as a value an assertion can inspect.
private func postOutcome(_ client: OverpassClient, query: String = "q") async -> Result<Data, OverpassClient.Failure> {
    do {
        return .success(try await client.post(query: query, timeout: 5))
    } catch {
        return .failure(error)
    }
}

private extension Result where Success == Data, Failure == OverpassClient.Failure {
    var data: Data? {
        if case .success(let data) = self { return data }
        return nil
    }

    var failure: OverpassClient.Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

/// Answers Overpass requests from a script (HTTP 200 once it runs out) and
/// records which hosts were asked and how many requests overlapped.
private actor StubOverpass {
    enum Reply: Sendable {
        case status(Int)
        case offline
    }

    private var script: [Reply]
    private let delayNanoseconds: UInt64
    private var inFlight = 0
    private(set) var peakInFlight = 0
    private(set) var askedHosts: [String] = []

    init(_ script: [Reply], delayNanoseconds: UInt64 = 0) {
        self.script = script
        self.delayNanoseconds = delayNanoseconds
    }

    func respond(to request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(fileURLWithPath: "/")
        askedHosts.append(url.host ?? "")
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        defer { inFlight -= 1 }
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        let reply = script.isEmpty ? Reply.status(200) : script.removeFirst()
        guard case .status(let code) = reply else { throw URLError(.notConnectedToInternet) }
        guard let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return (Data("{}".utf8), response)
    }
}
