import CoreLocation
@testable import Emuqu
import XCTest

/// Characterisation tests for `RoadAwarenessEngine` — the pure road-graph
/// reasoning behind the AI Coach's "you're on Main, approaching Oak" line.
///
/// Everything under test is a static function over a `RoadGraphService.Tile`
/// plus a `CLLocation`: no network, no cache, no actor hops. The file was at
/// zero coverage, which is exactly wrong for the one component whose failure
/// mode is *inventing a street name and reading it aloud to someone who is
/// running*.
///
/// Geometry note: all fixtures sit at 40.0° N where one degree of latitude is
/// ~111,195 m and one degree of longitude is ~85,394 m. A 0.001° step east is
/// therefore ~85.4 m, which is the unit the chain fixtures are built from.
/// Shared road-graph fixtures. Lifted to file scope so the three test
/// classes below can share them without any one type body running past
/// SwiftLint's 500-line limit.
private enum RoadFixture {
    typealias Point = RoadGraphService.Point
    typealias Segment = RoadGraphService.RoadSegment
    typealias Node = RoadGraphService.GraphNode
    typealias Tile = RoadGraphService.Tile

    static func point(_ lat: Double, _ lon: Double) -> Point {
        Point(lat: lat, lon: lon)
    }

    static func segment(
        id: Int64,
        name: String?,
        ref: String? = nil,
        highway: String = "residential",
        geometry: [Point],
        nodeIds: [Int64]
    ) -> Segment {
        Segment(
            id: id,
            geometry: geometry,
            name: name,
            ref: ref,
            highwayClass: highway,
            oneway: false,
            onewayFoot: false,
            nodeIds: nodeIds
        )
    }

    static func node(
        id: Int64,
        at coord: Point,
        ways: [Int64],
        tags: [String: String] = [:],
        onRoundaboutWay: Bool = false
    ) -> Node {
        Node(id: id, coord: coord, wayIds: ways, tags: tags, onRoundaboutWay: onRoundaboutWay)
    }

