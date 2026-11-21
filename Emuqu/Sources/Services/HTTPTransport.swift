import Foundation

/// Sends one HTTP request and returns the reply.
///
/// Every web-API client in `Services/` (Overpass, MET Norway, Tavily,
/// OpenTopoData) sends through one of these, handed to it by its initialiser
/// or entry point: `live` in the app, a stub in tests, so a test drives the
/// client's real request building and reply parsing without the network.
struct HTTPTransport: Sendable {
    /// Sends the request and returns the body and response, or throws the
    /// transport error (no connection, timeout, cancellation).
    let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Sends through the system's shared `URLSession`.
    static var live: HTTPTransport {
        HTTPTransport { request in try await URLSession.shared.data(for: request) }
    }
}
