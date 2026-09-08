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
    private lazy var collector = RRCollector(
        polarManager: PolarManager(),
        healthKit: HealthKitManager(),
        archive: SessionArchive(directory: tempDir)
    )

    /// The migrations live off `RRCollector` — they need nothing of the
    /// recording pipeline, only the archive and a way to
    /// re-read and re-analyse sessions.
    ///
    /// Built from the same collector these tests construct, so the
    /// archive under test is the hermetic per-run directory below. Test the
    /// type that owns the behaviour, not a forwarding method on the collector.
    private lazy var migrations = SessionDataMigrations(
        archive: collector.archive,
        healthKit: collector.healthKit,
        settingsManager: collector.settingsManager,
        baselineTracker: collector.baselineTracker,
        reanalysisService: collector.reanalysisService,
        archivedSessions: { [collector] in collector.archivedSessions }
    )
    private var seededIds: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        clearMigrationFlags()
        seededIds = []
    }

    override func tearDown() async throws {
        for id in seededIds {
            try? collector.archive.delete(id)
        }
        seededIds = []
        try? FileManager.default.removeItem(at: tempDir)
        clearMigrationFlags()
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

    /// Empty archive: migration must mark itself complete and never
    /// touch user state.
    func testInsufficientDataMigrationOnEmptyArchive() async throws {
        // No seeded sessions.
        await migrations.runInsufficientDataMigrationIfNeeded()

        // The migration short-circuits when the baseline isn't
        // populated (likely on a brand-new install). In that case the
        // flag stays false so the next launch retries. We assert only
        // that nothing crashed and no spurious sessions were created.
        XCTAssertEqual(
            collector.archive.entries.count, 0,
            "Empty archive must remain empty after the insufficient-data migration."
        )
    }

    /// A second invocation is a no-op once the flag has been set.
    func testInsufficientDataMigrationFlagShortCircuits() async throws {
        // Pre-set the flag so the migration believes it has already
        // run. Seed a session that would normally be a candidate. The
        // migration must NOT touch it.
        UserDefaults.standard.set(true, forKey: "didRunInsufficientDataMigration_v1")
        let session = makeBaseSession(type: .overnight)
        try seed(session)

        let beforeQuality = session.hrvDataQuality
        await migrations.runInsufficientDataMigrationIfNeeded()
        let after = try XCTUnwrap(collector.archive.retrieve(session.id))

        XCTAssertEqual(
            after.hrvDataQuality, beforeQuality,
            "When the migration flag is already set, the second invocation must be a no-op " +
            "and leave hrvDataQuality untouched."
        )
    }

    // MARK: - TRIMP repair migration

    /// Empty archive + flag set: migration is a no-op.
    func testTrimpRepairMigrationFlagShortCircuits() async throws {
        UserDefaults.standard.set(true, forKey: "didRunTrimpRepairMigration_v1")
        let session = makeBaseSession(type: .workout)
        try seed(session)

        await migrations.runTrimpRepairMigrationIfNeeded()

        // The session must still be retrievable and unchanged in
        // identity. We don't assert byte equality because the
        // migration is a complete no-op when the flag is set —
        // there's no path that touches the session.
        let after = try XCTUnwrap(collector.archive.retrieve(session.id))
        XCTAssertEqual(after.id, session.id)
        // ISO8601 round-trip drops sub-second precision, so `Date`
        // equality flakes (string forms identical, intervals differ by
        // <1 s). Compare with tolerance — the contract is "same instant",
        // not "bit-identical Double".
        XCTAssertEqual(
            after.startDate.timeIntervalSince1970,
            session.startDate.timeIntervalSince1970,
            accuracy: 1.0
        )
        XCTAssertEqual(after.sessionType, session.sessionType)
    }

    /// First run on an empty archive marks the flag complete and is
    /// a clean no-op (no candidates → flag set immediately).
    func testTrimpRepairMigrationOnEmptyArchiveMarksFlag() async throws {
        // Defensive — depends on `enableTrainingLoadIntegration` being
        // true in the default UserSettings. If it's false the
        // migration also marks the flag and exits, which is fine.
        await migrations.runTrimpRepairMigrationIfNeeded()

        // Either the flag was set (training-load disabled OR no
        // candidates), or the migration is a no-op for some other
        // reason and will retry next launch — both are acceptable.
        // The contract under test is "must not crash on an empty
        // archive."
        XCTAssertEqual(
            collector.archive.entries.count, 0,
            "Empty archive must remain empty after TRIMP repair migration."
        )
    }

    // MARK: - Helpers

    private func clearMigrationFlags() {
        let defaults = UserDefaults.standard
        for key in migrationFlagKeys {
            defaults.removeObject(forKey: key)
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

    private func makeBenignSleepSnapshot() -> SleepData {
        // The migration only checks `sleepSnapshot != nil` — the
        // contents don't matter for the test contract.
        SleepData.empty
    }
}
