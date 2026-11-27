@testable import Emuqu
import XCTest

/// ADR 009, an accepted session is frozen: opening or re-scoring an
/// archived session must produce an IDENTICAL frozen score. This suite guards
/// against one specific way it can drift.
///
/// An `.insufficient` / `.preSleep` session is scored off BASELINE HRV at
/// acceptance (its own RMSSD is untrustworthy). A sleep-edit or training-only
/// re-score that recomputes it WITHOUT that fallback, as a `useBaselineHRV`
/// defaulting to `false` would, moves the frozen score and violates §13.3.
///
/// The re-score path derives the flag from
/// the session's own reliability, so a re-score reproduces the accepted value.
/// These tests assert (a) that derivation equals the acceptance rule for every
/// quality, and (b) that it actually removes a real score difference.
///
@MainActor
final class SessionImmutabilityTests: XCTestCase {

    // Baseline resting HRV ≈ 40 ms (lnRmssdMean = log 40). A session RMSSD well
    // below baseline is where the baseline-HRV fallback changes the score, so
    // these tests exercise the drift rather than passing tautologically.
    private var baselineStats: BaselineTracker.RecoveryBaselineStats {
        BaselineTracker.RecoveryBaselineStats(
            lnRmssdMean: log(40.0), lnRmssdSD: 0.3, lnRmssdCV7Day: 6.0,
            meanHRBaseline: 58.0, meanHRSD: 3.0, daysInWindow: 30
        )
    }

    // Tier-1 (HRV-only) config isolates the HRV factor, where `useBaselineHRV`
    // acts — no sleep / training / vitals to dilute the effect.
    private var config: RecoveryScoreCalculator.ScoringConfiguration {
        RecoveryScoreCalculator.ScoringConfiguration(
            enableTrainingLoadIntegration: false, isOnTrainingBreak: false,
            enableSleepIntegration: false, penalizeMissingSleep: false, userAge: 40
        )
    }

    // Fixed anchor so `referenceDate` (baseline-staleness) can't vary the score.
    private let anchor = Date(timeIntervalSince1970: 1_750_000_000)

