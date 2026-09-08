import CoreLocation
import Foundation

// MARK: - OSM Nominatim reverse-geocode service
//
// Apple's MKLocalSearch + CLGeocoder pipeline returns thin data in
// suburban-residential areas: no cross-street, often no
// `subLocality` (subdivision name), no neighborhood. The user
// repeatedly asked "what subdivision am I in?" and got the road
// name back because the underlying data wasn't in Apple's tile
// set.
//
// OpenStreetMap is materially denser in suburban-residential than
// Apple Maps for that exact use case. Nominatim's reverse-geocode
// returns `neighbourhood`, `residential`, `suburb`, `road`, `city`,
// `state` cleanly — for community-mapped subdivisions like
// "Woodbridge Glen" the `neighbourhood` field is populated where
// Apple's `CLPlacemark.subLocality` is nil.
//
// **Cost / keys / billing**: none. Nominatim is run by the OSM
// Foundation, free, no key required. Strict usage policy though
// (operations.osmfoundation.org/policies/nominatim):
//   • max 1 request/second sustained, single-thread
//   • must include a descriptive User-Agent that identifies the
//     app + a contact email
//   • no bulk geocoding, no autocomplete-style usage
//   • cache aggressively client-side
//   • display attribution: "© OpenStreetMap contributors"
//
// **This implementation honors the policy via**:
//   1. An actor (serial access by construction — no parallel
//      requests on the same instance)
//   2. A min-gap of 1.1s between outbound requests
//   3. A 50 m geographic grid cache with 24 h TTL — most users
//      produce <10 unique grid cells per workout
//   4. Identifying User-Agent set on every request
//   5. Falls back silently to nil on rate-limit / 5xx / timeout
//      so Apple's data path always remains the floor
//
// **Privacy**: HTTPS to OSMF (non-profit, non-ad-tech). IPs are
// logged per the policy but never sold. Materially better posture
// than continuing to lean on Apple's CLGeocoder for every fix.

