import CoreLocation
import Foundation

// MARK: - RoadGraphService
//
// Forward-looking road awareness ("you're approaching
// Birch Lane in 200 ft"), built on OpenStreetMap. The user's reverse-
// geocoder pipeline answers "what road am I on RIGHT NOW"; this
// service answers "what's on the road ahead of me."
//
// **Why a dedicated service.** Apple's MKDirections is the obvious
// shortcut — call `calculate` to a coordinate 500 m ahead in the
// user's heading direction and the returned `MKRoute.steps` gives
// you street names along the route. Two killers:
//   1. MKDirections is rate-limited per-device, ~50 calls in a short
//      window before `MKErrorCode.loadingThrottled` fires (Apple
//      Developer Forums, "MKDirections Calculate Over Limit"). A
//      free-roam coach refreshing every block would blow that
//      budget in <15 min, AND poison every other MapKit caller in
//      the app (the throttle is device-wide).
//   2. A "phantom destination" 500 m ahead routinely lands a few
//      meters off-network (in a yard / parking lot / field). MapKit
//      then routes the user TO that off-network point — often
//      detouring off the road they're walking on. So step[1..n]
//      is unreliable as "what's ahead on my current road."
//
// OSM's road graph (queried via Overpass) gives us the actual
// network topology: every road segment with its node sequence and
// tags. With a small bbox (~800 m) we can fetch a few hundred ways,
// snap the user to one, and walk the graph forward to enumerate
// the next named intersections. This works:
//   • Offline (once a tile is cached) — important for hikers in
//     dead zones.
//   • Globally — OSM coverage is dense in EU/NA/AU/JP and adequate
//     in most populated areas elsewhere.
//   • Without throttle anxiety — Overpass fair-use is 10k req/day
//     and 1 GB/day, well above what one user produces.
//
// **Tile caching.** A 250 m grid cell with a 800 m fetch radius
// gives ≥600 m of usable road graph in every direction from any
// point inside the cell. A 5 km walk hits ~20–25 cells, so per-
// workout Overpass traffic is bounded. 6 h TTL — the road
// network doesn't change minute-to-minute and a same-day repeat
// of the user's morning loop reuses every cell.
//
// **Throttle policy** (Overpass usage policy):
//   • Actor (serial fetches by construction, no parallel hammering)
//   • 1.1 s min-gap between outbound Overpass requests; inside it the
//     cached tile (or nil) is returned rather than waiting
//   • Requests go through `OverpassClient`: identifying User-Agent, the
//     main instance first and a fallback instance when it fails, and a
//     cooldown for a host that is busy or refuses
//   • Hard 8 s timeout
//   • Falls back silently to nil on 429 / 5xx / timeout — the
//     awareness engine then reports "I don't have road data for
//     this stretch" rather than guessing.

