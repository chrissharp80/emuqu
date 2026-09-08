@testable import Emuqu
import XCTest

/// `ActivityBoutResolver` answers the one question a crashed recording cannot:
/// when did the activity stop. Everything else about a rebuild comes straight
/// out of Apple Health; this is the only inference, so it is the only part that
/// can be wrong in a way the user would not notice.
final class ActivityBoutResolverTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func window(_ fromMinutes: Double, _ toMinutes: Double, steps: Double = 100) -> HealthSampleWindow {
        HealthSampleWindow(
            start: start.addingTimeInterval(fromMinutes * 60),
            end: start.addingTimeInterval(toMinutes * 60),
            value: steps
        )
    }

    // MARK: - Finding the end

    func testContinuousSamplesEndAtTheLastOne() {
        let end = ActivityBoutResolver.end(
            ofBoutStartingAt: start,
            activity: [window(0, 5), window(5, 10), window(10, 42)]
        )
        XCTAssertEqual(end, start.addingTimeInterval(42 * 60))
    }

    func testSamplesInAnyOrderProduceTheSameEnd() {
        let ordered = ActivityBoutResolver.end(
            ofBoutStartingAt: start, activity: [window(0, 5), window(5, 10), window(10, 20)]
        )
        let shuffled = ActivityBoutResolver.end(
            ofBoutStartingAt: start, activity: [window(10, 20), window(0, 5), window(5, 10)]
        )
        XCTAssertEqual(ordered, shuffled)
    }

    /// A road crossing, a shoe re-tie, a conversation. Health also writes step
    /// samples in irregular batches, so a small hole usually means "not written
    /// yet" rather than "not walking".
    func testShortPauseDoesNotEndTheBout() {
        let end = ActivityBoutResolver.end(
            ofBoutStartingAt: start, activity: [window(0, 10), window(14, 30)]
        )
        XCTAssertEqual(end, start.addingTimeInterval(30 * 60))
    }

    /// Getting home and staying there ends the walk. Without this the rebuild
    /// would annex the rest of the day's incidental steps into the workout and
    /// report an hour's walk as five hours.
    func testLongSilenceEndsTheBoutBeforeLaterActivity() {
        let end = ActivityBoutResolver.end(
            ofBoutStartingAt: start,
            activity: [window(0, 40), window(180, 200)]
        )
        XCTAssertEqual(end, start.addingTimeInterval(40 * 60))
    }

    func testGapBoundaryIsInclusive() {
        let gap = ActivityBoutResolver.defaultMaxGap
        let atLimit = ActivityBoutResolver.end(
            ofBoutStartingAt: start,
            activity: [window(0, 10), window(10 + gap / 60, 25)]
        )
        XCTAssertEqual(atLimit, start.addingTimeInterval(25 * 60))

        let pastLimit = ActivityBoutResolver.end(
            ofBoutStartingAt: start,
            activity: [window(0, 10), window(10 + gap / 60 + 1, 25)]
        )
        XCTAssertEqual(pastLimit, start.addingTimeInterval(10 * 60))
    }

    // MARK: - Nothing to rebuild from

    /// The honest answer when Health has nothing: no end at all, so the caller
    /// tells the user instead of archiving an invented hour.
    func testNoSamplesMeansNoBout() {
        XCTAssertNil(ActivityBoutResolver.end(ofBoutStartingAt: start, activity: []))
    }

    func testSamplesEntirelyBeforeTheStartAreIgnored() {
        XCTAssertNil(ActivityBoutResolver.end(ofBoutStartingAt: start, activity: [window(-30, -5)]))
    }

    func testZeroStepWindowsAreNotActivity() {
        XCTAssertNil(ActivityBoutResolver.end(ofBoutStartingAt: start, activity: [window(0, 30, steps: 0)]))
    }

    /// The user was already walking when they hit Start; the window straddles
    /// the boundary and still counts.
    func testWindowStraddlingTheStartCounts() {
        let end = ActivityBoutResolver.end(ofBoutStartingAt: start, activity: [window(-2, 12)])
        XCTAssertEqual(end, start.addingTimeInterval(12 * 60))
    }

    // MARK: - The ceiling

    /// A rebuild has no stop event to trust, so it needs a limit that does not
    /// come from the data. A stuck or backfilled sample stream must not be able
    /// to produce a fourteen-hour walk that then dominates training load.
    func testBoutIsCappedRegardlessOfHowLongTheSamplesRun() {
        let hours = Int(ActivityBoutResolver.maxBoutDuration / 3_600)
        let steps = (0 ..< (hours + 4)).map { window(Double($0) * 60, Double($0 + 1) * 60) }
        let end = ActivityBoutResolver.end(ofBoutStartingAt: start, activity: steps)
        XCTAssertEqual(end, start.addingTimeInterval(ActivityBoutResolver.maxBoutDuration))
    }

    /// The cap has to clip INSIDE a sample, not just stop at the first one that
    /// ends past it. HealthKit backfills long windows — a single ten-hour step
    /// sample is exactly the shape that would sail past a boundary check and
    /// hand the user a ten-hour walk.
    func testSampleThatOvershootsTheCeilingIsClippedToIt() {
        let end = ActivityBoutResolver.end(ofBoutStartingAt: start, activity: [window(0, 600)])
        XCTAssertEqual(end, start.addingTimeInterval(ActivityBoutResolver.maxBoutDuration))
    }

    func testThresholdsMatchTheAuditedValues() {
        XCTAssertEqual(ActivityBoutResolver.defaultMaxGap, 600)
        XCTAssertEqual(ActivityBoutResolver.maxBoutDuration, 21_600)
    }
}
