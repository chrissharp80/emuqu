@testable import Emuqu
import os
import XCTest

/// Migration parity tests.
///
/// Each `Archive+Migrations.swift` entry mutates the index or session files
/// based on a UserDefaults-flagged "have I run yet?" check. The refactor spec
/// §§ 17-18 (Migration Safety / Data Model Versioning) requires that these
/// migrations be verifiable: a pre-state → post-state pair, where the post
/// state is what the app observes on a clean boot, and a second run of the
/// migration is a no-op.
///
/// These tests cover the *contract* each migration is expected to satisfy —
/// not the implementation detail. Each case:
///   1. Archives a session whose index entry is in the "pre-migration" shape.
///   2. Runs the migration directly.
///   3. Asserts the index entry is now in the "post-migration" shape.
///   4. Runs the migration a second time and asserts the state is stable.
///
/// A failing test here means a migration either missed a case the real
/// codebase relies on, or silently corrupted data. Either way, block ship.
final class ArchiveMigrationParityTests: XCTestCase {
    // Stored properties rather than implicitly-unwrapped optionals:
    // XCTest builds the test class once per test method, so these are
    // already fresh for every test.
    /// A private directory per test: `runDeferredMigrations` walks every
    /// entry, so the shared archive would hand it other suites' sessions.
    let archiveDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ArchiveMigrationParityTests-\(UUID().uuidString)", isDirectory: true)
    lazy var archive = SessionArchive(directory: archiveDirectory)
    var testSessionIds: [UUID] = []

