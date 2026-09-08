import CoreLocation
import Foundation
import MapKit

// MARK: - SavedRouteStepBuilder
//
// Synthesise an `ActiveRouteSession`-compatible step
// list from a SavedRoute's polyline. Lets the user say "load my
// Saturday loop" and get the SAME proactive turn alerts +
// turn-as-marker updates that the MKDirections-backed
// `directions.routeTo` flow gives them — but following THEIR
// recorded path, not whatever Apple's walking router would compute
// to the same endpoint.
//
// **Why this exists.** SavedRoute is a polyline of trackpoints
// from a previously-walked path; it has no turn-by-turn
// instructions baked in. MKDirections won't help — even if we
// asked it for a route to the same endpoint, it'd pick its own
// path (potentially the shortcut around the lake when the user
// recorded the long way along the lake). For "Saturday hill loop"
// type routes the user wants their EXACT path. So we detect turns
// from the polyline ourselves.
//
// **Pipeline.**
//   1. Decode the saved polyline into a coordinate list. Reverse
//      if the user is closer to the END of the recorded path
//      (they're walking it the other way).
//   2. Detect turn nodes by bearing-change between consecutive
//      trackpoint triplets. Threshold 30°. Smooth: collapse turns
//      within 15 m of each other (GPS jitter), drop turns whose
//      onward segment is shorter than 30 m (clutter).
//   3. For each turn node, look up the road name at the user's
//      snapped position via `RoadGraphService` (the same OSM road
//      graph the awareness engine uses). Cache hits are free; new
//      tiles fetch sequentially under the 1.1 s OSM throttle.
//   4. Build instruction strings ("Head north on Maple Ave",
//      "Turn right onto Oak St", "Arrive at Saturday loop").
//      Falls back to nameless directions when OSM has no name
//      ("Turn left in 50 m") — same global-safety pattern as the
//      forward-awareness engine.
//   5. Bundle into `[ActiveRouteSession.InternalStep]` so the
//      session can engage it via `engageSyntheticRoute(...)`.
//
// **Latency.** Per-turn road lookup is RoadGraphService's tile
// fetch — typically 200–800 ms cold, ~0 ms after the first turn
// in each tile (cache hit). For a typical 5 km neighborhood loop
// with 8 turns spanning 3–4 OSM tiles: ~2–3 s cold build, near-
// instant subsequent re-engages of the same route.

enum SavedRouteStepBuilder {
    enum Direction: String, Sendable {
        case forward
        case reverse
    }

    struct BuildResult {
        let steps: [ActiveRouteSession.InternalStep]
        let totalDistanceMeters: Double
        /// Estimated walking duration at 1.4 m/s (typical adult
        /// pace). The user's actual pace from past workouts could
        /// give a better estimate; future enhancement.
        let totalDurationSeconds: TimeInterval
        let direction: Direction
        let routeName: String
        /// True when at least one turn instruction failed to
        /// resolve a road name (Japan / unnamed footpaths /
        /// offline tile fetch). Surfaces to the AI so it can
        /// caveat: "loaded your loop, but a couple turns don't
        /// have road names — I'll just say 'turn left in 50 m'
        /// instead."
        let hasUnnamedTurns: Bool
        /// Coordinate of the route's last trackpoint — handed to
        /// `ActiveRouteSession.engageSyntheticRoute` as the
        /// destination so arrival detection works.
        let destinationCoordinate: CLLocationCoordinate2D
    }

    // MARK: - Tunables

    /// Bearing-change threshold for a trackpoint to count as a
    /// turn. 30° is the industry-standard value for foot-pace
    /// "did the road bend significantly here" detection. Lower
    /// values produce a torrent of false-positive turns from GPS
    /// noise around long curves.
    static let turnAngleThresholdDegrees: Double = 30
    /// Minimum distance between adjacent turns. Trackpoint-level
    /// jitter can fire two consecutive "turn" detections on either
    /// side of a single intersection; collapse them so the user
    /// hears one announcement, not three.
    static let minTurnSeparationMeters: Double = 15
    /// Minimum onward segment length for a turn to count. A "turn"
    /// followed by another turn 5 m later is just GPS noise; drop
    /// the first one.
    static let minSegmentMeters: Double = 30

    // MARK: - Public

