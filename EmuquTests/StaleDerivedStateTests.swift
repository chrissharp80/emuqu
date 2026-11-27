@testable import Emuqu
import XCTest

/// When a value a session's other state is derived from changes, the derived
/// state follows it: the quality class the sleep decides, the sleep HR the
/// analysis decides, the sleep window the snapshot decides, the cached
/// summary, the Apple Health export. Each test changes one source the way a
/// writer does and checks what is derived from it.
@MainActor
final class StaleDerivedStateTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_750_000_000)

    nonisolated private let archiveDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StaleDerivedStateTests-\(UUID().uuidString)", isDirectory: true)
    nonisolated private let baselineFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("StaleDerivedBaseline-\(UUID().uuidString).json")

    override func tearDown() {
        for url in [archiveDirectory, baselineFile] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                // swallow-ok: a test that wrote nothing left nothing behind.
            }
        }
        super.tearDown()
    }

    // MARK: - Fixtures

    private func result(meanHR: Double) -> HRVAnalysisResult {
        HRVAnalysisResult(
            windowStart: 0, windowEnd: 400,
            timeDomain: TimeDomainMetrics(
                meanRR: 60000 / meanHR, sdnn: 30, rmssd: 15, pnn50: 2, sdsd: 14, meanHR: meanHR, sdHR: 3, triangularIndex: nil
            ),
            frequencyDomain: nil,
            nonlinear: NonlinearMetrics(
                sd1: 10, sd2: 40, sd1Sd2Ratio: 0.25, sampleEntropy: 1.5, approxEntropy: 1.3,
                dfaAlpha1: 0.85, dfaAlpha2: nil, dfaAlpha1R2: 0.95
            ),
            ansMetrics: nil, artifactPercentage: 1, cleanBeatCount: 400, analysisDate: anchor
        )
    }

    private func vitals(restingHeartRate: Double?) -> RecoveryVitals {
        RecoveryVitals(
            respiratoryRate: 14, respiratoryRateBaseline: 14, oxygenSaturation: 97, oxygenSaturationMin: 95,
            wristTemperature: nil, wristTemperatureBaseline: nil, restingHeartRate: restingHeartRate
        )
    }

    /// An eight-hour night from `anchor`, analysed with `meanHR` and holding
    /// `restingHeartRate` in its vitals.
    private func night(quality: HRVDataQuality?, meanHR: Double = 58, restingHeartRate: Double? = 58) -> HRVSession {
        var night = HRVSession(startDate: anchor, sessionType: .overnight)
        night.endDate = anchor.addingTimeInterval(8 * 3600)
        night.analysisResult = result(meanHR: meanHR)
        night.hrvDataQuality = quality
        night.vitalsSnapshot = vitals(restingHeartRate: restingHeartRate)
        return night
    }

    /// Sleep from `fromHours` to `toHours` after `anchor`.
    private func sleep(fromHours: Double, toHours: Double) -> SleepData {
        let start = anchor.addingTimeInterval(fromHours * 3600)
        let end = anchor.addingTimeInterval(toHours * 3600)
        let minutes = Int((toHours - fromHours) * 60)
        return SleepData(
            date: end, inBedStart: start, sleepStart: start, sleepEnd: end,
            totalSleepMinutes: minutes, inBedMinutes: minutes,
            deepSleepMinutes: minutes / 5, remSleepMinutes: minutes / 5, awakeMinutes: 0,
            sleepEfficiency: 92, boundarySource: .healthKit,
            segments: [], stageIntervals: [], boundaryValidation: nil, hrSleepQuality: nil
        )
    }

    private func breakdown(rmssd: Double) -> RecoveryScoreCalculator.ScoreBreakdown {
        RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: nil, rmssd: rmssd, meanHR: 58, dfaAlpha1: 0.85, baselineStats: nil,
                sleepData: nil, vitals: nil, typicalSleepHours: 7.5
            ),
            trainingContext: nil,
            config: RecoveryScoreCalculator.ScoringConfiguration(
                enableTrainingLoadIntegration: false, isOnTrainingBreak: false,
                enableSleepIntegration: false, penalizeMissingSleep: false, userAge: 40
            ),
            useBaselineHRV: false, referenceDate: anchor
        )
    }

    private func training(atl: Double) -> TrainingContext {
        TrainingContext(atl: atl, ctl: 50, tsb: 50 - atl, yesterdayTrimp: 0, vo2Max: nil, daysSinceHardWorkout: nil, recentWorkouts: nil)
    }

    private func makeArchive() -> SessionArchive {
        SessionArchive(
            directory: archiveDirectory,
            sleepScheduleProvider: { SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0) },
            sessionMergeModeProvider: { .off }
        )
    }

    private func makeService(
        healthKit: MockHealthKitService, awaitingReview: Set<UUID> = [], archive: SessionArchive? = nil,
        analysis: @escaping () -> HRVAnalysisResult? = { nil }
    ) -> ReanalysisService {
        let windowSelector = WindowSelector()
        let artifactDetector = ArtifactDetector()
        let settings = UserSettings()
        return ReanalysisService(
            archive: archive ?? makeArchive(),
            healthKit: healthKit,
            analysisPipeline: HRVAnalysisPipeline(artifactDetector: artifactDetector, windowSelector: windowSelector, healthKit: healthKit),
            windowSelector: windowSelector, artifactDetector: artifactDetector,
            baselineTracker: BaselineTracker(baselineFile: baselineFile),
            settingsProvider: { settings },
            scoringConfigProvider: { .init(from: settings) },
            ansConfigProvider: { _ in HRVAnalysisPipeline.ANSConfiguration(baselineRMSSD: 40, vo2Max: nil, trainingLoadAdjustment: 0) },
            trainingContextProvider: { _ in nil },
            analyzeWithWindow: { _, _, _, _ in analysis() },
            analyzeFullSession: { _, _ in analysis() },
            onArchiveChanged: {},
            onSessionUploaded: { _ in },
            onZonesStale: { _ in },
            isAwaitingReview: { awaitingReview.contains($0) }
        )
    }

    // MARK: - The cached summary

    /// Every session field the summary generator reads changes the cache
    /// key, so an edit to any of them (a feeling set on the dashboard, a
    /// healed training load, a reclassified night) never hands back the
    /// summary written before it.
    func testTheSummaryFingerprintChangesWithEveryFieldTheGeneratorReads() {
        var base = night(quality: .good)
        base.scoreBreakdown = breakdown(rmssd: 15)
        base.trainingSnapshot = training(atl: 40)
        let (otherBreakdown, otherTraining) = (breakdown(rmssd: 60), training(atl: 80))
        let edits: [(String, (inout HRVSession) -> Void)] = [
            ("morning feeling", { $0.morningFeeling = 2 }),
            ("feeling tags", { $0.morningFeelingTags = Array(MorningFeelingTag.allCases.prefix(1)) }),
            ("breakdown composite", { $0.scoreBreakdown = otherBreakdown }),
            ("quality", { $0.hrvDataQuality = .preSleep }),
            ("end date", { $0.endDate = $0.endDate?.addingTimeInterval(600) }),
            ("training load", { $0.trainingSnapshot = otherTraining }),
            ("window", { $0.analysisResult?.windowStartMs = 1000 })
        ]
        let baseKey = AnalysisSummaryCache.fingerprint(for: base)
        for (field, edit) in edits {
            var edited = base
            edit(&edited)
            XCTAssertNotEqual(AnalysisSummaryCache.fingerprint(for: edited), baseKey, field)
        }
    }

    // MARK: - The sleep HR follows the analysis

    /// A usable night holds its window's strap HR (58) as sleep HR. When the
    /// analysis or the quality changes, the stored snapshot follows: a new
    /// window's HR replaces it, a recording marked unusable drops it, and
    /// HealthKit's own value is never dropped for being unlike the strap's.
    func testTheStoredSleepHeartRateFollowsTheAnalysisAndQuality() {
        let usable = night(quality: .good)
        let cases: [(String, HRVSession, Double?)] = [
            ("a new window", night(quality: .good, meanHR: 50), 50),
            ("marked unusable", night(quality: .preSleep), nil),
            ("a new window marked unusable", night(quality: .preSleep, meanHR: 50), nil),
            ("unchanged", usable, 58)
        ]
        for (change, after, expected) in cases {
            var refreshed = after
            refreshed.vitalsSnapshot = usable.vitalsSnapshot
            refreshed.refreshSleepHeartRate(replacing: usable)
            XCTAssertEqual(refreshed.vitalsSnapshot?.restingHeartRate, expected, change)
        }
        var health = night(quality: .good)
        health.vitalsSnapshot = vitals(restingHeartRate: 62)
        health.refreshSleepHeartRate(replacing: night(quality: .preSleep, restingHeartRate: 62))
        XCTAssertEqual(health.vitalsSnapshot?.restingHeartRate, 58, "a night that became usable takes the strap's HR")
        var keptHealth = night(quality: .preSleep, restingHeartRate: 62)
        keptHealth.refreshSleepHeartRate(replacing: night(quality: .preSleep, restingHeartRate: 62))
        XCTAssertEqual(keptHealth.vitalsSnapshot?.restingHeartRate, 62, "HealthKit's resting HR stays")
    }

    /// Both kinds of rescore write the quality and the snapshot the pass
    /// scored with, not the ones decided before it.
    func testEveryRescoreWritesTheQualityAndSleepHeartRateItScoredWith() {
        var rescored = night(quality: .good, meanHR: 50, restingHeartRate: 50)
        rescored.recoveryScore = 7
        for kind in [RescoreWrite.Kind.reanalysis(healedTraining: false), .scoreOnly(healedTraining: false)] {
            var stored = night(quality: .preSleep, restingHeartRate: 62)
            RescoreWrite.applyComputedFields(from: rescored, to: &stored, kind: kind)
            XCTAssertEqual(stored.hrvDataQuality, .good, "\(kind)")
            XCTAssertEqual(stored.vitalsSnapshot?.restingHeartRate, 50, "\(kind)")
        }
    }

    /// The score-only pass, which a sleep change on a night with a picked
    /// window falls back to, classifies the night against the sleep it now
    /// holds: a recording that did not overlap the old sleep but overlaps the
    /// new one is no longer `.preSleep`, and its strap HR now counts.
    func testTheScoreOnlyPassClassifiesAgainstTheSleepTheNightHoldsNow() {
        let service = makeService(healthKit: MockHealthKitService())
        var moved = night(quality: .preSleep, restingHeartRate: 62)
        moved.sleepSnapshot = sleep(fromHours: 1, toHours: 7)
        let classified = service.classifiedAgainstCurrentSleep(moved, result: result(meanHR: 58))
        XCTAssertEqual(classified.hrvDataQuality, .good)
        XCTAssertEqual(classified.vitalsSnapshot?.restingHeartRate, 58)
    }

    /// A reanalysis that moves the window to one with another heart rate
    /// stores that window's heart rate as the night's sleep HR.
    func testAReanalysisMovesTheStoredSleepHeartRateToTheNewWindow() async throws {
        var stored = night(quality: .good)
        stored.rrSeries = RRSeries(points: Self.beats(count: 900), sessionId: stored.id, startDate: anchor)
        let archived = makeArchive()
        try archived.archive(stored)
        let read = try XCTUnwrap(try archived.retrieve(stored.id))
        let newWindow = result(meanHR: 50)
        let service = makeService(healthKit: MockHealthKitService(), archive: archived) { newWindow }
        _ = await service.reanalyzeSession(read)
        XCTAssertEqual(try archived.retrieve(stored.id)?.vitalsSnapshot?.restingHeartRate, 50)
    }

    /// A sleep edit that moves the sleep off the recording marks it
    /// `.preSleep`, and its strap HR stops standing as sleep HR.
    func testASleepEditThatMakesTheRecordingUnusableDropsItsSleepHeartRate() {
        var edited = night(quality: .good)
        edited.sleepSnapshot = sleep(fromHours: 9, toHours: 10)
        let context = RescoreContext(
            baselineStats: nil, typicalSleepHours: 8,
            scoringConfig: RecoveryScoreCalculator.ScoringConfiguration(
                enableTrainingLoadIntegration: false, isOnTrainingBreak: false,
                enableSleepIntegration: true, penalizeMissingSleep: false, userAge: 40
            )
        )
        SleepBoundaryWrite.rescore(
            &edited, sessionEnd: anchor.addingTimeInterval(8 * 3600),
            inputs: SleepBoundaryWrite.Inputs(context: context, fallbackTraining: nil)
        )
        XCTAssertEqual(edited.hrvDataQuality, .preSleep)
        XCTAssertNil(edited.vitalsSnapshot?.restingHeartRate)
    }

    /// Beats with a little variation, about a second apart.
    private static func beats(count: Int) -> [RRPoint] {
        var tMs: Int64 = 0
        return (0 ..< count).map { i in
            let rr = 1000 + [20, -5, -20, 5][i % 4]
            tMs += Int64(rr)
            return RRPoint(t_ms: tMs, rr_ms: rr)
        }
    }

    /// A full night folded into a fragment that kept its own vitals takes the
    /// full night's analysis, and the vitals' sleep HR moves with it.
    func testAMergeThatAdoptsAnAnalysisMovesTheKeptSleepHeartRate() {
        var fragment = MergeClockFixture.session(start: anchor, minutes: 20, meanRR: 1000, withAnalysis: true)
        fragment.hrvDataQuality = .good
        fragment.vitalsSnapshot = vitals(restingHeartRate: fragment.strapSleepHeartRate)
        var full = MergeClockFixture.session(start: anchor.addingTimeInterval(30 * 60), minutes: 420, meanRR: 950, withAnalysis: true)
        full.hrvDataQuality = .good
        let fragmentHR = fragment.strapSleepHeartRate
        XCTAssertTrue(SessionMerger.mergeSessionData(from: full, into: &fragment))
        let adopted = fragment.analysisResult?.timeDomain.meanHR
        XCTAssertNotEqual(adopted, fragmentHR)
        XCTAssertEqual(fragment.vitalsSnapshot?.restingHeartRate, adopted)
    }

    /// A newer iCloud copy reanalysed on another device keeps this device's
    /// vitals, with the sleep HR of the iCloud copy's window.
    func testAPulledReanalysisMovesTheLocalSleepHeartRate() {
        let local = night(quality: .good)
        var remote = night(quality: .good, meanHR: 52, restingHeartRate: nil)
        remote.vitalsSnapshot = nil
        CloudSessionPayload.restoringLocalOnlyFields(into: &remote, from: local)
        XCTAssertEqual(remote.vitalsSnapshot?.restingHeartRate, 52)
    }

    // MARK: - The quality follows the sleep

    /// Refreshing an archived night's score with a sleep that moved
    /// classifies it again; the same sleep keeps the quality decided on it.
    func testARefreshedSleepThatMovedClassifiesTheNightAgain() {
        let before = sleep(fromHours: 9, toHours: 10)
        let cases: [(String, SleepData, HRVDataQuality)] = [
            ("moved onto the recording", sleep(fromHours: 1, toHours: 7), .good),
            ("unchanged", before, .preSleep)
        ]
        for (change, refreshed, expected) in cases {
            var session = night(quality: .preSleep)
            session.sleepSnapshot = refreshed
            _ = SessionAcceptanceService.refreshedUseBaselineHRV(
                on: &session, result: result(meanHR: 58), baselineStats: nil, sleepBefore: before
            )
            XCTAssertEqual(session.hrvDataQuality, expected, change)
        }
    }

    // MARK: - The sleep window follows the snapshot

    /// Acceptance freezes a fetched sleep with the window the analysis is
    /// chosen in moved to it; a user's own sleep and an empty fetch leave the
    /// night's sleep as it was.
    func testAcceptanceMovesTheSleepWindowWithTheSnapshotItFreezes() {
        var base = night(quality: .good)
        base.sleepSnapshot = sleep(fromHours: 0, toHours: 8)
        base.sleepStartMs = 0
        base.sleepEndMs = 8 * 3_600_000
        var fresh = base
        SessionAcceptanceService.freezeFetchedSleep(sleep(fromHours: 1, toHours: 7), on: &fresh)
        XCTAssertEqual(fresh.sleepStartMs, 3_600_000)
        XCTAssertEqual(fresh.sleepEndMs, 7 * 3_600_000)
        var adjusted = base
        adjusted.sleepUserAdjusted = true
        SessionAcceptanceService.freezeFetchedSleep(sleep(fromHours: 1, toHours: 7), on: &adjusted)
        XCTAssertEqual(adjusted.sleepStartMs, 0)
        var empty = base
        SessionAcceptanceService.freezeFetchedSleep(sleep(fromHours: 1, toHours: 1), on: &empty)
        XCTAssertEqual(empty.sleepStartMs, 0)
    }

    /// The acceptance and score-refresh writes put the frozen sleep's window
    /// on the archived copy with the snapshot.
    func testTheAcceptanceWritesCarryTheSleepWindowWithTheSnapshot() {
        var frozen = night(quality: .good)
        frozen.sleepSnapshot = sleep(fromHours: 1, toHours: 7)
        frozen.sleepStartMs = 3_600_000
        frozen.sleepEndMs = 7 * 3_600_000
        let stored = night(quality: .good)
        var accepted = stored
        SessionAcceptanceService.applyAccepted(from: frozen, to: &accepted)
        var updated = stored
        SessionAcceptanceService.applyUpdate(frozen, scoredFrom: stored, to: &updated)
        for (write, written) in [("accept", accepted), ("refresh", updated)] {
            XCTAssertEqual(written.sleepStartMs, frozen.sleepStartMs, write)
            XCTAssertEqual(written.sleepEndMs, frozen.sleepEndMs, write)
        }
    }

    /// A write that moved the sleep window asks for the night to be analysed
    /// again; one that did not, does not.
    func testAMovedSleepWindowIsAnalysedAgain() {
        let before = night(quality: .good)
        var moved = before
        moved.sleepStartMs = 3_600_000
        var split = before
        split.sleepSegments = [HRVSession.SleepSegmentMs(startMs: 0, endMs: 1000)]
        XCTAssertTrue(ReanalysisService.sleepWindowMoved(from: before, to: moved))
        XCTAssertTrue(ReanalysisService.sleepWindowMoved(from: before, to: split))
        XCTAssertFalse(ReanalysisService.sleepWindowMoved(from: before, to: before))
        let movedId = moved.id
        let posted = expectation(forNotification: .flowRecoveryRescoreNeeded, object: nil) { ($0.object as? UUID) == movedId }
        SessionAcceptanceService.requestRewindowIfSleepMoved(from: before, to: moved)
        wait(for: [posted], timeout: 1)
    }

    /// A strap download replacing a night whose sleep the user set by hand
    /// is analysed inside that sleep, re-counted from the download's start.
    func testARecoveredNightIsAnalysedInsideTheUsersSleep() throws {
        var existing = night(quality: .good)
        existing.sleepUserAdjusted = true
        existing.sleepStartMs = 3_600_000
        existing.sleepEndMs = 7 * 3_600_000
        existing.sleepSegments = [HRVSession.SleepSegmentMs(startMs: 3_600_000, endMs: 7 * 3_600_000)]
        let context = try XCTUnwrap(DeviceRecordingSession.userSleepContext(of: existing, onto: anchor.addingTimeInterval(600)))
        XCTAssertEqual(context.sleepStartMs, 3_000_000)
        XCTAssertEqual(context.wakeTimeMs, 7 * 3_600_000 - 600_000)
        XCTAssertEqual(context.sleepSegments?.first?.startMs, 3_000_000)
    }

    /// A repaired night that kept the user's sleep is scored again; one that
    /// kept nothing the score reads is not.
    func testARepairThatKeptTheUsersSleepIsScoredAgain() {
        let rebuilt = night(quality: .good)
        var kept = rebuilt
        kept.sleepStartMs = 3_600_000
        XCTAssertTrue(SessionRecoveryCoordinator.carriedEditsChangeScoringInputs(rebuilt: rebuilt, carried: kept))
        var tagged = rebuilt
        tagged.notes = "kept"
        XCTAssertFalse(SessionRecoveryCoordinator.carriedEditsChangeScoringInputs(rebuilt: rebuilt, carried: tagged))
    }

    // MARK: - The Apple Health export follows the readings

    /// The readings an export is written from change with the beats, the
    /// figures and the sleep, and not with the score or the user's notes.
    func testTheExportReadingsChangeOnlyWithWhatTheExportWrites() {
        var base = night(quality: .good)
        base.rrSeries = RRSeries(points: [RRPoint(t_ms: 0, rr_ms: 1000)], sessionId: base.id, startDate: anchor)
        let (slower, slept) = (result(meanHR: 50), sleep(fromHours: 1, toHours: 7))
        let exported: [(String, (inout HRVSession) -> Void)] = [
            ("beats", { $0.rrSeries = nil }),
            ("heart rate", { $0.analysisResult = slower }),
            ("sleep", { $0.sleepSnapshot = slept }),
            ("end date", { $0.endDate = $0.endDate?.addingTimeInterval(600) })
        ]
        for (field, edit) in exported {
            var edited = base
            edit(&edited)
            XCTAssertNotEqual(HealthExportReadings(of: edited), HealthExportReadings(of: base), field)
        }
        var scored = base
        scored.recoveryScore = 9
        scored.notes = "note"
        XCTAssertEqual(HealthExportReadings(of: scored), HealthExportReadings(of: base))
    }

    /// A rewrite that changed the readings is exported again; one that did
    /// not, or a night still on the review card, is not.
    func testARewriteIsExportedAgainOnlyWhenItsReadingsChanged() async {
        let healthKit = MockHealthKitService()
        let before = night(quality: .good)
        let reviewed = night(quality: .good)
        let service = makeService(healthKit: healthKit, awaitingReview: [reviewed.id])
        var changed = before
        changed.analysisResult = result(meanHR: 50)
        var reviewedChanged = reviewed
        reviewedChanged.analysisResult = result(meanHR: 50)
        service.reexportIfReadingsChanged(from: before, to: before)
        service.reexportIfReadingsChanged(from: reviewed, to: reviewedChanged)
        service.reexportIfReadingsChanged(from: before, to: changed)
        for _ in 0 ..< 100 where healthKit.exportedSessionIds.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(healthKit.exportedSessionIds, [before.id])
    }
}
