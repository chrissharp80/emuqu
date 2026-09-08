@testable import Emuqu
import XCTest

/// Tests for the Get Me Back accuracy classification.
///
/// This logic lived in a `private enum` inside `GetMeBackView`,
/// which is why nothing tested it and why two defects shipped in a
/// safety feature. Both are pinned below.
final class GPSAccuracyLevelTests: XCTestCase {
    // MARK: - The crash

    func testNoFixDoesNotProduceANumberToRender() {
        // The view used `.greatestFiniteMagnitude` as its no-fix sentinel.
        // That value is finite, so an `isFinite` guard passed it through, and
        // `Int(1.8e308)` traps. The screen crashed whenever the ribbon drew
        // before GPS locked.
        XCTAssertNil(GPSAccuracyLevel.displayMetres(.greatestFiniteMagnitude))
        XCTAssertNil(GPSAccuracyLevel.displayMetres(nil))
        XCTAssertNil(GPSAccuracyLevel.displayMetres(.infinity))
        XCTAssertNil(GPSAccuracyLevel.displayMetres(.nan))
    }

    func testOrdinaryAccuracyStillFormats() {
        XCTAssertEqual(GPSAccuracyLevel.displayMetres(12.6), 12)
        XCTAssertEqual(GPSAccuracyLevel.displayMetres(0), 0)
    }

    // MARK: - The invalid fix

    func testNegativeAccuracyIsNotReportedAsStrong() {
        // CoreLocation uses a negative horizontalAccuracy to mean "this fix is
        // invalid". `case ..<10` matched -1 and said "GPS strong", telling a
        // lost user to trust an arrow built on a fix CoreLocation disowned.
        XCTAssertEqual(
            GPSAccuracyLevel.classify(horizontalAccuracyMetres: -1), .waiting,
            "an invalid fix must never read as a good one"
        )
    }

    func testMissingFixIsWaiting() {
        XCTAssertEqual(GPSAccuracyLevel.classify(horizontalAccuracyMetres: nil), .waiting)
    }

    func testNonFiniteAccuracyIsWaiting() {
        XCTAssertEqual(GPSAccuracyLevel.classify(horizontalAccuracyMetres: .nan), .waiting)
        XCTAssertEqual(
            GPSAccuracyLevel.classify(horizontalAccuracyMetres: .greatestFiniteMagnitude),
            .waiting
        )
    }

    // MARK: - The bands

    func testAccuracyBands() {
        XCTAssertEqual(GPSAccuracyLevel.classify(horizontalAccuracyMetres: 0), .good)
        XCTAssertEqual(GPSAccuracyLevel.classify(horizontalAccuracyMetres: 9.9), .good)
        XCTAssertEqual(GPSAccuracyLevel.classify(horizontalAccuracyMetres: 10), .ok)
        XCTAssertEqual(GPSAccuracyLevel.classify(horizontalAccuracyMetres: 29.9), .ok)
        XCTAssertEqual(GPSAccuracyLevel.classify(horizontalAccuracyMetres: 30), .poor)
        XCTAssertEqual(GPSAccuracyLevel.classify(horizontalAccuracyMetres: 99.9), .poor)
    }

    func testAboveTheUsableThresholdWeStopPointing() {
        // Above 100 m the arrow is hidden entirely: pointing someone in a
        // wrong direction is worse than not pointing them at all.
        XCTAssertEqual(GPSAccuracyLevel.classify(horizontalAccuracyMetres: 100), .waiting)
        XCTAssertEqual(GPSAccuracyLevel.classify(horizontalAccuracyMetres: 5_000), .waiting)
    }

    func testOnlyWaitingHidesTheArrow() {
        for level in GPSAccuracyLevel.allCases {
            XCTAssertEqual(
                level.showsDirection, level != .waiting,
                "\(level.rawValue) must \(level == .waiting ? "hide" : "show") the arrow"
            )
        }
    }
}