    /// Build the step list. Returns nil only when the saved route
    /// is structurally invalid (<2 trackpoints) — every other
    /// failure path returns a partial-success result with
    /// `hasUnnamedTurns=true` so the user gets SOMETHING.
    static func build(
        savedRoute: SavedRoute,
        currentLocation: CLLocationCoordinate2D
    ) async -> BuildResult? {
        let route = await MainActor.run { savedRoute.toRoute() }
        let originalCoords: [CLLocationCoordinate2D] = route.trackpoints.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard originalCoords.count >= 2 else {
            debugLog("[SavedRouteStepBuilder] route '\(savedRoute.name)' has <2 trackpoints — abort", level: .info)
            return nil
        }
        let direction = inferDirection(from: originalCoords, currentLocation: currentLocation)
        let coords = direction == .forward ? originalCoords : Array(originalCoords.reversed())
        let turnIndices = detectTurns(in: coords)
        debugLog("[SavedRouteStepBuilder] '\(savedRoute.name)' \(direction.rawValue) — \(coords.count) trackpoints, \(turnIndices.count) turns detected", level: .info)
        return await result(
            coords: coords, turnIndices: turnIndices, direction: direction, routeName: savedRoute.name
        )
    }

    /// Name the turns, cut the route into steps, and total it up.
    ///
    /// Walking pace 1.4 m/s — ~3.1 mph, the international adult average for
    /// "purposeful" walking. Future improvement: pull the user's median pace
    /// from past walks of this saved route via SessionArchive.
    private static func result(
        coords: [CLLocationCoordinate2D], turnIndices: [Int], direction: Direction, routeName: String
    ) async -> BuildResult {
        let names = await resolveNames(coords: coords, turnIndices: turnIndices)
        let steps = buildSteps(
            coords: coords,
            boundaries: stepBoundaries(turnIndices: turnIndices, lastIndex: coords.count - 1),
            names: names, routeName: routeName
        )
        let totalDistance = steps.reduce(0) { $0 + $1.distance }
        return BuildResult(
            steps: steps, totalDistanceMeters: totalDistance,
            totalDurationSeconds: totalDistance / 1.4, direction: direction,
            routeName: routeName, hasUnnamedTurns: names.unnamedCount > 0,
            destinationCoordinate: coords[coords.count - 1]
        )
    }

    /// Walk toward whichever end is farther from the user — they are at one
    /// end, so they walk to the other.
    private static func inferDirection(
        from coords: [CLLocationCoordinate2D], currentLocation: CLLocationCoordinate2D
    ) -> Direction {
        let userCL = CLLocation(latitude: currentLocation.latitude, longitude: currentLocation.longitude)
        let startCL = CLLocation(latitude: coords[0].latitude, longitude: coords[0].longitude)
        let endCL = CLLocation(latitude: coords[coords.count - 1].latitude, longitude: coords[coords.count - 1].longitude)
        return userCL.distance(from: startCL) <= userCL.distance(from: endCL) ? .forward : .reverse
    }

    /// The road names one route needs: the two endpoints and every turn.
    private struct ResolvedNames {
        let start: String?
        let end: String?
        let byIndex: [Int: String]
        let unnamedCount: Int
    }

    /// Resolve road names at each turn. Sequential — RoadGraph tile fetches
    /// are cache-fronted so repeats are free, but first-time-in-cell fetches
    /// respect the 1.1 s throttle. A per-turn nil result is fine: the
    /// formatter degrades.
    private static func resolveNames(
        coords: [CLLocationCoordinate2D], turnIndices: [Int]
    ) async -> ResolvedNames {
        // Start segment name (used for "Head north on <name>")
        let startName = await roadName(at: coords[0], coords: coords, index: 0)
        let endName = await roadName(at: coords[coords.count - 1], coords: coords, index: coords.count - 1)
        var byIndex: [Int: String] = [:]
        var unnamedCount = 0
        for idx in turnIndices {
            if let name = await roadName(at: coords[idx], coords: coords, index: idx) {
                byIndex[idx] = name
            } else {
                unnamedCount += 1
            }
        }
        return ResolvedNames(start: startName, end: endName, byIndex: byIndex, unnamedCount: unnamedCount)
    }

    /// Step boundaries: 0, each turn, then the end (if not already a turn).
    private static func stepBoundaries(turnIndices: [Int], lastIndex: Int) -> [Int] {
        var boundaries: [Int] = [0]
        boundaries.append(contentsOf: turnIndices)
        if boundaries.last != lastIndex {
            boundaries.append(lastIndex)
        }
        return boundaries
    }