    static func tile(segments: [Segment], nodes: [Node]) -> Tile {
        Tile(
            cellLat: 0,
            cellLon: 0,
            centerLat: 40.0,
            centerLon: -75.0,
            segments: Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) }),
            nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) }),
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// A location with fully-specified motion metadata. The convenience
    /// `CLLocation(latitude:longitude:)` initialiser leaves `course` at -1,
    /// which the engine reads as "untrustworthy" — so every test that cares
    /// about bearing has to go through the long-form initialiser.
    static func location(
        lat: Double,
        lon: Double,
        course: CLLocationDirection = 90,
        courseAccuracy: CLLocationDirectionAccuracy = 5,
        speed: CLLocationSpeed = 2.5
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: 10,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: course,
            courseAccuracy: courseAccuracy,
            speed: speed,
            speedAccuracy: 1,
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    /// Main St running west→east through one crossing with Oak Ave, then
    /// dead-ending. This is the canonical "user is mid-block" fixture.
    ///
    ///                     111 (Oak, north)
    ///                      |
    ///   100 --- (way 1) -- 101 -- (way 2) --- 102     (Main St, dead end)
    ///                      |
    ///                     110 (Oak, south)
    /// A snap result with no graph behind it — enough to drive the phrasing
    /// functions, which only read the two name fields.
    static func snapFixture(
        name: String? = "Main St",
        ref: String? = nil
    ) -> RoadAwarenessEngine.SnapResult {
        RoadAwarenessEngine.SnapResult(
            segmentId: 1,
            segmentName: name,
            segmentRef: ref,
            highwayClass: "residential",
            snappedCoord: point(40.0, -75.0),
            perpendicularDistanceMeters: 4,
            segmentNodeIndex: 0,
            walkingForwardAlongNodeIds: true,
            confidence: 0.9
        )
    }

    static func crossroadsTile(roundabout: Bool = false) -> Tile {
        let west = point(40.0, -75.000)
        let mid = point(40.0, -74.999)
        let east = point(40.0, -74.998)
        let mainWest = segment(
            id: 1,
            name: "Main St",
            geometry: [west, mid],
            nodeIds: [100, 101]
        )
        let mainEast = segment(
            id: 2,
            name: "Main St",
            geometry: [mid, east],
            nodeIds: [101, 102]
        )
        let oak = segment(
            id: 3,
            name: "Oak Ave",
            geometry: [point(39.9995, -74.999), mid, point(40.0005, -74.999)],
            nodeIds: [110, 101, 111]
        )
        return tile(
            segments: [mainWest, mainEast, oak],
            nodes: [
                node(id: 100, at: west, ways: [1]),
                node(
                    id: 101,
                    at: mid,
                    ways: [1, 2, 3],
                    onRoundaboutWay: roundabout
                ),
                node(id: 102, at: east, ways: [2]),
                node(id: 110, at: point(39.9995, -74.999), ways: [3]),
                node(id: 111, at: point(40.0005, -74.999), ways: [3])
            ]
        )
    }

    /// A straight run of same-named segments, each `stepDegrees` of longitude
    /// long, with a named cross street at every interior node. Used to probe
    /// the two lookahead caps (intersection count, distance).
    static func chainTile(segmentCount: Int, stepDegrees: Double) -> Tile {
        var segments: [Segment] = []
        var nodes: [Node] = []
        let baseLon = -75.0
        var nodeWays: [Int64: [Int64]] = [:]

        for i in 0 ..< segmentCount {
            let wayId = Int64(i + 1)
            let a = point(40.0, baseLon + Double(i) * stepDegrees)
            let b = point(40.0, baseLon + Double(i + 1) * stepDegrees)
            let nodeA = Int64(200 + i)
            let nodeB = Int64(200 + i + 1)
            segments.append(segment(
                id: wayId,
                name: "Long Rd",
                geometry: [a, b],
                nodeIds: [nodeA, nodeB]
            ))
            nodeWays[nodeA, default: []].append(wayId)
            nodeWays[nodeB, default: []].append(wayId)
        }

        // A cross street hanging off every interior node, so each junction
        // has something nameable to announce.
        for i in 1 ..< segmentCount {
            let crossId = Int64(900 + i)
            let junctionNode = Int64(200 + i)
            let lon = baseLon + Double(i) * stepDegrees
            let crossNode = Int64(800 + i)
            segments.append(segment(
                id: crossId,
                name: "Cross \(i)",
                geometry: [point(40.0, lon), point(40.0005, lon)],
                nodeIds: [junctionNode, crossNode]
            ))
            nodeWays[junctionNode, default: []].append(crossId)
            nodeWays[crossNode, default: []].append(crossId)
            nodes.append(node(id: crossNode, at: point(40.0005, lon), ways: [crossId]))
        }

        for i in 0 ... segmentCount {
            let nodeId = Int64(200 + i)
            let coord = point(40.0, baseLon + Double(i) * stepDegrees)
            nodes.append(node(id: nodeId, at: coord, ways: nodeWays[nodeId] ?? []))
        }

        return tile(segments: segments, nodes: nodes)
    }
}

/// Haversine, bearing, projection, distance formatting, and the
/// bearing-trust gate — the primitives everything else is built on.
final class RoadAwarenessGeometryTests: XCTestCase {
    // MARK: - haversineMeters

    func testHaversineIsZeroForIdenticalPoints() {
        let p = RoadFixture.point(40.0, -75.0)
        XCTAssertEqual(RoadAwarenessEngine.haversineMeters(p, p), 0, accuracy: 1e-9)
    }

    func testHaversineMatchesOneDegreeOfLatitude() {
        // One degree of latitude on a 6,371 km sphere is R * π/180.
        let expected = 6_371_000.0 * .pi / 180
        let d = RoadAwarenessEngine.haversineMeters(RoadFixture.point(40.0, -75.0), RoadFixture.point(41.0, -75.0))
        XCTAssertEqual(d, expected, accuracy: 0.5)
    }

    func testHaversineShrinksLongitudeDistanceWithLatitude() {
        let atEquator = RoadAwarenessEngine.haversineMeters(
            RoadFixture.point(0, 0),
            RoadFixture.point(0, 1)
        )
        let atForty = RoadAwarenessEngine.haversineMeters(
            RoadFixture.point(40, 0),
            RoadFixture.point(40, 1)
        )
        // cos(40°) ≈ 0.766 — the classic convergence-of-meridians factor.
        XCTAssertEqual(atForty / atEquator, cos(40 * .pi / 180), accuracy: 0.001)
    }

    func testHaversineIsSymmetric() {
        let a = RoadFixture.point(40.0, -75.0)
        let b = RoadFixture.point(40.01, -74.98)
        XCTAssertEqual(
            RoadAwarenessEngine.haversineMeters(a, b),
            RoadAwarenessEngine.haversineMeters(b, a),
            accuracy: 1e-9
        )
    }

