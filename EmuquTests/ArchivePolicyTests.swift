@testable import Emuqu
import os
import XCTest

/// Tests for the pure archive policy functions:
/// - `SessionArchive.duplicatesToQuarantine` — the dedupe keeper-ranking +
///   containment selection from `removeDuplicates()` (Archive+Migrations).
/// - `SessionArchive.mergeOutcome` / `.apply` — the session-merge decision
///   core from Archive+Merge.
///
/// Both run entirely in memory: no disk, no locks, no settings singletons.
final class ArchivePolicyTests: XCTestCase {
    /// Capture-and-restore, not fire-and-forget.
    ///
    /// `NSTimeZone.default` is **process-global**. Ten test classes set it to
    /// UTC in `class setUp()` and none of them put it back, so every test class
    /// that happened to run afterwards in the same process silently inherited
    /// UTC. `LiveReadinessTests` computes "today" from `Date()` against the
    /// current calendar, so between 19:00 and midnight US-Central (when the UTC
    /// date is already tomorrow) four of its tests failed — a genuine
    /// time-of-day flake that was invisible only because the suite used to
    /// deadlock before reaching them.
    private static let savedDefaultTimeZone = OSAllocatedUnfairLock<TimeZone?>(initialState: nil)
    override class func setUp() {
        super.setUp()
        // Pin to UTC so the fixed calendar anchors used below sit on the
        // same biological night on every machine.
        savedDefaultTimeZone.withLock { $0 = NSTimeZone.default }
        NSTimeZone.default = TestTimeZone.utc
    }

    override class func tearDown() {
        if let saved = savedDefaultTimeZone.withLock({ $0 }) { NSTimeZone.default = saved }
        savedDefaultTimeZone.withLock { $0 = nil }
        super.tearDown()
    }

    // MARK: - Fixtures

