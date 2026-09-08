@testable import Emuqu
import XCTest

/// Tests for `SleepRefreshPolicy` — the gates that decide whether HealthKit's
/// latest sleep data may replace what a session was scored against.
///
/// These gates were unreachable inside `RRCollector` through two production
/// bugs (a stale scoring window, and an onset move / source upgrade).
/// Each of those regressions has a named test below.
final class SleepRefreshPolicyTests: XCTestCase {
    private let recordingStart = Date(timeIntervalSince1970: 1_785_600_000)

    private func makeSession(
        sleepSnapshot: SleepData? = nil,
        sleepStartMs: Int64? = nil,
        sleepEndMs: Int64? = nil,
        sleepUserAdjusted: Bool? = nil
    ) -> HRVSession {
        var session = HRVSession(
            id: UUID(),
            startDate: recordingStart,
            endDate: recordingStart.addingTimeInterval(8 * 3600),
            state: .complete,
            sessionType: .overnight,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil
        )
        session.sleepSnapshot = sleepSnapshot
        session.sleepStartMs = sleepStartMs
        session.sleepEndMs = sleepEndMs
        session.sleepUserAdjusted = sleepUserAdjusted
        return session
    }

    private func makeSleep(
        startOffsetMin: Int,
        minutes: Int,
        source: HealthKitManager.SleepBoundarySource = .healthKit
    ) -> SleepData {
        let start = recordingStart.addingTimeInterval(Double(startOffsetMin) * 60)
        return SleepData(
            date: start,
            sleepStart: start,
            sleepEnd: start.addingTimeInterval(Double(minutes) * 60),
            totalSleepMinutes: minutes,
            inBedMinutes: minutes,
            awakeMinutes: 0,
            sleepEfficiency: 95,
            boundarySource: source
        )
    }

    // MARK: - autoSleepRefreshAllowed

    /// A user who has hand-corrected their sleep timeline must not have it
    /// silently overwritten on the next foreground.
    func testUserAdjustedSleepWithASnapshotBlocksAutoRefresh() {
        let session = makeSession(
            sleepSnapshot: makeSleep(startOffsetMin: 10, minutes: 400),
            sleepUserAdjusted: true
        )
        XCTAssertFalse(SleepRefreshPolicy.autoSleepRefreshAllowed(for: session))
    }

    /// CloudKit strips HK-derived snapshots, so a user-adjusted session pulled
    /// onto a second device arrives flag=true, snapshot=nil. First-fill from
    /// that device's own HealthKit is allowed — only overwriting is blocked.
    func testUserAdjustedSessionWithNoSnapshotStillAllowsFirstFill() {
        let session = makeSession(sleepSnapshot: nil, sleepUserAdjusted: true)
        XCTAssertTrue(SleepRefreshPolicy.autoSleepRefreshAllowed(for: session))
    }

    func testUntouchedSessionAllowsAutoRefresh() {
        XCTAssertTrue(SleepRefreshPolicy.autoSleepRefreshAllowed(for: makeSession()))
        XCTAssertTrue(SleepRefreshPolicy.autoSleepRefreshAllowed(
            for: makeSession(sleepUserAdjusted: false)
        ))
    }

    // MARK: - Verdict: first snapshot

    func testFirstSnapshotAlwaysUpdatesAndRescores() {
        let verdict = SleepRefreshPolicy.sleepRefreshVerdict(
            session: makeSession(),
            fresh: makeSleep(startOffsetMin: 10, minutes: 420)
        )
        XCTAssertTrue(verdict.firstSnapshot)
        XCTAssertTrue(verdict.shouldUpdate)
        XCTAssertTrue(verdict.needsRescore)
    }

    // MARK: - Verdict: total minutes

    func testMoreSleepUpdatesButASmallDeltaDoesNotRescore() {
        let prior = makeSleep(startOffsetMin: 10, minutes: 400)
        let session = makeSession(sleepSnapshot: prior, sleepStartMs: 10 * 60_000)
        // +10 min, same onset, same source: worth showing, not worth rescoring.
        let fresh = makeSleep(startOffsetMin: 10, minutes: 410)
        let verdict = SleepRefreshPolicy.sleepRefreshVerdict(session: session, fresh: fresh)
        XCTAssertTrue(verdict.shouldUpdate)
        XCTAssertFalse(verdict.needsRescore)
        XCTAssertEqual(verdict.delta, 10)
    }

    func testATwentyMinuteDeltaRescores() {
        let prior = makeSleep(startOffsetMin: 10, minutes: 400)
        let session = makeSession(sleepSnapshot: prior, sleepStartMs: 10 * 60_000)
        let verdict = SleepRefreshPolicy.sleepRefreshVerdict(
            session: session,
            fresh: makeSleep(startOffsetMin: 10, minutes: 420)
        )
        XCTAssertTrue(verdict.needsRescore)
    }