    // MARK: - bearingDegrees

    func testBearingCardinalDirections() {
        let origin = RoadFixture.point(40.0, -75.0)
        XCTAssertEqual(
            RoadAwarenessEngine.bearingDegrees(from: origin, to: RoadFixture.point(40.01, -75.0)),
            0,
            accuracy: 0.01
        )
        XCTAssertEqual(
            RoadAwarenessEngine.bearingDegrees(from: origin, to: RoadFixture.point(40.0, -74.99)),
            90,
            accuracy: 0.01
        )
        XCTAssertEqual(
            RoadAwarenessEngine.bearingDegrees(from: origin, to: RoadFixture.point(39.99, -75.0)),
            180,
            accuracy: 0.01
        )
        XCTAssertEqual(
            RoadAwarenessEngine.bearingDegrees(from: origin, to: RoadFixture.point(40.0, -75.01)),
            270,
            accuracy: 0.01
        )
    }

    func testBearingIsNormalisedToZeroThreeSixty() {
        // South-west should land in the third quadrant, not as a negative.
        let b = RoadAwarenessEngine.bearingDegrees(
            from: RoadFixture.point(40.0, -75.0),
            to: RoadFixture.point(39.99, -75.01)
        )
        XCTAssertGreaterThan(b, 180)
        XCTAssertLessThan(b, 270)
    }

    // MARK: - projectPointOntoSegment

    func testProjectionOntoMidpoint() {
        let a = RoadFixture.point(40.0, -75.0)
        let b = RoadFixture.point(40.0, -74.998)
        // Directly north of the segment's midpoint.
        let p = RoadFixture.point(40.001, -74.999)
        let result = RoadAwarenessEngine.projectPointOntoSegment(
            point: p,
            segmentStart: a,
            segmentEnd: b
        )
        XCTAssertEqual(result.t, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result.snapped.lat, 40.0, accuracy: 1e-9)
        XCTAssertEqual(result.snapped.lon, -74.999, accuracy: 1e-9)
    }

    func testProjectionClampsBeforeSegmentStart() {
        let a = RoadFixture.point(40.0, -75.0)
        let b = RoadFixture.point(40.0, -74.998)
        let result = RoadAwarenessEngine.projectPointOntoSegment(
            point: RoadFixture.point(40.0, -75.01),
            segmentStart: a,
            segmentEnd: b
        )
        XCTAssertEqual(result.t, 0)
        XCTAssertEqual(result.snapped, a)
    }

    func testProjectionClampsPastSegmentEnd() {
        let a = RoadFixture.point(40.0, -75.0)
        let b = RoadFixture.point(40.0, -74.998)
        let result = RoadAwarenessEngine.projectPointOntoSegment(
            point: RoadFixture.point(40.0, -74.99),
            segmentStart: a,
            segmentEnd: b
        )
        XCTAssertEqual(result.t, 1)
        XCTAssertEqual(result.snapped.lat, b.lat, accuracy: 1e-9)
        XCTAssertEqual(result.snapped.lon, b.lon, accuracy: 1e-9)
    }

    func testProjectionOntoDegenerateSegmentReturnsStart() {
        // Duplicated OSM geometry points are real and would divide by zero.
        let a = RoadFixture.point(40.0, -75.0)
        let result = RoadAwarenessEngine.projectPointOntoSegment(
            point: RoadFixture.point(40.5, -74.0),
            segmentStart: a,
            segmentEnd: a
        )
        XCTAssertEqual(result.t, 0)
        XCTAssertEqual(result.snapped, a)
    }

    // MARK: - formatDistance

    func testFormatDistanceUsesFeetBelowThreeHundredMeters() {
        XCTAssertEqual(RoadAwarenessEngine.formatDistance(0), "0 ft")
        // 100 m → 328.084 ft, rounded.
        XCTAssertEqual(RoadAwarenessEngine.formatDistance(100), "328 ft")
        XCTAssertEqual(
            RoadAwarenessEngine.formatDistance(299.9),
            "\(Int((299.9 * UnitConstants.feetPerMeter).rounded())) ft"
        )
    }

    func testFormatDistanceSwitchesToMilesAtThreeHundredMeters() {
        // The boundary is `< 300`, so exactly 300 m is already miles.
        XCTAssertEqual(RoadAwarenessEngine.formatDistance(300), "0.2 mi")
        XCTAssertEqual(RoadAwarenessEngine.formatDistance(1609.34), "1.0 mi")
        XCTAssertEqual(RoadAwarenessEngine.formatDistance(3218.68), "2.0 mi")
    }

