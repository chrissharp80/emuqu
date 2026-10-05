import CoreLocation
import Foundation

// MARK: - TrailDiscoveryService
//
// Searches for hiking, mountain-biking, and road-cycling trails near
// the user via the OpenStreetMap Overpass API. Free, no API key, global
// coverage. Quality varies by region — popular trail systems (Yosemite,
// Appalachian Trail, Alps) have rich metadata including difficulty
// ratings; rural/back-country areas are sparser.
//
// Why Overpass over the alternatives:
//   • AllTrails / Komoot / Trailforks APIs are partner-only — closed
//     to indie devs.
//   • Wikiloc requires manual key request + slow approval.
//   • Hiking Project (REI) was deprecated.
//   • Strava only returns activities you're connected to, not a
//     trail database.
//   • OSM Overpass is the only truly-free, no-key, global option.
//
// We bias the query toward NAMED trails to avoid returning every random
// `highway=path` way in the area. Difficulty ratings come from the
// `sac_scale` (Swiss Alpine Club hiking scale, T1–T6) and `mtb:scale`
// (mountain bike scale, 0–6) tags. Length is computed from the way
// nodes' great-circle distances. Ascent/descent comes from a downstream
// `TopoElevationService` lookup (the Overpass response doesn't include
// elevation at node level for free).
//
// Requests go through `OverpassClient`, which holds the endpoint list, the
// fallback instance, request spacing and the User-Agent. A search reply is
// kept for `replyCacheSeconds`, so repeating the same search from the same
// spot does not query Overpass again.
final class TrailDiscoveryService: Sendable {
    static let shared = TrailDiscoveryService()

    private let overpass = OverpassClient()

    /// How long an identical search is answered from the last reply. Named
    /// trails change on a scale of weeks; ten minutes covers re-running a
    /// search after adjusting a filter that only applies on device.
    private static let replyCacheSeconds: TimeInterval = 10 * 60

    private init() {}

    // Same threading rationale as `WebSearchService`: this type is
    // intentionally NOT @MainActor so async work can run off-MainActor
    // and not deadlock the resolver bridge if we later expose this as
    // an AI tool. It has no UI state.