    /// Less sleep than we already have, same onset and source, is not an
    /// improvement — HealthKit has simply not finished syncing.
    func testLessSleepWithNothingElseChangedIsNotAnUpdate() {
        let prior = makeSleep(startOffsetMin: 10, minutes: 420)
        let session = makeSession(sleepSnapshot: prior, sleepStartMs: 10 * 60_000)
        let verdict = SleepRefreshPolicy.sleepRefreshVerdict(
            session: session,
            fresh: makeSleep(startOffsetMin: 10, minutes: 400)
        )
        XCTAssertFalse(verdict.shouldUpdate)
    }

    /// The user went back to sleep after the recording ended and the watch
    /// tracked it: the end moving later is its own reason to update.
    func testALaterSleepEndUpdatesEvenWithoutMoreTotalMinutes() {
        let prior = makeSleep(startOffsetMin: 10, minutes: 400)
        let session = makeSession(sleepSnapshot: prior, sleepStartMs: 10 * 60_000)
        // Same total, whole block shifted 30 min later → end is later.
        let fresh = makeSleep(startOffsetMin: 40, minutes: 400)
        let verdict = SleepRefreshPolicy.sleepRefreshVerdict(session: session, fresh: fresh)
        XCTAssertTrue(verdict.endMovedLater)
        XCTAssertTrue(verdict.shouldUpdate)
    }

    // MARK: - Verdict: onset move (regression)

    /// The exact regression: HR estimated onset 117 min in, Apple says 5 min,
    /// with a similar TOTAL. Keying only on minutes skipped both gates and
    /// left the score computed from a bogus window.
    func testALargeOnsetMoveAtTheSameTotalStillRescores() {
        let prior = makeSleep(startOffsetMin: 117, minutes: 343, source: .hrEstimated)
        let session = makeSession(sleepSnapshot: prior, sleepStartMs: 117 * 60_000)
        let fresh = makeSleep(startOffsetMin: 5, minutes: 343, source: .hrEstimated)
        let verdict = SleepRefreshPolicy.sleepRefreshVerdict(session: session, fresh: fresh)
        XCTAssertEqual(verdict.delta, 0, "the total is unchanged — minutes alone would skip both gates")
        XCTAssertEqual(verdict.onsetMovedMin, 112)
        XCTAssertTrue(verdict.onsetMovedMaterially)
        XCTAssertTrue(verdict.shouldUpdate)
        XCTAssertTrue(verdict.needsRescore)
    }

    /// 15 minutes is the threshold: beyond typical sleep-onset latency, so it
    /// shifts the HRV scoring band. Below it, normal night-to-night noise.
    func testAnOnsetMoveBelowFifteenMinutesIsNotMaterial() {
        let prior = makeSleep(startOffsetMin: 10, minutes: 400)
        let session = makeSession(sleepSnapshot: prior, sleepStartMs: 10 * 60_000)
        let fresh = makeSleep(startOffsetMin: 24, minutes: 400)
        let verdict = SleepRefreshPolicy.sleepRefreshVerdict(session: session, fresh: fresh)
        XCTAssertEqual(verdict.onsetMovedMin, 14)
        XCTAssertFalse(verdict.onsetMovedMaterially)
    }

    func testOnsetMoveIsMeasuredInEitherDirection() {
        let session = makeSession(
            sleepSnapshot: makeSleep(startOffsetMin: 60, minutes: 400),
            sleepStartMs: 60 * 60_000
        )
        XCTAssertEqual(
            SleepRefreshPolicy.onsetMoveMinutes(
                session: session, fresh: makeSleep(startOffsetMin: 20, minutes: 400)
            ), 40
        )
        XCTAssertEqual(
            SleepRefreshPolicy.onsetMoveMinutes(
                session: session, fresh: makeSleep(startOffsetMin: 100, minutes: 400)
            ), 40
        )
    }

    /// With no prior boundary there is nothing to have moved from; the
    /// first-snapshot gate handles that case instead.
    func testOnsetMoveIsZeroWithNoPriorBoundary() {
        XCTAssertEqual(
            SleepRefreshPolicy.onsetMoveMinutes(
                session: makeSession(sleepStartMs: nil),
                fresh: makeSleep(startOffsetMin: 30, minutes: 400)
            ), 0
        )
    }

    // MARK: - Verdict: source upgrade

    /// Once Apple Watch sleep syncs it should always win, whatever the totals.
    func testAnUpgradeFromAnEstimateToHealthKitAlwaysRescores() {
        for priorSource in [HealthKitManager.SleepBoundarySource.hrEstimated,
                            .healthKitHREstimated,
                            .recordingBounds] {
            let prior = makeSleep(startOffsetMin: 10, minutes: 400, source: priorSource)
            let session = makeSession(sleepSnapshot: prior, sleepStartMs: 10 * 60_000)
            let fresh = makeSleep(startOffsetMin: 10, minutes: 400, source: .healthKit)
            let verdict = SleepRefreshPolicy.sleepRefreshVerdict(session: session, fresh: fresh)
            XCTAssertTrue(verdict.sourceUpgradedToWatch, "\(priorSource) → healthKit is an upgrade")
            XCTAssertTrue(verdict.shouldUpdate)
            XCTAssertTrue(verdict.needsRescore)
        }
    }