    // MARK: - bearingTrust

    func testBearingDistrustedWhenCourseIsNegative() {
        let result = RoadAwarenessEngine.bearingTrust(
            for: RoadFixture.location(lat: 40, lon: -75, course: -1)
        )
        XCTAssertFalse(result.trusted)
        XCTAssertEqual(result.reason, "course=-1")
    }

    func testBearingDistrustedBelowWalkingSpeed() {
        let result = RoadAwarenessEngine.bearingTrust(
            for: RoadFixture.location(lat: 40, lon: -75, speed: 0.2)
        )
        XCTAssertFalse(result.trusted)
        XCTAssertTrue(result.reason.hasPrefix("speed<"))
    }

    func testBearingDistrustedWhenCourseAccuracyIsPoor() {
        let result = RoadAwarenessEngine.bearingTrust(
            for: RoadFixture.location(lat: 40, lon: -75, courseAccuracy: 45)
        )
        XCTAssertFalse(result.trusted)
        XCTAssertTrue(result.reason.hasPrefix("courseAccuracy>"))
    }

    func testBearingTrustedWhenCourseAccuracyUnavailableButSpeedIsGood() {
        // courseAccuracy == -1 means "not reported", not "bad". Older devices
        // and weak fixes both do this, and gating on it would silently turn
        // the feature off for them.
        let result = RoadAwarenessEngine.bearingTrust(
            for: RoadFixture.location(lat: 40, lon: -75, courseAccuracy: -1, speed: 2.0)
        )
        XCTAssertTrue(result.trusted)
        XCTAssertEqual(result.reason, "ok")
    }

    func testBearingTrustedWhenSpeedIsUnavailable() {
        // Negative speed is "unknown"; the speed gate only applies to a
        // reported, genuinely-slow value.
        let result = RoadAwarenessEngine.bearingTrust(
            for: RoadFixture.location(lat: 40, lon: -75, speed: -1)
        )
        XCTAssertTrue(result.trusted)
    }

    func testBearingTrustedForNormalRunningFix() {
        let result = RoadAwarenessEngine.bearingTrust(
            for: RoadFixture.location(lat: 40, lon: -75, course: 87, courseAccuracy: 10, speed: 3.2)
        )
        XCTAssertTrue(result.trusted)
        XCTAssertEqual(result.reason, "ok")
    }
}

/// Snapping a fix to a road segment, and walking the graph forward
/// from that snap.
final class RoadAwarenessSnapTests: XCTestCase {
    // MARK: - snap

    func testSnapReturnsNilForEmptyTile() {
        let empty = RoadFixture.tile(segments: [], nodes: [])
        XCTAssertNil(RoadAwarenessEngine.snap(
            location: RoadFixture.location(lat: 40, lon: -75),
            tile: empty,
            useBearing: false,
            userCourseDegrees: nil
        ))
    }

    func testSnapReturnsNilWhenNoSegmentIsWithinThreshold() {
        // ~0.002° of latitude ≈ 222 m north of Main St, well past the 40 m cap.
        XCTAssertNil(RoadAwarenessEngine.snap(
            location: RoadFixture.location(lat: 40.002, lon: -75.0),
            tile: RoadFixture.crossroadsTile(),
            useBearing: false,
            userCourseDegrees: nil
        ))
    }

    func testSnapFindsNearestSegmentAndPosition() {
        // ~5.6 m north of the west end of Main St.
        guard let result = RoadAwarenessEngine.snap(
            location: RoadFixture.location(lat: 40.00005, lon: -75.0),
            tile: RoadFixture.crossroadsTile(),
            useBearing: true,
            userCourseDegrees: 90
        ) else { return XCTFail("expected a snap") }
        XCTAssertEqual(result.segmentId, 1)
        XCTAssertEqual(result.segmentName, "Main St")
        XCTAssertEqual(result.highwayClass, "residential")
        XCTAssertEqual(result.segmentNodeIndex, 0)
        XCTAssertEqual(result.perpendicularDistanceMeters, 5.56, accuracy: 0.2)
        XCTAssertEqual(result.snappedCoord.lat, 40.0, accuracy: 1e-9)
    }

