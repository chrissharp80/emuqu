@testable import Emuqu
import XCTest

/// Tests for the ticker state values lifted out of `WorkoutRecorder`.
final class TrackBackupWatermarkTests: XCTestCase {
    func testFirstCallWithAnyCountsRequestsASnapshot() {
        var mark = TrackBackupWatermark()
        XCTAssertTrue(mark.advanceIfChanged(trackCount: 1, baroCount: 0, samplesCount: 0))
    }

    /// A workout that has not started still has all-zero counts, and those
    /// match the initial watermark — nothing to back up yet.
    func testAllZeroCountsRequestNoSnapshot() {
        var mark = TrackBackupWatermark()
        XCTAssertFalse(mark.advanceIfChanged(trackCount: 0, baroCount: 0, samplesCount: 0))
    }

    /// The whole point of the watermark: ~5,400 ticks on a 90-minute walk,
    /// only the ones where something arrived may copy the growing arrays.
    func testRepeatedIdenticalCountsRequestNoSnapshot() {
        var mark = TrackBackupWatermark()
        XCTAssertTrue(mark.advanceIfChanged(trackCount: 10, baroCount: 4, samplesCount: 30))
        for _ in 0 ..< 100 {
            XCTAssertFalse(mark.advanceIfChanged(trackCount: 10, baroCount: 4, samplesCount: 30))
        }
    }

    /// Each stream must be able to trigger a snapshot on its own; an indoor
    /// row grows samples with no GPS fixes and no barometer at all.
    func testEachStreamIndependentlyTriggersASnapshot() {
        var mark = TrackBackupWatermark()
        _ = mark.advanceIfChanged(trackCount: 5, baroCount: 5, samplesCount: 5)
        XCTAssertTrue(mark.advanceIfChanged(trackCount: 6, baroCount: 5, samplesCount: 5))
        XCTAssertTrue(mark.advanceIfChanged(trackCount: 6, baroCount: 7, samplesCount: 5))
        XCTAssertTrue(mark.advanceIfChanged(trackCount: 6, baroCount: 7, samplesCount: 8))
        XCTAssertFalse(mark.advanceIfChanged(trackCount: 6, baroCount: 7, samplesCount: 8))
    }

    /// A second workout in the same app session restarts its streams at
    /// zero. A "has it grown" comparison would skip every snapshot until the
    /// new workout out-grew the old one, losing crash recovery for the first
    /// stretch — so the check is inequality, not greater-than.
    func testCountsDroppingBackToZeroStillRequestASnapshot() {
        var mark = TrackBackupWatermark()
        _ = mark.advanceIfChanged(trackCount: 5_400, baroCount: 900, samplesCount: 5_400)
        XCTAssertTrue(mark.advanceIfChanged(trackCount: 0, baroCount: 0, samplesCount: 0))
        XCTAssertTrue(mark.advanceIfChanged(trackCount: 1, baroCount: 0, samplesCount: 1))
    }

    /// Each stream's comparison has to be inequality on its OWN. Testing all
    /// three dropping together proves nothing about any one of them: the three
    /// clauses are OR-ed, so a single clause weakened to `>` stays hidden
    /// behind the other two. Mutation `backup_watermark_uses_greater_than`
    /// survived exactly that way. Drop one at a time.
    func testEachStreamDroppingAloneStillRequestsASnapshot() {
        for dimension in 0 ..< 3 {
            var mark = TrackBackupWatermark()
            _ = mark.advanceIfChanged(trackCount: 5, baroCount: 5, samplesCount: 5)
            XCTAssertTrue(
                mark.advanceIfChanged(
                    trackCount: dimension == 0 ? 3 : 5,
                    baroCount: dimension == 1 ? 3 : 5,
                    samplesCount: dimension == 2 ? 3 : 5
                ),
                "a drop in dimension \(dimension) alone must still snapshot"
            )
        }
    }

    /// Returning true must advance the watermark, or the very next tick
    /// snapshots again and the optimisation does nothing.
    func testASnapshotAdvancesTheWatermark() {
        var mark = TrackBackupWatermark()
        XCTAssertTrue(mark.advanceIfChanged(trackCount: 3, baroCount: 2, samplesCount: 1))
        XCTAssertFalse(mark.advanceIfChanged(trackCount: 3, baroCount: 2, samplesCount: 1))
    }

    /// Returning false must leave the watermark alone, so a later tick that
    /// does bring new data is still detected against the right baseline.
    func testANoOpTickLeavesTheWatermarkUntouched() {
        var mark = TrackBackupWatermark()
        _ = mark.advanceIfChanged(trackCount: 3, baroCount: 2, samplesCount: 1)
        let after = mark
        XCTAssertFalse(mark.advanceIfChanged(trackCount: 3, baroCount: 2, samplesCount: 1))
        XCTAssertEqual(mark, after)
    }
}

final class AutoPauseDetectorTests: XCTestCase {
    // MARK: - Auto-pause

