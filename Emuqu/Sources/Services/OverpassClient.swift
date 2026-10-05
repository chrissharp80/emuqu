import Foundation

// MARK: - OverpassClient
//
// The one place requests to the OpenStreetMap Overpass API are built and sent,
// for trail search (`TrailDiscoveryService`) and road awareness
// (`RoadGraphService`). Each service owns its own client.
//
// **Endpoints.** `endpoints` lists the instances in the order they are asked:
//   1. overpass-api.de, the main public instance. Its usage policy
//      (dev.overpass-api.de/overpass-doc/en/preface/commons.html) asks each
//      client to stay under about 10 000 requests and 1 GB a day, and gives
//      light users priority. One device's trail searches and 250 m road tiles
//      stay far below that.
//   2. overpass.private.coffee (formerly overpass.kumi.systems), whose
//      operator states that any project may use it and that it has no rate
//      limit. It is asked when the main instance is busy, refuses the request
//      or cannot be reached.
//
// **Politeness.**
//   • Requests are sent one at a time (actor) and at least `minRequestGap`
//     apart.
//   • The User-Agent names the app, its version and a contact address.
//   • A host that answers 429 / 504 is left alone for `busyCooldown`; one that
//     refuses or cannot be reached, for `failureCooldown`. While every host is
//     cooling down the client sends nothing and reports the last failure.
//   • A caller can ask for a reply to be reused for a while (`cacheFor`), so a
//     repeated identical query is answered without a request.
actor OverpassClient {
    /// Why no host answered.
    enum Failure: Error, Equatable {
        /// Every host asked was busy (HTTP 429 or 504). Worth trying again later.
        case busy
        /// A host answered with an HTTP status outside 2xx (other than busy):
        /// it will not serve this query, possibly because it has blocked the app.
        case refused(Int)
        /// No host could be reached, or one sent something other than HTTP.
        case unreachable(String)
        /// The calling task was cancelled; no host is blamed for it.
        case cancelled
    }

    /// Overpass instances, in the order they are tried.
    static let endpoints: [URL] = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.private.coffee/api/interpreter"
    ].compactMap { URL(string: $0) }

    /// Identifies the app to the instance operators, so a misbehaving version
    /// can be told apart and its author reached.
    static let userAgent = "Emuqu/\(Bundle.main.appVersion) iOS (chrissharp80@gmail.com)"

    private let minRequestGap: TimeInterval = 1.1
    private let busyCooldown: TimeInterval = 60
    private let failureCooldown: TimeInterval = 5 * 60
    private let maxCachedReplies = 16

    private let session: URLSession
    private var lastRequestAt: Date?
    private var cooling: [URL: (until: Date, failure: Failure)] = [:]
    private var replies: [String: (data: Data, until: Date)] = [:]

    init(session: URLSession = URLSession.shared) {
        self.session = session
    }

    /// The reply to `query` from the first host that answers with a 2xx.
    /// `cacheFor` > 0 keeps the reply for that long and answers an identical
    /// query from it.
    func post(query: String, timeout: TimeInterval, cacheFor: TimeInterval = 0) async throws(Failure) -> Data {
        if let cached = replies[query], cached.until > Date() { return cached.data }
        let hosts = Self.endpoints.filter { (cooling[$0]?.until ?? .distantPast) <= Date() }
        guard !hosts.isEmpty else { throw firstCoolingFailure() }
        var lastFailure = Failure.unreachable("no Overpass endpoint")
        for url in hosts {
            switch await attempt(query: query, at: url, timeout: timeout) {
            case .success(let data):
                remember(data, for: query, keepFor: cacheFor)
                return data
            case .failure(.cancelled):
                throw .cancelled
            case .failure(let failure):
                coolDown(url, after: failure)
                lastFailure = failure
            }
        }
        throw lastFailure
    }

    private func attempt(query: String, at url: URL, timeout: TimeInterval) async -> Result<Data, Failure> {
        do {
            return .success(try await send(query: query, to: url, timeout: timeout))
        } catch {
            return .failure(error)
        }
    }

    private func firstCoolingFailure() -> Failure {
        Self.endpoints.compactMap { cooling[$0]?.failure }.first ?? .unreachable("every Overpass host is cooling down")
    }

    private func coolDown(_ url: URL, after failure: Failure) {
        let wait = failure == .busy ? busyCooldown : failureCooldown
        cooling[url] = (Date().addingTimeInterval(wait), failure)
        debugLog("[Overpass] \(url.host ?? "host") failed (\(failure)); skipping it for \(Int(wait)) s", level: .info)
    }

    private func remember(_ data: Data, for query: String, keepFor seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let now = Date()
        replies = replies.filter { $0.value.until > now }
        if replies.count >= maxCachedReplies, let oldest = replies.min(by: { $0.value.until < $1.value.until }) {
            replies.removeValue(forKey: oldest.key)
        }
        replies[query] = (data, now.addingTimeInterval(seconds))
    }

    private func send(query: String, to url: URL, timeout: TimeInterval) async throws(Failure) -> Data {
        await waitForRequestGap()
        if Task.isCancelled { throw .cancelled }
        lastRequestAt = Date()
        let reply: (Data, URLResponse)
        do {
            reply = try await session.data(for: Self.request(query: query, to: url, timeout: timeout))
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw .cancelled }
            throw .unreachable(error.localizedDescription)
        }
        try Self.checkStatus(reply.1, host: url.host ?? "host")
        return reply.0
    }

    private func waitForRequestGap() async {
        guard let last = lastRequestAt else { return }
        let remaining = minRequestGap - Date().timeIntervalSince(last)
        guard remaining > 0 else { return }
        await sleepQuietly(UInt64(remaining * 1_000_000_000), context: "Overpass request spacing")
    }

    /// 429 (rate-limited) and 504 (Overpass's own queue timeout) mean busy;
    /// anything else outside 2xx means this host will not answer the query.
    static func checkStatus(_ response: URLResponse, host: String) throws(Failure) {
        guard let http = response as? HTTPURLResponse else { throw .unreachable("non-HTTP response from \(host)") }
        if http.statusCode == 429 || http.statusCode == 504 { throw .busy }
        guard (200 ..< 300).contains(http.statusCode) else { throw .refused(http.statusCode) }
    }

    /// A form POST carrying the query in the `data` field, as Overpass expects.
    static func request(query: String, to url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("data=\(formEncoded(query))".utf8)
        return request
    }

    /// Percent-encodes everything but the unreserved characters, which is
    /// always valid in a form body (a bare `+` or `&` in a query would not be).
    static func formEncoded(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
