@testable import Emuqu
import XCTest

/// Tests for the pure decisions inside crash-session recovery: which recording
/// wins when a strap pull is merged into an already-archived workout, how the
/// v5 merge corruption is detected, and how a recovered session's summary card
/// is built.
///
/// All three ran unreachable inside a 870-line coordinator extension. Each one
/// decides what happens to data a user cannot re-record.
final class SessionRecoveryMergeTests: XCTestCase {
    private let sessionId = UUID()
    private let start = Date(timeIntervalSince1970: 1_785_600_000)

    private func points(count: Int, rrMs: Int = 1000, startingAt offset: Int64 = 0) -> [RRPoint] {
        (0 ..< count).map { RRPoint(t_ms: offset + Int64($0) * Int64(rrMs), rr_ms: rrMs) }
    }

    private func series(_ points: [RRPoint]) -> RRSeries {
        RRSeries(points: points, sessionId: sessionId, startDate: start)
    }

    // MARK: - Merge source selection

    /// Nothing archived means the strap pull is the whole session.
    func testWithNothingAlreadyArchivedTheStrapRecordingWins() {
        let strap = points(count: 500)
        let merged = SessionRecoveryMath.mergedWorkoutPoints(
            existing: [], strapRR: strap, sessionId: sessionId, sessionStart: start
        )
        XCTAssertEqual(merged.count, 500)
    }

    /// The last-resort tie-break: more beats wins. Keeping the shorter
    /// recording silently throws away part of a workout the user cannot record
    /// again.
    ///
    /// Tested on `longerRecording` directly rather than through
    /// `mergedWorkoutPoints`, because for any pair `DataSourceSelector` can
    /// judge it answers first and this branch never runs — a test that went in
    /// the front door passed while the comparison was inverted (mutation
    /// `recovery_merge_keeps_fewer_beats`).
    func testTheFallbackKeepsWhicheverRecordingHasMoreBeats() {
        let short = points(count: 100)
        let long = points(count: 900)
        XCTAssertEqual(
            SessionRecoveryMath.longerRecording(existing: short, strapRR: long).count, 900
        )
        XCTAssertEqual(
            SessionRecoveryMath.longerRecording(existing: long, strapRR: short).count, 900
        )
    }

    /// Equal lengths keep what is already archived rather than churning the
    /// stored session for no gain.
    func testEqualLengthRecordingsKeepTheArchivedOne() {
        let existing = points(count: 500)
        let strap = points(count: 500, rrMs: 900)
        XCTAssertEqual(
            SessionRecoveryMath.longerRecording(existing: existing, strapRR: strap).first?.rr_ms,
            1000
        )
    }

    /// An empty strap pull must never replace real archived data with nothing.
    func testAnEmptyStrapPullNeverErasesArchivedBeats() {
        let existing = points(count: 900)
        let merged = SessionRecoveryMath.mergedWorkoutPoints(
            existing: existing, strapRR: [], sessionId: sessionId, sessionStart: start
        )
        XCTAssertEqual(merged.count, 900)
    }

    /// Both empty is a session with no data, not a crash.
    func testBothEmptyYieldsNothing() {
        XCTAssertTrue(SessionRecoveryMath.mergedWorkoutPoints(
            existing: [], strapRR: [], sessionId: sessionId, sessionStart: start
        ).isEmpty)
    }

    // MARK: - v5 merge corruption

    /// The v5 bug concatenated a child series onto its parent without
    /// rebasing, so the first beat past the parent's length restarts near zero.
    func testATimestampRestartAtTheSpliceIsDetected() {
        let parent = points(count: 100)                       // t_ms 0 … 99_000
        let unrebased = points(count: 100, startingAt: 0)     // restarts at 0
        XCTAssertTrue(SessionRecoveryMath.hasV5TimestampDiscontinuity(
            childSeries: series(parent + unrebased), parentBeatCount: 100
        ))
    }

    /// A correct merge rebases the second series, so time keeps increasing.
    func testACorrectlyRebasedMergeIsNotFlagged() {
        let parent = points(count: 100)
        let rebased = points(count: 100, startingAt: 100_000)
        XCTAssertFalse(SessionRecoveryMath.hasV5TimestampDiscontinuity(
            childSeries: series(parent + rebased), parentBeatCount: 100
        ))
    }