    private func compositeScore(rmssd: Double, useBaselineHRV: Bool) -> Double {
        RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: nil, rmssd: rmssd, meanHR: 58.0, dfaAlpha1: 0.85, baselineStats: baselineStats,
                sleepData: nil, vitals: nil, typicalSleepHours: 7.5
            ),
            trainingContext: nil,
            config: config,
            useBaselineHRV: useBaselineHRV,
            referenceDate: anchor
        ).compositeScore
    }

    private func session(quality: HRVDataQuality?) -> HRVSession {
        var s = HRVSession(startDate: anchor, sessionType: .overnight)
        s.hrvDataQuality = quality
        return s
    }

    // MARK: - Derivation equals the acceptance rule (the invariant the fix relies on)

    func testBaselineHRVDerivationMatchesAcceptanceRuleForAllQualities() {
        // Acceptance freezes the score with `HRVQualityDecision.useBaselineHRV`;
        // the re-score paths derive `!isReliableForHRVAggregates` from the
        // stored quality. They must agree for every quality, or a re-score
        // drifts the frozen score.
        for quality in HRVDataQuality.allCases {
            let acceptance = SessionAcceptanceService.HRVQualityDecision(dataQuality: quality)
            XCTAssertEqual(
                !session(quality: quality).isReliableForHRVAggregates, acceptance.useBaselineHRV,
                "useBaselineHRV derivation must match acceptance for quality \(quality)"
            )
        }
        // Legacy entries carry no quality: treated as reliable, never re-scored
        // against the baseline.
        XCTAssertTrue(session(quality: nil).isReliableForHRVAggregates)
    }

    // MARK: - The derived flag reproduces the accepted value (§13.3 stability)

    /// Scores at the calculator level: the flag every `ReanalysisService` path
    /// derives (`!isReliableForHRVAggregates`) gives the composite acceptance
    /// froze, and leaving the fallback off gives a different one.
    /// `ReanalysisService` reads its baseline from `BaselineTracker`, which
    /// loads the shared on-disk baseline file, so the service itself is not
    /// driven here.
    func testDerivedBaselineFallbackReproducesTheAcceptedCompositeForAnInsufficientNight() {
        // Depressed RMSSD (15 ms) well below the 40 ms baseline — the shape
        // that makes a session `.insufficient` in the first place.
        let depressedRmssd = 15.0
        let insufficient = session(quality: .insufficient)
        let derivedUseBaseline = !insufficient.isReliableForHRVAggregates
        XCTAssertTrue(derivedUseBaseline, ".insufficient must derive useBaselineHRV = true")

        // Acceptance freezes with useBaselineHRV = true; the fixed re-score
        // derives the same → byte-identical composite (§13.3, no drift).
        let accepted = compositeScore(rmssd: depressedRmssd, useBaselineHRV: true)
        let rescored = compositeScore(rmssd: depressedRmssd, useBaselineHRV: derivedUseBaseline)
        XCTAssertEqual(rescored, accepted, accuracy: 1e-9,
                       "A re-score must reproduce the accepted score, not drift (§13.3).")

        // Prove the drift is real: omitting the flag (useBaselineHRV = false)
        // scores the same session differently. If this ever fails with
        // equality, the fixture stopped exercising the bug — move RMSSD further
        // from baseline.
        let legacyOmission = compositeScore(rmssd: depressedRmssd, useBaselineHRV: false)
        XCTAssertNotEqual(legacyOmission, accepted, accuracy: 1e-6,
                          "The baseline-HRV fallback must actually change the score for an untrustworthy session.")
    }

    // MARK: - Determinism: identical inputs → identical frozen pieces

    func testCompositeScoreAndFrozenReadinessAreDeterministic() {
        let s1 = compositeScore(rmssd: 15.0, useBaselineHRV: true)
        let s2 = compositeScore(rmssd: 15.0, useBaselineHRV: true)
        XCTAssertEqual(s1, s2, accuracy: 1e-12, "calculateWithBreakdown must be a pure function of its inputs.")

        let r1 = ReanalysisService.computeFrozenReadiness(compositeScore: s1, trainingContext: nil)
        let r2 = ReanalysisService.computeFrozenReadiness(compositeScore: s2, trainingContext: nil)
        XCTAssertEqual(r1, r2, accuracy: 1e-12, "frozenReadiness must be deterministic for a fixed composite.")
    }

    // MARK: - The archived-session update follows the same rule

    /// `updateCompositeRecoveryScore` hard-coded `useBaselineHRV: false`, so
    /// re-saving an `.insufficient` night from the results sheet scored its
    /// untrustworthy RMSSD and moved the frozen score. It now derives the flag
    /// from the session, like every `ReanalysisService` path.
    func testArchivedScoreUpdateScoresAnUntrustworthyNightFromTheBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcceptanceRescore-\(UUID().uuidString)", isDirectory: true)
        let schedule = SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
        let archive = SessionArchive(directory: directory, sleepScheduleProvider: { schedule }, sessionMergeModeProvider: { .off })
        // The tracker and the raw backups live in the test's directory, never
        // on the app's own files, and the tracker has no baseline-changed
        // callback.
        let tracker = BaselineTracker(baselineFile: directory.appendingPathComponent("HRVBaseline.json"))
        let rawBackup = RawRRBackup(directory: directory.appendingPathComponent(AppConfig.backupDirectoryName, isDirectory: true))
        defer {
            rawBackup.waitForQueuedWork()
            XCTAssertNoThrow(try FileManager.default.removeItem(at: directory))
        }
        let service = SessionAcceptanceService(
            archive: archive, healthKit: MockHealthKitService(), baselineTracker: tracker, rawBackup: rawBackup,
            onCloudSync: { _ in }, onCloudDelete: { _ in }
        )
        var night = session(quality: .insufficient)
        night.endDate = anchor.addingTimeInterval(8 * 3600)
        night.analysisResult = depressedResult()
        try archive.archive(night)

        let saved = await service.updateCompositeRecoveryScore(
            for: night, scoringConfig: config, trainingContext: nil, baselineStats: baselineStats,
            typicalSleepHours: 7.5, sleepSchedule: schedule
        )

        XCTAssertTrue(saved)
        let hrv = try XCTUnwrap(archive.retrieve(night.id)?.scoreBreakdown?.factors.first { $0.label == "HRV" })
        XCTAssertEqual(hrv.score, compositeScore(rmssd: 15, useBaselineHRV: true), accuracy: 1e-9)
    }

    /// The update is written onto the archived copy: what it computed (the
    /// score) and the tags the caller carried land, and a field saved
    /// meanwhile (the feeling) stays as the archive holds it.
    func testTheArchivedScoreUpdateKeepsWhatWasSavedWhileItRan() {
        let read = session(quality: .insufficient)
        var updated = read
        updated.recoveryScore = 7.4
        updated.tags = [ReadingTag.alcohol]
        var archived = read
        archived.morningFeeling = 2

        SessionAcceptanceService.applyUpdate(updated, scoredFrom: read, to: &archived)

        XCTAssertEqual(archived.recoveryScore, 7.4)
        XCTAssertEqual(archived.tags, [ReadingTag.alcohol])
        XCTAssertEqual(archived.morningFeeling, 2, "the update put back the copy it read")
    }

    /// A sleep edit saved while the score was computed changed an input of
    /// it, and scored the night itself: the stale score is not written over
    /// it. The caller's tags still are.
    func testAScoreComputedBeforeASleepEditIsNotWrittenOverIt() {
        let read = session(quality: .insufficient)
        var updated = read
        updated.recoveryScore = 7.4
        updated.tags = [ReadingTag.alcohol]
        var archived = read
        archived.sleepStartMs = 1_800_000
        archived.recoveryScore = 5.2

        SessionAcceptanceService.applyUpdate(updated, scoredFrom: read, to: &archived)

        XCTAssertEqual(archived.recoveryScore, 5.2)
        XCTAssertEqual(archived.sleepStartMs, 1_800_000)
        XCTAssertEqual(archived.tags, [ReadingTag.alcohol])
    }

    // MARK: - Acceptance

    /// What the acceptance service handed iCloud, recorded as it happens.
    private final class CloudCalls: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var uploaded: [UUID] = []
        private(set) var liveBackupsCleared: [UUID] = []
        let done: XCTestExpectation

        init(done: XCTestExpectation) { self.done = done }

        func upload(_ id: UUID) { lock.withLock { uploaded.append(id) } }
        func clear(_ id: UUID) {
            lock.withLock { liveBackupsCleared.append(id) }
            done.fulfill()
        }
    }

    private func acceptanceService(in directory: URL, archive: SessionArchive, cloud: CloudCalls) -> SessionAcceptanceService {
        SessionAcceptanceService(
            archive: archive, healthKit: MockHealthKitService(),
            baselineTracker: BaselineTracker(baselineFile: directory.appendingPathComponent("HRVBaseline.json")),
            rawBackup: RawRRBackup(directory: directory.appendingPathComponent(AppConfig.backupDirectoryName, isDirectory: true)),
            onCloudSync: { cloud.upload($0.id) }, onCloudDelete: { cloud.clear($0) }
        )
    }

    private var acceptanceInputs: SessionAcceptanceService.AcceptanceInputs {
        SessionAcceptanceService.AcceptanceInputs(
            scoringConfig: config, trainingContext: nil, baselineStats: baselineStats,
            typicalSleepHours: 7.5, sleepSchedule: SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
        )
    }

    /// Accepting a night freezes its score under the current version,
    /// archives it, uploads it and clears its live backup.
    func testAcceptanceArchivesScoresAndUploadsTheNight() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Acceptance-\(UUID().uuidString)", isDirectory: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let archive = SessionArchive(directory: directory, sleepScheduleProvider: { SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0) }, sessionMergeModeProvider: { .off })
        let cloud = CloudCalls(done: expectation(description: "live backup cleared"))
        var night = session(quality: nil)
        night.endDate = anchor.addingTimeInterval(8 * 3600)
        night.analysisResult = depressedResult()
        var cleared = false

        let accepted = try await acceptanceService(in: directory, archive: archive, cloud: cloud).processAcceptance(
            session: night, inputs: acceptanceInputs, enableHealthKitExport: false,
            clearPersistedRecordingState: { cleared = true }
        )
        await fulfillment(of: [cloud.done], timeout: 2)

        XCTAssertEqual(accepted.id, night.id)
        XCTAssertNotNil(accepted.recoveryScore)
        XCTAssertEqual(accepted.scoreBreakdown?.scoringVersion, ScoringVersion.current)
        XCTAssertNotNil(try archive.retrieve(night.id)?.recoveryScore, "The frozen score was not archived")
        XCTAssertTrue(cleared, "The recording marker was left behind")
        XCTAssertEqual(cloud.uploaded, [night.id])
        XCTAssertEqual(cloud.liveBackupsCleared, [night.id])
    }

    /// A second recording of a night already archived is folded into it;
    /// acceptance carries on with that night and still clears the
    /// recording's own live backup.
    func testAcceptanceAfterAFoldCarriesOnWithTheMergedNight() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcceptanceFold-\(UUID().uuidString)", isDirectory: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let lastNight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-3600)
        // Same-night merging on, as it is by default.
        let archive = SessionArchive(directory: directory)
        func recording(from start: Date, hours: Double) -> HRVSession {
            var session = HRVSession(startDate: start, sessionType: .overnight)
            session.endDate = start.addingTimeInterval(hours * 3600)
            let beats = (0 ..< 200).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: $0 % 2 == 0 ? 990 : 1010) }
            session.rrSeries = RRSeries(points: beats, sessionId: session.id, startDate: start)
            return session
        }
        let earlier = recording(from: lastNight, hours: 7)
        try archive.archive(earlier, skipSameNightMerge: true)
        var second = recording(from: lastNight.addingTimeInterval(3600), hours: 5)
        second.analysisResult = depressedResult()
        let cloud = CloudCalls(done: expectation(description: "live backup cleared"))

        let accepted = try await acceptanceService(in: directory, archive: archive, cloud: cloud).processAcceptance(
            session: second, inputs: acceptanceInputs, enableHealthKitExport: false, clearPersistedRecordingState: {}
        )
        await fulfillment(of: [cloud.done], timeout: 2)

        XCTAssertEqual(accepted.id, earlier.id, "Acceptance carried on with a recording the archive folded away")
        XCTAssertEqual(cloud.uploaded, [earlier.id])
        XCTAssertEqual(cloud.liveBackupsCleared, [second.id])
    }

    /// A recording the archive folded into a night before it was reviewed is
    /// accepted as that night: the night takes the frozen score, and the
    /// recording is not archived, and merged in, a second time.
    func testAcceptingARecordingFoldedBeforeReviewAcceptsTheNightItWentInto() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcceptanceFoldedBefore-\(UUID().uuidString)", isDirectory: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let lastNight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-3600)
        let archive = SessionArchive(directory: directory)
        func recording(from start: Date, hours: Double) -> HRVSession {
            var session = HRVSession(startDate: start, sessionType: .overnight)
            session.endDate = start.addingTimeInterval(hours * 3600)
            let beats = (0 ..< 200).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: $0 % 2 == 0 ? 990 : 1010) }
            session.rrSeries = RRSeries(points: beats, sessionId: session.id, startDate: start)
            session.analysisResult = depressedResult()
            return session
        }
        let earlier = recording(from: lastNight, hours: 7)
        try archive.archive(earlier, skipSameNightMerge: true)
        let second = recording(from: lastNight.addingTimeInterval(3600), hours: 5)
        XCTAssertEqual(try archive.archive(second).sessionId, earlier.id, "the fixture expects the second recording folded")
        let refolds = FoldNotices(recordingId: second.id)
        let token = NotificationCenter.default.addObserver(forName: .flowRecoveryArchiveChanged, object: nil, queue: nil) { note in
            refolds.note(note.object as? UUID)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let cloud = CloudCalls(done: expectation(description: "live backup cleared"))

        let accepted = try await acceptanceService(in: directory, archive: archive, cloud: cloud).processAcceptance(
            session: second, inputs: acceptanceInputs, enableHealthKitExport: false, clearPersistedRecordingState: {}
        )
        await fulfillment(of: [cloud.done], timeout: 2)

        XCTAssertEqual(accepted.id, earlier.id)
        XCTAssertEqual(refolds.count, 0, "the card's copy was archived again and folded into the night a second time")
        XCTAssertNotNil(try archive.retrieve(earlier.id)?.recoveryScore, "the score was frozen on the card's copy, which nothing keeps")
        XCTAssertEqual(cloud.liveBackupsCleared, [second.id])
    }

    /// Counts the change notices posted under a folded recording's id, which
    /// only a fold of it posts.
    private final class FoldNotices: @unchecked Sendable {
        private let lock = NSLock()
        private let recordingId: UUID
        private var seen = 0

        init(recordingId: UUID) { self.recordingId = recordingId }

        var count: Int { lock.withLock { seen } }

        func note(_ id: UUID?) {
            guard id == recordingId else { return }
            lock.withLock { seen += 1 }
        }
    }

    // MARK: - An unusable recording's heart rate is not a sleep HR

    private func vitals(restingHeartRate: Double?) -> RecoveryVitals {
        RecoveryVitals(
            respiratoryRate: 14, respiratoryRateBaseline: 14, oxygenSaturation: 97, oxygenSaturationMin: 95,
            wristTemperature: nil, wristTemperatureBaseline: nil, restingHeartRate: restingHeartRate
        )
    }

    private func breakdown(
        meanHR: Double, vitals: RecoveryVitals, useBaselineHRV: Bool
    ) -> RecoveryScoreCalculator.ScoreBreakdown {
        let stats = BaselineTracker.RecoveryBaselineStats(
            lnRmssdMean: log(40.0), lnRmssdSD: 0.3, lnRmssdCV7Day: 6.0,
            meanHRBaseline: 52.0, meanHRSD: 3.0, daysInWindow: 30
        )
        return RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: nil, rmssd: 15, meanHR: meanHR, dfaAlpha1: 0.85, baselineStats: stats,
                sleepData: sleep(minutes: 480), vitals: vitals, typicalSleepHours: 7.5
            ),
            // Sleep and vitals both present: the three-factor tier, where the
            // vitals sub-score weighs in.
            trainingContext: nil, config: rescoreContext(baseline: nil).scoringConfig,
            useBaselineHRV: useBaselineHRV, referenceDate: anchor
        )
    }

    /// A recording made awake (22:00 to 23:00, `.preSleep`) has a mean HR of
    /// 70 against a 52 ± 3 sleep-HR baseline. A pass that ran before the
    /// recording was classified copied that 70 into the vitals as resting
    /// HR. Scored from the baseline, the night must read as having no sleep
    /// HR, not as "Sleep HR 70 (+18 bpm)".
    func testAnUnusableRecordingsHeartRateIsNotScoredAsSleepHR() {
        let copied = breakdown(meanHR: 70, vitals: vitals(restingHeartRate: 70), useBaselineHRV: true)
        let none = breakdown(meanHR: 70, vitals: vitals(restingHeartRate: nil), useBaselineHRV: true)
        XCTAssertEqual(copied.compositeScore, none.compositeScore, accuracy: 1e-9)
        let factors = copied.factors.map { "\($0.label) \($0.score) \($0.facts?.vitals?.sleepHR ?? -1)" }
        XCTAssertEqual(factors, none.factors.map { "\($0.label) \($0.score) \($0.facts?.vitals?.sleepHR ?? -1)" })
        // HealthKit's resting HR is a different number and still counts.
        let health = breakdown(meanHR: 70, vitals: vitals(restingHeartRate: 60), useBaselineHRV: true)
        XCTAssertNotEqual(health.compositeScore, none.compositeScore, accuracy: 1e-6)
    }

    /// The snapshot rule: a usable recording's strap HR stands as sleep HR; an
    /// unusable one keeps HealthKit's resting HR, and drops a value copied
    /// from its own mean HR.
    func testTheSleepHeartRateRuleUsesTheStrapOnlyForAUsableRecording() {
        var usable = session(quality: .good)
        usable.analysisResult = depressedResult()
        XCTAssertEqual(usable.withSleepHeartRate(vitals(restingHeartRate: 62)).restingHeartRate, 58)
        var awake = session(quality: .preSleep)
        awake.analysisResult = depressedResult()
        XCTAssertNil(awake.strapSleepHeartRate)
        XCTAssertEqual(awake.withSleepHeartRate(vitals(restingHeartRate: 62)).restingHeartRate, 62)
        XCTAssertNil(awake.withSleepHeartRate(vitals(restingHeartRate: 58)).restingHeartRate)
    }

    // MARK: - A sleep edit on a night with no baseline

    private func scoredWithoutBaseline(sleepMinutes: Int) -> HRVSession {
        var night = session(quality: .good)
        night.endDate = anchor.addingTimeInterval(8 * 3600)
        night.analysisResult = depressedResult()
        night.sleepSnapshot = sleep(minutes: sleepMinutes)
        let scored = ReanalysisService.rescoredBreakdown(
            of: night, result: depressedResult(), training: nil, referenceDate: anchor,
            context: rescoreContext(baseline: nil)
        )
        night.scoreBreakdown = scored
        night.recoveryScore = RecoveryScoreCalculator.toTenScale(scored.compositeScore)
        return night
    }

    private func sleep(minutes: Int) -> SleepData {
        let end = anchor.addingTimeInterval(8 * 3600)
        let start = end.addingTimeInterval(-Double(minutes) * 60)
        return SleepData(
            date: end, inBedStart: start, sleepStart: start, sleepEnd: end,
            totalSleepMinutes: minutes, inBedMinutes: minutes,
            deepSleepMinutes: minutes / 5, remSleepMinutes: minutes / 5, awakeMinutes: 0,
            sleepEfficiency: 92, boundarySource: .healthKit,
            segments: [], stageIntervals: [], boundaryValidation: nil, hrSleepQuality: nil
        )
    }

    private func rescoreContext(baseline: BaselineTracker.RecoveryBaselineStats?) -> RescoreContext {
        RescoreContext(
            baselineStats: baseline, typicalSleepHours: 8,
            scoringConfig: RecoveryScoreCalculator.ScoringConfiguration(
                enableTrainingLoadIntegration: false, isOnTrainingBreak: false,
                enableSleepIntegration: true, penalizeMissingSleep: false, userAge: 40
            )
        )
    }

    /// One of a user's first nights, scored with no baseline, has its sleep
    /// edited from 8 hours to 3. The re-score reads the edited sleep, so the
    /// stored score is not left computed on the old night.
    func testASleepEditRescoresANightFirstScoredWithoutABaseline() {
        var night = scoredWithoutBaseline(sleepMinutes: 480)
        let before = night.scoreBreakdown?.compositeScore
        night.sleepSnapshot = sleep(minutes: 180)
        let inputs = SleepBoundaryWrite.Inputs(context: rescoreContext(baseline: nil), fallbackTraining: nil)
        SleepBoundaryWrite.rescore(&night, sessionEnd: anchor.addingTimeInterval(8 * 3600), inputs: inputs)
        let after = ReanalysisService.rescoredBreakdown(
            of: night, result: depressedResult(), training: nil, referenceDate: anchor.addingTimeInterval(8 * 3600),
            context: inputs.context
        )
        XCTAssertNotEqual(night.scoreBreakdown?.compositeScore, before)
        XCTAssertEqual(night.scoreBreakdown?.compositeScore, after.compositeScore)
    }

    /// A night scored against a baseline that can no longer be rebuilt keeps
    /// its stored score: a no-baseline score would replace it.
    func testANightScoredAgainstABaselineKeepsItsScoreWhenNoneCanBeRebuilt() {
        var night = session(quality: .good)
        night.analysisResult = depressedResult()
        night.recoveryScore = 6
        night.scoreBreakdown = breakdown(meanHR: 58, vitals: vitals(restingHeartRate: nil), useBaselineHRV: false)
        XCTAssertTrue(ReanalysisService.keepsStoredScore(night, baseline: nil))
        night.scoreBreakdown = scoredWithoutBaseline(sleepMinutes: 480).scoreBreakdown
        XCTAssertFalse(ReanalysisService.keepsStoredScore(night, baseline: nil))
    }

    private func depressedResult() -> HRVAnalysisResult {
        HRVAnalysisResult(
            windowStart: 0, windowEnd: 400,
            timeDomain: TimeDomainMetrics(
                meanRR: 1035, sdnn: 30, rmssd: 15, pnn50: 2, sdsd: 14, meanHR: 58, sdHR: 3, triangularIndex: nil
            ),
            frequencyDomain: nil,
            nonlinear: NonlinearMetrics(
                sd1: 10, sd2: 40, sd1Sd2Ratio: 0.25, sampleEntropy: 1.5, approxEntropy: 1.3,
                dfaAlpha1: 0.85, dfaAlpha2: nil, dfaAlpha1R2: 0.95
            ),
            ansMetrics: nil, artifactPercentage: 1, cleanBeatCount: 400, analysisDate: anchor
        )
    }
}
