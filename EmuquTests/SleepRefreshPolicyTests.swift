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

    // MARK: - Verdict: onset move

    /// HR estimated onset 117 min in, Apple says 5 min, with a similar TOTAL.
    /// Keying only on minutes would skip both gates and leave the score
    /// computed from a bogus window.
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

    // MARK: - applyFreshSleep

    /// The critical one: `sleepStartMs` / `sleepEndMs` are what
    /// WindowSelection scores from; the snapshot is display-only. Updating
    /// only the snapshot would leave the display corrected and the score
    /// computed from the stale HR-estimated window.
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

    /// A split night whose first segment began before the recording did:
    /// its offsets clamp at zero, as the boundaries do, so the segments and
    /// the scoring window agree.
    func testSegmentsStartingBeforeTheRecordingClampToZero() {
        var session = makeSession()
        let segment = { (from: Int, to: Int) in
            HealthKitManager.SleepSegment(
                sleepStart: self.recordingStart.addingTimeInterval(Double(from) * 60),
                sleepEnd: self.recordingStart.addingTimeInterval(Double(to) * 60),
                totalSleepMinutes: to - from, deepSleepMinutes: nil, remSleepMinutes: nil,
                coreSleepMinutes: nil, awakeMinutes: 0
            )
        }
        let fresh = SleepData(
            date: recordingStart, sleepStart: recordingStart.addingTimeInterval(-30 * 60),
            sleepEnd: recordingStart.addingTimeInterval(400 * 60), totalSleepMinutes: 400, inBedMinutes: 430,
            awakeMinutes: 30, sleepEfficiency: 93, boundarySource: .healthKit,
            segments: [segment(-30, 120), segment(150, 400)]
        )
        SleepRefreshPolicy.applyFreshSleep(fresh, to: &session)
        XCTAssertEqual(session.sleepStartMs, 0)
        XCTAssertEqual(session.sleepSegments?.first?.startMs, 0)
        XCTAssertEqual(session.sleepSegments?.first?.endMs, 120 * 60_000)
        XCTAssertEqual(session.sleepSegments?.last?.startMs, 150 * 60_000)
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

    // MARK: - applyAutoRefresh

    /// A user-adjusted night pulled onto a second device has no snapshot, so
    /// the auto refresh may run, but the boundaries the user edited (which
    /// sync) must survive.
    func testAutoRefreshOfAUserAdjustedNightKeepsTheEditedBoundaries() {
        var session = makeSession(sleepStartMs: 90 * 60_000, sleepEndMs: 400 * 60_000, sleepUserAdjusted: true)
        SleepRefreshPolicy.applyAutoRefresh(makeSleep(startOffsetMin: 5, minutes: 343), to: &session)
        XCTAssertEqual(session.sleepStartMs, 90 * 60_000)
        XCTAssertEqual(session.sleepEndMs, 400 * 60_000)
        XCTAssertNotNil(session.sleepSnapshot)
    }

    func testAutoRefreshOfAnUntouchedNightMovesTheBoundaries() {
        var session = makeSession(sleepStartMs: 90 * 60_000, sleepEndMs: 400 * 60_000)
        SleepRefreshPolicy.applyAutoRefresh(makeSleep(startOffsetMin: 5, minutes: 343), to: &session)
        XCTAssertEqual(session.sleepStartMs, 5 * 60_000)
    }
}

/// Today's results screen hands measured live sleep to the caller's
/// boundary writer; the hook was wired but never called, so stored sleep
/// never caught up with the Watch's later sync.
@MainActor
final class MorningResultsLiveSleepTests: XCTestCase {
    private func viewModel(endingAt end: Date, userAdjusted: Bool? = nil) -> MorningResultsViewModel {
        var session = HRVSession(startDate: end.addingTimeInterval(-8 * 3600), sessionType: .overnight)
        session.endDate = end
        session.state = .complete
        session.sleepUserAdjusted = userAdjusted
        let result = SnapshotFixtures.analysisResult()
        session.analysisResult = result
        return MorningResultsViewModel(session: session, result: result)
    }

    func testMeasuredSleepForTodayIsStored() {
        let vm = viewModel(endingAt: Date())
        var stored: [SleepData] = []
        vm.onUpdateSleep = { stored.append($0) }
        vm.storeSleepBoundariesIfMeasured(SnapshotFixtures.sleepData())
        XCTAssertEqual(stored.count, 1)
    }

