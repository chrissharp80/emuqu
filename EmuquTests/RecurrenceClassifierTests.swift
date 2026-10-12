import CoreLocation
@testable import Emuqu
import XCTest

/// Tests for the recurring-route classifier: its geometry helpers and
/// `match(current:archive:)` on synthetic trails.
///
/// `roundCoord` buckets a trail by its
/// starting point: two trails are only compared if their rounded coordinates
/// match. Round too coarsely and separate routes merge into one "recurring"
/// trail; too finely and the same loop never recognises itself.
final class RecurrenceClassifierTests: XCTestCase {
    // MARK: - Rounding to a metre grid

    func testLatitudeRoundsToTheRequestedGrid() {
        // ~111 km per degree of latitude, so a 100 m grid is ~0.0009 degrees.
        let a = RecurrenceClassifier.roundCoord(51.500_00, toMeters: 100)
        let b = RecurrenceClassifier.roundCoord(51.500_20, toMeters: 100)
        XCTAssertEqual(a, b, accuracy: 1e-9, "22 m apart must land in the same 100 m bucket")
    }

    func testPointsBeyondTheGridLandInDifferentBuckets() {
        let a = RecurrenceClassifier.roundCoord(51.5000, toMeters: 100)
        let b = RecurrenceClassifier.roundCoord(51.5050, toMeters: 100)
        XCTAssertNotEqual(a, b, "555 m apart must not share a 100 m bucket")
    }

    // MARK: - Longitude narrows with latitude

    func testLongitudeGridWidensInDegreesTowardThePoles() {
        // A degree of longitude covers less ground the further from the
        // equator, so a fixed metre grid must span MORE degrees up north.
        // Without the cosine correction, northern routes bucket too finely and
        // a recurring loop never matches itself.
        let atEquator = RecurrenceClassifier.roundCoord(
            0.010, toMeters: 100, isLongitude: true, latitudeForCorrection: 0
        )
        let atSixty = RecurrenceClassifier.roundCoord(
            0.010, toMeters: 100, isLongitude: true, latitudeForCorrection: 60
        )
        // At 60 degrees, cos = 0.5, so the grid is twice as wide in degrees and
        // 0.010 rounds to a coarser multiple.
        XCTAssertNotEqual(atEquator, atSixty, "the longitude grid must scale with latitude")
    }

    func testLongitudeAtTheEquatorMatchesLatitudeScale() {
        // cos(0) = 1, so longitude and latitude use the same metres-per-degree.
        let lat = RecurrenceClassifier.roundCoord(0.010, toMeters: 100)
        let lon = RecurrenceClassifier.roundCoord(
            0.010, toMeters: 100, isLongitude: true, latitudeForCorrection: 0
        )
        XCTAssertEqual(lat, lon, accuracy: 1e-12)
    }

    func testExtremeLatitudeDoesNotDivideByZero() {
        // cos(90 degrees) is ~0; the `max(1, metersPerDeg)` floor keeps this
        // finite rather than producing an infinite grid step.
        let value = RecurrenceClassifier.roundCoord(
            10.0, toMeters: 100, isLongitude: true, latitudeForCorrection: 90
        )
        XCTAssertTrue(value.isFinite, "a pole must not produce a non-finite bucket")
    }

    func testZeroStaysZero() {
        XCTAssertEqual(RecurrenceClassifier.roundCoord(0, toMeters: 100), 0, accuracy: 1e-12)
    }

    func testNegativeCoordinatesRoundSymmetrically() {
        let positive = RecurrenceClassifier.roundCoord(0.0050, toMeters: 100)
        let negative = RecurrenceClassifier.roundCoord(-0.0050, toMeters: 100)
        XCTAssertEqual(positive, -negative, accuracy: 1e-12, "western hemisphere must bucket like eastern")
    }

    // MARK: - Median

    func testMedianOfOddCount() {
        XCTAssertEqual(RecurrenceClassifier.median([3.0, 1.0, 2.0]) ?? 0, 2.0, accuracy: 1e-12)
    }