actor RoadGraphService {
    static let shared = RoadGraphService()

    // MARK: - Public types

    /// A single OSM way, projected into a flat geometry list. Only
    /// the fields the awareness engine reads are kept.
    struct RoadSegment: Sendable, Equatable {
        /// OSM way id — stable across queries; used to detect when
        /// two adjacent segments are the same logical road.
        let id: Int64
        /// Ordered coordinates along the way.
        let geometry: [Point]
        /// OSM `name` tag — the human road name. Nil when the way
        /// is unnamed (common for footways, common globally for
        /// residential streets in Japan / Korea / parts of Latin
        /// America).
        let name: String?
        /// OSM `ref` tag — route designation like "US-441" / "M25".
        /// Surfaced when `name` is nil for highways.
        let ref: String?
        /// OSM `highway` value: residential / primary / footway /
        /// path / service / etc.
        let highwayClass: String
        /// `oneway=yes` (vehicle direction). Pedestrians ignore unless
        /// `onewayFoot` is also true.
        let oneway: Bool
        /// `oneway:foot=yes` — true one-way for pedestrians (rare).
        let onewayFoot: Bool
        /// Sequence of node IDs the geometry maps to. Same length as
        /// `geometry`. Used to detect intersections (a node id that
        /// appears in >1 way's nodeIds is a junction).
        let nodeIds: [Int64]
    }

    /// A node in the road graph — every junction is a node, and so
    /// are interior way points. The awareness engine cares about
    /// the junctions (where ≥2 ways meet).
    struct GraphNode: Sendable, Equatable {
        let id: Int64
        let coord: Point
        /// IDs of ways that include this node in their nodeIds list.
        /// `count >= 2` means this is an intersection.
        let wayIds: [Int64]
        /// OSM tags — checked for `highway=mini_roundabout`,
        /// `highway=traffic_signals`, etc.
        let tags: [String: String]
        /// True when one of `wayIds` is tagged `junction=roundabout` or
        /// `circular`. OSM puts that tag on the ring's ways, not its nodes.
        let onRoundaboutWay: Bool

        var isIntersection: Bool { wayIds.count >= 2 }
        var isRoundabout: Bool { onRoundaboutWay || tags["highway"] == "mini_roundabout" }
    }

    /// Snapshot of the road network around a 250 m grid cell.
    struct Tile: Sendable {
        /// Quantized cell coordinates — `(latIndex, lonIndex)` such
        /// that cells of the same index cover the same 250 m square.
        let cellLat: Int
        let cellLon: Int
        /// Center of the cell in lat/lon — what we used as the
        /// Overpass query origin.
        let centerLat: Double
        let centerLon: Double
        /// way id → RoadSegment.
        let segments: [Int64: RoadSegment]
        /// node id → GraphNode. Nodes that appear in only one way
        /// are kept too — needed for geometry interpolation when
        /// snapping.
        let nodes: [Int64: GraphNode]
        /// When this tile was fetched. Read by the TTL check.
        let fetchedAt: Date
    }

    /// Compact, sendable point. We don't use CLLocationCoordinate2D
    /// in stored types because it isn't Sendable on all SDKs.
    struct Point: Sendable, Equatable, Hashable {
        let lat: Double
        let lon: Double

        var coord: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    // MARK: - State

    private var cache: [String: Tile] = [:]
    private var inflight: [String: Task<Tile?, Never>] = [:]
    private var lastRequestAt: Date?

    /// Hard ceiling on cached tiles. The 6 h TTL doesn't
    /// bound size on its own: a long point-to-point walk (or several
    /// workouts within the TTL window) can mint dozens of distinct 250 m
    /// cells, and each Tile holds a few hundred RoadSegments + nodes —
    /// the heaviest cache in the app. When a write would exceed this, the
    /// oldest tile (by fetchedAt) is evicted first. 64 tiles ≈ a 4 km
    /// radius of warm road graph, comfortably more than any one workout
    /// reuses, while keeping the memory footprint bounded.
    private let maxCachedTiles = 64

    /// 250 m grid step in latitude degrees. Longitude step is
    /// rescaled by `cos(lat)` so cells are roughly square in meters
    /// regardless of latitude.
    private let cellStepDegreesLat: Double = 250.0 / UnitConstants.metersPerDegreeLatitude
    /// Fetch radius. The cell is 250 m square; we grab 800 m around
    /// the cell center so any user position inside the cell has at
    /// least ~675 m (800 - half the cell diagonal) of road graph in
    /// every direction.
    private let fetchRadiusMeters: Int = 800
    /// Tile freshness. The road network changes on a multi-month
    /// cadence; 6 h is conservative and lets a same-day repeat of
    /// the user's loop reuse the cache.
    private let tileTTL: TimeInterval = 6 * 60 * 60
    /// Freshness of a tile that decoded but holds no roads. It may be a
    /// lake or a field — or Overpass returning nothing for a moment — so it
    /// is asked for again much sooner than a populated tile.
    private let emptyTileTTL: TimeInterval = 10 * 60
    /// Min gap between outbound Overpass requests (per OSMF fair-use).
    private let minRequestGapSec: TimeInterval = 1.1
    /// Hard timeout per Overpass request. Overpass-de typically
    /// responds in 200–800 ms for a road query of this size; 8 s
    /// is the give-up.
    private let requestTimeoutSec: TimeInterval = 8.0

    /// Sends the tile queries; holds the endpoints and the User-Agent.
    private let overpass = OverpassClient()

    private init() {}

    // MARK: - Public API

    /// Coalescing: if a fetch is already running for this cell, wait on its
    /// task instead of issuing a duplicate request.
    ///
    /// Throttle gate: inside the min-gap window with no cached tile to return,
    /// this bails with nil so the caller degrades gracefully.
    func tile(for coordinate: CLLocationCoordinate2D) async -> Tile? {
        let cell = cellKey(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let cached = cache[cell.key],
           Date().timeIntervalSince(cached.fetchedAt) < (cached.segments.isEmpty ? emptyTileTTL : tileTTL) {
            return cached
        }
        if let task = inflight[cell.key] { return await task.value }
        if let last = lastRequestAt, Date().timeIntervalSince(last) < minRequestGapSec {
            return cache[cell.key]
        }
        let task = Task<Tile?, Never> { [centerLat = cell.centerLat, centerLon = cell.centerLon, key = cell.key] in
            await self.fetchTile(
                cellKey: key, centerLat: centerLat, centerLon: centerLon,
                cellLatIndex: cell.latIndex, cellLonIndex: cell.lonIndex
            )
        }
        inflight[cell.key] = task
        let result = await task.value
        inflight[cell.key] = nil
        return result
    }

    /// Keep the tile cache under `maxCachedTiles` by
    /// evicting the oldest tiles (by fetchedAt) when a fresh write
    /// pushes it over. Cheap: only runs the sort/evict when actually
    /// over the cap, which is the uncommon case.
    private func evictOldestTilesIfNeeded() {
        guard cache.count > maxCachedTiles else { return }
        let overflow = cache.count - maxCachedTiles
        let oldestKeys = cache
            .sorted { $0.value.fetchedAt < $1.value.fetchedAt }
            .prefix(overflow)
            .map(\.key)
        for key in oldestKeys { cache.removeValue(forKey: key) }
    }

    // MARK: - Cell math

    /// One quantized 250 m grid cell: the integer indices that form the cache
    /// key, plus the cell centre used as the Overpass query origin.
    struct GridCell {
        let key: String
        let latIndex: Int
        let lonIndex: Int
        let centerLat: Double
        let centerLon: Double
    }

    /// Quantize a lat/lon into a 250 m grid cell. Returns the integer
    /// indices (used as the cache key) plus the cell center
    /// coordinate (used as the Overpass query origin).
    private func cellKey(latitude: Double, longitude: Double) -> GridCell {
        let latIndex = Int((latitude / cellStepDegreesLat).rounded(.down))
        // Longitude step varies with latitude — keep cells roughly
        // square in meters. Use the cell-center latitude (not the
        // user latitude) to compute the step so cells line up
        // consistently across the cell width.
        let approxCenterLat = (Double(latIndex) + 0.5) * cellStepDegreesLat
        let lonStep = cellStepDegreesLat / max(0.1, cos(approxCenterLat * .pi / 180))
        let lonIndex = Int((longitude / lonStep).rounded(.down))
        let centerLat = (Double(latIndex) + 0.5) * cellStepDegreesLat
        let centerLon = (Double(lonIndex) + 0.5) * lonStep
        return GridCell(
            key: "\(latIndex),\(lonIndex)",
            latIndex: latIndex,
            lonIndex: lonIndex,
            centerLat: centerLat,
            centerLon: centerLon
        )
    }

    // MARK: - Fetch

    private func fetchTile(
        cellKey: String,
        centerLat: Double,
        centerLon: Double,
        cellLatIndex: Int,
        cellLonIndex: Int
    ) async -> Tile? {
        lastRequestAt = Date()
        let started = Date()
        let query = Self.buildQuery(centerLat: centerLat, centerLon: centerLon, radiusMeters: fetchRadiusMeters)
        let data: Data
        do {
            data = try await overpass.post(query: query, timeout: requestTimeoutSec)
        } catch {
            debugLog("[RoadGraph] fetch failed for \(cellKey): \(error)", level: .info)
            return nil
        }
        guard let tile = Self.parse(
            data: data, cellLatIndex: cellLatIndex, cellLonIndex: cellLonIndex,
            centerLat: centerLat, centerLon: centerLon
        ) else { return nil }
        cache[cellKey] = tile
        evictOldestTilesIfNeeded()
        let secs = String(format: "%.3f", Date().timeIntervalSince(started))
        debugLog("[RoadGraph] tile \(cellKey) fetched in \(secs)s — \(tile.segments.count) segments, \(tile.nodes.count) nodes", level: .info)
        return tile
    }

    // MARK: - Query construction

    /// Build the Overpass QL query for the walkable road network in
    /// a radius around `centerLat,centerLon`. We pull all the
    /// pedestrian-relevant `highway=*` types — exclude motorway /
    /// trunk because pedestrians can't legally walk on them and
    /// their geometry would skew the snap.
    /// Walkable highway classes per OSM Wiki (Key:highway):
    /// residential / unclassified / tertiary / secondary / primary — the
    /// typical road network; service — driveways / parking aisles (often
    /// unnamed; useful for snap continuity); footway / path / pedestrian /
    /// steps / living_street — pedestrian-only or shared; cycleway / track —
    /// mixed-use, a walker can be on these. EXCLUDED: motorway / trunk (no
    /// pedestrian access), construction / proposed (not real yet).
    ///
    /// `out body geom;` returns the way with each node's lat/lon inlined under
    /// `geometry: [{lat, lon}, ...]`, which spares us the second resolve pass
    /// `>;` would cost. The node IDs themselves (for intersection detection)
    /// come with the body output. We then ALSO emit `>;out body;` to pull the
    /// standalone node objects with their tags, so roundabouts / signals at
    /// intersection nodes can be detected.
    private static func buildQuery(
        centerLat: Double,
        centerLon: Double,
        radiusMeters: Int
    ) -> String {
        let lat = String(format: "%.6f", centerLat)
        let lon = String(format: "%.6f", centerLon)
        let selector = "way[\"highway\"~\"^(primary|secondary|tertiary|residential|unclassified|service|footway|path|cycleway|track|pedestrian|living_street|steps)$\"](around:\(radiusMeters),\(lat),\(lon));"
        return """
        [out:json][timeout:25];
        (
          \(selector)
        );
        out body geom;
        >;
        out body;
        """
    }

    // MARK: - Parse

    /// The Overpass JSON shape we decode. Only the fields the graph needs.
    private struct OverpassEnvelope: Decodable {
        let elements: [OverpassElement]
        /// Set when Overpass hit a runtime error or its own timeout; the
        /// elements are then empty or partial, even with HTTP 200.
        let remark: String?
    }

    private struct OverpassElement: Decodable {
        let type: String
        let id: Int64
        let lat: Double?
        let lon: Double?
        let nodes: [Int64]?
        let geometry: [OverpassGeom]?
        let tags: [String: String]?
    }

    private struct OverpassGeom: Decodable {
        let lat: Double
        let lon: Double
    }

    /// Nil when the reply doesn't decode or Overpass flagged it incomplete
    /// (`remark`): a failed reply is not cached as an empty area.
    private static func parse(
        data: Data,
        cellLatIndex: Int,
        cellLonIndex: Int,
        centerLat: Double,
        centerLon: Double
    ) -> Tile? {
        guard let env = completeEnvelope(from: data) else { return nil }
        let ways = parseWays(env.elements)
        let roundaboutWays = Set(env.elements.lazy
            .filter { $0.type == "way" && ["roundabout", "circular"].contains($0.tags?["junction"] ?? "") }
            .map(\.id))
        let nodes = parseNodes(env.elements, nodeToWays: ways.nodeToWays, roundaboutWays: roundaboutWays)
        return Tile(
            cellLat: cellLatIndex, cellLon: cellLonIndex,
            centerLat: centerLat, centerLon: centerLon,
            segments: ways.segments, nodes: nodes, fetchedAt: Date()
        )
    }

    private static func completeEnvelope(from data: Data) -> OverpassEnvelope? {
        let env: OverpassEnvelope
        do {
            env = try JSONDecoder().decode(OverpassEnvelope.self, from: data)
        } catch {
            debugLog("[RoadGraph] decode failed: \(error)", level: .info)
            return nil
        }
        if let remark = env.remark {
            debugLog("[RoadGraph] Overpass reply incomplete: \(remark)", level: .info)
            return nil
        }
        return env
    }

    /// Ways become segments, and every node they mention records which ways
    /// touch it — that map is what makes a node an intersection.
    ///
    /// The parallel `geometry` / `nodes` arrays in an untrusted Overpass reply
    /// must align, or `nodeIds[idx]` (indexed by geometry position in
    /// RoadAwarenessEngine) reads out of bounds.
    private static func parseWays(
        _ elements: [OverpassElement]
    ) -> (segments: [Int64: RoadSegment], nodeToWays: [Int64: [Int64]]) {
        var segments: [Int64: RoadSegment] = [:]
        var nodeToWays: [Int64: [Int64]] = [:]
        for el in elements where el.type == "way" {
            guard let geom = el.geometry, !geom.isEmpty,
                  let nodeIds = el.nodes, !nodeIds.isEmpty,
                  geom.count == nodeIds.count,
                  let highway = el.tags?["highway"]
            else { continue }
            let tags = el.tags ?? [:]
            segments[el.id] = RoadSegment(
                id: el.id, geometry: geom.map { Point(lat: $0.lat, lon: $0.lon) },
                name: tags["name"], ref: tags["ref"], highwayClass: highway,
                oneway: (tags["oneway"] == "yes") || (tags["oneway"] == "1"),
                onewayFoot: tags["oneway:foot"] == "yes", nodeIds: nodeIds
            )
            for nid in nodeIds {
                nodeToWays[nid, default: []].append(el.id)
            }
        }
        return (segments, nodeToWays)
    }

    /// Nodes that aren't part of any way are skipped — they appear in Overpass
    /// output as standalone POIs and aren't needed for snap / lookahead.
    private static func parseNodes(
        _ elements: [OverpassElement], nodeToWays: [Int64: [Int64]], roundaboutWays: Set<Int64>
    ) -> [Int64: GraphNode] {
        var nodes: [Int64: GraphNode] = [:]
        for el in elements where el.type == "node" {
            guard let lat = el.lat, let lon = el.lon else { continue }
            let wayIds = nodeToWays[el.id] ?? []
            guard !wayIds.isEmpty else { continue }
            nodes[el.id] = GraphNode(
                id: el.id,
                coord: Point(lat: lat, lon: lon),
                wayIds: wayIds,
                tags: el.tags ?? [:],
                onRoundaboutWay: wayIds.contains { roundaboutWays.contains($0) }
            )
        }
        return nodes
    }
}
