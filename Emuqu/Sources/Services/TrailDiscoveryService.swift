import CoreLocation
import Foundation

// MARK: - TrailDiscoveryService
//
// Searches for hiking, mountain-biking, and road-cycling trails near
// the user via the OpenStreetMap Overpass API. Free, no API key, global
// coverage. Quality varies by region — popular trail systems (Smokies,
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
// Endpoint: https://overpass-api.de/api/interpreter (also fronted by
// kumi.systems and z.overpass-api.de — we use the canonical .de host).
final class TrailDiscoveryService: Sendable {
    static let shared = TrailDiscoveryService()

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
            case .hiking: return "Hiking"
            case .mountainBiking: return "Mountain biking"
            case .roadCycling: return "Road cycling"
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
            case .easy: return "Easy"
            case .moderate: return "Moderate"
            case .hard: return "Hard"
            case .expert: return "Expert"
            case .unknown: return "Unrated"
            }
        }

        /// Map sac_scale → Difficulty. Per OSM wiki:
        ///   T1 hiking → easy
        ///   T2 mountain hiking → moderate
        ///   T3 demanding mountain hiking → moderate
        ///   T4 alpine hiking → hard
        ///   T5 demanding alpine hiking → hard
        ///   T6 difficult alpine hiking → expert
        static func fromSacScale(_ s: String?) -> Difficulty? {
            guard let s = s?.lowercased() else { return nil }
            if s.contains("t1") || s.contains("hiking") && !s.contains("mountain") { return .easy }
            if s.contains("t2") || s.contains("t3") { return .moderate }
            if s.contains("t4") || s.contains("t5") { return .hard }
            if s.contains("t6") { return .expert }
            return nil
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

    enum SearchError: Error, LocalizedError {
        case noLocation
        case network(String)
        case decode(String)
        case rateLimited
        case noResults

        var errorDescription: String? {
            switch self {
            case .noLocation: return "Need a GPS fix to search nearby trails"
            case .network(let s): return "Overpass network error: \(s)"
            case .decode(let s): return "Overpass decode error: \(s)"
            case .rateLimited: return "Overpass rate-limited — wait a moment and retry"
            case .noResults: return "No trails matched. Widen the search radius or relax the filters."
            }
        }
    }

    struct SearchFilters {
        var activity: Activity
        /// Search radius in meters from the user's current location.
        /// Capped at 50 km — Overpass struggles with very-large radii.
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

    /// The hard-coded URL is well-formed; this throws a typed
    /// error rather than force-unwrapping so a future URL change can't crash
    /// the trail-discovery flow.
    private func fetchOverpass(coord: CLLocationCoordinate2D, filters: SearchFilters) async throws -> Data {
        guard let url = URL(string: "https://overpass-api.de/api/interpreter") else {
            throw SearchError.network("invalid Overpass URL")
        }
        let query = Self.buildQuery(coord: coord, filters: filters)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Overpass expects the query in a `data=` form field.
        let body = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query)"
        request.httpBody = body.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkStatus(response)
        return data
    }

    /// 429 (rate-limited) and 504 (Overpass timeout) get their own error so
    /// the caller can back off; anything outside 2xx is a plain network miss.
    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SearchError.network("non-HTTP response")
        }
        if http.statusCode == 429 || http.statusCode == 504 {
            throw SearchError.rateLimited
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw SearchError.network("HTTP \(http.statusCode)")
        }
    }

    // MARK: - Query construction

    /// The centre coordinate is truncated to ~110 m. This is the
    /// centre of a radius search whose radius is measured in kilometres, so
    /// ~11 cm of centre precision was pure leakage and cannot move which
    /// trails come back.
    private static func buildQuery(coord: CLLocationCoordinate2D, filters: SearchFilters) -> String {
        let lat = String(format: "%.3f", coord.latitude)
        let lon = String(format: "%.3f", coord.longitude)
        let selectors = tagSelectors(
            for: filters.activity, lat: lat, lon: lon, radius: Int(filters.radiusMeters)
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
        let coords = (el.members ?? [])
            .filter { $0.type == "way" }
            .flatMap { member in (ways[member.ref] ?? []).compactMap { nodes[$0] } }
        guard coords.count >= 4 else { return nil }
        return makeTrail(id: "rel-\(el.id)", name: name, tags: tags, coords: coords, sport: sport)
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
        if let v = tags["distance"], !v.isEmpty { return "OSM \(v)" }
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