    func testStationaryTicksBelowThresholdDoNotPause() {
        var detector = AutoPauseDetector()
        for _ in 0 ..< (AutoPauseDetector.stationarySecondsBeforeAutoPause - 1) {
            XCTAssertFalse(detector.accrueStationary(isStopped: true))
        }
    }

    func testPauseFiresExactlyOnTheThresholdTick() {
        var detector = AutoPauseDetector()
        for _ in 0 ..< (AutoPauseDetector.stationarySecondsBeforeAutoPause - 1) {
            _ = detector.accrueStationary(isStopped: true)
        }
        XCTAssertTrue(detector.accrueStationary(isStopped: true))
        XCTAssertEqual(detector.stationarySeconds, AutoPauseDetector.stationarySecondsBeforeAutoPause)
    }

    /// Traffic light, then walking again: the run-length has to clear or a
    /// series of unrelated short stops would eventually add up to a pause.
    func testAMovingTickClearsTheStationaryRunLength() {
        var detector = AutoPauseDetector()
        for _ in 0 ..< 14 { _ = detector.accrueStationary(isStopped: true) }
        XCTAssertFalse(detector.accrueStationary(isStopped: false))
        XCTAssertEqual(detector.stationarySeconds, 0)
        XCTAssertFalse(detector.accrueStationary(isStopped: true))
    }

    // MARK: - Auto-resume

    func testMovingTicksBelowThresholdDoNotResume() {
        var detector = AutoPauseDetector()
        for _ in 0 ..< (AutoPauseDetector.movingSecondsBeforeAutoResume - 1) {
            XCTAssertFalse(detector.accrueMoving(isMoving: true))
        }
    }

    func testResumeFiresExactlyOnTheThresholdTick() {
        var detector = AutoPauseDetector()
        for _ in 0 ..< (AutoPauseDetector.movingSecondsBeforeAutoResume - 1) {
            _ = detector.accrueMoving(isMoving: true)
        }
        XCTAssertTrue(detector.accrueMoving(isMoving: true))
    }

    func testAStationaryTickClearsTheMovingRunLength() {
        var detector = AutoPauseDetector()
        _ = detector.accrueMoving(isMoving: true)
        _ = detector.accrueMoving(isMoving: true)
        XCTAssertFalse(detector.accrueMoving(isMoving: false))
        XCTAssertEqual(detector.movingSeconds, 0)
        XCTAssertFalse(detector.accrueMoving(isMoving: true))
    }

    // MARK: - The two counters are independent

    /// Resume is deliberately quicker than pause. A single shared counter
    /// decrementing from "−15 stationary" back to zero made resume feel
    /// draggy, which is why these are two counters and two thresholds.
    func testResumeIsQuickerThanPause() {
        XCTAssertLessThan(
            AutoPauseDetector.movingSecondsBeforeAutoResume,
            AutoPauseDetector.stationarySecondsBeforeAutoPause
        )
    }

    /// Accruing stationary must zero the moving counter, so a pause after a
    /// brief burst of movement doesn't leave a partial resume run-length
    /// primed to fire on the very next moving tick.
    func testAccruingStationaryClearsTheMovingCounter() {
        var detector = AutoPauseDetector()
        _ = detector.accrueMoving(isMoving: true)
        _ = detector.accrueMoving(isMoving: true)
        XCTAssertEqual(detector.movingSeconds, 2)
        _ = detector.accrueStationary(isStopped: true)
        XCTAssertEqual(detector.movingSeconds, 0)
    }

    func testAccruingMovingClearsTheStationaryCounter() {
        var detector = AutoPauseDetector()
        _ = detector.accrueStationary(isStopped: true)
        _ = detector.accrueStationary(isStopped: true)
        XCTAssertEqual(detector.stationarySeconds, 2)
        _ = detector.accrueMoving(isMoving: true)
        XCTAssertEqual(detector.stationarySeconds, 0)
    }

    // MARK: - Reset

    func testResetClearsBothCounters() {
        var detector = AutoPauseDetector()
        for _ in 0 ..< 10 { _ = detector.accrueStationary(isStopped: true) }
        _ = detector.accrueMoving(isMoving: true)
        detector.reset()
        XCTAssertEqual(detector, AutoPauseDetector())
    }

    /// After a manual pause/resume the detector must need the full threshold
    /// again, not fire on the next tick because of a stale run-length.
    func testResetMakesAutoPauseNeedTheFullThresholdAgain() {
        var detector = AutoPauseDetector()
        for _ in 0 ..< 14 { _ = detector.accrueStationary(isStopped: true) }
        detector.reset()
        for _ in 0 ..< (AutoPauseDetector.stationarySecondsBeforeAutoPause - 1) {
            XCTAssertFalse(detector.accrueStationary(isStopped: true))
        }
        XCTAssertTrue(detector.accrueStationary(isStopped: true))
    }
}