    func testMedianOfEvenCountAveragesTheMiddlePair() {
        XCTAssertEqual(RecurrenceClassifier.median([1.0, 2.0, 3.0, 4.0]) ?? 0, 2.5, accuracy: 1e-12)
    }

    func testMedianOfEmptyIsNil() {
        // Nil, not zero: "no trails yet" must not read as "median duration 0".
        XCTAssertNil(RecurrenceClassifier.median([Double]()))
    }

    func testMedianOfOneIsThatValue() {
        XCTAssertEqual(RecurrenceClassifier.median([7.5]) ?? 0, 7.5, accuracy: 1e-12)
    }

    func testMedianIsOrderIndependent() {
        let unsorted: [Double] = [9, 1, 7, 3, 5]
        XCTAssertEqual(
            RecurrenceClassifier.median(unsorted) ?? 0,
            RecurrenceClassifier.median(unsorted.sorted()) ?? 0,
            accuracy: 1e-12
        )
    }

    // MARK: - Cumulative distance

    func testCumulativeDistanceStartsAtZeroAndGrows() {
        let pts = (0 ..< 5).map { CLLocationCoordinate2D(latitude: 51.5, longitude: Double($0) * 0.001) }
        let cum = RecurrenceClassifier.cumulativeDistances(along: pts)
        XCTAssertEqual(cum.first ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(cum.count, pts.count)
        XCTAssertEqual(cum, cum.sorted(), "cumulative distance must never decrease")
    }

    func testCumulativeDistanceOfASinglePointIsJustZero() {
        let cum = RecurrenceClassifier.cumulativeDistances(
            along: [CLLocationCoordinate2D(latitude: 51.5, longitude: 0)]
        )
        XCTAssertEqual(cum, [0])
    }

    func testCumulativeDistanceOfNothingIsEmptyNotACrash() {
        XCTAssertTrue(RecurrenceClassifier.cumulativeDistances(along: []).isEmpty)
    }

    // MARK: - Matching a trail against the archive

    func testThreePriorWalksOfTheSameRouteMatchMidWalk() throws {
        // The current walk has covered the first 600 m of a 2 km route walked
        // three times before; each archived walk is cut at 600 m to compare.
        let route = path(northMeters: 2_000)
        let archive = try [40.0, 45.0, 50.0].enumerated().map { index, minutes in
            try trail(daysAgo: index + 1, along: route, minutes: minutes)
        }
        let current = try trail(daysAgo: 0, along: path(northMeters: 600), minutes: 8)

        let match = try XCTUnwrap(RecurrenceClassifier.match(current: current, archive: archive))
        XCTAssertEqual(match.priorOccurrences, 3)
        XCTAssertEqual(match.medianDurationSeconds, 45.0 * 60, accuracy: 1, "median of 40, 45 and 50 minutes")
        XCTAssertEqual(match.medianPathLengthMeters, 2_000, accuracy: 20, "the whole route, not the part walked")
        XCTAssertTrue(match.label.contains("morning"), "an 08:00 start is a morning route, got \(match.label)")
    }

    func testASingleEarlierWalkIsNotARecurrence() throws {
        let archive = [try trail(daysAgo: 1, along: path(northMeters: 2_000), minutes: 40)]
        let current = try trail(daysAgo: 0, along: path(northMeters: 600), minutes: 8)
        XCTAssertNil(RecurrenceClassifier.match(current: current, archive: archive))
    }

    func testUnderFiveMinutesIntoTheWalkIsTooEarlyToMatch() throws {
        let route = path(northMeters: 2_000)
        let archive = try (1 ... 3).map { try trail(daysAgo: $0, along: route, minutes: 40) }
        let current = try trail(daysAgo: 0, along: path(northMeters: 600), minutes: 4)
        XCTAssertNil(RecurrenceClassifier.match(current: current, archive: archive))
    }

    func testTwoRoutesSharingAStartAreNotMixedIntoOneCluster() throws {
        // Both routes leave the start northward for 600 m, so both match the
        // walk so far; then one carries on north and the other turns east.
        // The medians must describe one of them, not an average of the two.
        let north = path(northMeters: 2_000)
        let east = path(northMeters: 600, thenEastMeters: 2_000)
        let archive = [
            try trail(daysAgo: 1, along: north, minutes: 40),
            try trail(daysAgo: 2, along: north, minutes: 44),
            try trail(daysAgo: 3, along: east, minutes: 60),
            try trail(daysAgo: 4, along: east, minutes: 64)
        ]
        let current = try trail(daysAgo: 0, along: path(northMeters: 600), minutes: 8)

        let match = try XCTUnwrap(RecurrenceClassifier.match(current: current, archive: archive))
        XCTAssertEqual(match.priorOccurrences, 2, "one route's two walks, not all four")
        let wentNorth = abs(match.medianPathLengthMeters - 2_000) < 20
        let wentEast = abs(match.medianPathLengthMeters - 2_600) < 26
        XCTAssertTrue(wentNorth || wentEast, "median length \(match.medianPathLengthMeters) m mixes the two routes")
        XCTAssertEqual(
            match.medianDurationSeconds, (wentNorth ? 42.0 : 62.0) * 60, accuracy: 1,
            "the median duration must come from the same route as the median length"
        )
    }

    func testTrailsStartingFiveHundredMetresAwayAreADifferentBucket() throws {
        let elsewhere = path(northMeters: 2_000, startEastMeters: 500)
        let archive = try (1 ... 3).map { try trail(daysAgo: $0, along: elsewhere, minutes: 40) }
        let current = try trail(daysAgo: 0, along: path(northMeters: 600), minutes: 8)
        XCTAssertNil(RecurrenceClassifier.match(current: current, archive: archive))
    }

    // MARK: - Trail fixtures

    private static let originLatitude = 51.5
    private static let originLongitude = -0.12
    private static let referenceDay = Date(timeIntervalSince1970: 1_750_000_000)

    /// The point `north` metres north and `east` metres east of the origin.
    private func point(north: Double, east: Double) -> CLLocationCoordinate2D {
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = metersPerDegreeLatitude * cos(Self.originLatitude * .pi / 180)
        return CLLocationCoordinate2D(
            latitude: Self.originLatitude + north / metersPerDegreeLatitude,
            longitude: Self.originLongitude + east / metersPerDegreeLongitude
        )
    }

    /// A route with a point every 100 m: `northMeters` north from a start
    /// `startEastMeters` east of the origin, then `eastMeters` east.
    private func path(
        northMeters: Double, thenEastMeters eastMeters: Double = 0, startEastMeters: Double = 0
    ) -> [CLLocationCoordinate2D] {
        let up = (0 ... Int(northMeters / 100)).map { point(north: Double($0) * 100, east: startEastMeters) }
        let across = (0 ..< Int(eastMeters / 100)).map {
            point(north: northMeters, east: startEastMeters + Double($0 + 1) * 100)
        }
        return up + across
    }

    /// A trail started at 08:00 `daysAgo` days before `referenceDay`, with its
    /// fixes spread evenly over `minutes`.
    private func trail(daysAgo: Int, along points: [CLLocationCoordinate2D], minutes: Double) throws -> BreadcrumbTrail {
        let calendar = Calendar.current
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -daysAgo, to: Self.referenceDay))
        let start = try XCTUnwrap(calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day))
        let step = minutes * 60 / Double(max(1, points.count - 1))
        let fixes = points.enumerated().map { index, coordinate in
            BreadcrumbFix(from: CLLocation(
                coordinate: coordinate, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
                timestamp: start.addingTimeInterval(Double(index) * step)
            ))
        }
        return BreadcrumbTrail(startedAt: start, origin: fixes.first, fixes: fixes, label: nil, resolvedOriginLabel: nil)
    }
}
