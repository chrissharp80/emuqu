@testable import Emuqu
import XCTest

/// Tests for re-anchoring a child overnight segment onto its parent timeline.
///
/// When an overnight recording is split across two
/// sessions, the child's beats are shifted onto the parent's clock by this
/// offset. A wrong value silently misplaces every beat in the merged night —
/// the analysis window then lands on the wrong stretch of sleep.
///
/// The conversion must not be a bare `Int64(interval * 1000)` on two STORED
/// dates with the sanity guard running after it: a non-finite or absurdly
/// distant stored date traps in the conversion before the guard can reject it.
@MainActor
final class OvernightMergeOffsetTests: XCTestCase {
    private let parent = Date(timeIntervalSince1970: 1_622_534_400)

    // MARK: - The crash

    func testNonFiniteDateYieldsNoOffset() {
        let corrupt = Date(timeIntervalSince1970: .nan)
        XCTAssertNil(MillisecondOffset.between(corrupt, and: parent))
        XCTAssertNil(MillisecondOffset.between(parent, and: corrupt))
    }

    func testAbsurdlyDistantDateYieldsNoOffset() {
        XCTAssertNil(MillisecondOffset.between(.distantFuture, and: parent))
        XCTAssertNil(MillisecondOffset.between(.distantPast, and: parent))
    }

    // MARK: - Ordinary offsets

    func testChildAfterParentIsPositiveMilliseconds() {
        let child = parent.addingTimeInterval(90 * 60)
        XCTAssertEqual(MillisecondOffset.between(child, and: parent), 90 * 60 * 1000)
    }

    func testIdenticalStartsGiveZero() {
        XCTAssertEqual(MillisecondOffset.between(parent, and: parent), 0)
    }

    func testChildBeforeParentIsNegative() {
        // The caller rejects this (a child cannot precede its parent), but the
        // arithmetic must report it rather than trapping or wrapping.
        let child = parent.addingTimeInterval(-600)
        XCTAssertEqual(MillisecondOffset.between(child, and: parent), -600_000)
    }

    func testAFullNightOffsetIsRepresentable() {
        let child = parent.addingTimeInterval(8 * 3_600)
        XCTAssertEqual(MillisecondOffset.between(child, and: parent), 8 * 3_600 * 1_000)
    }

    // MARK: - Precision

    func testSubSecondOffsetsSurvive() {
        // Beat timestamps are milliseconds; losing sub-second precision would
        // shift every point in the child segment.
        let child = parent.addingTimeInterval(1.234)
        XCTAssertEqual(MillisecondOffset.between(child, and: parent), 1_234)
    }
}
