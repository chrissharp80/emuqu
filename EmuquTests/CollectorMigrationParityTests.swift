@testable import Emuqu
import XCTest

/// Parity tests for the three RRCollector
/// one-shot migrations.
///
/// `ArchiveMigrationParityTests.swift` already covers the `Archive`-level
/// migrations. The three migrations covered here run on `RRCollector`:
///
///   1. `runWorkoutSleepCleanupIfNeeded()` — strips `sleepSnapshot`
///      from workout-typed sessions where the dashboard's old
///      morning-reading selector erroneously attached one. Pre-fix,
///      this contaminated workout summaries with overnight sleep
///      data. Idempotent via `didRunWorkoutSleepCleanup_v1` flag.
///
///   2. `runInsufficientDataMigrationIfNeeded()` — re-flags sessions
///      archived before the insufficient-data acceptance gate
///      existed. Idempotent via `didRunInsufficientDataMigration_v1`.
///
///   3. `runTrimpRepairMigrationIfNeeded()` — recomputes training
///      context for sessions whose TRIMP was computed with the old
///      broken denominator. Idempotent via
///      `didRunTrimpRepairMigration_v1`.
///
/// Each test (a) seeds an archive with a representative pre-state
/// session, (b) runs the migration once, (c) asserts the post-state
/// is sensible, (d) runs the migration a second time and asserts it
/// is a no-op (the UserDefaults flag should short-circuit it).
///
/// What these tests do NOT do: they do not load real production
/// fixtures from disk and compare byte-for-byte against goldens.
/// These
/// tests are a regression net against the most common failure mode
/// (re-running a migration corrupting state on second launch).
@MainActor
final class CollectorMigrationParityTests: XCTestCase {
    private let migrationFlagKeys = [
        "didRunWorkoutSleepCleanup_v1",
        "didRunInsufficientDataMigration_v1",
        "didRunTrimpRepairMigration_v1"
    ]
    // `lazy` rather than assigned in `setUp`: `clearMigrationFlags()` must run
    // before the collector exists, and deferring construction to first use in
    // the test body keeps that order.
    //
    // Isolated on-disk archive. `RRCollector()` binds to
    // `SessionArchive.shared`, whose directory persists in the simulator
    // container across runs — the "empty archive must remain empty" tests were
    // reading 10 residue entries left by OTHER suites' killed runs. All three
    // migrations under test operate on the collector's injected `archive`, so a
    // hermetic per-run directory makes the empty-archive contracts testable.
    private lazy var tempDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("CollectorMigrationParityTests-\(UUID().uuidString)", isDirectory: true)
    //
    // The raw backups and the baseline are this test's too: the default
    // `BaselineTracker()` is the host's `HRVBaseline.json`, and whether the
    // insufficient-data migration runs at all depends on that baseline.
    private lazy var collector = RRCollector(
        polarManager: PolarManager(),
        healthKit: HealthKitManager(),
        archive: SessionArchive(directory: tempDir),
        rawBackup: RawRRBackup(directory: tempDir.appendingPathComponent(AppConfig.backupDirectoryName, isDirectory: true)),
        baselineTracker: BaselineTracker(baselineFile: baselineFile)
    )
    private lazy var baselineFile = tempDir.appendingPathComponent("HRVBaseline.json")
    /// What the TRIMP repair reads from HealthKit: a known training load, so
    /// a repair that ran shows in the session's snapshot.
    private lazy var healthKit: MockHealthKitService = {
        let mock = MockHealthKitService()
        mock.trainingLoadMetrics = TrainingMetrics(
            atl: 30, ctl: 40, tsb: 10, dailyTrimp: [:], todayTrimp: 0, todayWorkouts: [], recentWorkouts: []
        )
        return mock
    }()

