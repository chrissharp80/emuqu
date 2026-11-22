@testable import Emuqu
import XCTest

@MainActor
final class ReanalysisServiceTests: XCTestCase {
    // MARK: - computeFrozenReadiness (static, pure function)
    //
    // `compositeScore` is the 0-100 recovery score; the result is on the
    // 0-10 scale.

    /// With no training context ATL and CTL are 0: no load leaves full
    /// capacity (100), and with no fitness base the model earns no trust, so
    /// the recovery modulation hands the whole say to the recovery score:
    /// readiness is the composite on the 0-10 scale.
    func testComputeFrozenReadiness_withNilTrainingContext() {
        let readiness = ReanalysisService.computeFrozenReadiness(compositeScore: 75, trainingContext: nil)
        XCTAssertEqual(readiness, 7.5, accuracy: 1e-9)
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
        let low = ReanalysisService.computeFrozenReadiness(compositeScore: 30, trainingContext: nil)
        let high = ReanalysisService.computeFrozenReadiness(compositeScore: 90, trainingContext: nil)
        XCTAssertEqual(low, 3.0, accuracy: 1e-9)
        XCTAssertEqual(high, 9.0, accuracy: 1e-9)
    }

    func testComputeFrozenReadiness_zeroCompositeScore() {
        let readiness = ReanalysisService.computeFrozenReadiness(compositeScore: 0, trainingContext: nil)
        XCTAssertEqual(readiness, 0, accuracy: 1e-9)
    }

    func testComputeFrozenReadiness_maxCompositeScore() {
        let readiness = ReanalysisService.computeFrozenReadiness(compositeScore: 100, trainingContext: nil)
        XCTAssertEqual(readiness, 10, accuracy: 1e-9)
    }

    /// ATL 40 on CTL 40: a capacity ratio of 1.0, which maps to 70; the
    /// acute:chronic ratio of 1.0 is under the 1.3 damper and the morning ATL
    /// is the current one, so no bonus. CTL 40 earns the model its full
    /// trust (0.55). Against a recovery score of 50 the model is higher and
    /// keeps 55 % of its lead: 50 + 0.55 x 20 = 61. Against 90 it is lower
    /// and the score lifts it by 30 % of the gap: 70 + 0.3 x 20 = 76.
    func testComputeFrozenReadiness_withTrainingLoad() {
        let load = TrainingContext(atl: 40, ctl: 40, tsb: 0, yesterdayTrimp: 0, vo2Max: nil,
                                   daysSinceHardWorkout: nil, recentWorkouts: nil)
        XCTAssertEqual(ReanalysisService.computeFrozenReadiness(compositeScore: 50, trainingContext: load), 6.1, accuracy: 1e-9)
        XCTAssertEqual(ReanalysisService.computeFrozenReadiness(compositeScore: 90, trainingContext: load), 7.6, accuracy: 1e-9)
    }

    // MARK: - Sleep that arrives after the morning

    nonisolated private let archiveDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReanalysisSleepTests-\(UUID().uuidString)", isDirectory: true)

    /// The service's baseline tracker lives on this file, never on the app's
    /// own `HRVBaseline.json`.
    nonisolated private let baselineFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReanalysisBaseline-\(UUID().uuidString).json")

    private lazy var archive = makeArchive()