    func testSnapDetectsForwardTravelAlongNodeOrder() {
        let snap = RoadAwarenessEngine.snap(
            location: RoadFixture.location(lat: 40.00005, lon: -75.0, course: 90),
            tile: RoadFixture.crossroadsTile(),
            useBearing: true,
            userCourseDegrees: 90
        )
        XCTAssertEqual(snap?.walkingForwardAlongNodeIds, true)
    }

    func testSnapDetectsReverseTravelAlongNodeOrder() {
        // Main St's nodeIds run west→east; a runner heading west is reversed.
        let snap = RoadAwarenessEngine.snap(
            location: RoadFixture.location(lat: 40.00005, lon: -75.0, course: 270),
            tile: RoadFixture.crossroadsTile(),
            useBearing: true,
            userCourseDegrees: 270
        )
        XCTAssertEqual(snap?.walkingForwardAlongNodeIds, false)
    }

    func testSnapLeavesDirectionUnknownWithoutTrustedBearing() {
        let snap = RoadAwarenessEngine.snap(
            location: RoadFixture.location(lat: 40.00005, lon: -75.0),
            tile: RoadFixture.crossroadsTile(),
            useBearing: false,
            userCourseDegrees: nil
        )
        XCTAssertNil(snap?.walkingForwardAlongNodeIds)
    }