    private static func buildSteps(
        coords: [CLLocationCoordinate2D],
        boundaries: [Int],
        names: ResolvedNames,
        routeName: String
    ) -> [ActiveRouteSession.InternalStep] {
        var steps: [ActiveRouteSession.InternalStep] = []
        // A route whose boundary detection found nothing yields no steps
        // rather than trapping on `0 ..< -1`.
        for i in 0 ..< max(0, boundaries.count - 1) {
            let startIdx = boundaries[i]
            let endIdx = boundaries[i + 1]
            guard endIdx > startIdx else { continue }
            let segCoords = Array(coords[startIdx ... endIdx])
            let segDistance = pathLength(segCoords)
            steps.append(ActiveRouteSession.InternalStep(
                instructions: instruction(
                    stepIndex: i, boundaries: boundaries, coords: coords,
                    names: names, routeName: routeName, segDistance: segDistance
                ),
                distance: segDistance,
                polyline: polyline(for: segCoords)
            ))
        }
        return steps
    }

    /// The spoken instruction for one step: heading orientation for the
    /// first, arrival for the last, a turn phrase for everything between.
    private static func instruction(
        stepIndex i: Int,
        boundaries: [Int],
        coords: [CLLocationCoordinate2D],
        names: ResolvedNames,
        routeName: String,
        segDistance: Double
    ) -> String {
        if i == 0 {
            return headingInstruction(coords: coords, startIdx: boundaries[0], name: names.start, segDistance: segDistance)
        }
        if i == boundaries.count - 2 {
            guard let name = names.end else { return "Arrive at \(routeName)" }
            return "Arrive at \(routeName) — finish on \(name)"
        }
        return turnInstruction(coords: coords, turnIdx: boundaries[i], names: names)
    }

    /// First step — heading orientation. Picks a coord a bit further along to
    /// dampen single-fix jitter in the initial bearing.
    private static func headingInstruction(
        coords: [CLLocationCoordinate2D], startIdx: Int, name: String?, segDistance: Double
    ) -> String {
        let lookAheadIdx = min(coords.count - 1, max(2, startIdx + 2))
        let cardinal = compassFromBearing(bearing(from: coords[0], to: coords[lookAheadIdx]))
        guard let name else { return "Head \(cardinal) for \(formatDistance(segDistance))" }
        return "Head \(cardinal) on \(name)"
    }

    /// Interior turn. Direction comes from the before/after bearings around
    /// the turn node.
    private static func turnInstruction(
        coords: [CLLocationCoordinate2D], turnIdx: Int, names: ResolvedNames
    ) -> String {
        let preIdx = max(0, turnIdx - 1)
        let postIdx = min(coords.count - 1, turnIdx + 1)
        let beforeBearing = bearing(from: coords[preIdx], to: coords[turnIdx])
        let afterBearing = bearing(from: coords[turnIdx], to: coords[postIdx])
        let turnPhrase = turnDirection(before: beforeBearing, after: afterBearing)
        guard let name = names.byIndex[turnIdx] else { return turnPhrase }
        return "\(turnPhrase) onto \(name)"
    }

    /// Trackpoint coords are `CLLocationCoordinate2D`; `MKPolyline.init` wants
    /// an UnsafePointer to a contiguous buffer — easiest via a let-binding +
    /// `withUnsafeBufferPointer`.
    private static func polyline(for segCoords: [CLLocationCoordinate2D]) -> MKPolyline {
        segCoords.withUnsafeBufferPointer { buf -> MKPolyline in
            guard let base = buf.baseAddress else { return MKPolyline() }
            return MKPolyline(coordinates: base, count: buf.count)
        }
    }

    // MARK: - Turn detection

    static func detectTurns(in coords: [CLLocationCoordinate2D]) -> [Int] {
        guard coords.count >= 3 else { return [] }
        var raw: [Int] = []
        for i in 1 ..< (coords.count - 1) {
            let b1 = bearing(from: coords[i - 1], to: coords[i])
            let b2 = bearing(from: coords[i], to: coords[i + 1])
            if abs(angleDelta(from: b1, to: b2)) >= turnAngleThresholdDegrees {
                raw.append(i)
            }
        }
        return dropShortSegments(collapseNearby(raw, in: coords), in: coords)
    }

    /// Collapse turns within `minTurnSeparationMeters` — GPS noise around a
    /// single physical intersection.
    private static func collapseNearby(_ raw: [Int], in coords: [CLLocationCoordinate2D]) -> [Int] {
        var collapsed: [Int] = []
        for idx in raw {
            if let prev = collapsed.last,
               distance(coords[idx], coords[prev]) < minTurnSeparationMeters {
                continue
            }
            collapsed.append(idx)
        }
        return collapsed
    }