    func testHRValidatedCountsAsAWatchBasedUpgrade() {
        let prior = makeSleep(startOffsetMin: 10, minutes: 400, source: .hrEstimated)
        let session = makeSession(sleepSnapshot: prior, sleepStartMs: 10 * 60_000)
        XCTAssertTrue(SleepRefreshPolicy.isSourceUpgradeToWatch(
            session: session,
            fresh: makeSleep(startOffsetMin: 10, minutes: 400, source: .hrValidated)
        ))
    }

    /// Watch → watch is not an upgrade; neither is watch → estimate.
    func testAlreadyWatchBasedIsNotAnUpgrade() {
        let prior = makeSleep(startOffsetMin: 10, minutes: 400, source: .healthKit)
        let session = makeSession(sleepSnapshot: prior, sleepStartMs: 10 * 60_000)
        XCTAssertFalse(SleepRefreshPolicy.isSourceUpgradeToWatch(
            session: session,
            fresh: makeSleep(startOffsetMin: 10, minutes: 400, source: .healthKit)
        ))
        XCTAssertFalse(SleepRefreshPolicy.isSourceUpgradeToWatch(
            session: session,
            fresh: makeSleep(startOffsetMin: 10, minutes: 400, source: .hrEstimated)
        ))
    }

    /// A missing prior snapshot is an estimate for these purposes, so the very
    /// first watch-based data counts as an upgrade.
    func testNoPriorSourceCountsAsAnEstimate() {
        XCTAssertTrue(SleepRefreshPolicy.isSourceUpgradeToWatch(
            session: makeSession(),
            fresh: makeSleep(startOffsetMin: 10, minutes: 400, source: .healthKit)
        ))
    }

    // MARK: - applyFreshSleep (regression)

    /// The critical one: `sleepStartMs` / `sleepEndMs` are what
    /// WindowSelection scores from; the snapshot is display-only. Updating
    /// only the snapshot left the display corrected and the score computed
    /// from the stale HR-estimated window.
    func testApplyingFreshSleepMovesTheScoringBoundariesNotJustTheDisplay() {
        var session = makeSession(
            sleepSnapshot: makeSleep(startOffsetMin: 117, minutes: 343, source: .hrEstimated),
            sleepStartMs: 117 * 60_000,
            sleepEndMs: (117 + 343) * 60_000
        )
        let fresh = makeSleep(startOffsetMin: 5, minutes: 343, source: .healthKit)
        SleepRefreshPolicy.applyFreshSleep(fresh, to: &session)
        XCTAssertEqual(session.sleepStartMs, 5 * 60_000)
        XCTAssertEqual(session.sleepEndMs, (5 + 343) * 60_000)
        XCTAssertEqual(session.sleepSnapshot?.boundarySource, .healthKit)
    }

    /// Sleep that began before the recording did clamps to zero rather than
    /// going negative — a negative offset would index before the series.
    func testSleepStartingBeforeTheRecordingClampsToZero() {
        var session = makeSession()
        let fresh = makeSleep(startOffsetMin: -45, minutes: 400)
        SleepRefreshPolicy.applyFreshSleep(fresh, to: &session)
        XCTAssertEqual(session.sleepStartMs, 0)
    }

    /// A single-segment night carries no split information worth storing;
    /// only a genuinely split night replaces the segment list.
    func testOnlyASplitNightWritesSegments() {
        var session = makeSession()
        SleepRefreshPolicy.applyFreshSleep(makeSleep(startOffsetMin: 10, minutes: 400), to: &session)
        XCTAssertNil(session.sleepSegments)
    }

    // MARK: - applyPulledSleep

    /// CloudKit-pulled sessions get their display snapshot filled, but their
    /// frozen score must not be recomputed — so real boundaries are never
    /// overwritten, only nil ones filled.
    func testPulledSleepNeverOverwritesExistingBoundaries() {
        var session = makeSession(sleepStartMs: 90 * 60_000, sleepEndMs: 400 * 60_000)
        SleepRefreshPolicy.applyPulledSleep(makeSleep(startOffsetMin: 5, minutes: 343), to: &session)
        XCTAssertEqual(session.sleepStartMs, 90 * 60_000)
        XCTAssertEqual(session.sleepEndMs, 400 * 60_000)
        XCTAssertNotNil(session.sleepSnapshot, "the display snapshot is still filled")
    }

    func testPulledSleepFillsNilBoundaries() {
        var session = makeSession()
        SleepRefreshPolicy.applyPulledSleep(makeSleep(startOffsetMin: 5, minutes: 343), to: &session)
        XCTAssertEqual(session.sleepStartMs, 5 * 60_000)
        XCTAssertEqual(session.sleepEndMs, (5 + 343) * 60_000)
    }
}
