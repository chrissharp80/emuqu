import CoreLocation
@testable import Emuqu
import XCTest

/// Tests for the pure geometry and physiology used during a workout.
@MainActor
final class WorkoutGeometryTests: XCTestCase {
    // MARK: - Bearing

    func testBearingDueNorthIsZero() {
        let a = Route.Point(latitude: 51.500, longitude: -0.100, altitudeMeters: 0)
        let b = Route.Point(latitude: 51.510, longitude: -0.100, altitudeMeters: 0)
        XCTAssertEqual(WorkoutGeometry.bearing(from: a, to: b), 0, accuracy: 0.5)
    }

    func testBearingDueEastIsNinety() {
        let a = Route.Point(latitude: 51.500, longitude: -0.100, altitudeMeters: 0)
        let b = Route.Point(latitude: 51.500, longitude: -0.050, altitudeMeters: 0)
        XCTAssertEqual(WorkoutGeometry.bearing(from: a, to: b), 90, accuracy: 0.5)
    }

    func testBearingDueSouthIsOneEighty() {
        let a = Route.Point(latitude: 51.510, longitude: -0.100, altitudeMeters: 0)
        let b = Route.Point(latitude: 51.500, longitude: -0.100, altitudeMeters: 0)
        XCTAssertEqual(WorkoutGeometry.bearing(from: a, to: b), 180, accuracy: 0.5)
    }

    func testBearingIsAlwaysInZeroTo360() {
        // West is 270, not -90. A negative bearing would send a turn cue the
        // wrong way.
        let a = Route.Point(latitude: 51.500, longitude: -0.050, altitudeMeters: 0)
        let b = Route.Point(latitude: 51.500, longitude: -0.100, altitudeMeters: 0)
        let west = WorkoutGeometry.bearing(from: a, to: b)
        XCTAssertEqual(west, 270, accuracy: 0.5)
        XCTAssertTrue((0 ..< 360).contains(west))
    }

    // MARK: - Signed bearing delta

    func testDeltaWrapsTheShortWayRound() {
        // 350 -> 10 is a 20-degree right turn, not a 340-degree left one.
        XCTAssertEqual(WorkoutGeometry.signedBearingDelta(from: 350, to: 10), 20, accuracy: 0.001)
        XCTAssertEqual(WorkoutGeometry.signedBearingDelta(from: 10, to: 350), -20, accuracy: 0.001)
    }

    func testDeltaSignIndicatesTurnDirection() {
        XCTAssertGreaterThan(WorkoutGeometry.signedBearingDelta(from: 90, to: 135), 0, "right")
        XCTAssertLessThan(WorkoutGeometry.signedBearingDelta(from: 90, to: 45), 0, "left")
    }

    func testDeltaOfNoTurnIsZero() {
        XCTAssertEqual(WorkoutGeometry.signedBearingDelta(from: 42, to: 42), 0, accuracy: 0.001)
    }

    // MARK: - Turn labels

    func testTurnLabelNamesTheCorrectSide() {
        XCTAssertTrue(WorkoutGeometry.turnLabel(deltaDegrees: 90).contains("right"))
        XCTAssertTrue(WorkoutGeometry.turnLabel(deltaDegrees: -90).contains("left"))
    }

    func testTurnLabelIsNeverEmpty() {
        // Spoken aloud mid-run; an empty string is silence where a cue belongs.
        for delta in stride(from: -180.0, through: 180.0, by: 15.0) {
            XCTAssertFalse(
                WorkoutGeometry.turnLabel(deltaDegrees: delta).isEmpty,
                "no label for a \(delta) degree turn"
            )
        }
    }

    // MARK: - Heart-rate zones

    func testHRMaxZonesSpanOneToFive() {
        // % of max HR, breakpoints at 60/70/80/90 %: the band model the
        // zone-time breakdown and the zone-drift rules use.
        let maxHR = 200
        XCTAssertEqual(WorkoutGeometry.hrMaxZone(hr: 110, maxHR: maxHR), 1)
        XCTAssertEqual(WorkoutGeometry.hrMaxZone(hr: 130, maxHR: maxHR), 2)
        XCTAssertEqual(WorkoutGeometry.hrMaxZone(hr: 150, maxHR: maxHR), 3)
        XCTAssertEqual(WorkoutGeometry.hrMaxZone(hr: 170, maxHR: maxHR), 4)
        XCTAssertEqual(WorkoutGeometry.hrMaxZone(hr: 185, maxHR: maxHR), 5)
    }

    /// The audit's case: max 190, HR 150 is 79 % of max, zone 3 in the
    /// breakdown, so a "stay in Zone 3" threshold must see zone 3 too.
    func testHRMaxZoneMatchesTheBreakdownBands() {
        XCTAssertEqual(WorkoutGeometry.hrMaxZone(hr: 150, maxHR: 190), 3)
    }

    func testHRMaxZoneWithoutAHeartRateIsNil() {
        XCTAssertNil(WorkoutGeometry.hrMaxZone(hr: nil, maxHR: 190))
    }

    func testHRMaxZoneRejectsAMissingMax() {
        XCTAssertNil(WorkoutGeometry.hrMaxZone(hr: 150, maxHR: 0))
    }

    func testVeryLowHeartRateIsStillZoneOne() {
        XCTAssertEqual(WorkoutGeometry.hrMaxZone(hr: 40, maxHR: 190), 1)
    }

    // MARK: - Track length

    func testTrackLengthSumsConsecutiveLegs() {
        let track = (0 ..< 4).map { CLLocation(latitude: 51.5, longitude: Double($0) * 0.001) }
        let expected = zip(track, track.dropFirst()).reduce(0.0) { $0 + $1.0.distance(from: $1.1) }
        XCTAssertEqual(WorkoutGeometry.trackLengthMeters(track), expected, accuracy: 0.001)
    }

    func testTrackLengthOfFewerThanTwoPointsIsZero() {
        XCTAssertEqual(WorkoutGeometry.trackLengthMeters([]), 0)
        XCTAssertEqual(WorkoutGeometry.trackLengthMeters([CLLocation(latitude: 51.5, longitude: 0)]), 0)
    }

    // MARK: - Next index along a route

    func testNextIndexFindsThePointPastTheDistance() {
        let dists: [Double] = [0, 100, 200, 300, 400]
        XCTAssertEqual(WorkoutGeometry.nextIndex(after: 0, atDistance: 250, in: dists), 3)
    }

    func testNextIndexIsNilAtEndOfRoute() {
        let dists: [Double] = [0, 100, 200]
        XCTAssertNil(WorkoutGeometry.nextIndex(after: 0, atDistance: 5_000, in: dists))
    }

    func testNextIndexPastTheEndIsNilNotACrash() {
        XCTAssertNil(WorkoutGeometry.nextIndex(after: 99, atDistance: 100, in: [0, 100]))
    }

    func testNextIndexOnAnEmptyRouteIsNil() {
        XCTAssertNil(WorkoutGeometry.nextIndex(after: 0, atDistance: 100, in: []))
    }
}