    func testSnapConfidenceFallsWithDistanceAndRisesWithBearingTrust() {
        let near = RoadAwarenessEngine.snap(
            location: RoadFixture.location(lat: 40.00005, lon: -75.0),
            tile: RoadFixture.crossroadsTile(),
            useBearing: true,
            userCourseDegrees: 90
        )
        let far = RoadAwarenessEngine.snap(
            location: RoadFixture.location(lat: 40.0003, lon: -75.0),
            tile: RoadFixture.crossroadsTile(),
            useBearing: true,
            userCourseDegrees: 90
        )
        let untrusted = RoadAwarenessEngine.snap(
            location: RoadFixture.location(lat: 40.00005, lon: -75.0),
            tile: RoadFixture.crossroadsTile(),
            useBearing: false,
            userCourseDegrees: nil
        )
        guard let near, let far, let untrusted else {
            return XCTFail("expected three snaps")
        }
        XCTAssertGreaterThan(near.confidence, far.confidence)
        XCTAssertGreaterThan(near.confidence, untrusted.confidence)
        // Bearing contributes a flat 0.3 vs 0.15 — the gap is exactly 0.15.
        XCTAssertEqual(near.confidence - untrusted.confidence, 0.15, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(near.confidence, 1.0)
        XCTAssertGreaterThanOrEqual(far.confidence, 0.0)
    }

    func testSnapPrefersTheRoadTheUserIsTravellingAlong() {
        // Standing within snapping range of both Main (east-west) and Oak
        // (north-south) at their crossing, but moving east. Bearing is what
        // breaks the tie — this is the whole reason `useBearing` exists.
        let onCrossing = RoadFixture.location(lat: 40.00002, lon: -74.99902, course: 90)
        let withBearing = RoadAwarenessEngine.snap(
            location: onCrossing,
            tile: RoadFixture.crossroadsTile(),
            useBearing: true,
            userCourseDegrees: 90
        )
        XCTAssertNotEqual(withBearing?.segmentId, 3, "should not snap to Oak Ave while running east")
        XCTAssertEqual(withBearing?.segmentName, "Main St")
    }

    // MARK: - lookahead

    func testLookaheadReportsCrossStreetThenDeadEnd() {
        let fixture = RoadFixture.crossroadsTile()
        guard let snap = RoadAwarenessEngine.snap(
            location: RoadFixture.location(lat: 40.00005, lon: -75.0),
            tile: fixture,
            useBearing: true,
            userCourseDegrees: 90
        ) else { return XCTFail("expected a snap") }

        let events = RoadAwarenessEngine.lookahead(from: snap, tile: fixture)
        XCTAssertEqual(events.count, 2)

        guard case let .intersection(crossStreets, isRoundabout) = events[0].kind else {
            return XCTFail("first event should be an intersection")
        }
        XCTAssertEqual(crossStreets, ["Oak Ave"])
        XCTAssertFalse(isRoundabout)
        XCTAssertEqual(events[0].distanceMeters, 85.4, accuracy: 2.0)

        guard case let .roadEnds(continuations) = events[1].kind else {
            return XCTFail("second event should be the road ending")
        }
        XCTAssertTrue(continuations.isEmpty, "dead end has nothing to continue into")
        XCTAssertEqual(events[1].distanceMeters, 170.8, accuracy: 3.0)
    }

    func testLookaheadFlagsRoundabouts() {
        let fixture = RoadFixture.crossroadsTile(roundabout: true)
        guard let snap = RoadAwarenessEngine.snap(
            location: RoadFixture.location(lat: 40.00005, lon: -75.0),
            tile: fixture,
            useBearing: true,
            userCourseDegrees: 90
        ) else { return XCTFail("expected a snap") }

        let events = RoadAwarenessEngine.lookahead(from: snap, tile: fixture)
        guard let first = events.first,
              case let .intersection(_, isRoundabout) = first.kind
        else {
            return XCTFail("first event should be an intersection")
        }
        XCTAssertTrue(isRoundabout)
    }

    func testLookaheadReturnsEmptyWhenSnapSegmentIsNotInTile() {
        let orphan = RoadAwarenessEngine.SnapResult(
            segmentId: 9999,
            segmentName: "Ghost Rd",
            segmentRef: nil,
            highwayClass: "residential",
            snappedCoord: RoadFixture.point(40.0, -75.0),
            perpendicularDistanceMeters: 1,
            segmentNodeIndex: 0,
            walkingForwardAlongNodeIds: true,
            confidence: 0.9
        )
        XCTAssertTrue(RoadAwarenessEngine.lookahead(from: orphan, tile: RoadFixture.crossroadsTile()).isEmpty)
    }

    func testLookaheadStopsAtThreeIntersections() {
        // Six 85 m blocks — 510 m total, inside the distance cap, so the
        // intersection cap is the binding constraint.
        let fixture = RoadFixture.chainTile(segmentCount: 6, stepDegrees: 0.001)
        guard let snap = RoadAwarenessEngine.snap(
            location: RoadFixture.location(lat: 40.00005, lon: -75.0),
            tile: fixture,
            useBearing: true,
            userCourseDegrees: 90
        ) else { return XCTFail("expected a snap") }

        let events = RoadAwarenessEngine.lookahead(from: snap, tile: fixture)
        XCTAssertEqual(events.count, RoadAwarenessEngine.maxLookaheadIntersections)
        for event in events {
            guard case .intersection = event.kind else {
                return XCTFail("chain fixture should yield only intersections")
            }
        }
    }

    func testLookaheadStopsAtSixHundredMeters() {
        // 0.005° ≈ 427 m per block: the second junction is at ~854 m and is
        // never reported.
        let fixture = RoadFixture.chainTile(segmentCount: 4, stepDegrees: 0.005)
        guard let snap = RoadAwarenessEngine.snap(
            location: RoadFixture.location(lat: 40.00005, lon: -75.0),
            tile: fixture,
            useBearing: true,
            userCourseDegrees: 90
        ) else { return XCTFail("expected a snap") }

        let events = RoadAwarenessEngine.lookahead(from: snap, tile: fixture)
        XCTAssertEqual(events.count, 1)
        XCTAssertLessThanOrEqual(
            events[0].distanceMeters,
            RoadAwarenessEngine.maxLookaheadMeters
        )
    }

    func testLookaheadDistancesAreMonotonicallyIncreasing() {
        let fixture = RoadFixture.chainTile(segmentCount: 6, stepDegrees: 0.001)
        guard let snap = RoadAwarenessEngine.snap(
            location: RoadFixture.location(lat: 40.00005, lon: -75.0),
            tile: fixture,
            useBearing: true,
            userCourseDegrees: 90
        ) else { return XCTFail("expected a snap") }

        let distances = RoadAwarenessEngine.lookahead(from: snap, tile: fixture)
            .map(\.distanceMeters)
        XCTAssertEqual(distances, distances.sorted())
        XCTAssertEqual(Set(distances).count, distances.count)
    }

    func testLookaheadNamesEachCrossStreetInOrder() {
        let fixture = RoadFixture.chainTile(segmentCount: 6, stepDegrees: 0.001)
        guard let snap = RoadAwarenessEngine.snap(
            location: RoadFixture.location(lat: 40.00005, lon: -75.0),
            tile: fixture,
            useBearing: true,
            userCourseDegrees: 90
        ) else { return XCTFail("expected a snap") }

        let names = RoadAwarenessEngine.lookahead(from: snap, tile: fixture)
            .compactMap { event -> [String]? in
                guard case let .intersection(cross, _) = event.kind else { return nil }
                return cross
            }
        XCTAssertEqual(names, [["Cross 1"], ["Cross 2"], ["Cross 3"]])
    }
}

/// What actually gets said out loud, plus the end-to-end composition
/// of snap + lookahead + phrase.
final class RoadAwarenessPhrasingTests: XCTestCase {
    // MARK: - constructPhrase