actor OSMNominatimService {
    static let shared = OSMNominatimService()

    /// One reverse-geocoded result from Nominatim. Mirrors only the
    /// fields the app actually uses; the wire format has many more
    /// (`village`, `hamlet`, `house_number`, `postcode`, etc.) that
    /// can be added when a use case comes up.
    struct Result: Sendable, Equatable {
        let road: String?
        /// Most-specific named place that contains this fix. Falls
        /// back through the OSM hierarchy: `neighbourhood` →
        /// `residential` → `suburb` → `hamlet`. Nil when none of
        /// those polygons cover the coordinate (rural / unmapped).
        let subdivision: String?
        let city: String?
        let state: String?
        let postcode: String?
        let country: String?
        /// The full human-readable address line Nominatim
        /// constructed. Useful as a single-string fallback when the
        /// structured fields are sparse.
        let displayName: String?
    }

    // MARK: - Wire decoding

    private struct RawAddress: Decodable {
        let road: String?
        let neighbourhood: String?
        let residential: String?
        let suburb: String?
        let hamlet: String?
        let city: String?
        let town: String?
        let village: String?
        let state: String?
        let postcode: String?
        let country: String?
    }

    private struct RawResponse: Decodable {
        let address: RawAddress
        let display_name: String?
    }

    // MARK: - Cache + throttle state

    private struct CacheEntry {
        let result: Result
        let observedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var lastRequestAt: Date?

    /// Hard ceiling on distinct cached grid cells. The
    /// 24 h TTL alone doesn't bound size: a traveller (or a long-lived
    /// foreground session) can mint hundreds of unique 50 m cells
    /// before any expire. When the count exceeds this after an
    /// expired-entry sweep, the oldest entries are dropped. 500 cells
    /// of CacheEntry is trivial memory but stops unbounded growth.
    private let maxCacheEntries = 500

    /// 50 m grid cell — most suburban subdivisions span hundreds of
    /// meters, so the cell size lets one cached result serve many
    /// nearby fixes from the same workout.
    private let gridStepDegreesLat: Double = 50.0 / UnitConstants.metersPerDegreeLatitude
    /// 24 h TTL. Subdivisions don't move; the cache could be longer
    /// but 24 h matches a typical "a day's worth of walks from this
    /// neighborhood" usage pattern without going stale on
    /// newly-mapped places.
    private let cacheMaxAgeSec: TimeInterval = 24 * 60 * 60
    /// 1.1 s min-gap between outbound requests. Nominatim's policy
    /// is "1 req/sec sustained" — 1.1 s gives slack for clock jitter.
    private let minRequestGapSec: TimeInterval = 1.1
    /// Hard timeout per request. Nominatim is usually <1 s; cap at
    /// 3 s so a slow response can't block the AI's tool call.
    private let requestTimeoutSec: TimeInterval = 3.0

    /// Identifying User-Agent per the Nominatim usage policy. Plain
    /// Mozilla/5.0 will get IP-banned. This includes contact info so
    /// OSMF can reach the developer if there's ever an issue.
    private let userAgent = "Emuqu/1.0 iOS (chrissharp80@gmail.com)"

    /// Dedicated URLSession with HARD wall-clock cutoffs.
    ///
    /// Seen in a real user log: a Nominatim call took
    /// 13.7 s despite `URLRequest.timeoutInterval = 3.0`. Root cause:
    /// `timeoutInterval` is the *idle* timeout (time between bytes
    /// received), NOT the total request wall-clock. URLSession.shared
    /// uses the system default (typically 60 s for resource), so a
    /// slow-but-progressing connection blocked the AI's location
    /// pipeline for 13 s on workout start. Fix: dedicated session with
    /// `timeoutIntervalForResource = requestTimeoutSec` so the entire
    /// transfer is capped, regardless of progress.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeoutSec
        config.timeoutIntervalForResource = requestTimeoutSec
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Public API

    /// Expired entries are swept on every lookup so the cache
    /// can't accumulate stale grid cells past their TTL. Cheap (one pass over
    /// a small dict on the actor's serial executor).
    ///
    /// The throttle gate skips rather than queues when a request comes too
    /// soon after the last — the caller already has the Apple data, and we'd
    /// rather under-enrich than violate the OSM usage policy.
    func reverse(latitude: Double, longitude: Double) async -> Result? {
        sweepExpiredEntries()
        let key = gridKey(latitude: latitude, longitude: longitude)
        if let cached = cache[key],
           Date().timeIntervalSince(cached.observedAt) < cacheMaxAgeSec {
            return cached.result
        }
        if let last = lastRequestAt, Date().timeIntervalSince(last) < minRequestGapSec {
            return nil
        }
        lastRequestAt = Date()
        guard let url = Self.reverseURL(latitude: latitude, longitude: longitude) else { return nil }
        guard let data = await fetch(URLRequest(url: url), key: key) else { return nil }
        do {
            let result = Self.assemble(from: try JSONDecoder().decode(RawResponse.self, from: data))
            cache[key] = CacheEntry(result: result, observedAt: Date())
            return result
        } catch {
            debugLog("[Nominatim] reverse failed at \(key): \(error.localizedDescription)", level: .info)
            return nil
        }
    }

    /// Privacy: the coordinates sent to Nominatim are
    /// truncated to ~3 decimal places (~110 m). The 50 m grid cache already
    /// coarsens our own key; reverse-geocoding a subdivision name doesn't need
    /// 1 m precision, and sending raw 14-digit lat/lon to a third party is
    /// more precise location than the lookup requires. 3 dp resolves a
    /// neighbourhood without pinpointing a house.
    private static func reverseURL(latitude: Double, longitude: Double) -> URL? {
        let qLat = String(format: "%.3f", latitude)
        let qLon = String(format: "%.3f", longitude)
        return URL(string: "https://nominatim.openstreetmap.org/reverse?lat=\(qLat)&lon=\(qLon)&format=jsonv2&zoom=18&addressdetails=1")
    }

    /// The User-Agent comes from `session`'s httpAdditionalHeaders. A
    /// per-request `timeoutInterval` would be redundant with the session's
    /// hard `timeoutIntervalForResource` cutoff, and keeping both
    /// belt-and-suspenders would mask future regressions.
    ///
    /// Belt-and-suspenders timeout. The dedicated URLSession
    /// config has `timeoutIntervalForResource = 3.0`, which Apple documents as
    /// a hard cutoff. In a real-user log we still saw 8 s wall-clock for this
    /// call to fail — URLSession's timeout enforcement is apparently not
    /// ironclad on poor-connectivity / captive-portal paths. A
    /// Task.withTimeout race wraps the whole thing and GUARANTEES the actor
    /// hop returns within 3 s.
    private func fetch(_ request: URLRequest, key: String) async -> Data? {
        let pair: (Data, URLResponse)? = await runWithTimeoutOSM(seconds: requestTimeoutSec) {
            try await self.session.data(for: request)
        }
        guard let (data, response) = pair else {
            debugLog("[Nominatim] hard timeout (>\(requestTimeoutSec)s) for \(key) — URLSession config didn't honor cutoff", level: .info)
            return nil
        }
        guard let http = response as? HTTPURLResponse else { return nil }
        guard (200 ..< 300).contains(http.statusCode) else {
            debugLog("[Nominatim] HTTP \(http.statusCode) for \(key)", level: .info)
            return nil
        }
        return data
    }

    // MARK: - Helpers

    private static func assemble(from raw: RawResponse) -> Result {
        let subdivision: String? = raw.address.neighbourhood
            ?? raw.address.residential
            ?? raw.address.suburb
            ?? raw.address.hamlet
        let city: String? = raw.address.city
            ?? raw.address.town
            ?? raw.address.village
        return Result(
            road: raw.address.road,
            subdivision: subdivision,
            city: city,
            state: raw.address.state,
            postcode: raw.address.postcode,
            country: raw.address.country,
            displayName: raw.display_name
        )
    }

    /// Drop entries past their TTL and, if the cache is
    /// still over the size ceiling afterwards, evict the oldest until
    /// it fits. Keeps the cache bounded regardless of how many distinct
    /// places the user passes through.
    private func sweepExpiredEntries() {
        let now = Date()
        cache = cache.filter { now.timeIntervalSince($0.value.observedAt) < cacheMaxAgeSec }
        guard cache.count > maxCacheEntries else { return }
        let overflow = cache.count - maxCacheEntries
        let oldestKeys = cache
            .sorted { $0.value.observedAt < $1.value.observedAt }
            .prefix(overflow)
            .map(\.key)
        for key in oldestKeys { cache.removeValue(forKey: key) }
    }

    /// Round (lat, lon) to a 50 m grid cell so adjacent fixes from
    /// the same workout share a cache key.
    private func gridKey(latitude: Double, longitude: Double) -> String {
        let lat = (latitude / gridStepDegreesLat).rounded() * gridStepDegreesLat
        let lonStep = gridStepDegreesLat / max(0.1, cos(latitude * .pi / 180))
        let lon = (longitude / lonStep).rounded() * lonStep
        return String(format: "%.5f,%.5f", lat, lon)
    }
}

// MARK: - Wall-clock timeout helper (belt-and-suspenders for URLSession)
//
// `URLSessionConfiguration.timeoutIntervalForResource = 3.0`
// is Apple's documented hard cutoff. In a real-user log we observed
// 8 s wall-clock for a call to fail with NSURLErrorTimedOut. Apple's
// own enforcement isn't reliable on the connection-establishment path
// when the network is degraded. This helper races the URL work
// against a sleeping task; whichever resolves first wins. Returns
// nil on timeout.
private enum OSMTimeoutError: Error { case timedOut }

private func runWithTimeoutOSM<T: Sendable>(
    seconds: Double,
    operation: @Sendable @escaping () async throws -> T
) async -> T? {
    try? await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw OSMTimeoutError.timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw OSMTimeoutError.timedOut }
        return first
    }
}
