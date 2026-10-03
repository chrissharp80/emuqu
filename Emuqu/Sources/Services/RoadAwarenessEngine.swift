import CoreLocation
import Foundation

// MARK: - RoadAwarenessEngine
//
// Forward-looking road awareness over the OSM road
// graph fetched by `RoadGraphService`. Pure functions over a tile +
// a CLLocation; no side effects, no network. Safe to call from any
// async context — the tile fetch is the only async dance and
// happens at the public entry point.
//
// **The pipeline.**
//   1. `tile(for:)` — fetch the 250 m cell that covers the user's
//      coordinate from `RoadGraphService`. Hits the cache when
//      possible.
//   2. `snap(...)` — find the nearest road segment to the user's
//      fix, scored by perpendicular distance AND bearing agreement
//      (when bearing is trustworthy). Returns the segment id,
//      where the user is along it, and which direction along the
//      node-id sequence they're walking.
//   3. `lookahead(...)` — walk the graph forward in the direction
//      of travel, collecting upcoming intersection names + their
//      distances. Stops at 600 m or 3 intersections.
//   4. `phrase(...)` — turn the structured result into a single
//      sentence the AI Coach can read aloud. Returns nil when
//      confidence is too low to say anything safely (the global
//      invariant — never invent a road name).
//
// **Bearing trust** is the single hardest part. CLLocation's
// `course` is unreliable below ~1 m/s and at low GPS quality
// (`courseAccuracy >= 30°`); using a noisy bearing for snap
// disambiguation produces worse results than ignoring bearing
// entirely. The engine gates on `courseAccuracy` AND `speed`
// before allowing bearing to influence the snap.
//
// **Global safety invariant**: if the snap confidence is low OR
// every lookahead segment lacks a `name`/`ref` tag AND there is
// no neighbourhood fallback available, the engine returns nil.
// The AI Coach then says nothing — the difference between a
// feature that works in Tokyo and one that hallucinates "Birch
// Lane" in Shibuya.

enum RoadAwarenessEngine {
    // MARK: - Public types

    /// One match of the user's fix against a road segment.
    struct SnapResult: Sendable, Equatable {
        let segmentId: Int64
        let segmentName: String?
        let segmentRef: String?
        let highwayClass: String
        /// The point ON the segment closest to the user's fix.
        let snappedCoord: RoadGraphService.Point
        /// User's perpendicular distance from the segment, in meters.
        /// Used as the headline confidence score: <15 m is solid,
        /// 15-40 m is tentative, >40 m means the snap should be
        /// discarded.
        let perpendicularDistanceMeters: Double
        /// Index in the segment's `nodeIds` such that the user is
        /// BETWEEN `nodeIds[i]` and `nodeIds[i+1]`. Lookahead starts
        /// from this position.
        let segmentNodeIndex: Int
        /// True if the user is walking in the direction `nodeIds[0]
        /// → nodeIds[end]`; false for the reverse direction. nil
        /// when bearing wasn't trustworthy enough to determine.
        let walkingForwardAlongNodeIds: Bool?
        /// 0.0 (don't trust) → 1.0 (high confidence). Used by the
        /// caller to decide whether to surface anything.
        let confidence: Double
    }

    /// One event encountered while walking the graph forward from
    /// a snap point.
    struct LookaheadEvent: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            /// An intersection node where the user could turn off
            /// the current road. `crossStreets` is the names of the
            /// other ways meeting this node (deduped, current road
            /// excluded). Empty when none of the cross ways have
            /// names (common in Japan / Korea / rural areas).
            case intersection(crossStreets: [String], isRoundabout: Bool)
            /// The current road ends here with no same-named
            /// continuation — a T-junction, dead-end, or a road
            /// that becomes a different-named road.
            case roadEnds(continuations: [String])