    func testPhraseNamesTheCurrentRoadWithNoUpcomingEvents() {
        XCTAssertEqual(
            RoadAwarenessEngine.constructPhrase(
                snap: RoadFixture.snapFixture(),
                events: [],
                roadContinuesForMeters: nil,
                neighborhoodFallback: nil
            ),
            "on Main St"
        )
    }

    func testPhraseFallsBackToRouteRefWhenTheRoadIsUnnamed() {
        XCTAssertEqual(
            RoadAwarenessEngine.constructPhrase(
                snap: RoadFixture.snapFixture(name: nil, ref: "US-441"),
                events: [],
                roadContinuesForMeters: nil,
                neighborhoodFallback: nil
            ),
            "on US-441"
        )
    }

    func testPhraseUsesNeighbourhoodWhenTheRoadHasNoNameAtAll() {
        // Japan, Korea, and plenty of rural roads have no name tag. The
        // engine degrades to the area rather than going silent.
        XCTAssertEqual(
            RoadAwarenessEngine.constructPhrase(
                snap: RoadFixture.snapFixture(name: nil),
                events: [],
                roadContinuesForMeters: nil,
                neighborhoodFallback: "Shibuya"
            ),
            "walking through Shibuya"
        )
    }

    func testPhraseIsNilWhenThereIsNothingSafeToSay() {
        // The global invariant: never invent a road name.
        XCTAssertNil(RoadAwarenessEngine.constructPhrase(
            snap: RoadFixture.snapFixture(name: nil),
            events: [],
            roadContinuesForMeters: nil,
            neighborhoodFallback: nil
        ))
    }

    func testPhraseAnnouncesTheNextCrossStreet() {
        let phrase = RoadAwarenessEngine.constructPhrase(
            snap: RoadFixture.snapFixture(),
            events: [
                RoadAwarenessEngine.LookaheadEvent(
                    distanceMeters: 100,
                    kind: .intersection(crossStreets: ["Oak Ave", "Elm St"], isRoundabout: false)
                )
            ],
            roadContinuesForMeters: nil,
            neighborhoodFallback: nil
        )
        XCTAssertEqual(phrase, "on Main St, approaching Oak Ave in 328 ft")
    }

    func testPhrasePrefersRoundaboutOverCrossStreetName() {
        let phrase = RoadAwarenessEngine.constructPhrase(
            snap: RoadFixture.snapFixture(),
            events: [
                RoadAwarenessEngine.LookaheadEvent(
                    distanceMeters: 100,
                    kind: .intersection(crossStreets: ["Oak Ave"], isRoundabout: true)
                )
            ],
            roadContinuesForMeters: nil,
            neighborhoodFallback: nil
        )
        XCTAssertEqual(phrase, "on Main St, approaching a roundabout in 328 ft")
    }

    func testPhraseFallsBackToRoadLengthAtAnUnnamedIntersection() {
        let phrase = RoadAwarenessEngine.constructPhrase(
            snap: RoadFixture.snapFixture(),
            events: [
                RoadAwarenessEngine.LookaheadEvent(
                    distanceMeters: 100,
                    kind: .intersection(crossStreets: [], isRoundabout: false)
                )
            ],
            roadContinuesForMeters: 500,
            neighborhoodFallback: nil
        )
        XCTAssertEqual(phrase, "on Main St, road continues 0.3 mi before the next change")
    }

    func testPhraseOmitsTheClauseWhenAnUnnamedIntersectionHasNoDistanceEither() {
        let phrase = RoadAwarenessEngine.constructPhrase(
            snap: RoadFixture.snapFixture(),
            events: [
                RoadAwarenessEngine.LookaheadEvent(
                    distanceMeters: 100,
                    kind: .intersection(crossStreets: [], isRoundabout: false)
                )
            ],
            roadContinuesForMeters: nil,
            neighborhoodFallback: nil
        )
        XCTAssertEqual(phrase, "on Main St")
    }

    func testPhraseAnnouncesWhereTheRoadEnds() {
        let phrase = RoadAwarenessEngine.constructPhrase(
            snap: RoadFixture.snapFixture(),
            events: [
                RoadAwarenessEngine.LookaheadEvent(
                    distanceMeters: 200,
                    kind: .roadEnds(continuations: ["Oak Ave", "Elm St"])
                )
            ],
            roadContinuesForMeters: 200,
            neighborhoodFallback: nil
        )
        XCTAssertEqual(phrase, "on Main St, ends at Oak Ave in 656 ft")
    }