    /// Drop turns whose onward segment is shorter than `minSegmentMeters` —
    /// the next "turn" is so close it's really part of the same maneuver.
    private static func dropShortSegments(_ turns: [Int], in coords: [CLLocationCoordinate2D]) -> [Int] {
        var kept: [Int] = []
        for (i, idx) in turns.enumerated() {
            let nextIdx = i + 1 < turns.count ? turns[i + 1] : coords.count - 1
            if pathLength(Array(coords[idx ... nextIdx])) >= minSegmentMeters {
                kept.append(idx)
            }
        }
        return kept
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    // MARK: - Road name lookup

    /// Look up the road name at a coordinate by snapping to the
    /// nearest segment in the OSM road graph. Returns nil when
    /// the tile fetch fails OR no segment is close enough OR the
    /// snapped segment lacks a name+ref tag.
    private static func roadName(
        at coord: CLLocationCoordinate2D,
        coords: [CLLocationCoordinate2D],
        index: Int
    ) async -> String? {
        guard let tile = await AppDependencies.current.location.roadGraphService.tile(for: coord) else {
            return nil
        }
        let prevIdx = max(0, index - 1)
        let nextIdx = min(coords.count - 1, index + 1)
        let course = bearing(from: coords[prevIdx], to: coords[nextIdx])
        guard let snap = RoadAwarenessEngine.snap(
            location: snapLocation(at: coord, course: course),
            tile: tile,
            useBearing: true,
            userCourseDegrees: course
        ) else { return nil }
        return snap.segmentName ?? snap.segmentRef
    }

    /// A synthesised CLLocation whose course comes from the surrounding
    /// trackpoints, so the snap can use bearing for disambiguation at
    /// intersections (where multiple ways converge).
    private static func snapLocation(at coord: CLLocationCoordinate2D, course: Double) -> CLLocation {
        CLLocation(
            coordinate: coord,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: -1,
            course: course,
            speed: 1.5,
            timestamp: Date()
        )
    }

    // MARK: - Geometry helpers

    /// Initial bearing from a→b in degrees clockwise from true
    /// north (0°). Same formula used elsewhere in the codebase
    /// (RoadGeocodingService, RoadAwarenessEngine).
    private static func bearing(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radians = atan2(y, x)
        let degrees = radians * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Signed angular delta from b1 to b2, normalized to [-180, 180].
    /// Positive = right turn (clockwise); negative = left turn.
    private static func angleDelta(from b1: Double, to b2: Double) -> Double {
        var d = b2 - b1
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    /// 8-point cardinal label from a bearing. "north" / "northeast" / etc.
    private static func compassFromBearing(_ bearing: Double) -> String {
        let dirs = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        // Shift by half-step so each cardinal covers 45° centered
        // on its compass point.
        let shifted = (bearing + 22.5).truncatingRemainder(dividingBy: 360)
        let idx = Int(shifted / 45)
        return dirs[max(0, min(dirs.count - 1, idx))]
    }

    /// Phrase a turn based on signed angle change. Threshold
    /// alignment matches user expectation: <30° = "bear left/right"
    /// (gentle), 30–90° = "turn", >90° = "sharp turn." Below 15°
    /// we shouldn't have detected a turn at all.
    private static func turnDirection(before: Double, after: Double) -> String {
        let delta = angleDelta(from: before, to: after)
        if delta > 90 { return "Turn sharp right" }
        if delta > 30 { return "Turn right" }
        if delta > 15 { return "Bear right" }
        if delta < -90 { return "Turn sharp left" }
        if delta < -30 { return "Turn left" }
        if delta < -15 { return "Bear left" }
        return "Continue"
    }

    /// Sum of consecutive haversine distances along a coordinate list.
    private static func pathLength(_ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count >= 2 else { return 0 }
        var total: Double = 0
        for i in 1 ..< coords.count {
            let a = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
            let b = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
            total += a.distance(from: b)
        }
        return total
    }

    /// Compact distance for the "Head north for X" instruction
    /// when there's no road name. Returns "200 m" / "1.4 km" or
    /// "0.9 mi" — but the UI doesn't have a units pref at this
    /// layer so default to metric (the AI / formatter can
    /// reformat downstream).
    private static func formatDistance(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters.rounded())) m" }
        return String(format: "%.1f km", meters / 1000)
    }
}