    /// The migrations live off `RRCollector` — they need nothing of the
    /// recording pipeline, only the archive and a way to
    /// re-read and re-analyse sessions.
    ///
    /// Built from the same collector these tests construct, so the
    /// archive under test is the hermetic per-run directory below. Test the
    /// type that owns the behaviour, not a forwarding method on the collector.
    ///
    /// The settings are a fresh-install profile in this test's folder, and
    /// the reanalysis reads HealthKit from `healthKit` and scores against
    /// the collector's baseline.
    private lazy var migrations = SessionDataMigrations(
        archive: collector.archive,
        healthKit: collector.healthKit,
        settingsManager: SettingsManager(settingsURL: tempDir.appendingPathComponent("user_settings.json")),
        baselineTracker: collector.baselineTracker,
        reanalysisService: makeReanalysisService()
    )

    private func makeReanalysisService() -> ReanalysisService {
        let windowSelector = WindowSelector()
        let artifactDetector = ArtifactDetector()
        let settings = UserSettings()
        return ReanalysisService(
            archive: collector.archive, healthKit: healthKit,
            analysisPipeline: HRVAnalysisPipeline(
                artifactDetector: artifactDetector, windowSelector: windowSelector, healthKit: healthKit
            ),
            windowSelector: windowSelector, artifactDetector: artifactDetector,
            baselineTracker: collector.baselineTracker,
            settingsProvider: { settings },
            scoringConfigProvider: { .init(from: settings) },
            ansConfigProvider: { _ in
                HRVAnalysisPipeline.ANSConfiguration(baselineRMSSD: 60, vo2Max: nil, trainingLoadAdjustment: 0)
            },
            trainingContextProvider: { _ in nil },
            analyzeWithWindow: { _, _, _, _ in nil },
            analyzeFullSession: { _, _ in nil },
            onArchiveChanged: {},
            onSessionUploaded: { _ in },
            onZonesStale: { _ in }
        )
    }
    private var seededIds: [UUID] = []
    /// The host app's own values of the flags, put back after each test. The
    /// flags live in the host's standard defaults, so clearing them for good
    /// would make the host re-run all three migrations against the user's
    /// real archive on its next launch.
    private var savedMigrationFlags: [String: Bool] = [:]

    override func setUp() async throws {
        try await super.setUp()
        clearMigrationFlags()
        seededIds = []
    }

    override func tearDown() async throws {
        for id in seededIds {
            _ = try? collector.archive.delete(id)
        }
        seededIds = []
        try? FileManager.default.removeItem(at: tempDir)
        restoreMigrationFlags()
        try await super.tearDown()
    }

    // MARK: - Workout sleep cleanup

