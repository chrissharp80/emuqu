@testable import Emuqu
import XCTest

@MainActor
final class ReanalysisServiceTests: XCTestCase {
    // MARK: - computeFrozenReadiness (static, pure function)
    //
    // `compositeScore` is the 0-100 recovery score; the result is on the
    // 0-10 scale.

    func testComputeFrozenReadiness_withNilTrainingContext() {
        // When training context is nil, ATL and CTL default to 0
        let readiness = ReanalysisService.computeFrozenReadiness(
            compositeScore: 75,
            trainingContext: nil
        )
        // Should return a valid 0-10 scale score
        XCTAssertFalse(readiness.isNaN)
        XCTAssertFalse(readiness.isInfinite)
        XCTAssertGreaterThanOrEqual(readiness, 0)
        XCTAssertLessThanOrEqual(readiness, 10)
    }

    func testComputeFrozenReadiness_deterministic() {
        // Same inputs should always produce the same output
        let score1 = ReanalysisService.computeFrozenReadiness(
            compositeScore: 65,
            trainingContext: nil
        )
        let score2 = ReanalysisService.computeFrozenReadiness(
            compositeScore: 65,
            trainingContext: nil
        )
        XCTAssertEqual(score1, score2, accuracy: 0.0001)
    }

    func testComputeFrozenReadiness_higherCompositeScoreYieldsHigherReadiness() {
        let low = ReanalysisService.computeFrozenReadiness(
            compositeScore: 30,
            trainingContext: nil
        )
        let high = ReanalysisService.computeFrozenReadiness(
            compositeScore: 90,
            trainingContext: nil
        )
        XCTAssertGreaterThan(high, low)
    }

    func testComputeFrozenReadiness_zeroCompositeScore() {
        let readiness = ReanalysisService.computeFrozenReadiness(
            compositeScore: 0,
            trainingContext: nil
        )
        XCTAssertFalse(readiness.isNaN)
        XCTAssertGreaterThanOrEqual(readiness, 0)
    }

    func testComputeFrozenReadiness_maxCompositeScore() {
        let readiness = ReanalysisService.computeFrozenReadiness(
            compositeScore: 100,
            trainingContext: nil
        )
        XCTAssertFalse(readiness.isNaN)
        XCTAssertLessThanOrEqual(readiness, 10)
    }

    // MARK: - Sleep that arrives after the morning

    nonisolated private let archiveDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReanalysisSleepTests-\(UUID().uuidString)", isDirectory: true)

    /// The service's baseline tracker lives on this file, never on the app's
    /// own `HRVBaseline.json`.
    nonisolated private let baselineFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReanalysisBaseline-\(UUID().uuidString).json")