    /// Trail-search activity bucket. Distinct from the top-level `Sport`
    /// enum so we can express OSM-specific categories (mountain biking
    /// vs road cycling map differently in OSM tags but both are `.bike`
    /// in our workout pipeline).
    enum Activity: String, Codable, CaseIterable, Identifiable {
        case hiking
        case mountainBiking = "mountain_biking"
        case roadCycling = "road_cycling"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .hiking: return String(localized: "Hiking", bundle: LanguageManager.appBundle)
            case .mountainBiking: return String(localized: "Mountain biking", bundle: LanguageManager.appBundle)
            case .roadCycling: return String(localized: "Road cycling", bundle: LanguageManager.appBundle)
            }
        }

        /// Mapped to the workout `Sport` used by SavedRoute /
        /// WorkoutRecorder. Mountain and road cycling both fold to .bike.
        var workoutSport: Sport {
            switch self {
            case .hiking: return .hike
            case .mountainBiking, .roadCycling: return .bike
            }
        }
    }

    /// Standardised difficulty bucket. We collapse the various scales
    /// (sac_scale, mtb:scale, etc.) into one human-readable label per
    /// trail so the UI doesn't have to juggle three rating systems.
    enum Difficulty: String, Codable, Comparable, CaseIterable, Identifiable {
        case easy
        case moderate
        case hard
        case expert
        case unknown

        var id: String { rawValue }

        static func < (lhs: Difficulty, rhs: Difficulty) -> Bool {
            order(lhs) < order(rhs)
        }

        private static func order(_ d: Difficulty) -> Int {
            switch d {
            case .easy: return 0
            case .moderate: return 1
            case .hard: return 2
            case .expert: return 3
            case .unknown: return 4
            }
        }

        var displayName: String {
            switch self {
            case .easy: return String(localized: "Easy", bundle: LanguageManager.appBundle)
            case .moderate: return String(localized: "Moderate", bundle: LanguageManager.appBundle)
            case .hard: return String(localized: "Hard", bundle: LanguageManager.appBundle)
            case .expert: return String(localized: "Expert", bundle: LanguageManager.appBundle)
            case .unknown: return String(localized: "Unrated", bundle: LanguageManager.appBundle)
            }
        }

        /// Map sac_scale → Difficulty. Per OSM wiki:
        ///   T1 hiking → easy
        ///   T2 mountain hiking → moderate
        ///   T3 demanding mountain hiking → moderate
        ///   T4 alpine hiking → hard
        ///   T5 demanding alpine hiking → hard
        ///   T6 difficult alpine hiking → expert
        ///
        /// OSM stores the words, not the T-grades, so the match is exact. A
        /// "contains hiking" test rated every alpine grade Easy.
        static func fromSacScale(_ s: String?) -> Difficulty? {
            switch s?.lowercased().trimmingCharacters(in: .whitespaces) {
            case "hiking", "t1": .easy
            case "mountain_hiking", "demanding_mountain_hiking", "t2", "t3": .moderate
            case "alpine_hiking", "demanding_alpine_hiking", "t4", "t5": .hard
            case "difficult_alpine_hiking", "t6": .expert
            default: nil
            }
        }

        /// Map mtb:scale → Difficulty. 0–6 numeric:
        ///   0–1 → easy, 2 → moderate, 3 → hard, 4–6 → expert.
        static func fromMtbScale(_ s: String?) -> Difficulty? {
            guard let raw = s, let n = Int(raw.prefix(1)) else { return nil }
            switch n {
            case 0, 1: return .easy
            case 2: return .moderate
            case 3: return .hard
            default: return .expert
            }
        }
    }

    struct DiscoveredTrail: Identifiable, Sendable {
        let id: String  // OSM relation/way ID, prefixed with "rel-" or "way-"
        let name: String
        let activity: Activity
        /// Computed total length from way nodes, meters.
        let lengthMeters: Double
        /// Difficulty bucket; .unknown when no rating tag was present.
        let difficulty: Difficulty
        /// Centroid of the trail — used for "distance from you" sorting
        /// + map preview centering.
        let centerCoord: CLLocationCoordinate2D
        /// All trackpoints in trail order. Used for the map preview and
        /// for converting to a SavedRoute polyline.
        let trackpoints: [CLLocationCoordinate2D]
        /// Optional descriptor pulled from OSM tags ("national_park",
        /// "loop", "out and back"). Surfaces in the row's subtitle.
        let descriptor: String?

        /// Distance from a given user location, meters. Used for the
        /// row's "X km away" badge + sort.
        func distanceFrom(_ location: CLLocation) -> Double {
            let center = CLLocation(latitude: centerCoord.latitude, longitude: centerCoord.longitude)
            return center.distance(from: location)
        }
    }

    enum SearchError: Error, LocalizedError, Equatable {
        case noLocation
        case network(String)
        case decode(String)
        case rateLimited
        /// The trail map service refused the request: it may be blocking the
        /// app, or be down for maintenance. Retrying at once will not help.
        case unavailable
        case noResults

        /// What the user sees. The network and decode details are for the
        /// log; they are technical English and say nothing the user can act on.
        var errorDescription: String? {
            let b = LanguageManager.appBundle
            switch self {
            case .noLocation: return String(localized: "Need a GPS fix to search nearby trails", bundle: b)
            case .network: return String(localized: "Couldn't reach the trail map service. Check your connection and try again.", bundle: b)
            case .decode: return String(localized: "The trail map service sent a reply the app couldn't read. Try again.", bundle: b)
            case .rateLimited: return String(localized: "The trail map service is busy. Wait a moment and try again.", bundle: b)
            case .unavailable: return String(localized: "Trail search is unavailable right now. Try again later.", bundle: b)
            case .noResults: return String(localized: "No trails matched. Widen the search radius or relax the filters.", bundle: b)
            }
        }
    }

    struct SearchFilters {
        var activity: Activity
        /// Search radius in meters from the user's current location.
        /// The query caps it at `maxRadiusMeters` — Overpass struggles with
        /// very-large radii.
        var radiusMeters: Double = 10_000
        /// Min trail length (meters). nil = no min.
        var minLengthMeters: Double?
        /// Max trail length (meters). nil = no max.
        var maxLengthMeters: Double?
        /// Min difficulty bucket. nil = any. Unranked trails always pass.
        var minDifficulty: Difficulty?
        /// Max difficulty bucket. nil = any. Unranked trails always pass.
        var maxDifficulty: Difficulty?
        /// Cap the number of results returned. Overpass can return
        /// hundreds of ways for a popular area; we trim to the closest.
        var maxResults: Int = 25
    }

    func search(near location: CLLocation, filters: SearchFilters) async throws -> [DiscoveredTrail] {
        let data = try await fetchOverpass(coord: location.coordinate, filters: filters)
        let trails = try Self.parse(data: data, sport: filters.activity)
        let trimmed = Self.applyFilters(trails, filters: filters)
            .sorted { $0.distanceFrom(location) < $1.distanceFrom(location) }
            .prefix(filters.maxResults)
        if trimmed.isEmpty { throw SearchError.noResults }
        return Array(trimmed)
    }

    /// The Overpass reply for this search, with the client's failures turned
    /// into the errors the trail sheet shows.
    private func fetchOverpass(coord: CLLocationCoordinate2D, filters: SearchFilters) async throws -> Data {
        let query = Self.buildQuery(coord: coord, filters: filters)
        do {
            return try await overpass.post(query: query, timeout: 30, cacheFor: Self.replyCacheSeconds)
        } catch {
            throw Self.searchError(for: error)
        }
    }

    static func searchError(for failure: OverpassClient.Failure) -> Error {
        switch failure {
        case .busy: return SearchError.rateLimited
        case .refused(let status):
            debugLog("[TrailDiscovery] Overpass refused the search (HTTP \(status))", level: .warning)
            return SearchError.unavailable
        case .unreachable(let detail): return SearchError.network(detail)
        case .cancelled: return CancellationError()
        }
    }

    // MARK: - Query construction

    static let maxRadiusMeters: Double = 50_000

    /// The centre coordinate is truncated to ~110 m. This is the
    /// centre of a radius search whose radius is measured in kilometres, so
    /// ~11 cm of centre precision was pure leakage and cannot move which
    /// trails come back.
    private static func buildQuery(coord: CLLocationCoordinate2D, filters: SearchFilters) -> String {
        let lat = String(format: "%.3f", coord.latitude)
        let lon = String(format: "%.3f", coord.longitude)
        let selectors = tagSelectors(
            for: filters.activity, lat: lat, lon: lon, radius: Int(min(filters.radiusMeters, maxRadiusMeters))
        )
        return """
        [out:json][timeout:25];
        (
          \(selectors)
        );
        out body;
        >;
        out skel qt;
        """
    }

    /// Tag selectors per sport. Hiking pulls `route=hiking` relations plus
    /// named `highway=path` ways — the latter catches a lot of shorter trails
    /// that aren't part of a formal long-distance route. Mountain biking pulls
    /// `route=mtb` + `mtb=yes` ways. Road cycling pulls `route=bicycle`
    /// relations. `[name]` is the gating filter throughout.
    private static func tagSelectors(
        for activity: Activity, lat: String, lon: String, radius: Int
    ) -> String {
        switch activity {
        case .hiking:
            return """
              relation[route=hiking][name](around:\(radius),\(lat),\(lon));
              relation[route=foot][name](around:\(radius),\(lat),\(lon));
              way[highway=path][name][foot!=no](around:\(radius),\(lat),\(lon));
              way[highway=footway][name](around:\(radius),\(lat),\(lon));
            """
        case .mountainBiking:
            return """
              relation[route=mtb][name](around:\(radius),\(lat),\(lon));
              way[highway=path][mtb=yes][name](around:\(radius),\(lat),\(lon));
              way[highway=track][bicycle=yes][name](around:\(radius),\(lat),\(lon));
            """
        case .roadCycling:
            return """
              relation[route=bicycle][name](around:\(radius),\(lat),\(lon));
              way[highway=cycleway][name](around:\(radius),\(lat),\(lon));
            """
        }
    }

    // MARK: - Parsing

    /// The Overpass JSON shape trail discovery decodes.
    private struct TrailEnvelope: Decodable {
        let elements: [TrailElement]
    }

    private struct TrailElement: Decodable {
        let type: String
        let id: Int64
        let lat: Double?
        let lon: Double?
        let nodes: [Int64]?
        let members: [TrailMember]?
        let tags: [String: String]?
    }

    private struct TrailMember: Decodable {
        let type: String
        let ref: Int64
        let role: String?
    }

    private static func parse(data: Data, sport: Activity) throws -> [DiscoveredTrail] {
        let env: TrailEnvelope
        do {
            env = try JSONDecoder().decode(TrailEnvelope.self, from: data)
        } catch {
            debugLog("[TrailDiscovery] Overpass decode error: \(error)", level: .warning)
            throw SearchError.decode(String(describing: error))
        }
        // Index nodes + ways for relation/way → coordinate resolution.
        var nodes: [Int64: CLLocationCoordinate2D] = [:]
        for el in env.elements where el.type == "node" {
            if let lat = el.lat, let lon = el.lon {
                nodes[el.id] = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        var ways: [Int64: [Int64]] = [:]
        for el in env.elements where el.type == "way" {
            ways[el.id] = el.nodes ?? []
        }
        return relationTrails(in: env, nodes: nodes, ways: ways, sport: sport)
            + wayTrails(in: env, nodes: nodes, sport: sport)
    }

    /// Relations: long-form named routes that may span multiple ways.
    private static func relationTrails(
        in env: TrailEnvelope,
        nodes: [Int64: CLLocationCoordinate2D],
        ways: [Int64: [Int64]],
        sport: Activity
    ) -> [DiscoveredTrail] {
        env.elements.filter { $0.type == "relation" }.compactMap {
            relationTrail($0, nodes: nodes, ways: ways, sport: sport)
        }
    }

    /// Nil for an unnamed relation or one whose member ways resolve to fewer
    /// than 4 coordinates (a stub, not a route).
    private static func relationTrail(
        _ el: TrailElement,
        nodes: [Int64: CLLocationCoordinate2D],
        ways: [Int64: [Int64]],
        sport: Activity
    ) -> DiscoveredTrail? {
        guard let tags = el.tags, let name = tags["name"], !name.isEmpty else { return nil }
        let memberWays = (el.members ?? []).filter { $0.type == "way" }.map { ways[$0.ref] ?? [] }
        let coords = stitchedNodeIds(memberWays).compactMap { nodes[$0] }
        guard coords.count >= 4 else { return nil }
        return makeTrail(id: "rel-\(el.id)", name: name, tags: tags, coords: coords, sport: sport)
    }

    /// Member ways joined end to end at their shared nodes, each turned round
    /// where needed. OSM lists members in no guaranteed order or direction;
    /// concatenated as listed, gaps and reversed ways counted as straight
    /// jumps, inflating the length and zig-zagging the track. A way that
    /// joins neither end starts a new piece, and the longest piece is kept.
    static func stitchedNodeIds(_ memberWays: [[Int64]]) -> [Int64] {
        var pieces: [[Int64]] = []
        for way in memberWays where way.count >= 2 {
            if let last = pieces.last, let joined = joined(last, way) {
                pieces[pieces.count - 1] = joined
            } else {
                pieces.append(way)
            }
        }
        return pieces.max { $0.count < $1.count } ?? []
    }

    private static func joined(_ piece: [Int64], _ way: [Int64]) -> [Int64]? {
        guard let start = piece.first, let end = piece.last, let wayStart = way.first, let wayEnd = way.last else { return nil }
        let reversedWay = Array(way.reversed())
        if end == wayStart { return piece + way.dropFirst() }
        if end == wayEnd { return piece + reversedWay.dropFirst() }
        if start == wayEnd { return way + piece.dropFirst() }
        if start == wayStart { return reversedWay + piece.dropFirst() }
        return nil
    }

    /// Ways: shorter individual trails not part of a relation. Ways that are
    /// members of relations already emitted are skipped to avoid duplicates.
    private static func wayTrails(
        in env: TrailEnvelope, nodes: [Int64: CLLocationCoordinate2D], sport: Activity
    ) -> [DiscoveredTrail] {
        let usedWayIDs = Set(env.elements.lazy
            .filter { $0.type == "relation" }
            .flatMap { ($0.members ?? []).filter { $0.type == "way" }.map(\.ref) }
        )
        return env.elements.filter { $0.type == "way" && !usedWayIDs.contains($0.id) }.compactMap { el in
            guard let tags = el.tags, let name = tags["name"], !name.isEmpty else { return nil }
            let coords = (el.nodes ?? []).compactMap { nodes[$0] }
            guard coords.count >= 4 else { return nil }
            return makeTrail(id: "way-\(el.id)", name: name, tags: tags, coords: coords, sport: sport)
        }
    }

    private static func makeTrail(
        id: String,
        name: String,
        tags: [String: String],
        coords: [CLLocationCoordinate2D],
        sport: Activity
    ) -> DiscoveredTrail? {
        let length = computeLength(coords)
        guard length > 100 else { return nil } // Sub-100 m: tracking artifact
        return DiscoveredTrail(
            id: id,
            name: name,
            activity: sport,
            lengthMeters: length,
            difficulty: Difficulty.fromSacScale(tags["sac_scale"])
                ?? Difficulty.fromMtbScale(tags["mtb:scale"])
                ?? .unknown,
            centerCoord: computeCentroid(coords),
            trackpoints: coords,
            descriptor: descriptor(from: tags)
        )
    }

    /// Prefer a route_type / network / operator tag for context. A trail in
    /// "Great Smoky Mountains National Park" is more informative than just
    /// "Loop Trail".
    private static func descriptor(from tags: [String: String]) -> String? {
        if let v = tags["operator"], !v.isEmpty { return v }
        if let v = tags["network"], !v.isEmpty { return v }
        if let v = tags["route_type"], !v.isEmpty { return v }
        if let v = tags["distance"], !v.isEmpty { return String(localized: "Listed distance \(v)", bundle: LanguageManager.appBundle) }
        return nil
    }

    private static func computeLength(_ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count >= 2 else { return 0 }
        var total: Double = 0
        var prev = CLLocation(latitude: coords[0].latitude, longitude: coords[0].longitude)
        for c in coords.dropFirst() {
            let next = CLLocation(latitude: c.latitude, longitude: c.longitude)
            total += next.distance(from: prev)
            prev = next
        }
        return total
    }

    private static func computeCentroid(_ coords: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        guard !coords.isEmpty else { return CLLocationCoordinate2D(latitude: 0, longitude: 0) }
        let lat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
        let lon = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private static func applyFilters(_ trails: [DiscoveredTrail], filters: SearchFilters) -> [DiscoveredTrail] {
        trails.filter { passes($0, filters: filters) }
    }

    /// Difficulty filters: unrated trails always pass — we don't want to hide
    /// every backcountry path just because OSM contributors didn't tag a
    /// sac_scale.
    private static func passes(_ trail: DiscoveredTrail, filters: SearchFilters) -> Bool {
        if let min = filters.minLengthMeters, trail.lengthMeters < min { return false }
        if let max = filters.maxLengthMeters, trail.lengthMeters > max { return false }
        guard trail.difficulty != .unknown else { return true }
        if let min = filters.minDifficulty, trail.difficulty < min { return false }
        if let max = filters.maxDifficulty, trail.difficulty > max { return false }
        return true
    }
}