    /// 22:00 bedtime → overnight window anchor at 20:00 (bedtime − 2 h).
    private let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)

    /// Fixed clock far from any entry, so the 24-hour dedupe safety window
    /// never trips unless a test wants it to.
    private var farFuture: Date { date(day: 25, hour: 12) }

    /// June 2025, UTC. `day`/`hour` build deterministic night fixtures.
    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2025
        c.month = 6
        c.day = day
        c.hour = hour
        c.minute = minute
        return TestDate.from(c)
    }

    private func entry(
        id: UUID = UUID(),
        date: Date,
        endDate: Date?,
        recoveryScore: Double? = nil,
        meanRMSSD: Double? = nil,
        linked: [UUID]? = nil
    ) -> SessionArchiveEntry {
        SessionArchiveEntry(
            sessionId: id,
            date: date,
            endDate: endDate,
            fileHash: "policy-test",
            filePath: "\(id.uuidString).json",
            recoveryScore: recoveryScore,
            meanRMSSD: meanRMSSD,
            sessionType: .overnight,
            linkedSessionIds: linked
        )
    }

    private func quarantine(
        _ entries: [SessionArchiveEntry],
        now: Date? = nil,
        mergeMode: SessionMergeMode = .defaultGap
    ) -> [UUID] {
        SessionArchive.duplicatesToQuarantine(
            overnightEntries: entries,
            linkedIds: SessionArchive.linkedSessionIdSet(in: entries),
            schedule: schedule,
            now: now ?? farFuture,
            mergeMode: mergeMode
        )
    }

    // MARK: - duplicatesToQuarantine

    /// A loser whose range is ≥85% contained in the keeper's is a true
    /// duplicate and gets quarantined. Keeper ranking: has score wins.
    func testTrueDuplicateFullyContainedIsQuarantined() {
        let keeper = entry(date: date(day: 10, hour: 22), endDate: date(day: 11, hour: 6), recoveryScore: 7.0)
        let loser = entry(date: date(day: 10, hour: 23), endDate: date(day: 11, hour: 5))
        XCTAssertEqual(quarantine([keeper, loser]), [loser.sessionId])
    }

    /// Disjoint same-night segments are split nights, not duplicates —
    /// they belong to `relinkSameNightSessions`, never to quarantine.
    func testDisjointSameNightSegmentsAreNotQuarantined() {
        let early = entry(date: date(day: 10, hour: 22), endDate: date(day: 11, hour: 0), recoveryScore: 7.0)
        let late = entry(date: date(day: 11, hour: 3), endDate: date(day: 11, hour: 6))
        XCTAssertEqual(quarantine([early, late]), [])
    }

    /// Partial overlap below the 85% containment ratio is still a split
    /// night: 23:00–03:00 overlaps a 22:00–01:00 keeper by only 2 of 4 h.
    func testPartialOverlapBelowRatioIsNotQuarantined() {
        let keeper = entry(date: date(day: 10, hour: 22), endDate: date(day: 11, hour: 1), recoveryScore: 7.0)
        let partial = entry(date: date(day: 10, hour: 23), endDate: date(day: 11, hour: 3))
        XCTAssertEqual(quarantine([keeper, partial]), [])
    }

    /// Any entry younger than the 24-hour safety window skips the WHOLE
    /// night — CloudKit may still be reconciling it.
    func testRecentEntrySkipsNight() {
        let keeper = entry(date: date(day: 10, hour: 22), endDate: date(day: 11, hour: 6), recoveryScore: 7.0)
        let loser = entry(date: date(day: 10, hour: 23), endDate: date(day: 11, hour: 5))
        // 12 hours after the loser started — inside the safety window.
        XCTAssertEqual(quarantine([keeper, loser], now: date(day: 11, hour: 11)), [])
    }

    /// A loser without an endDate is skipped: containment can't be proven,
    /// so nothing is retired on a guess.
    func testLoserWithNilEndDateIsSkipped() {
        let keeper = entry(date: date(day: 10, hour: 22), endDate: date(day: 11, hour: 6), recoveryScore: 7.0)
        let endless = entry(date: date(day: 10, hour: 23), endDate: nil)
        XCTAssertEqual(quarantine([keeper, endless]), [])
    }

    /// A keeper without an endDate skips the whole night for the same reason.
    func testKeeperWithNilEndDateSkipsNight() {
        let keeper = entry(date: date(day: 10, hour: 22), endDate: nil, recoveryScore: 7.0)
        let loser = entry(date: date(day: 10, hour: 23), endDate: date(day: 11, hour: 5))
        XCTAssertEqual(quarantine([keeper, loser]), [])
    }

    /// mergeMode .off means the user opted out of same-night cleanup —
    /// even an obvious true duplicate is left alone.
    func testMergeModeOffReturnsEmpty() {
        let keeper = entry(date: date(day: 10, hour: 22), endDate: date(day: 11, hour: 6), recoveryScore: 7.0)
        let loser = entry(date: date(day: 10, hour: 23), endDate: date(day: 11, hour: 5))
        XCTAssertEqual(quarantine([keeper, loser], mergeMode: .off), [])
    }

    /// Sessions on either side of a link relationship are protected —
    /// they're explicit split-sleep segments.
    func testLinkedSessionsAreProtected() {
        let segment = entry(date: date(day: 10, hour: 22), endDate: date(day: 11, hour: 5))
        let parent = entry(
            date: date(day: 10, hour: 23), endDate: date(day: 11, hour: 6),
            recoveryScore: 7.0, linked: [segment.sessionId]
        )
        XCTAssertEqual(quarantine([parent, segment]), [])
    }

    /// Zero-length junk entries sitting inside the keeper's range are
    /// quarantined via the zero-duration containment branch.
    func testZeroLengthEntryInsideKeeperIsQuarantined() {
        let keeper = entry(date: date(day: 10, hour: 22), endDate: date(day: 11, hour: 6), recoveryScore: 7.0)
        let junkStamp = date(day: 11, hour: 1)
        let junk = entry(date: junkStamp, endDate: junkStamp)
        XCTAssertEqual(quarantine([keeper, junk]), [junk.sessionId])
    }

    /// Keeper ranking prefers a scored entry even when the unscored one is
    /// newer — the OLDER scored entry survives and the newer one (when
    /// contained) is quarantined.
    func testKeeperRankingPrefersScoreOverRecency() {
        let scoredOlder = entry(date: date(day: 10, hour: 22), endDate: date(day: 11, hour: 6), recoveryScore: 6.0)
        let unscoredNewer = entry(date: date(day: 10, hour: 23), endDate: date(day: 11, hour: 6))
        XCTAssertEqual(quarantine([unscoredNewer, scoredOlder]), [unscoredNewer.sessionId])
    }

    // MARK: - MergeOutcome decisions

    private func rrPoints(count: Int) -> [RRPoint] {
        var points: [RRPoint] = []
        points.reserveCapacity(count)
        var tMs: Int64 = 0
        for i in 0 ..< count {
            let rrMs = 800 + ((i % 5) - 2) * 10
            points.append(RRPoint(t_ms: tMs, rr_ms: rrMs))
            tMs += Int64(rrMs)
        }
        return points
    }

    private func makeAnalysisResult(for points: [RRPoint], start: Date) -> HRVAnalysisResult {
        let series = RRSeries(points: points, sessionId: UUID(), startDate: start)
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)
        let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series, flags: flags, windowStart: 0, windowEnd: points.count
        ) ?? TestFixtureDefaults.timeDomain
        let nonlinear = NonlinearMetrics(
            sd1: 50.0, sd2: 100.0, sd1Sd2Ratio: 0.5,
            sampleEntropy: 1.5, approxEntropy: 1.2,
            dfaAlpha1: 1.0, dfaAlpha2: 1.0, dfaAlpha1R2: 0.95
        )
        return HRVAnalysisResult(
            windowStart: 0,
            windowEnd: points.count,
            timeDomain: timeDomain,
            frequencyDomain: nil,
            nonlinear: nonlinear,
            ansMetrics: nil,
            artifactPercentage: 0,
            cleanBeatCount: points.count,
            analysisDate: start,
            windowStartMs: 0,
            windowEndMs: Int64(points.count * 800),
            windowMeanHR: nil,
            windowHRStability: nil,
            windowSelectionReason: nil,
            windowRelativePosition: nil,
            isConsolidated: nil,
            isOrganizedRecovery: true,
            windowClassification: "test",
            peakCapacity: nil
        )
    }

    private func makeSession(
        points: [RRPoint]?,
        withAnalysis: Bool = false,
        recoveryScore: Double? = nil,
        tags: [ReadingTag] = [],
        notes: String? = nil,
        importedMetrics: HRVSession.ImportedMetrics? = nil
    ) -> HRVSession {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let id = UUID()
        return HRVSession(
            id: id,
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            state: .complete,
            sessionType: .overnight,
            rrSeries: points.map { RRSeries(points: $0, sessionId: id, startDate: start) },
            analysisResult: withAnalysis
                ? points.map { makeAnalysisResult(for: $0, start: start) }
                : nil,
            artifactFlags: nil,
            recoveryScore: recoveryScore,
            tags: tags,
            notes: notes,
            importedMetrics: importedMetrics
        )
    }

    /// The analysis comparison must use the
    /// PRE-merge series sizes. A fresh full-night import (more raw beats)
    /// folded into a small partial must win the analysis slot.
    func testCompositeAdoptsImportedAnalysisWhenImportedHasMoreBeats() {
        let existing = makeSession(points: rrPoints(count: 200), withAnalysis: true, recoveryScore: 2.5)
        let imported = makeSession(points: rrPoints(count: 400), withAnalysis: true, recoveryScore: 7.5)

        let outcome = SessionArchive.mergeOutcome(imported: imported, existing: existing)

        guard case let .composite(_, summary, _, adoptImportedAnalysis) = outcome.rrChange else {
            return XCTFail("Both sides have RR data — expected a composite outcome, got \(String(describing: outcome.rrChange))")
        }
        XCTAssertTrue(adoptImportedAnalysis, "Imported analysis is backed by more raw beats and must win")
        XCTAssertEqual(summary.selectedSource, "composite")
        XCTAssertTrue(outcome.hasChanges)

        // Apply and confirm the end state matches the decision.
        var target = existing
        SessionArchive.apply(outcome, from: imported, to: &target)
        XCTAssertEqual(target.recoveryScore, 7.5)
        XCTAssertEqual(target.dataSourceSummary?.selectedSource, "composite")
        XCTAssertNil(target.artifactFlags, "Composite merge invalidates stale artifact flags")
    }

    /// The clobber guard: a smaller import must NOT replace an
    /// existing analysis computed on more raw data.
    func testCompositeKeepsExistingAnalysisWhenImportedHasFewerBeats() {
        let existing = makeSession(points: rrPoints(count: 400), withAnalysis: true, recoveryScore: 7.5)
        let imported = makeSession(points: rrPoints(count: 200), withAnalysis: true, recoveryScore: 2.5)

        let outcome = SessionArchive.mergeOutcome(imported: imported, existing: existing)

        guard case let .composite(_, _, _, adoptImportedAnalysis) = outcome.rrChange else {
            return XCTFail("Both sides have RR data — expected a composite outcome")
        }
        XCTAssertFalse(adoptImportedAnalysis, "Smaller-session analysis must not clobber the existing one")

        var target = existing
        SessionArchive.apply(outcome, from: imported, to: &target)
        XCTAssertEqual(target.recoveryScore, 7.5, "Existing score survives the merge")
    }

    /// A streamed copy of the night merged with the strap's own recording of
    /// the same beats: the stream's arrival clock sits a few tens of
    /// milliseconds off every device beat, so a merge that kept streamed beats
    /// inside the recorded span would put every beat in twice. Only beats the
    /// device lacks are added, so the merged series is the device's 300.
    func testStreamedBeatsTheDeviceRecordedAreNotAddedTwice() {
        let device = rrPoints(count: 300)
        let streamed = device.map { RRPoint(t_ms: $0.t_ms, rr_ms: $0.rr_ms, wallClockMs: $0.t_ms + 37) }
        var existing = makeSession(points: streamed)
        existing.dataSourceSummary = HRVSession.DataSourceSummary(
            selectedSource: "streaming", streamingBeats: 300, deviceBeats: nil, totalBeats: 300,
            beatDifferencePercent: nil, reconnectCount: 0, deviceModel: nil
        )
        let imported = makeSession(points: device)

        let outcome = SessionMerger.mergeOutcome(imported: imported, existing: existing)

        guard case let .composite(mergedPoints, _, _, _) = outcome.rrChange else {
            return XCTFail("Both sides have RR data — expected a composite outcome")
        }
        XCTAssertEqual(mergedPoints.count, 300, "beats both sources captured must be counted once")
    }

    /// Existing has no RR series — imported's series (and analysis, when
    /// present) is adopted wholesale.
    func testAdoptsImportedSeriesWhenExistingHasNone() {
        let existing = makeSession(points: nil)
        let imported = makeSession(points: rrPoints(count: 200), withAnalysis: true, recoveryScore: 6.0)

        let outcome = SessionArchive.mergeOutcome(imported: imported, existing: existing)

        guard case let .adoptImportedSeries(adoptImportedAnalysis) = outcome.rrChange else {
            return XCTFail("Existing has no RR — expected adoptImportedSeries")
        }
        XCTAssertTrue(adoptImportedAnalysis)

        var target = existing
        SessionArchive.apply(outcome, from: imported, to: &target)
        XCTAssertEqual(target.rrSeries?.points.count, 200)
        XCTAssertEqual(target.recoveryScore, 6.0)
    }

    /// Neither side triggers an RR merge — nil analysis/score fill in, and
    /// metadata fills follow the historical rules (tags deduped by id,
    /// notes only into an empty slot, importedMetrics only when nil).
    func testMetadataAndScalarFillsWithoutRRMerge() {
        let existing = makeSession(points: nil, tags: [ReadingTag.morning], notes: nil)
        let imported = makeSession(
            points: nil,
            recoveryScore: 5.0,
            tags: [ReadingTag.morning, ReadingTag.stressed],
            notes: "imported note",
            importedMetrics: HRVSession.ImportedMetrics(rmssd: 50, rmssdRaw: 48, artifactPercent: 1, source: "test")
        )

        let outcome = SessionArchive.mergeOutcome(imported: imported, existing: existing)

        XCTAssertNil(outcome.rrChange)
        XCTAssertFalse(outcome.adoptAnalysisResult, "Imported has no analysis to offer")
        XCTAssertTrue(outcome.adoptRecoveryScore)
        XCTAssertEqual(outcome.tagsToAppend.map(\.id), [ReadingTag.stressed.id], "Only the missing tag is appended")
        XCTAssertTrue(outcome.adoptNotes)
        XCTAssertTrue(outcome.adoptImportedMetrics)
        XCTAssertTrue(outcome.hasChanges)

        var target = existing
        SessionArchive.apply(outcome, from: imported, to: &target)
        XCTAssertEqual(target.recoveryScore, 5.0)
        XCTAssertEqual(target.tags.map(\.id), [ReadingTag.morning.id, ReadingTag.stressed.id])
        XCTAssertEqual(target.notes, "imported note")
        XCTAssertNotNil(target.importedMetrics)
    }

    /// Nothing to merge → no changes reported (the `changed == false`
    /// contract callers use to decide whether to re-archive).
    func testNoChangesWhenNothingToMerge() {
        let existing = makeSession(points: nil, recoveryScore: 5.0, tags: [ReadingTag.morning], notes: "keep")
        let imported = makeSession(points: nil, tags: [ReadingTag.morning])

        let outcome = SessionArchive.mergeOutcome(imported: imported, existing: existing)

        XCTAssertNil(outcome.rrChange)
        XCTAssertFalse(outcome.hasChanges)

        var target = existing
        SessionArchive.apply(outcome, from: imported, to: &target)
        XCTAssertEqual(target.recoveryScore, 5.0)
        XCTAssertEqual(target.notes, "keep")
        XCTAssertEqual(target.tags.map(\.id), [ReadingTag.morning.id])
    }
}