            /// Pattern-match shorthand — `if case .roadEnds` doesn't compose
            /// inside a `first(where:)` closure without a full if/else.
            var isRoadEnds: Bool {
                if case .roadEnds = self { return true }
                return false
            }
        }

        /// Distance from the user's snapped position to this event,
        /// along the road network.
        let distanceMeters: Double
        let kind: Kind
    }

    /// Top-level result for the awareness query. All optional —
    /// nil signals "engine couldn't say anything safely."
    struct AwarenessResult: Sendable, Equatable {
        /// Name of the road the user is currently on. May differ
        /// from `RoadGeocodingService.current.road` when OSM and
        /// Apple disagree (rare but happens in newly-mapped areas).
        let currentRoadName: String?
        /// All upcoming events within the lookahead window, in
        /// distance order. May be empty.
        let events: [LookaheadEvent]
        /// Distance from the user to where the current road
        /// terminates / changes name, if known. Nil when the road
        /// continues past the lookahead window.
        let roadContinuesForMeters: Double?
        /// Snap confidence (0–1). Mirrors `SnapResult.confidence`.
        let confidence: Double
        /// Optional spoken-form sentence. Nil when the engine
        /// couldn't construct anything safe (no current road
        /// name AND no useful lookahead AND no neighbourhood
        /// fallback). Caller can build their own phrasing too.
        let phrase: String?
    }

    // MARK: - Tunables

    /// Below this speed (m/s), `course` is unreliable per Apple's
    /// CLLocation docs. ~0.7 m/s is a slow walk; below it we don't
    /// use bearing for snap scoring.
    static let minSpeedForCourseTrust: Double = 0.7
    /// Required `courseAccuracy` to trust bearing. Apple uses
    /// degrees; the property is -1 when not available. 30° is the
    /// industry rule of thumb (Apple's nav UI uses similar gating).
    static let maxCourseAccuracyDegrees: Double = 30
    /// Snap perpendicular-distance threshold. Beyond this, the snap
    /// is too loose to trust — return nil.
    static let maxSnapDistanceMeters: Double = 40
    /// Forward lookahead distance cap. 600 m is enough for ~5–7 min
    /// of walking — past that, the user is going to ask again
    /// before they get there.
    static let maxLookaheadMeters: Double = 600
    /// Forward lookahead cap by intersection count.
    static let maxLookaheadIntersections: Int = 3

    // MARK: - Public entry point

    static func awareness(
        for location: CLLocation,
        neighborhoodFallback: String? = nil
    ) async -> AwarenessResult? {
        guard let tile = await AppDependencies.current.location.roadGraphService.tile(for: location.coordinate) else {
            return nil
        }
        return awareness(
            for: location,
            tile: tile,
            neighborhoodFallback: neighborhoodFallback
        )
    }

    static func awareness(
        for location: CLLocation,
        tile: RoadGraphService.Tile,
        neighborhoodFallback: String?
    ) -> AwarenessResult {
        let trust = bearingTrust(for: location)
        let snapped = snap(
            location: location, tile: tile, useBearing: trust.trusted,
            userCourseDegrees: trust.trusted ? location.course : nil
        )
        guard let snap = snapped else { return fallbackResult(neighborhoodFallback) }
        let events = lookahead(from: snap, tile: tile)
        let endsAt = events.first { $0.kind.isRoadEnds }?.distanceMeters
        let phrase = constructPhrase(
            snap: snap, events: events, roadContinuesForMeters: endsAt,
            neighborhoodFallback: neighborhoodFallback
        )
        return AwarenessResult(
            currentRoadName: snap.segmentName ?? snap.segmentRef, events: events,
            roadContinuesForMeters: endsAt, confidence: snap.confidence, phrase: phrase
        )
    }

    /// Nothing snapped — the engine can't say anything about the road, so
    /// hand back only the neighbourhood phrase at zero confidence.
    private static func fallbackResult(_ neighborhoodFallback: String?) -> AwarenessResult {
        AwarenessResult(
            currentRoadName: nil, events: [], roadContinuesForMeters: nil,
            confidence: 0, phrase: phraseFromFallback(neighborhoodFallback)
        )
    }

    // MARK: - Bearing trust

    /// Decide whether `location.course` should influence the snap.
    /// Returns the trusted bearing (or nil) plus a flag for the
    /// caller's confidence math.
    static func bearingTrust(for location: CLLocation) -> (trusted: Bool, reason: String) {
        if location.course < 0 {
            return (false, "course=-1")
        }
        if location.speed >= 0, location.speed < minSpeedForCourseTrust {
            return (false, "speed<\(minSpeedForCourseTrust)")
        }
        // courseAccuracy is -1 when unavailable (older devices,
        // weak GPS). When -1, fall back to "trust if speed is
        // good" — Apple silently exposes a clean course on iOS 13+
        // even when the accuracy property is missing.
        if location.courseAccuracy >= 0,
           location.courseAccuracy > maxCourseAccuracyDegrees {
            return (false, "courseAccuracy>\(maxCourseAccuracyDegrees)")
        }
        return (true, "ok")
    }

    // MARK: - Snap

    /// Find the road segment in `tile` closest to `location`,
    /// optionally biased by bearing agreement.
    ///
    /// Returns nil when no segment is within `maxSnapDistanceMeters`.
    /// Best snap candidate seen so far in the scan. A named type rather than a
    /// five-member tuple: at that width the labels stop helping and the
    /// destructuring at the use site becomes the thing you have to decode.
    private struct Candidate {
        let segment: RoadGraphService.RoadSegment
        let perpDist: Double
        let nodeIndex: Int
        let snapped: RoadGraphService.Point
        let segmentBearing: Double
    }

    static func snap(
        location: CLLocation,
        tile: RoadGraphService.Tile,
        useBearing: Bool,
        userCourseDegrees: Double?
    ) -> SnapResult? {
        guard !tile.segments.isEmpty else { return nil }
        let userPoint = RoadGraphService.Point(
            lat: location.coordinate.latitude, lon: location.coordinate.longitude
        )
        let course = useBearing ? userCourseDegrees : nil
        guard let best = bestCandidate(for: userPoint, in: tile, userCourse: course),
              best.perpDist <= maxSnapDistanceMeters else { return nil }
        // Confidence blends perp-dist (closer = better) with bearing trust, 0–1.
        let perpScore = max(0, 1 - (best.perpDist / maxSnapDistanceMeters))
        let bearingScore: Double = useBearing ? 1.0 : 0.5
        return SnapResult(
            segmentId: best.segment.id, segmentName: best.segment.name,
            segmentRef: best.segment.ref, highwayClass: best.segment.highwayClass,
            snappedCoord: best.snapped, perpendicularDistanceMeters: best.perpDist,
            segmentNodeIndex: best.nodeIndex,
            walkingForwardAlongNodeIds: Self.walkingForward(along: best.segmentBearing, userCourse: course),
            confidence: perpScore * 0.7 + bearingScore * 0.3
        )
    }

    /// Each pair of consecutive geometry points is one line segment we can
    /// test against. We pick the closest LINE SEGMENT, not the closest node —
    /// that matters in the middle of a long way.
    private static func bestCandidate(
        for userPoint: RoadGraphService.Point,
        in tile: RoadGraphService.Tile,
        userCourse: Double?
    ) -> Candidate? {
        var best: Candidate?
        var bestScore: Double = .greatestFiniteMagnitude
        for (_, segment) in tile.segments {
            guard let scored = bestCandidate(for: userPoint, in: segment, userCourse: userCourse),
                  scored.score < bestScore
            else { continue }
            bestScore = scored.score
            best = scored.candidate
        }
        return best
    }

    /// The closest scoring segment within one way's geometry.
    private static func bestCandidate(
        for userPoint: RoadGraphService.Point,
        in segment: RoadGraphService.RoadSegment,
        userCourse: Double?
    ) -> (candidate: Candidate, score: Double)? {
        var best: (candidate: Candidate, score: Double)?
        // Road-graph geometry arrives from a downloaded tile; a way with a
        // single point (or none) is malformed data, not a reason to crash a
        // runner's navigation.
        for i in 0 ..< max(0, segment.geometry.count - 1) {
            guard let scored = candidate(for: userPoint, in: segment, atIndex: i, userCourse: userCourse),
                  scored.score < (best?.score ?? .greatestFiniteMagnitude)
            else { continue }
            best = scored
        }
        return best
    }

    /// Perpendicular distance is the great-circle distance from the user to
    /// the projected point. A road runs both ways, so the bearing penalty uses
    /// the smaller alignment (parallel = 0°, perpendicular = 90°,
    /// anti-parallel = 0° again) — a 0–90° "alignment" metric worth up to
    /// +36 m of penalty at 90°.
    private static func candidate(
        for userPoint: RoadGraphService.Point,
        in segment: RoadGraphService.RoadSegment,
        atIndex i: Int,
        userCourse: Double?
    ) -> (candidate: Candidate, score: Double)? {
        let a = segment.geometry[i]
        let b = segment.geometry[i + 1]
        let proj = projectPointOntoSegment(point: userPoint, segmentStart: a, segmentEnd: b)
        let perpDist = haversineMeters(userPoint, proj.snapped)
        guard perpDist <= maxSnapDistanceMeters * 1.5 else { return nil }
        let segmentBearing = bearingDegrees(from: a, to: b)
        var bearingPenalty: Double = 0
        if let userCourse {
            let raw = abs(((segmentBearing - userCourse).truncatingRemainder(dividingBy: 180)) + 180)
                .truncatingRemainder(dividingBy: 180)
            bearingPenalty = min(raw, 180 - raw) * 0.4
        }
        let candidate = Candidate(
            segment: segment, perpDist: perpDist, nodeIndex: i,
            snapped: proj.snapped, segmentBearing: segmentBearing
        )
        return (candidate, perpDist + bearingPenalty)
    }

    /// Direction along nodeIds: compare segment-bearing-at-snap to user
    /// course. Aligned within 90° means the user is walking forward;
    /// otherwise reversed. Nil when the bearing wasn't trustworthy.
    private static func walkingForward(along segmentBearing: Double, userCourse: Double?) -> Bool? {
        guard let userCourse else { return nil }
        let delta = abs(((segmentBearing - userCourse).truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        return (delta > 180 ? 360 - delta : delta) <= 90
    }

    // MARK: - Lookahead

    /// From the snapped position, walk along the road graph in the
    /// direction of travel and collect upcoming intersection events.
    /// Capped at `maxLookaheadMeters` and `maxLookaheadIntersections`.
    /// Where the walk currently is: which segment, which direction, and how
    /// far it has come.
    private struct Walk {
        var segment: RoadGraphService.RoadSegment
        var segmentName: String?
        var walkingForward: Bool
        var fromCoord: RoadGraphService.Point
        var nextNodeIndex: Int
        var distanceTravelled: Double = 0
        var visitedSegments: Set<Int64> = []
        /// Geometry index on `segment` of the node the last advance stopped at.
        var hitIndex: Int?
    }

    /// If `walkingForwardAlongNodeIds` is unknown, default to forward — the
    /// user will usually be walking along the way, and a wrong guess here just
    /// means we say "heading toward Oak" when the user is actually heading the
    /// other way. Acceptable failure mode; we confess to it in the engine
    /// output by suppressing the phrase when confidence is low.
    static func lookahead(
        from snap: SnapResult,
        tile: RoadGraphService.Tile
    ) -> [LookaheadEvent] {
        guard let segment = tile.segments[snap.segmentId] else { return [] }
        let initialForward = snap.walkingForwardAlongNodeIds ?? true
        var walk = Walk(
            segment: segment,
            segmentName: segment.name,
            walkingForward: initialForward,
            fromCoord: snap.snappedCoord,
            // Start node depends on direction.
            nextNodeIndex: initialForward ? snap.segmentNodeIndex + 1 : snap.segmentNodeIndex,
            visitedSegments: [segment.id]
        )
        var events: [LookaheadEvent] = []
        while events.count < maxLookaheadIntersections, walk.distanceTravelled < maxLookaheadMeters {
            guard let next = nextEvent(&walk, tile: tile) else { break }
            events.append(next.event)
            guard next.keepWalking else { break }
        }
        return events
    }

    /// Walk to the next node and say what happens there. OSM ways are not
    /// split at every crossing, so a crossing in the MIDDLE of the current
    /// way is an intersection the road carries on through: the walk stays on
    /// the same way. At the way's end, `event(at:walk:tile:)` decides between
    /// a same-name continuation and the road ending.
    private static func nextEvent(_ walk: inout Walk, tile: RoadGraphService.Tile) -> (event: LookaheadEvent, keepWalking: Bool)? {
        guard let hit = advanceToNextNode(&walk, tile: tile) else { return nil }
        if let index = walk.hitIndex, index > 0, index < walk.segment.geometry.count - 1 {
            walk.nextNodeIndex = walk.walkingForward ? index + 1 : index - 1
            walk.fromCoord = hit.coord
            return (midWayIntersection(at: hit, walk: walk, tile: tile), true)
        }
        guard let event = event(at: hit, walk: walk, tile: tile) else { return nil }
        guard let continuation = event.continuation else { return (event.event, false) }
        return (event.event, advanceIntoContinuation(&walk, continuation: continuation, hit: hit))
    }

    /// A crossing inside the current way: the other named ways meeting here,
    /// leaving out other pieces of the road the user is on.
    private static func midWayIntersection(
        at hit: (node: RoadGraphService.GraphNode, id: Int64, coord: RoadGraphService.Point),
        walk: Walk,
        tile: RoadGraphService.Tile
    ) -> LookaheadEvent {
        let branches = hit.node.wayIds
            .filter { $0 != walk.segment.id }
            .compactMap { tile.segments[$0] }
            .filter { walk.segmentName == nil || $0.name != walk.segmentName }
        let crossNames = namesOf(branches, excluding: nil, includingRefs: true)
        return LookaheadEvent(
            distanceMeters: walk.distanceTravelled,
            kind: .intersection(crossStreets: crossNames, isRoundabout: hit.node.isRoundabout)
        )
    }

    /// Advance through the current segment's remaining geometry, summing
    /// distance, until we hit a node that exists in the tile's node table
    /// (intersection or way endpoint). Nil when the walk is over.
    private static func advanceToNextNode(
        _ walk: inout Walk, tile: RoadGraphService.Tile
    ) -> (node: RoadGraphService.GraphNode, id: Int64, coord: RoadGraphService.Point)? {
        let step = advance(
            along: walk.segment,
            from: walk.nextNodeIndex,
            forward: walk.walkingForward,
            startingAt: walk.fromCoord,
            distanceSoFar: walk.distanceTravelled,
            tile: tile
        )
        walk.distanceTravelled = step.distanceTravelled
        walk.fromCoord = step.endCoord
        walk.hitIndex = step.nodeIndex
        guard let hitNodeId = step.nodeId,
              let hitNodeCoord = step.nodeCoord,
              walk.distanceTravelled <= maxLookaheadMeters,
              let hitNode = tile.nodes[hitNodeId]
        else { return nil }
        return (hitNode, hitNodeId, hitNodeCoord)
    }

    /// What happens at the END of the current way. A same-name continuation
    /// means the road goes on and we only surface the cross streets; no
    /// continuation means the road ends here (T-junction or a transition to
    /// a differently-named road) and the walk stops.
    ///
    /// OSM convention: a road that continues across an intersection carries
    /// the same `name` tag on both sides.
    private static func event(
        at hit: (node: RoadGraphService.GraphNode, id: Int64, coord: RoadGraphService.Point),
        walk: Walk,
        tile: RoadGraphService.Tile
    ) -> (event: LookaheadEvent, continuation: RoadGraphService.RoadSegment?)? {
        let branches = hit.node.wayIds.filter { $0 != walk.segment.id }.compactMap { tile.segments[$0] }
        // A dead end / map edge / way endpoint with no continuation in our
        // tile stops the walk.
        let continuation = branches.isEmpty ? nil : walk.segmentName.flatMap { name in
            name.isEmpty ? nil : branches.first(where: { $0.name == name })
        }
        guard let continuation else {
            let kind = LookaheadEvent.Kind.roadEnds(continuations: namesOf(branches, excluding: nil, includingRefs: false))
            return (LookaheadEvent(distanceMeters: walk.distanceTravelled, kind: kind), nil)
        }
        // Cross-street names = branches that AREN'T the continuation, with a
        // name. Deduped by `namesOf`.
        let crossNames = namesOf(branches, excluding: continuation.id, includingRefs: true)
        return (
            LookaheadEvent(
                distanceMeters: walk.distanceTravelled,
                kind: .intersection(crossStreets: crossNames, isRoundabout: hit.node.isRoundabout)
            ),
            continuation
        )
    }

    /// Step onto the same-named road on the far side of the intersection.
    /// False when that would loop back through a segment we already walked,
    /// or when the entry node isn't on the new segment.
    private static func advanceIntoContinuation(
        _ walk: inout Walk,
        continuation: RoadGraphService.RoadSegment,
        hit: (node: RoadGraphService.GraphNode, id: Int64, coord: RoadGraphService.Point)
    ) -> Bool {
        guard !walk.visitedSegments.contains(continuation.id) else { return false }
        // The intersection node is at one of the new segment's endpoints (or
        // somewhere in its nodeIds). Find it, then walk away from it — pick
        // whichever end is farther.
        guard let entryIdx = continuation.nodeIds.firstIndex(of: hit.id) else { return false }
        walk.visitedSegments.insert(continuation.id)
        walk.segment = continuation
        walk.segmentName = continuation.name
        walk.walkingForward = entryIdx < (continuation.nodeIds.count - 1 - entryIdx)
        walk.nextNodeIndex = walk.walkingForward ? entryIdx + 1 : entryIdx - 1
        walk.fromCoord = hit.coord
        return true
    }

    /// One hop along a segment's geometry: sum distance point-to-point until a
    /// node the graph cares about turns up (an intersection, or either end of
    /// the way), or until the lookahead budget runs out.
    ///
    /// Extracted from `lookahead` unchanged. Returning the running totals
    /// rather than mutating captured `var`s is what lets the walk be read on
    /// its own.
    private struct Advance {
        let nodeId: Int64?
        let nodeIndex: Int?
        let nodeCoord: RoadGraphService.Point?
        let distanceTravelled: Double
        let endCoord: RoadGraphService.Point
    }

    private static func advance(
        along segment: RoadGraphService.RoadSegment,
        from index: Int,
        forward: Bool,
        startingAt start: RoadGraphService.Point,
        distanceSoFar: Double,
        tile: RoadGraphService.Tile
    ) -> Advance {
        let indices: [Int] = forward
            ? Array(index ..< segment.geometry.count)
            : Array(stride(from: index, through: 0, by: -1))
        var travelled = distanceSoFar
        var cursor = start
        for idx in indices {
            let pt = segment.geometry[idx]
            travelled += haversineMeters(cursor, pt)
            cursor = pt
            if travelled > maxLookaheadMeters { break }
            let nid = segment.nodeIds[idx]
            let isEndpoint = idx == 0 || idx == segment.geometry.count - 1
            guard let node = tile.nodes[nid], node.isIntersection || isEndpoint else { continue }
            return Advance(nodeId: nid, nodeIndex: idx, nodeCoord: pt, distanceTravelled: travelled, endCoord: cursor)
        }
        return Advance(nodeId: nil, nodeIndex: nil, nodeCoord: nil, distanceTravelled: travelled, endCoord: cursor)
    }

    /// Deduplicated, order-preserving names for a set of branches.
    ///
    /// `includingRefs` mirrors the original two call sites exactly: cross
    /// streets fall back to a route `ref` when they have no name, while the
    /// "road ends, continues as…" list only ever used names.
    private static func namesOf(
        _ branches: [RoadGraphService.RoadSegment],
        excluding excludedId: Int64?,
        includingRefs: Bool
    ) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for b in branches where b.id != excludedId {
            if let nm = b.name, !nm.isEmpty, !seen.contains(nm) {
                seen.insert(nm)
                ordered.append(nm)
            } else if includingRefs, let rf = b.ref, !rf.isEmpty, !seen.contains(rf) {
                seen.insert(rf)
                ordered.append(rf)
            }
        }
        return ordered
    }

    // MARK: - Phrasing

    static func constructPhrase(
        snap: SnapResult,
        events: [LookaheadEvent],
        roadContinuesForMeters: Double?,
        neighborhoodFallback: String?
    ) -> String? {
        // No name AND no neighbourhood → say nothing safely.
        guard snap.segmentName ?? snap.segmentRef ?? neighborhoodFallback != nil else { return nil }
        var parts: [String] = []
        if let name = snap.segmentName ?? snap.segmentRef {
            parts.append("on \(name)")
        } else if let nb = neighborhoodFallback {
            parts.append("walking through \(nb)")
        }
        if let first = events.first,
           let clause = Self.clause(for: first, roadContinuesForMeters: roadContinuesForMeters) {
            parts.append(clause)
        }
        return parts.joined(separator: ", ")
    }

    /// The first useful upcoming event dictates the rest of the sentence. We
    /// prioritise: roadEnds (a real "you'll have to turn") >
    /// intersection-with-named-cross > nothing.
    private static func clause(
        for first: LookaheadEvent, roadContinuesForMeters: Double?
    ) -> String? {
        switch first.kind {
        case let .intersection(crossStreets, isRoundabout):
            if isRoundabout {
                return "approaching a roundabout in \(formatDistance(first.distanceMeters))"
            }
            // `if let` rather than `crossStreets.first!` after an `!isEmpty`
            // guard: functionally equivalent, but spec forbids force-unwrap.
            if let crossStreet = crossStreets.first {
                return "approaching \(crossStreet) in \(formatDistance(first.distanceMeters))"
            }
            return roadContinuesForMeters.map {
                "road continues \(formatDistance($0)) before the next change"
            }
        case let .roadEnds(continuations):
            guard let next = continuations.first else {
                return "ends in \(formatDistance(first.distanceMeters))"
            }
            return "ends at \(next) in \(formatDistance(first.distanceMeters))"
        }
    }

    /// Phrase when snap failed but we have a neighbourhood string
    /// from the reverse geocoder. Lets the AI Coach degrade gracefully in
    /// places where street names don't exist (Japan, rural).
    static func phraseFromFallback(_ fallback: String?) -> String? {
        guard let fallback else { return nil }
        return "walking through \(fallback)"
    }

    // MARK: - Distance formatting

    /// Compact human distance — feet for <300 m, otherwise miles.
    /// Could be unit-aware if the user's preference is wired in
    /// later; for now the AI Coach can re-format as needed.
    static func formatDistance(_ meters: Double) -> String {
        if meters < 300 {
            let feet = Int((meters * UnitConstants.feetPerMeter).rounded())
            return "\(feet) ft"
        }
        let miles = meters / 1609.34
        return String(format: "%.1f mi", miles)
    }

    // MARK: - Geometry helpers

    /// Project `point` onto the line segment a→b. Returns the
    /// closest point on the segment and the parametric `t`
    /// (clamped to [0,1]). Done in flat lat/lon — close-enough at
    /// our 800 m bbox scale; the haversine call afterward gives
    /// us the actual meter distance.
    static func projectPointOntoSegment(
        point p: RoadGraphService.Point,
        segmentStart a: RoadGraphService.Point,
        segmentEnd b: RoadGraphService.Point
    ) -> (snapped: RoadGraphService.Point, t: Double) {
        let dx = b.lon - a.lon
        let dy = b.lat - a.lat
        let lenSq = dx * dx + dy * dy
        if lenSq < 1e-18 {
            return (a, 0)
        }
        let t = ((p.lon - a.lon) * dx + (p.lat - a.lat) * dy) / lenSq
        let clamped = max(0, min(1, t))
        return (
            RoadGraphService.Point(
                lat: a.lat + clamped * dy,
                lon: a.lon + clamped * dx
            ),
            clamped
        )
    }

    /// Great-circle distance between two points in meters. Standard
    /// haversine — accurate to fractions of a meter at our scale.
    static func haversineMeters(
        _ a: RoadGraphService.Point,
        _ b: RoadGraphService.Point
    ) -> Double {
        let earthR = 6_371_000.0
        let lat1 = a.lat * .pi / 180
        let lat2 = b.lat * .pi / 180
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(h), sqrt(1 - h))
        return earthR * c
    }

    /// Initial bearing from a→b in degrees clockwise from true
    /// north (0°). Same formula as `RoadGeocodingService` uses for
    /// tile-search ranking.
    static func bearingDegrees(
        from a: RoadGraphService.Point,
        to b: RoadGraphService.Point
    ) -> Double {
        let lat1 = a.lat * .pi / 180
        let lat2 = b.lat * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radians = atan2(y, x)
        let degrees = radians * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
}