    /// An archive over the test's directory; a second one reads the index as
    /// it is on disk now.
    private func makeArchive() -> SessionArchive {
        SessionArchive(
            directory: archiveDirectory,
            sleepScheduleProvider: { SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0) },
            sessionMergeModeProvider: { .off }
        )
    }

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

    /// `analysis` answers both analysis closures (window and full session),
    /// once per reanalysis pass; nil fails the pass. The service works on
    /// `archive`, the test's own unless another is given.
    private func makeService(
        on archive: SessionArchive? = nil, analysis: @escaping () -> HRVAnalysisResult? = { nil }
    ) -> ReanalysisService {
        let archive = archive ?? self.archive
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
            analyzeWithWindow: { _, _, _, _ in analysis() },
            analyzeFullSession: { _, _ in analysis() },
            onArchiveChanged: {},
            onSessionUploaded: { _ in },
            onZonesStale: { _ in }
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
    func testLateHealthKitSleepIsSavedForASessionWithoutASnapshot() async throws {
        let session = overnight()
        try archive.archive(session)
        let saved = await makeService().updateSessionSleepBoundaries(sessionId: session.id, sleepData: watchNight(minutes: 420)).value
        XCTAssertTrue(saved)
        XCTAssertEqual(try archive.retrieve(session.id)?.sleepSnapshot?.nightSleepMinutes, 420)
    }

    /// User edits are the source of truth: late HealthKit sleep never
    /// replaces a timeline the user adjusted.
    func testLateHealthKitSleepNeverOverwritesAUserAdjustedNight() async throws {
        var session = overnight()
        session.sleepSnapshot = watchNight(minutes: 300)
        session.sleepUserAdjusted = true
        try archive.archive(session)
        let saved = await makeService().updateSessionSleepBoundaries(sessionId: session.id, sleepData: watchNight(minutes: 420)).value
        XCTAssertFalse(saved)
        XCTAssertEqual(try archive.retrieve(session.id)?.sleepSnapshot?.nightSleepMinutes, 300)
    }

    // MARK: - Writing a sleep edit

    /// What a sleep edit's re-score reads besides the session, as the tests'
    /// service would capture it.
    private func sleepInputs() -> SleepBoundaryWrite.Inputs {
        SleepBoundaryWrite.Inputs(
            context: RescoreContext(baselineStats: nil, typicalSleepHours: 8, scoringConfig: .init(from: UserSettings())),
            fallbackTraining: nil
        )
    }

    /// A user's edit decided on the copy it read lands on the archived copy:
    /// the clamped boundaries, the snapshot and the adjusted mark are stored,
    /// and an edit saved meanwhile to a field the edit does not read (the
    /// tags) is kept.
    func testASleepEditLandsOnTheArchivedCopy() throws {
        let read = overnight()
        try archive.archive(read)
        try archive.updateTags(read.id, tags: [ReadingTag.alcohol], notes: "late dinner")
        let edit = try XCTUnwrap(SleepBoundaryWrite.Edit(sleepData: watchNight(minutes: 420), isUserAdjustment: true))

        let outcome = try SleepBoundaryWrite.write(edit, readFrom: read, inputs: sleepInputs(), to: archive)

        guard case .written = outcome else { return XCTFail("expected a write, got \(outcome)") }
        let stored = try XCTUnwrap(try archive.retrieve(read.id))
        XCTAssertEqual(stored.sleepSnapshot?.nightSleepMinutes, 420)
        XCTAssertEqual(stored.sleepStartMs, 600_000)
        XCTAssertEqual(stored.sleepEndMs, (600 + 450 * 60) * 1000)
        XCTAssertEqual(stored.sleepUserAdjusted, true)
        XCTAssertEqual(stored.tags, [ReadingTag.alcohol])
    }

    /// A sleep edit decided on a copy that is no longer the archive's (other
    /// sleep was saved after it was read) is refused: nothing of it is
    /// written, and the stored copy comes back to run again from.
    func testAStaleSleepEditIsRefused() throws {
        let read = overnight()
        try archive.archive(read)
        let savedMeanwhile = watchNight(minutes: 300)
        try archive.update(read.id, requestingReupload: false) { $0.sleepSnapshot = savedMeanwhile }
        let edit = try XCTUnwrap(SleepBoundaryWrite.Edit(sleepData: watchNight(minutes: 420), isUserAdjustment: true))

        let outcome = try SleepBoundaryWrite.write(edit, readFrom: read, inputs: sleepInputs(), to: archive)

        guard case .inputsChanged(let stored) = outcome else { return XCTFail("expected a refusal, got \(outcome)") }
        XCTAssertEqual(stored.sleepSnapshot?.nightSleepMinutes, 300, "the refusal hands back the stored copy")
        let archived = try XCTUnwrap(try archive.retrieve(read.id))
        XCTAssertEqual(archived.sleepSnapshot?.nightSleepMinutes, 300)
        XCTAssertNil(archived.sleepStartMs)
        XCTAssertNil(archived.sleepUserAdjusted)
    }

    /// Through the service, edits made one after another land in that order
    /// (each waits for the one before), so the last one made is the one
    /// stored.
    func testSleepEditsLandInTheOrderTheyWereMade() async throws {
        let session = overnight()
        try archive.archive(session)
        let service = makeService()

        let first = service.updateSessionSleepBoundaries(sessionId: session.id, sleepData: watchNight(minutes: 420), isUserAdjustment: true)
        let second = service.updateSessionSleepBoundaries(sessionId: session.id, sleepData: watchNight(minutes: 300), isUserAdjustment: true)
        let firstSaved = await first.value
        let secondSaved = await second.value

        XCTAssertTrue(firstSaved)
        XCTAssertTrue(secondSaved)
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

        let outcome = try RescoreWrite.write(rescored, readFrom: read, kind: .scoreOnly(healedTraining: false), to: archive)

        let stored = try XCTUnwrap(try archive.retrieve(read.id))
        XCTAssertEqual(stored.recoveryScore, 7.4)
        XCTAssertEqual(stored.tags, [ReadingTag.alcohol])
        XCTAssertEqual(stored.notes, "late dinner")
        XCTAssertEqual(stored.morningFeeling, 2)
        guard case .written(let written) = outcome else { return XCTFail("expected a write, got \(outcome)") }
        XCTAssertEqual(written.tags, [ReadingTag.alcohol], "callers get the session as written")
    }

    /// A rescore never creates a session. One the archive does not hold (a
    /// reading not yet accepted, or a night "Delete All My Data" removed while
    /// the rescore ran) is not written, so the purge's empty archive stays
    /// empty.
    func testARescoreOfASessionTheArchiveDoesNotHoldIsNotWritten() throws {
        var session = overnight()
        session.recoveryScore = 7.4
        session.notes = "from the card"

        let outcome = try RescoreWrite.write(session, readFrom: session, kind: .reanalysis(healedTraining: false), to: archive)

        guard case .notArchived = outcome else { return XCTFail("expected no write, got \(outcome)") }
        XCTAssertNil(outcome.written)
        XCTAssertFalse(archive.exists(session.id), "A rescore archived a session the archive did not hold")
    }

    /// A rescore that finishes while "Delete All My Data" runs is refused by
    /// the purge gate and writes nothing.
    func testARescoreWriteIsRefusedWhileAPurgeRuns() async throws {
        var read = overnight()
        read.recoveryScore = 6.1
        try archive.archive(read)
        var rescored = read
        rescored.recoveryScore = 7.4

        await PurgeGate.beginPurge()
        defer { PurgeGate.endPurge() }
        XCTAssertThrowsError(try RescoreWrite.write(rescored, readFrom: read, kind: .scoreOnly(healedTraining: false), to: archive)) {
            XCTAssertTrue($0 is PurgeGate.Refused, "expected the purge gate's refusal, got \($0)")
        }
        XCTAssertEqual(try archive.retrieve(read.id)?.recoveryScore, 6.1)
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

        _ = try RescoreWrite.write(rescored, readFrom: read, kind: .reanalysis(healedTraining: false), to: archive)

        let stored = try XCTUnwrap(try archive.retrieve(read.id))
        XCTAssertEqual(stored.recoveryScore, 7.4)
        XCTAssertEqual(stored.healthKitExportedAt, exportedAt)
        XCTAssertEqual(stored.aiContext, ["coaching": "easy day"])
    }

    /// A score-only pass sets the score and nothing it does not compute: the
    /// window mark, the artifact flags and the quality class stay as stored.
    func testAScoreOnlyWriteLeavesTheWindowFlagsAndQualityAlone() throws {
        var read = overnight()
        read.recoveryScore = 6.1
        read.windowUserAdjusted = true
        read.hrvDataQuality = .insufficient
        try archive.archive(read)
        var rescored = read
        rescored.recoveryScore = 7.4
        rescored.windowUserAdjusted = nil
        rescored.hrvDataQuality = .preSleep
        rescored.artifactFlags = []

        _ = try RescoreWrite.write(rescored, readFrom: read, kind: .scoreOnly(healedTraining: false), to: archive)

        let stored = try XCTUnwrap(try archive.retrieve(read.id))
        XCTAssertEqual(stored.recoveryScore, 7.4)
        XCTAssertEqual(stored.windowUserAdjusted, true)
        XCTAssertEqual(stored.hrvDataQuality, .insufficient)
        XCTAssertNil(stored.artifactFlags)
    }

    /// A sleep edit saved while a reanalysis ran changes an input of its
    /// score. Nothing is written from the stale run; the pass runs again from
    /// the stored copy, and the score written is the one the new sleep gives.
    func testASleepEditDuringAReanalysisIsScoredFromTheNewSleep() async throws {
        var night = overnight()
        night.rrSeries = RRSeries(points: Self.beats(count: 900), sessionId: night.id, startDate: nightStart)
        night.sleepSnapshot = watchNight(minutes: 300)
        try archive.archive(night)
        let read = try XCTUnwrap(try archive.retrieve(night.id))
        var passes = 0
        let service = makeService { [archive = self.archive, nightStart = self.nightStart] in
            passes += 1
            if passes == 1 { Self.editSleep(of: read.id, in: archive, nightStart: nightStart) }
            return Self.analysis(at: nightStart)
        }

        let written = await service.reanalyzeSession(read)

        let stored = try XCTUnwrap(try archive.retrieve(night.id))
        XCTAssertEqual(passes, 2, "the stale run was not written; the pass ran again")
        XCTAssertEqual(stored.sleepSnapshot?.nightSleepMinutes, 420)
        let expected = service.deterministicRecoveryScore(for: stored, result: Self.analysis(at: nightStart)).score
        XCTAssertEqual(try XCTUnwrap(stored.recoveryScore), expected, accuracy: 0.0001)
        XCTAssertEqual(written?.recoveryScore, stored.recoveryScore)
    }

    /// A window picked by hand while an automatic reanalysis ran is the
    /// user's: the reanalysis writes nothing over it and does not run again.
    func testAManualWindowPickedDuringAnAutomaticReanalysisSurvives() async throws {
        var night = overnight()
        night.rrSeries = RRSeries(points: Self.beats(count: 900), sessionId: night.id, startDate: nightStart)
        night.recoveryScore = 6.1
        try archive.archive(night)
        let read = try XCTUnwrap(try archive.retrieve(night.id))
        var passes = 0
        let service = makeService { [archive = self.archive, nightStart = self.nightStart] in
            passes += 1
            Self.pickWindow(of: read.id, in: archive)
            return Self.analysis(at: nightStart)
        }

        let written = await service.reanalyzeSession(read)

        let stored = try XCTUnwrap(try archive.retrieve(night.id))
        XCTAssertNil(written)
        XCTAssertEqual(passes, 1)
        XCTAssertEqual(stored.windowUserAdjusted, true)
        XCTAssertEqual(stored.recoveryScore, 8.8, "the manual pick's own score")
    }

    // MARK: - Manual window and stored beats

    /// A manual pick handed a copy without its beats (a lightweight copy the
    /// dashboard decoded) is applied to the archived copy, beats included.
    func testAManualWindowOnALightweightCopyKeepsTheStoredBeats() async throws {
        var night = overnight()
        night.rrSeries = RRSeries(points: Self.beats(count: 900), sessionId: night.id, startDate: nightStart)
        try archive.archive(night)
        var lightweight = night
        lightweight.rrSeries = nil

        let written = await makeService().applyManualAnalysis(lightweight, result: Self.analysis(at: nightStart))

        XCTAssertEqual(written?.windowUserAdjusted, true)
        XCTAssertEqual(try archive.retrieve(night.id)?.rrSeries?.points.count, 900)
    }

    /// When the archived copy cannot be read (its index hash no longer matches
    /// the file), hydration fails and the pick goes to the copy it was handed,
    /// which has no beats. Whatever the write then does, the stored beats are
    /// still on disk: the archive splices them back, or refuses the write.
    func testAManualWindowWhoseArchivedCopyCannotBeReadKeepsTheStoredBeats() async throws {
        var night = overnight()
        night.rrSeries = RRSeries(points: Self.beats(count: 900), sessionId: night.id, startDate: nightStart)
        let entry = try archive.archive(night)
        try Self.forgeIndexHash(of: entry, in: archiveDirectory)
        let unreadable = makeArchive()
        XCTAssertThrowsError(try unreadable.retrieve(night.id), "the forged hash makes the archived copy unreadable")
        var lightweight = night
        lightweight.rrSeries = nil

        _ = await makeService(on: unreadable).applyManualAnalysis(lightweight, result: Self.analysis(at: nightStart))

        guard case .preserved(let stored, _) = makeArchive().store.storedRRSeries(for: night.id) else {
            return XCTFail("the stored beats were lost")
        }
        XCTAssertEqual(stored.points.count, 900)
    }

    /// Replace `entry`'s hash in the index file on disk with one that matches
    /// no file, as an interrupted write leaves it.
    private static func forgeIndexHash(of entry: SessionArchiveEntry, in directory: URL) throws {
        let indexURL = directory.appendingPathComponent("index.json")
        let index = try SessionArchive.indexJSON(Data(contentsOf: indexURL))
        let text = try XCTUnwrap(String(data: index, encoding: .utf8))
        let forged = text.replacingOccurrences(of: entry.fileHash, with: String(repeating: "0", count: 64))
        try Data(forged.utf8).write(to: indexURL, options: .atomic)
    }

    /// Every stored field of the session is either computed by a rescore or
    /// kept from the archived copy. A field added to `HRVSession` fails here
    /// until it is classified, so a rescore cannot silently write it back.
    func testEveryStoredSessionFieldIsClassifiedForARescoreWrite() {
        let fields = Set(Mirror(reflecting: overnight()).children.compactMap(\.label))
        let computed = RescoreWrite.computedFields
        let stored = RescoreWrite.storedFields
        XCTAssertTrue(computed.isDisjoint(with: stored), "a field is either computed or kept, not both")
        XCTAssertEqual(computed.union(stored), fields)
    }

    /// Beats with a little variation, a second apart in a 1 s rhythm.
    private static func beats(count: Int) -> [RRPoint] {
        var tMs: Int64 = 0
        return (0 ..< count).map { i in
            let rr = 1000 + [20, -5, -20, 5][i % 4]
            tMs += Int64(rr)
            return RRPoint(t_ms: tMs, rr_ms: rr)
        }
    }

    /// An analysis carrying its own training context, so scoring it never
    /// asks HealthKit for the load.
    private static func analysis(at date: Date) -> HRVAnalysisResult {
        var result = HRVAnalysisResult(
            windowStart: 0, windowEnd: 400,
            timeDomain: TimeDomainMetrics(
                meanRR: 1000, sdnn: 30, rmssd: 35, pnn50: 12, sdsd: 30, meanHR: 60, sdHR: 3, triangularIndex: nil
            ),
            frequencyDomain: nil,
            nonlinear: NonlinearMetrics(
                sd1: 25, sd2: 40, sd1Sd2Ratio: 0.6, sampleEntropy: 1.5, approxEntropy: 1.3,
                dfaAlpha1: 0.85, dfaAlpha2: nil, dfaAlpha1R2: 0.95
            ),
            ansMetrics: nil, artifactPercentage: 1, cleanBeatCount: 400, analysisDate: date
        )
        result.trainingContext = TrainingContext(
            atl: 0, ctl: 0, tsb: 0, yesterdayTrimp: 0, vo2Max: nil, daysSinceHardWorkout: nil, recentWorkouts: nil
        )
        return result
    }

    /// The user's sleep edit, saved while the reanalysis runs.
    private static func editSleep(of id: UUID, in archive: SessionArchive, nightStart: Date) {
        do {
            try archive.update(id, requestingReupload: false) {
                $0.sleepSnapshot = SleepData(
                    date: nightStart, inBedStart: nightStart,
                    sleepStart: nightStart.addingTimeInterval(600),
                    sleepEnd: nightStart.addingTimeInterval(600 + 450 * 60),
                    totalSleepMinutes: 420, inBedMinutes: 450,
                    deepSleepMinutes: 60, remSleepMinutes: 90, awakeMinutes: 30, sleepEfficiency: 93,
                    boundarySource: .healthKit, segments: [], stageIntervals: [],
                    boundaryValidation: nil, hrSleepQuality: nil
                )
                $0.sleepUserAdjusted = true
            }
        } catch {
            XCTFail("the sleep edit was not saved: \(error)")
        }
    }

    /// The user's manual window pick, with the score it gives, saved while
    /// the reanalysis runs.
    private static func pickWindow(of id: UUID, in archive: SessionArchive) {
        do {
            try archive.update(id, requestingReupload: false) {
                $0.windowUserAdjusted = true
                $0.recoveryScore = 8.8
            }
        } catch {
            XCTFail("the window pick was not saved: \(error)")
        }
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
