@testable import Emuqu
import Foundation

/// Answers every request with one canned reply and keeps the requests it was
/// sent, so a test drives a web-API client's real request building and reply
/// parsing through `transport` without the network.
actor StubHTTPTransport {
    private let status: Int
    private let body: Data
    private let headers: [String: String]
    private(set) var requests: [URLRequest] = []

    init(status: Int = 200, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    /// The transport to hand to the client under test.
    nonisolated var transport: HTTPTransport {
        HTTPTransport { request in try await self.respond(to: request) }
    }

    private func respond(to request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)
        else { throw URLError(.badURL) }
        return (body, response)
    }
}