    private lazy var archive = SessionArchive(
        directory: archiveDirectory,
        sleepScheduleProvider: { SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0) },
        sessionMergeModeProvider: { .off }
    )

    override func tearDown() {
        do {
            try FileManager.default.removeItem(at: archiveDirectory)
        } catch {
            // swallow-ok: a test that never archived left no directory behind.
        }
        do {
            try FileManager.default.removeItem(at: baselineFile)
        } catch {
            // swallow-ok: a test whose tracker never saved left no file behind.
        }
        super.tearDown()
    }

    private func makeService() -> ReanalysisService {
        let healthKit = MockHealthKitService()
        let windowSelector = WindowSelector()
        let artifactDetector = ArtifactDetector()
        let settings = UserSettings()
        return ReanalysisService(
            archive: archive, healthKit: healthKit,
            analysisPipeline: HRVAnalysisPipeline(
                artifactDetector: artifactDetector, windowSelector: windowSelector, healthKit: healthKit
            ),
            windowSelector: windowSelector, artifactDetector: artifactDetector,
            baselineTracker: BaselineTracker(baselineFile: baselineFile),
            settingsProvider: { settings },
            scoringConfigProvider: { .init(from: settings) },
            ansConfigProvider: { _ in
                HRVAnalysisPipeline.ANSConfiguration(baselineRMSSD: 40, vo2Max: nil, trainingLoadAdjustment: 0)
            },
            trainingContextProvider: { _ in nil },
            analyzeWithWindow: { _, _, _, _ in nil },
            analyzeFullSession: { _, _ in nil },
            onArchiveChanged: {},
            onSessionUploaded: { _ in }
        )
    }

    private let nightStart = Date(timeIntervalSince1970: 4_102_444_800) // 2100-01-01T00:00:00Z

    private func overnight() -> HRVSession {
        HRVSession(
            id: UUID(), startDate: nightStart, endDate: nightStart.addingTimeInterval(8 * 3600),
            state: .complete, sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
    }

    private func watchNight(minutes: Int) -> SleepData {
        SleepData(
            date: nightStart, inBedStart: nightStart,
            sleepStart: nightStart.addingTimeInterval(600),
            sleepEnd: nightStart.addingTimeInterval(600 + Double(minutes + 30) * 60),
            totalSleepMinutes: minutes, inBedMinutes: minutes + 30,
            deepSleepMinutes: 60, remSleepMinutes: 90, awakeMinutes: 30, sleepEfficiency: 93,
            boundarySource: .healthKit, segments: [], stageIntervals: [],
            boundaryValidation: nil, hrSleepQuality: nil
        )
    }

    /// The results screen fetches HealthKit sleep live for a session with no
    /// snapshot yet; the automatic update path saves it, so the session holds
    /// the sleep ("the app will update sleep data from HealthKit when you view
    /// the session later") instead of re-querying on every open.
    func testLateHealthKitSleepIsSavedForASessionWithoutASnapshot() throws {
        let session = overnight()
        try archive.archive(session)
        XCTAssertTrue(makeService().updateSessionSleepBoundaries(sessionId: session.id, sleepData: watchNight(minutes: 420)))
        XCTAssertEqual(try archive.retrieve(session.id)?.sleepSnapshot?.nightSleepMinutes, 420)
    }

    /// User edits are the source of truth: late HealthKit sleep never
    /// replaces a timeline the user adjusted.
    func testLateHealthKitSleepNeverOverwritesAUserAdjustedNight() throws {
        var session = overnight()
        session.sleepSnapshot = watchNight(minutes: 300)
        session.sleepUserAdjusted = true
        try archive.archive(session)
        XCTAssertFalse(makeService().updateSessionSleepBoundaries(sessionId: session.id, sleepData: watchNight(minutes: 420)))
        XCTAssertEqual(try archive.retrieve(session.id)?.sleepSnapshot?.nightSleepMinutes, 300)
    }

    // MARK: - Writing a rescore

    /// A rescore works from the copy it read. An edit the user saved to the
    /// archive while it ran survives the rescore's write, and the write
    /// still lands the new score.
    func testAnEditSavedWhileARescoreRanSurvivesItsWrite() throws {
        var read = overnight()
        read.recoveryScore = 6.1
        try archive.archive(read)
        try archive.updateTags(read.id, tags: [ReadingTag.alcohol], notes: "late dinner")
        try archive.update(read.id, requestingReupload: false) { $0.morningFeeling = 2 }
        var rescored = read
        rescored.recoveryScore = 7.4

        let written = try ReanalysisService.writeRescore(rescored, to: archive)

        let stored = try XCTUnwrap(try archive.retrieve(read.id))
        XCTAssertEqual(stored.recoveryScore, 7.4)
        XCTAssertEqual(stored.tags, [ReadingTag.alcohol])
        XCTAssertEqual(stored.notes, "late dinner")
        XCTAssertEqual(stored.morningFeeling, 2)
        XCTAssertEqual(written.tags, [ReadingTag.alcohol], "callers get the session as written")
    }

    /// A rescored session the archive does not hold is archived as it is.
    func testARescoreOfASessionNotYetArchivedIsArchivedAsItIs() throws {
        var session = overnight()
        session.recoveryScore = 7.4
        session.notes = "from the card"

        let written = try ReanalysisService.writeRescore(session, to: archive)

        XCTAssertEqual(written.notes, "from the card")
        XCTAssertEqual(try archive.retrieve(session.id)?.recoveryScore, 7.4)
    }

    /// The HealthKit export stamp and the AI context are written while a
    /// rescore can run. Putting the stamp back to nil would export the same
    /// samples again, so both stay as the archive holds them.
    func testARescoreKeepsTheExportStampAndAIContextSavedWhileItRan() throws {
        var read = overnight()
        read.recoveryScore = 6.1
        try archive.archive(read)
        let exportedAt = nightStart.addingTimeInterval(9 * 3600)
        try archive.update(read.id, requestingReupload: false) {
            $0.healthKitExportedAt = exportedAt
            $0.aiContext = ["coaching": "easy day"]
        }
        var rescored = read
        rescored.recoveryScore = 7.4

        _ = try ReanalysisService.writeRescore(rescored, to: archive)

        let stored = try XCTUnwrap(try archive.retrieve(read.id))
        XCTAssertEqual(stored.recoveryScore, 7.4)
        XCTAssertEqual(stored.healthKitExportedAt, exportedAt)
        XCTAssertEqual(stored.aiContext, ["coaching": "easy day"])
    }

    /// Every stored field of the session is either computed by a rescore or
    /// kept from the archived copy. A field added to `HRVSession` fails here
    /// until it is classified, so a rescore cannot silently write it back.
    func testEveryStoredSessionFieldIsClassifiedForARescoreWrite() {
        let fields = Set(Mirror(reflecting: overnight()).children.compactMap(\.label))
        let computed = ReanalysisService.rescoreComputedFields
        let stored = ReanalysisService.rescoreStoredFields
        XCTAssertTrue(computed.isDisjoint(with: stored), "a field is either computed or kept, not both")
        XCTAssertEqual(computed.union(stored), fields)
    }

    // MARK: - Unlinking a segment

    /// A linked segment that can be read is unlinked: the parent drops the
    /// link and the call reports true, which is what lets the report take the
    /// segment off its list.
    func testUnlinkingALinkedSegmentDropsTheLinkAndReportsTrue() throws {
        let segment = HRVSession(
            id: UUID(), startDate: nightStart.addingTimeInterval(2 * 3600), endDate: nightStart.addingTimeInterval(3 * 3600),
            state: .complete, sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        var parent = overnight()
        parent.linkedSessionIds = [segment.id]
        try archive.archive(segment)
        try archive.archive(parent)

        XCTAssertTrue(makeService().unlinkSegment(segmentId: segment.id, fromSession: parent.id))
        XCTAssertNil(try archive.retrieve(parent.id)?.linkedSessionIds)
    }

    // MARK: - Re-score vitals

    /// A snapshot written without the strap swap (an iCloud backfill stores
    /// Apple Health's daytime resting HR) is re-scored with the strap's
    /// nocturnal HR, as acceptance would have frozen it; a snapshot that
    /// already carries it is unchanged.
    func testRescoreReadsTheStrapNocturnalHeartRate() {
        var session = overnight()
        session.vitalsSnapshot = RecoveryVitals(
            respiratoryRate: 14, respiratoryRateBaseline: 14, oxygenSaturation: 97, oxygenSaturationMin: 95,
            wristTemperature: nil, wristTemperatureBaseline: nil, restingHeartRate: 64
        )
        let result = HRVAnalysisResult(
            windowStart: 0, windowEnd: 400,
            timeDomain: TimeDomainMetrics(
                meanRR: 1100, sdnn: 55, rmssd: 45, pnn50: 20, sdsd: 40, meanHR: 52, sdHR: 5, triangularIndex: nil
            ),
            frequencyDomain: nil,
            nonlinear: NonlinearMetrics(
                sd1: 30, sd2: 60, sd1Sd2Ratio: 0.5, sampleEntropy: 1.5, approxEntropy: 1.3,
                dfaAlpha1: 0.9, dfaAlpha2: nil, dfaAlpha1R2: 0.95
            ),
            ansMetrics: nil, artifactPercentage: 1, cleanBeatCount: 400, analysisDate: nightStart
        )
        let vitals = ReanalysisService.scoringVitals(of: session, result: result)
        XCTAssertEqual(vitals?.restingHeartRate, 52)
        XCTAssertEqual(vitals?.respiratoryRate, 14, "Only the heart rate is swapped")
        session.vitalsSnapshot = vitals
        XCTAssertEqual(ReanalysisService.scoringVitals(of: session, result: result), vitals)
    }
}