    /// An ordinary gap — the strap dropped for a while and resumed — moves
    /// time FORWARD. Flagging it would reject a healthy merge.
    func testAnOrdinaryDropoutGapIsNotFlagged() {
        let parent = points(count: 100)
        let afterGap = points(count: 100, startingAt: 600_000)
        XCTAssertFalse(SessionRecoveryMath.hasV5TimestampDiscontinuity(
            childSeries: series(parent + afterGap), parentBeatCount: 100
        ))
    }

    /// The half-of-preceding rule is deliberately loose, so a merge that
    /// merely nudges backwards is left alone rather than being discarded.
    func testASmallBackwardsNudgeIsNotFlagged() {
        let parent = points(count: 100)
        let slightlyBack = points(count: 100, startingAt: 80_000)
        XCTAssertFalse(SessionRecoveryMath.hasV5TimestampDiscontinuity(
            childSeries: series(parent + slightlyBack), parentBeatCount: 100
        ))
    }

    /// A child no longer than its parent was never spliced, so there is no
    /// boundary to inspect.
    func testAChildNoLongerThanItsParentIsNotFlagged() {
        let parent = points(count: 100)
        XCTAssertFalse(SessionRecoveryMath.hasV5TimestampDiscontinuity(
            childSeries: series(parent), parentBeatCount: 100
        ))
        XCTAssertFalse(SessionRecoveryMath.hasV5TimestampDiscontinuity(
            childSeries: series(parent), parentBeatCount: 200
        ))
    }

    /// A zero-length parent has no beat before the boundary to compare
    /// against, and indexing `-1` would trap.
    func testAZeroLengthParentIsNotFlagged() {
        XCTAssertFalse(SessionRecoveryMath.hasV5TimestampDiscontinuity(
            childSeries: series(points(count: 50)), parentBeatCount: 0
        ))
    }

    func testAnEmptyChildSeriesIsNotFlagged() {
        XCTAssertFalse(SessionRecoveryMath.hasV5TimestampDiscontinuity(
            childSeries: series([]), parentBeatCount: 0
        ))
    }

    // MARK: - Recovered-workout summary

    func testAverageHeartRateRoundsToTheNearestBeat() {
        XCTAssertEqual(SessionRecoveryMath.recoveredAverageHR(142.4), 142)
        XCTAssertEqual(SessionRecoveryMath.recoveredAverageHR(142.5), 143)
    }

    /// No mean HR is 0 in the card, not a crash and not a fabricated number.
    func testAMissingAverageHeartRateIsZero() {
        XCTAssertEqual(SessionRecoveryMath.recoveredAverageHR(nil), 0)
        XCTAssertEqual(SessionRecoveryMath.recoveredAverageHR(0), 0)
        XCTAssertEqual(SessionRecoveryMath.recoveredAverageHR(-5), 0)
    }

    /// `Int(Double)` traps on NaN and on anything past `Int`'s range. This
    /// runs on a session that has already survived a crash and a merge — the
    /// input least worth trusting.
    /// A non-finite mean means the computation broke, not that the user's
    /// heart rate was enormous — so it reads as "no value" (0), not as the
    /// plausible-physiology cap. `.greatestFiniteMagnitude` IS finite, passes
    /// the guard, and is what the cap is actually there for.
    func testANonFiniteAverageHeartRateReadsAsNoValue() {
        XCTAssertEqual(SessionRecoveryMath.recoveredAverageHR(.nan), 0)
        XCTAssertEqual(SessionRecoveryMath.recoveredAverageHR(.infinity), 0)
        XCTAssertEqual(SessionRecoveryMath.recoveredAverageHR(-.infinity), 0)
    }

    /// The one that would actually trap: finite, in range for a `Double`, far
    /// outside `Int`'s. `Int(_:)` on it is a process kill, so the cap runs
    /// before the conversion.
    func testAFiniteButAstronomicalAverageIsCappedBeforeConversion() {
        XCTAssertEqual(SessionRecoveryMath.recoveredAverageHR(.greatestFiniteMagnitude), 300)
    }

    /// Bounded to plausible physiology, so a corrupt series renders as a
    /// suspicious number rather than an astronomical one.
    func testAnImplausiblyHighAverageIsBounded() {
        XCTAssertEqual(SessionRecoveryMath.recoveredAverageHR(50_000), 300)
    }
}
