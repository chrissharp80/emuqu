import Foundation

// MARK: - OverpassClient
//
// The one place requests to the OpenStreetMap Overpass API are built and sent,
// for trail search (`TrailDiscoveryService`) and road awareness
// (`RoadGraphService`). The composition root (`AppDependencies`) builds one
// client and hands it to both services, so request spacing, back-off and the
// reply cache apply to the whole app.
//
// **Endpoints.** `endpoints` lists the instances in the order they are asked:
//   1. overpass.private.coffee (formerly overpass.kumi.systems). Its operator
//      invites any project to use it, sets no rate limit, and asks for a
//      User-Agent with contact details, no personal data in requests, and
//      notice before large-scale use.
//   2. overpass-api.de, the main public instance, asked only when the first
//      is busy, refuses the request or cannot be reached. Its usage policy
//      (dev.overpass-api.de/overpass-doc/en/preface/commons.html and the OSM
//      wiki's Overpass API page) counts the requests of every user of an app
//      together against about 10 000 requests and 1 GB a day, asks for no
//      parallel requests, and asks a client that gets 429 or 504 to wait
//      before trying again. Keeping it as the fallback keeps the app's share
//      of that budget small.
//
// **Politeness.**
//   • Requests are sent strictly one at a time: a caller waits for the
//     request in flight to finish, then for `minRequestGap` after it started.
//   • The User-Agent names the app, its version and a contact address.
//     Queries carry only coordinates truncated by the caller.
//   • A host that answers 429 / 504 is left alone for `busyCooldown` (the
//     OSM wiki asks for at least 30 s); one that refuses the query with
//     another HTTP status, for `refusalCooldown`. While every host is cooling
//     down the client sends nothing and reports why.
//   • A transport error (offline, connection lost, timeout) says nothing
//     about the host, so no host is set aside for it: the next host is asked,
//     and the next call goes to the network again, so a search works as soon
//     as the connection is back.
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

    /// Sends one request and returns the reply; `URLSession` in the app, a
    /// stub in tests.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Overpass instances, in the order they are tried.
    static let endpoints: [URL] = [
        "https://overpass.private.coffee/api/interpreter",
        "https://overpass-api.de/api/interpreter"
    ].compactMap { URL(string: $0) }

    /// Identifies the app to the instance operators, so a misbehaving version
    /// can be told apart and its author reached.
    static let userAgent = "Emuqu/\(Bundle.main.appVersion) iOS (\(AppConfig.contactEmail))"

    static let busyCooldown: TimeInterval = 60
    static let refusalCooldown: TimeInterval = 5 * 60
    private let maxCachedReplies = 16

    private let transport: Transport
    private let minRequestGap: TimeInterval
    private var lastRequestAt: Date?
    private var requestInFlight = false
    private var queuedCallers: [CheckedContinuation<Void, Never>] = []
    private var cooling: [URL: (until: Date, failure: Failure)] = [:]
    private var replies: [String: (data: Data, until: Date)] = [:]

    init(
        minRequestGap: TimeInterval = 1.1,
        transport: @escaping Transport = { request in try await URLSession.shared.data(for: request) }
    ) {
        self.minRequestGap = minRequestGap
        self.transport = transport
    }

    /// The reply to `query` from the first host that answers with a 2xx.
    /// `cacheFor` > 0 keeps the reply for that long and answers an identical
    /// query from it.
    func post(query: String, timeout: TimeInterval, cacheFor: TimeInterval = 0) async throws(Failure) -> Data {
        if let cached = cachedReply(for: query) { return cached }
        await waitForTurn()
        defer { finishTurn() }
        if let cached = cachedReply(for: query) { return cached }
        let hosts = Self.endpoints.filter { (cooling[$0]?.until ?? .distantPast) <= Date() }
        guard !hosts.isEmpty else { throw firstCoolingFailure() }
        let data = try await firstReply(to: query, from: hosts, timeout: timeout)
        remember(data, for: query, keepFor: cacheFor)
        return data
    }

    /// Asks `hosts` in order and returns the first 2xx reply. A host that
    /// fails is set aside for as long as `cooldown(after:)` says.
    private func firstReply(to query: String, from hosts: [URL], timeout: TimeInterval) async throws(Failure) -> Data {
        var lastFailure = Failure.unreachable("no Overpass endpoint")
        for url in hosts {
            switch await attempt(query: query, at: url, timeout: timeout) {
            case .success(let data):
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

    /// How long a host is left alone after `failure`, or nil when the failure
    /// says nothing about the host (a transport error or a cancellation).
    static func cooldown(after failure: Failure) -> TimeInterval? {
        switch failure {
        case .busy: return busyCooldown
        case .refused: return refusalCooldown
        case .unreachable, .cancelled: return nil
        }
    }

    private func cachedReply(for query: String) -> Data? {
        guard let cached = replies[query], cached.until > Date() else { return nil }
        return cached.data
    }

    /// Returns once no other request is in flight; callers go in arrival order.
    private func waitForTurn() async {
        guard requestInFlight else {
            requestInFlight = true
            return
        }
        await withCheckedContinuation { (turn: CheckedContinuation<Void, Never>) in
            queuedCallers.append(turn)
        }
    }

    /// Hands the turn to the next queued caller, or frees it.
    private func finishTurn() {
        if queuedCallers.isEmpty {
            requestInFlight = false
        } else {
            queuedCallers.removeFirst().resume()
        }
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
        guard let wait = Self.cooldown(after: failure) else {
            debugLog("[Overpass] \(url.host ?? "host") failed (\(failure)); trying the next host", level: .info)
            return
        }
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
            reply = try await transport(Self.request(query: query, to: url, timeout: timeout))
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