    func testPastNightAndUserAdjustmentAreLeftAlone() {
        var stored: [SleepData] = []
        let past = viewModel(endingAt: Date().addingTimeInterval(-3 * 86_400))
        past.onUpdateSleep = { stored.append($0) }
        past.storeSleepBoundariesIfMeasured(SnapshotFixtures.sleepData())
        let adjusted = viewModel(endingAt: Date(), userAdjusted: true)
        adjusted.onUpdateSleep = { stored.append($0) }
        adjusted.storeSleepBoundariesIfMeasured(SnapshotFixtures.sleepData())
        XCTAssertTrue(stored.isEmpty)
    }
}

/// The perceived-readiness card on the morning results: the rating is saved
/// to the stored night, an unreliable night is re-scored with it, and what
/// the screen shows is what the archive holds.
@MainActor
final class MorningResultsReadinessTests: XCTestCase {
    private var directory: URL!
    private var archive: SessionArchive!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MorningReadiness-\(UUID().uuidString)")
        archive = SessionArchive(directory: directory)
    }

    override func tearDown() async throws {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            // swallow-ok: a test that archived nothing leaves no directory to remove.
        }
        try await super.tearDown()
    }

    private let baseline = BaselineTracker.RecoveryBaselineStats(
        lnRmssdMean: log(40.0), lnRmssdSD: 0.3, lnRmssdCV7Day: 6.0,
        meanHRBaseline: 58.0, meanHRSD: 3.0, daysInWindow: 30
    )

    private func night(quality: HRVDataQuality, score: Double? = nil) -> HRVSession {
        let end = Date(timeIntervalSince1970: 1_780_000_000)
        var session = HRVSession(startDate: end.addingTimeInterval(-8 * 3600), sessionType: .overnight)
        session.endDate = end
        session.state = .complete
        session.hrvDataQuality = quality
        session.recoveryScore = score
        session.analysisResult = SnapshotFixtures.analysisResult()
        return session
    }

    private func viewModel(for session: HRVSession) -> MorningResultsViewModel {
        let dependencies = AppDependencies()
        dependencies.overrides.sessionArchive = archive
        let vm = MorningResultsViewModel(
            session: session, result: session.analysisResult ?? SnapshotFixtures.analysisResult(),
            services: MorningResultsServices(dependencies)
        )
        vm.baselineStats = baseline
        return vm
    }

    func testARatingIsSavedAndScoresAnUnreliableNight() async throws {
        let session = night(quality: .preSleep)
        _ = try archive.archive(session)
        let vm = viewModel(for: session)

        vm.updatePerceivedReadiness(0.8)
        await vm.perceivedReadinessSaved()

        let stored = try XCTUnwrap(archive.retrieve(session.id))
        XCTAssertEqual(stored.perceivedReadiness, 0.8)
        XCTAssertNotNil(stored.recoveryScore, "the rating scores a night its recording could not")
        XCTAssertNotNil(stored.scoreBreakdown)
        XCTAssertEqual(vm.displaySession.perceivedReadiness, 0.8)
        XCTAssertEqual(vm.displaySession.recoveryScore, stored.recoveryScore, "the screen shows what was stored")
    }

    func testClearingTheRatingIsSavedToo() async throws {
        let session = night(quality: .preSleep)
        _ = try archive.archive(session)
        let vm = viewModel(for: session)

        vm.updatePerceivedReadiness(0.8)
        vm.updatePerceivedReadiness(nil)
        await vm.perceivedReadinessSaved()

        XCTAssertNil(try archive.retrieve(session.id)?.perceivedReadiness, "the last answer given is the one stored")
        XCTAssertNil(vm.displaySession.perceivedReadiness)
    }

    func testRatingANightNotYetStoredStoresIt() async throws {
        let session = night(quality: .preSleep)
        let vm = viewModel(for: session)

        vm.updatePerceivedReadiness(0.4)
        await vm.perceivedReadinessSaved()

        XCTAssertEqual(try archive.retrieve(session.id)?.perceivedReadiness, 0.4)
    }

    func testAReliableNightKeepsItsScore() async throws {
        let session = night(quality: .good, score: 7.0)
        _ = try archive.archive(session)
        let vm = viewModel(for: session)

        vm.updatePerceivedReadiness(0.2)
        await vm.perceivedReadinessSaved()

        let stored = try XCTUnwrap(archive.retrieve(session.id))
        XCTAssertEqual(stored.perceivedReadiness, 0.2)
        XCTAssertEqual(stored.recoveryScore, 7.0, "measured HRV scores the night, not the rating")
    }
}