    /// Workout-typed sessions must lose their `sleepSnapshot` after the
    /// migration runs. Non-workout sessions are untouched. Second run
    /// is a no-op.
    func testWorkoutSleepCleanupStripsContaminatedFieldOnceOnly() async throws {
        // Arrange — a workout session with a (contaminating) sleepSnapshot
        // and a separate overnight session whose sleepSnapshot is legit.
        var workout = makeBaseSession(type: .workout)
        workout.sleepSnapshot = makeBenignSleepSnapshot()
        var overnight = makeBaseSession(type: .overnight)
        overnight.sleepSnapshot = makeBenignSleepSnapshot()

        try seed(workout)
        try seed(overnight)

        // Act — first run.
        await migrations.runWorkoutSleepCleanupIfNeeded()

        // Assert — workout snapshot stripped, overnight preserved.
        let workoutAfter = try XCTUnwrap(collector.archive.retrieve(workout.id))
        XCTAssertNil(
            workoutAfter.sleepSnapshot,
            "Workout sessions must have their sleepSnapshot cleared by the cleanup migration."
        )
        let overnightAfter = try XCTUnwrap(collector.archive.retrieve(overnight.id))
        XCTAssertNotNil(
            overnightAfter.sleepSnapshot,
            "Overnight sessions must retain their sleepSnapshot — the migration only targets workouts."
        )
        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: "didRunWorkoutSleepCleanup_v1"),
            "Migration must set its idempotency flag on completion."
        )

        // Act 2 — second run is a no-op (the flag short-circuits).
        // Re-attach a snapshot on the workout to prove the migration
        // doesn't run again. If it did, this snapshot would be cleared.
        var rearmed = try XCTUnwrap(collector.archive.retrieve(workout.id))
        rearmed.sleepSnapshot = makeBenignSleepSnapshot()
        try collector.archive.archive(rearmed)

        await migrations.runWorkoutSleepCleanupIfNeeded()

        let workoutFinal = try XCTUnwrap(collector.archive.retrieve(workout.id))
        XCTAssertNotNil(
            workoutFinal.sleepSnapshot,
            "Second migration run must be a no-op — the UserDefaults flag gates it. " +
            "If this fails, the flag check at the top of runWorkoutSleepCleanupIfNeeded regressed."
        )
    }

    // MARK: - Insufficient-data migration

    /// Empty archive with a baseline: no candidates, so the migration marks
    /// itself complete and creates nothing.
    func testInsufficientDataMigrationOnEmptyArchive() async throws {
        try seedBaseline()
        await migrations.runInsufficientDataMigrationIfNeeded()

        XCTAssertEqual(
            collector.archive.store.entries.count, 0,
            "Empty archive must remain empty after the insufficient-data migration."
        )
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "didRunInsufficientDataMigration_v1"),
                      "No candidates marks the migration complete")
    }

    /// The positive control for the test below: with the flag clear, a
    /// night analysed over a two-minute window with RMSSD under its baseline
    /// is re-flagged insufficient, and the flag is set.
    func testInsufficientDataMigrationReflagsATooShortWindowBelowBaseline() async throws {
        try seedBaseline()
        let session = insufficientDataCandidate()
        try seed(session)

        await migrations.runInsufficientDataMigrationIfNeeded()

        XCTAssertEqual(try XCTUnwrap(collector.archive.retrieve(session.id)).hrvDataQuality, .insufficient)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "didRunInsufficientDataMigration_v1"))
    }

    /// With the flag already set, the same candidate is left alone. The
    /// baseline is there, so only the flag can stop the migration.
    func testInsufficientDataMigrationFlagShortCircuits() async throws {
        try seedBaseline()
        UserDefaults.standard.set(true, forKey: "didRunInsufficientDataMigration_v1")
        let session = insufficientDataCandidate()
        try seed(session)

        await migrations.runInsufficientDataMigrationIfNeeded()

        XCTAssertEqual(
            try XCTUnwrap(collector.archive.retrieve(session.id)).hrvDataQuality, .good,
            "When the migration flag is already set, the second invocation must be a no-op " +
            "and leave hrvDataQuality untouched."
        )
    }

    // MARK: - TRIMP repair migration

    /// The positive control for the test below: with the flag clear, the
    /// repair rewrites the session's training snapshot from HealthKit's load
    /// (ATL 30, CTL 40) and sets the flag.
    func testTrimpRepairMigrationRewritesTheTrainingSnapshot() async throws {
        let session = trainedSession()
        try seed(session)

        await migrations.runTrimpRepairMigrationIfNeeded()

        let after = try XCTUnwrap(collector.archive.retrieve(session.id))
        XCTAssertEqual(after.trainingSnapshot?.atl, 30)
        XCTAssertEqual(after.trainingSnapshot?.ctl, 40)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "didRunTrimpRepairMigration_v1"))
    }

    /// With the flag set, the snapshot the session was archived with stays.
    func testTrimpRepairMigrationFlagShortCircuits() async throws {
        UserDefaults.standard.set(true, forKey: "didRunTrimpRepairMigration_v1")
        let session = trainedSession()
        try seed(session)

        await migrations.runTrimpRepairMigrationIfNeeded()

        let after = try XCTUnwrap(collector.archive.retrieve(session.id))
        XCTAssertEqual(after.trainingSnapshot?.atl, 1, "The repair ran although its flag was set")
        XCTAssertEqual(after.trainingSnapshot?.ctl, 1)
    }

    /// First run on an empty archive has no candidates and marks the flag.
    func testTrimpRepairMigrationOnEmptyArchiveMarksFlag() async throws {
        await migrations.runTrimpRepairMigrationIfNeeded()

        XCTAssertEqual(
            collector.archive.store.entries.count, 0,
            "Empty archive must remain empty after TRIMP repair migration."
        )
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "didRunTrimpRepairMigration_v1"),
                      "The repair over an empty archive must mark itself complete")
    }

    // MARK: - Helpers

    /// Saves the host's values of the flags, then clears them.
    private func clearMigrationFlags() {
        let defaults = UserDefaults.standard
        savedMigrationFlags = [:]
        for key in migrationFlagKeys {
            if let value = defaults.object(forKey: key) as? Bool { savedMigrationFlags[key] = value }
            defaults.removeObject(forKey: key)
        }
    }

    /// Puts back the values `clearMigrationFlags` saved; a flag the host did
    /// not have is removed again.
    private func restoreMigrationFlags() {
        let defaults = UserDefaults.standard
        for key in migrationFlagKeys {
            if let value = savedMigrationFlags[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func seed(_ session: HRVSession) throws {
        try collector.archive.archive(session)
        seededIds.append(session.id)
    }

    private func makeBaseSession(type: SessionType) -> HRVSession {
        let now = Date()
        let start = Calendar.current.date(byAdding: .hour, value: -8, to: now) ?? now
        var session = HRVSession(startDate: start, sessionType: type)
        session.endDate = now
        session.state = .complete
        return session
    }

    /// Five earlier nights at RMSSD 60 ms in the collector's baseline file,
    /// written before the collector (and its tracker) is first built.
    private func seedBaseline() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let nights = (1 ... 5).map { day in
            #"{"date":"2026-01-0\#(day)T23:00:00Z","rmssd":60,"sdnn":70,"meanHR":55}"#
        }
        try Data(#"{"historicalData":[\#(nights.joined(separator: ","))]}"#.utf8).write(to: baselineFile)
        XCTAssertNotNil(collector.baselineTracker.recoveryBaselineStats, "Sanity: the seeded baseline loaded")
    }

    /// A scored, good-quality night analysed over a two-minute window (the
    /// gate needs five) with RMSSD 30 ms: under a 60 ms baseline, so the
    /// insufficient-data gate holds.
    private func insufficientDataCandidate() -> HRVSession {
        var session = makeBaseSession(type: .overnight)
        session.analysisResult = analysisResult(rmssd: 30, windowMs: 120_000, at: session.endDate ?? Date())
        session.recoveryScore = 7
        session.hrvDataQuality = .good
        return session
    }

    /// An analysed night archived with a training snapshot of ATL 1, CTL 1.
    private func trainedSession() -> HRVSession {
        var session = makeBaseSession(type: .overnight)
        session.analysisResult = analysisResult(rmssd: 50, windowMs: 600_000, at: session.endDate ?? Date())
        session.trainingSnapshot = TrainingContext(
            atl: 1, ctl: 1, tsb: 0, yesterdayTrimp: 0, vo2Max: nil, daysSinceHardWorkout: nil, recentWorkouts: nil
        )
        return session
    }

    private func analysisResult(rmssd: Double, windowMs: Int64, at date: Date) -> HRVAnalysisResult {
        var result = HRVAnalysisResult(
            windowStart: 0,
            windowEnd: 150,
            timeDomain: TimeDomainMetrics(
                meanRR: 1000, sdnn: 40, rmssd: rmssd, pnn50: 5, sdsd: rmssd, meanHR: 60, sdHR: 4, triangularIndex: nil
            ),
            frequencyDomain: nil,
            nonlinear: NonlinearMetrics(
                sd1: 20, sd2: 50, sd1Sd2Ratio: 0.4, sampleEntropy: 1.5, approxEntropy: 1.3,
                dfaAlpha1: 0.9, dfaAlpha2: nil, dfaAlpha1R2: 0.95
            ),
            ansMetrics: nil,
            artifactPercentage: 1.0,
            cleanBeatCount: 150,
            analysisDate: date
        )
        result.windowStartMs = 0
        result.windowEndMs = windowMs
        return result
    }

    private func makeBenignSleepSnapshot() -> SleepData {
        // The migration only checks `sleepSnapshot != nil` — the
        // contents don't matter for the test contract.
        SleepData.empty
    }
}
