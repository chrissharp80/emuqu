@testable import Emuqu
import XCTest

/// `PauseTimeline` maps a workout sample's `offsetSec`, which stops while the
/// workout is paused, back to the wall-clock moment it was taken. Wrist heart
/// rate is matched at that moment.
final class PauseTimelineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_785_600_000)

    func testWithoutPausesTheOffsetIsTheWallClock() {
        let timeline = PauseTimeline()
        XCTAssertEqual(timeline.wallClock(forOffset: 600, sessionStart: start), start.addingTimeInterval(600))
    }

    /// A 10-minute stop at 20 minutes: a sample 30 active minutes in was
    /// taken 40 minutes after the start.
    func testAPauseShiftsEveryLaterSample() {
        var timeline = PauseTimeline()
        timeline.pause(atElapsed: 1_200, now: start.addingTimeInterval(1_200))
        timeline.resume(now: start.addingTimeInterval(1_800))
        XCTAssertEqual(timeline.wallClock(forOffset: 1_800, sessionStart: start), start.addingTimeInterval(2_400))
    }

    /// The sample at the second the pause began was captured before it.
    func testTheSampleAtThePauseSecondIsNotShifted() {
        var timeline = PauseTimeline()
        timeline.pause(atElapsed: 1_200, now: start.addingTimeInterval(1_200))
        timeline.resume(now: start.addingTimeInterval(1_800))
        XCTAssertEqual(timeline.wallClock(forOffset: 1_200, sessionStart: start), start.addingTimeInterval(1_200))
    }

    /// The workout clock is the wall clock less the pauses, so ticks the
    /// timer missed (the app suspended on a locked phone) are not lost.
    func testActiveSecondsFollowTheWallClockLessPauses() {
        var timeline = PauseTimeline()
        XCTAssertEqual(timeline.activeSeconds(sessionStart: start, now: start.addingTimeInterval(2_700.6)), 2_700)
        timeline.pause(atElapsed: 600, now: start.addingTimeInterval(600))
        XCTAssertEqual(timeline.activeSeconds(sessionStart: start, now: start.addingTimeInterval(900)), 600, "stands still while paused")
        timeline.resume(now: start.addingTimeInterval(900))
        XCTAssertEqual(timeline.activeSeconds(sessionStart: start, now: start.addingTimeInterval(1_000)), 700)
        XCTAssertEqual(timeline.activeSeconds(sessionStart: start, now: start.addingTimeInterval(-5)), 0)
    }

    /// A workout stopped while paused ends its pause at the stop, so the
    /// last pause is saved with the others.
    func testAPauseEndedAtTheStopIsSaved() {
        var timeline = PauseTimeline()
        timeline.pause(atElapsed: 1_800, now: start.addingTimeInterval(1_800))
        timeline.resume(now: start.addingTimeInterval(2_100))
        XCTAssertEqual(timeline.spans, [PauseTimeline.Span(atElapsed: 1_800, seconds: 300)])
    }

    func testAResumeWithoutAPauseRecordsNothing() {
        var timeline = PauseTimeline()
        timeline.resume(now: start)
        XCTAssertTrue(timeline.spans.isEmpty)
    }
}
