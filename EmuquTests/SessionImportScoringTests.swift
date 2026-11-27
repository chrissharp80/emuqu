@testable import Emuqu
import XCTest

/// Saving imported RR recordings (`SessionImport`): every night is scored on
/// save against the nights before it, and a batch that fails partway still
/// hands what it wrote to the baseline.
@MainActor
final class SessionImportScoringTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SessionImportScoring-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: directory.appendingPathComponent("Archive", isDirectory: true))
    private lazy var settings = SettingsManager(settingsURL: directory.appendingPathComponent("user_settings.json"))
    private lazy var tracker = BaselineTracker(baselineFile: directory.appendingPathComponent("HRVBaseline.json"))
    private lazy var sessionImport = SessionImport(
        archive: archive, archiveSignal: ArchiveSignal(), baselineTracker: tracker,
        cloudSyncManager: CloudKitSyncManager.isolated(
            archive: archive, directory: directory.appendingPathComponent("Sync", isDirectory: true), settings: settings
        ),
        sessionState: SessionState(), settingsManager: settings
    )

    override func setUp() async throws {
        try await super.setUp()
        try requireEncryptionKey()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try await super.tearDown()
    }

    /// A night recorded at 23:00 `daysAgo` days ago, with beats, analysed
    /// whole as an import is, and unscored as the import screens leave it.
    private func importedNight(daysAgo: Int, rmssd: Double) -> HRVSession {
        let midnight = Calendar.current.startOfDay(for: Date())
        let start = midnight.addingTimeInterval(Double(-daysAgo) * 86_400 + 23 * 3_600)
        let id = UUID()
        let timeDomain = TimeDomainMetrics(
            meanRR: 1_000, sdnn: 55, rmssd: rmssd, pnn50: 20, sdsd: rmssd * 0.9, meanHR: 60, sdHR: 5, triangularIndex: nil
        )
        let nonlinear = NonlinearMetrics(
            sd1: 30, sd2: 60, sd1Sd2Ratio: 0.5, sampleEntropy: 1.5, approxEntropy: 1.3, dfaAlpha1: 0.9, dfaAlpha2: nil, dfaAlpha1R2: 0.95
        )
        let result = HRVAnalysisResult(
            windowStart: 0, windowEnd: 500, timeDomain: timeDomain, frequencyDomain: nil, nonlinear: nonlinear,
            ansMetrics: nil, artifactPercentage: 2, cleanBeatCount: 500, analysisDate: start
        )
        return HRVSession(
            id: id, startDate: start, endDate: start.addingTimeInterval(8 * 3_600), state: .complete,
            sessionType: .overnight, rrSeries: RRSeries(points: createRealisticPoints(count: 600, meanRR: 1_000), sessionId: id, startDate: start),
            analysisResult: result, artifactFlags: nil, recoveryScore: nil, tags: [], notes: nil,
            importedMetrics: nil, deviceProvenance: nil, sleepStartMs: nil, sleepEndMs: nil
        )
    }

    /// Three stored nights the scores are measured against.
    private func storedNights() -> [HRVSession] {
        [(10, 50.0), (9, 52.0), (8, 48.0)].map { importedNight(daysAgo: $0.0, rmssd: $0.1) }
    }

    /// The expected score of each of `nights`, oldest first, from a tracker
    /// of its own fed the stored nights and then each scored night in turn.
    private func expectedScores(of nights: [HRVSession], after stored: [HRVSession]) -> [Double?] {
        let reference = BaselineTracker(baselineFile: directory.appendingPathComponent("Reference-\(UUID().uuidString).json"))
        let schedule = settings.settings.sleepSchedule
        reference.rebuildFromSessions(stored, sleepSchedule: schedule)
        return nights.map { night in
            let context = RescoreContext(
                baselineStats: reference.recoveryBaselineStats(excludingNightOf: night, sleepSchedule: schedule),
                typicalSleepHours: settings.settings.typicalSleepHours,
                scoringConfig: RecoveryScoreCalculator.ScoringConfiguration(from: settings.settings)
            )
            let scored = SessionImport.scored(night, context: context)
            reference.update(with: scored, sleepSchedule: schedule)
            return scored.recoveryScore
        }
    }

    /// A batch of three overnights stores three scores, each against the
    /// stored nights and the batch's earlier nights: the last one's baseline
    /// holds five nights, not the three stored before the import.
    func testABatchImportScoresEachNightAgainstTheNightsBeforeIt() async throws {
        let stored = storedNights()
        tracker.rebuildFromSessions(stored, sleepSchedule: settings.settings.sleepSchedule)
        let nights = [importedNight(daysAgo: 1, rmssd: 38), importedNight(daysAgo: 3, rmssd: 30), importedNight(daysAgo: 2, rmssd: 35)]

        let saved = try await sessionImport.saveBatch(nights)

        XCTAssertEqual(saved, 3)
        let oldestFirst = nights.sorted { $0.startDate < $1.startDate }
        let scores = try oldestFirst.map { try XCTUnwrap(archive.retrieve($0.id)).recoveryScore }
        XCTAssertTrue(scores.allSatisfy { $0 != nil }, "every imported night is scored")
        let expected = expectedScores(of: oldestFirst, after: stored)
        for (score, want) in zip(scores, expected) {
            XCTAssertEqual(try XCTUnwrap(score), try XCTUnwrap(want), accuracy: 1e-9)
        }
        let last = try XCTUnwrap(archive.retrieve(oldestFirst[2].id))
        XCTAssertEqual(last.scoreBreakdown?.scoringVersion, ScoringVersion.current)
        let storedOnly = expectedScores(of: [oldestFirst[2]], after: stored)[0]
        XCTAssertNotEqual(last.recoveryScore, storedOnly, "the earlier imported nights are in its baseline")
    }

    /// A single import is scored when it is saved.
    func testASingleImportIsScored() async throws {
        let stored = storedNights()
        tracker.rebuildFromSessions(stored, sleepSchedule: settings.settings.sleepSchedule)
        let night = importedNight(daysAgo: 1, rmssd: 40)

        try await sessionImport.save(night)

        let score = try XCTUnwrap(archive.retrieve(night.id)?.recoveryScore)
        XCTAssertEqual(score, try XCTUnwrap(expectedScores(of: [night], after: stored)[0]), accuracy: 1e-9)
    }

    /// A batch that fails partway (here: a later night merges into a stored
    /// night whose file is gone) still puts the night it wrote into the
    /// baseline, and the error still reaches the caller.
    func testABatchThatFailsPartwayStillFeedsTheBaselineWhatItWrote() async throws {
        let broken = importedNight(daysAgo: 5, rmssd: 50)
        _ = try archive.archive(broken)
        try FileManager.default.removeItem(at: archive.archiveDirectory.appendingPathComponent("\(broken.id.uuidString).json"))
        let written = importedNight(daysAgo: 6, rmssd: 50)
        let copy = importedNight(daysAgo: 5, rmssd: 52)

        do {
            _ = try await sessionImport.saveBatch([copy, written])
            XCTFail("the failed merge must be reported")
        } catch {}

        XCTAssertTrue(archive.store.exists(written.id), "the earlier night was written")
        XCTAssertTrue(tracker.holdsReading(of: written.id), "and reached the baseline")
    }
}