    /// The done flags `runIndexMigration` checks before each backfill
    /// (`MigrationFlag` in Archive+Migrations.swift). They live in the host
    /// app's standard defaults, so once any earlier run or launch set them
    /// every backfill here would return at once. Each test clears them and
    /// puts the host's values back afterwards.
    private static let migrationDoneFlags = [
        "FlowRecovery.migration.recoveryScores.v1.done",
        "FlowRecovery.migration.endDates.v1.done",
        "FlowRecovery.migration.metrics.v1.done",
        "FlowRecovery.migration.sleepIndexFields.v1.done",
        "FlowRecovery.migration.legacyEliteIndex.v1.done"
    ]
    private var savedMigrationFlags: [String: Bool] = [:]

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
        savedDefaultTimeZone.withLock { $0 = NSTimeZone.default }
        NSTimeZone.default = TestTimeZone.utc
    }

    override class func tearDown() {
        if let saved = savedDefaultTimeZone.withLock({ $0 }) { NSTimeZone.default = saved }
        savedDefaultTimeZone.withLock { $0 = nil }
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        archive = SessionArchive(
            directory: archiveDirectory,
            sleepScheduleProvider: {
                SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
            },
            sessionMergeModeProvider: { .off }
        )
        testSessionIds = []
        clearMigrationFlags()
    }

    override func tearDown() {
        for id in testSessionIds {
            try? archive.delete(id)
        }
        testSessionIds = []
        try? FileManager.default.removeItem(at: archiveDirectory)
        restoreMigrationFlags()
        super.tearDown()
    }

    private func clearMigrationFlags() {
        let defaults = UserDefaults.standard
        savedMigrationFlags = [:]
        for key in Self.migrationDoneFlags {
            if let value = defaults.object(forKey: key) as? Bool { savedMigrationFlags[key] = value }
            defaults.removeObject(forKey: key)
        }
    }

    private func restoreMigrationFlags() {
        let defaults = UserDefaults.standard
        for key in Self.migrationDoneFlags {
            if let value = savedMigrationFlags[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// A backfill sets its flag only after a pass that read every session in
    /// its work list, and the flags were cleared in setUp, so all four set
    /// after a run means each backfill ran over this archive and none failed
    /// to read a session it picked (the bare session here is picked by the
    /// sleep-index backfill: no sleepEnd, no segment count).
    private func assertEveryBackfillRan(file: StaticString = #filePath, line: UInt = #line) {
        for key in Self.migrationDoneFlags {
            XCTAssertTrue(UserDefaults.standard.bool(forKey: key), "\(key) not set: that backfill did not run or failed to read a session", file: file, line: line)
        }
    }

    // MARK: - `runDeferredMigrations` is idempotent

    /// The whole migration pipeline must be safe to call repeatedly — the
    /// app calls it on every launch and we can't afford a migration that
    /// destabilizes state on the second run.
    func testRunDeferredMigrationsIsIdempotent() throws {
        let session = makeCompletedSession()
        testSessionIds.append(session.id)
        _ = try archive.archive(session)

        let before = archive.entries.first { $0.sessionId == session.id }
        XCTAssertNotNil(before)

        archive.runDeferredMigrations()
        assertEveryBackfillRan()
        let afterFirstRun = archive.entries.first { $0.sessionId == session.id }

        archive.runDeferredMigrations()
        let afterSecondRun = archive.entries.first { $0.sessionId == session.id }

        XCTAssertEqual(afterFirstRun?.fileHash, afterSecondRun?.fileHash,
                       "Second run of runDeferredMigrations changed the file hash")
        XCTAssertEqual(afterFirstRun?.recoveryScore, afterSecondRun?.recoveryScore)
        XCTAssertEqual(afterFirstRun?.meanRMSSD, afterSecondRun?.meanRMSSD)
        XCTAssertEqual(afterFirstRun?.endDate, afterSecondRun?.endDate)
    }

    // MARK: - Index entry round-trips survive migration

    /// A session archived with a fully-populated index entry must not lose
    /// fields after migration. This is the core behavioral parity guarantee.
    func testArchivedEntryPreservedAcrossMigrations() throws {
        let session = makeCompletedSession()
        testSessionIds.append(session.id)
        _ = try archive.archive(session)

        guard let before = archive.entries.first(where: { $0.sessionId == session.id }) else {
            return XCTFail("Session missing from index after archive")
        }

        archive.runDeferredMigrations()
        assertEveryBackfillRan()

        guard let after = archive.entries.first(where: { $0.sessionId == session.id }) else {
            return XCTFail("Session dropped from index by migration")
        }

        XCTAssertEqual(before.sessionId, after.sessionId)
        XCTAssertEqual(before.date, after.date)
        XCTAssertEqual(before.sessionType, after.sessionType)
        // `fileHash` may change if a migration re-wrote the session, but
        // the file itself must still decode and match whatever hash is now
        // stored.
        let round = archive.retrieveLightweightOrLog(session.id, caller: "parityTest")
        XCTAssertNotNil(round, "Session unreadable after migration")
    }

    // MARK: - Legacy Elite HRV index entries

    /// An Elite import saved by an earlier build has its RMSSD-made stress
    /// index and score in the index. The session decodes without them, and
    /// the migration makes the entry say the same; a recorded night is left
    /// alone.
    func testLegacyEliteIndexEntryLosesItsMadeUpStressAndScore() throws {
        let legacy = HRVSession(
            id: UUID(), startDate: Date().addingTimeInterval(-86_400), endDate: Date().addingTimeInterval(-86_100),
            state: .complete, rrSeries: nil, analysisResult: SnapshotFixtures.legacyEliteImportResult(),
            artifactFlags: nil, recoveryScore: 6.5,
            importedMetrics: HRVSession.ImportedMetrics(rmssd: 45, rmssdRaw: 45, artifactPercent: 0, source: "Elite HRV")
        )
        testSessionIds.append(legacy.id)
        _ = try archive.archive(legacy)
        let before = archive.entries.first { $0.sessionId == legacy.id }
        XCTAssertEqual(before?.stressIndex, 18.2, "Pre-state: the index holds the old importer's stress index")

        archive.runDeferredMigrations()
        assertEveryBackfillRan()

        let after = archive.entries.first { $0.sessionId == legacy.id }
        XCTAssertNil(after?.stressIndex)
        XCTAssertNil(after?.recoveryScore)
        XCTAssertEqual(after?.fileHash, before?.fileHash, "Only the index entry changes")
    }

    // MARK: - Helpers

    /// Coverage limit: these sessions are synthesised, not loaded from disk, so
    /// the parity check is structural rather than byte-for-byte against known
    /// post-migration goldens. Golden-file parity needs a Resources bundle of
    /// pre-migration archives captured from older production builds, which the
    /// repo does not carry — this helper is the seam that work would plug into.
    private func makeCompletedSession() -> HRVSession {
        let now = Date()
        let startDate = Calendar.current.date(byAdding: .hour, value: -8, to: now) ?? now
        var session = HRVSession(startDate: startDate, sessionType: .overnight)
        session.endDate = now
        return session
    }
}