    func testPhraseAnnouncesADeadEndWithoutNamingAnything() {
        let phrase = RoadAwarenessEngine.constructPhrase(
            snap: RoadFixture.snapFixture(),
            events: [
                RoadAwarenessEngine.LookaheadEvent(
                    distanceMeters: 200,
                    kind: .roadEnds(continuations: [])
                )
            ],
            roadContinuesForMeters: 200,
            neighborhoodFallback: nil
        )
        XCTAssertEqual(phrase, "on Main St, ends in 656 ft")
    }

    func testPhraseUsesOnlyTheFirstEvent() {
        let phrase = RoadAwarenessEngine.constructPhrase(
            snap: RoadFixture.snapFixture(),
            events: [
                RoadAwarenessEngine.LookaheadEvent(
                    distanceMeters: 100,
                    kind: .intersection(crossStreets: ["Oak Ave"], isRoundabout: false)
                ),
                RoadAwarenessEngine.LookaheadEvent(
                    distanceMeters: 400,
                    kind: .roadEnds(continuations: ["Elm St"])
                )
            ],
            roadContinuesForMeters: 400,
            neighborhoodFallback: nil
        )
        XCTAssertEqual(phrase, "on Main St, approaching Oak Ave in 328 ft")
        XCTAssertFalse(phrase?.contains("Elm") ?? true)
    }

    // MARK: - phraseFromFallback

    func testPhraseFromFallbackWrapsTheNeighbourhood() {
        XCTAssertEqual(
            RoadAwarenessEngine.phraseFromFallback("Fishtown"),
            "walking through Fishtown"
        )
    }

    func testPhraseFromFallbackIsNilWithoutANeighbourhood() {
        XCTAssertNil(RoadAwarenessEngine.phraseFromFallback(nil))
    }

    // MARK: - awareness (end to end, pure variant)

    func testAwarenessComposesSnapLookaheadAndPhrase() {
        let result = RoadAwarenessEngine.awareness(
            for: RoadFixture.location(lat: 40.00005, lon: -75.0, course: 90),
            tile: RoadFixture.crossroadsTile(),
            neighborhoodFallback: nil
        )
        XCTAssertEqual(result.currentRoadName, "Main St")
        XCTAssertEqual(result.events.count, 2)
        XCTAssertGreaterThan(result.confidence, 0.8)
        // `roadContinuesForMeters` tracks the first `roadEnds`, not the first
        // event — the crossing at ~85 m does not end Main St.
        XCTAssertEqual(result.roadContinuesForMeters ?? 0, 170.8, accuracy: 3.0)
        let phrase = result.phrase ?? ""
        XCTAssertTrue(phrase.hasPrefix("on Main St, approaching Oak Ave in "), phrase)
        XCTAssertTrue(phrase.hasSuffix(" ft"), phrase)
    }

    func testAwarenessDegradesToNeighbourhoodWhenTheSnapFails() {
        let result = RoadAwarenessEngine.awareness(
            for: RoadFixture.location(lat: 40.002, lon: -75.0),
            tile: RoadFixture.crossroadsTile(),
            neighborhoodFallback: "Fishtown"
        )
        XCTAssertNil(result.currentRoadName)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.confidence, 0)
        XCTAssertNil(result.roadContinuesForMeters)
        XCTAssertEqual(result.phrase, "walking through Fishtown")
    }

    func testAwarenessSaysNothingWhenTheSnapFailsAndThereIsNoFallback() {
        let result = RoadAwarenessEngine.awareness(
            for: RoadFixture.location(lat: 40.002, lon: -75.0),
            tile: RoadFixture.crossroadsTile(),
            neighborhoodFallback: nil
        )
        XCTAssertNil(result.phrase)
        XCTAssertEqual(result.confidence, 0)
    }

    func testAwarenessOnAnEmptyTileIsSilentRatherThanWrong() {
        let result = RoadAwarenessEngine.awareness(
            for: RoadFixture.location(lat: 40.0, lon: -75.0),
            tile: RoadFixture.tile(segments: [], nodes: []),
            neighborhoodFallback: nil
        )
        XCTAssertNil(result.currentRoadName)
        XCTAssertNil(result.phrase)
        XCTAssertTrue(result.events.isEmpty)
    }
}
