import CoreLocation
@testable import Emuqu
import XCTest

/// Tests for the recurring-route classifier's geometry helpers.
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
}
