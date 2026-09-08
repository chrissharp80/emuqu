import CoreLocation
@testable import Emuqu
import XCTest

/// Tests for the route-matching geometry.
///
/// `RouteLibrary` decides whether the run
/// you are on is recognised as a route you have run before — which is what
/// gates the route-history TRIMP estimate, the fallback that credits your
/// training load when the strap drops. A false match anchors your load on
/// somebody else's hill.
@MainActor
final class RouteLibraryGeometryTests: XCTestCase {
    /// A straight line east from a fixed origin, one point every ~70 m.
    private func line(points: Int, spacingDegrees: Double = 0.001) -> [CLLocation] {
        (0 ..< points).map {
            CLLocation(latitude: 51.5, longitude: Double($0) * spacingDegrees)
        }
    }

    // MARK: - Total distance

    func testTotalDistanceSumsConsecutiveLegs() {
        let track = line(points: 3)
        let expected = track[0].distance(from: track[1]) + track[1].distance(from: track[2])
        XCTAssertEqual(RouteLibrary.totalDistanceMeters(of: track), expected, accuracy: 0.001)
    }

    func testSinglePointHasNoDistance() {
        XCTAssertEqual(RouteLibrary.totalDistanceMeters(of: line(points: 1)), 0)
    }

    func testEmptyTrackHasNoDistance() {
        XCTAssertEqual(RouteLibrary.totalDistanceMeters(of: []), 0)
    }

    // MARK: - Prefix

    func testPrefixStopsOnceTheDistanceIsCovered() {
        let track = line(points: 50)
        let prefix = RouteLibrary.trackPrefix(track, meters: 200)
        XCTAssertLessThan(prefix.count, track.count, "a 200 m prefix of a long track is not the whole track")
        XCTAssertGreaterThanOrEqual(
            RouteLibrary.totalDistanceMeters(of: prefix), 200,
            "the prefix must cover the distance asked for"
        )
    }

    func testPrefixLongerThanTheTrackReturnsEverything() {
        let track = line(points: 5)
        XCTAssertEqual(RouteLibrary.trackPrefix(track, meters: 1_000_000).count, track.count)
    }

    func testPrefixOfZeroMetresReturnsTheTrackUnchanged() {
        // Guarded rather than returning an empty prefix, which would make the
        // shape comparison trivially "match".
        let track = line(points: 5)
        XCTAssertEqual(RouteLibrary.trackPrefix(track, meters: 0).count, track.count)
    }

    func testPrefixKeepsTheStartingPoint() {
        let track = line(points: 30)
        let prefix = RouteLibrary.trackPrefix(track, meters: 150)
        XCTAssertEqual(prefix.first?.coordinate.longitude, track.first?.coordinate.longitude)
    }

    // MARK: - Mean nearest distance

    func testIdenticalTracksHaveZeroMeanDistance() {
        let track = line(points: 20)
        XCTAssertEqual(RouteLibrary.meanNearestDistance(from: track, to: track), 0, accuracy: 0.001)
    }

    func testParallelTrackMeasuresTheOffset() {
        let a = line(points: 10)
        // Same longitudes, shifted north — every point's nearest neighbour is
        // its opposite number.
        let b = a.map { CLLocation(latitude: $0.coordinate.latitude + 0.0005, longitude: $0.coordinate.longitude) }
        let mean = RouteLibrary.meanNearestDistance(from: a, to: b)
        XCTAssertEqual(mean, a[0].distance(from: b[0]), accuracy: 1.0)
    }

    func testEmptyComparisonIsInfiniteNotZero() {
        // Zero would read as a perfect match and wrongly claim the route.
        XCTAssertEqual(RouteLibrary.meanNearestDistance(from: line(points: 5), to: []), .infinity)
        XCTAssertEqual(RouteLibrary.meanNearestDistance(from: [], to: line(points: 5)), .infinity)
    }

    func testMeanIsSymmetricForIdenticalShapes() {
        // The doc promises the same number regardless of sample density, so a
        // denser copy of the same line must still read as a match.
        let sparse = line(points: 10, spacingDegrees: 0.002)
        let dense = line(points: 20, spacingDegrees: 0.001)
        XCTAssertLessThan(
            RouteLibrary.meanNearestDistance(from: sparse, to: dense), 5,
            "the same path sampled differently is still the same path"
        )
    }

    // MARK: - Nearest distance

    func testNearestPicksTheClosestPoint() {
        let target = CLLocation(latitude: 51.5, longitude: 0.0015)
        let candidates = line(points: 5)
        let best = RouteLibrary.nearestDistance(from: target, to: candidates)
        let bruteForce = candidates.map { target.distance(from: $0) }.min() ?? .infinity
        XCTAssertEqual(best, bruteForce, accuracy: 0.001)
    }
}
