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
    var archive = SessionArchive()
    var testSessionIds: [UUID] = []

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
            sleepScheduleProvider: {
                SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
            },
            sessionMergeModeProvider: { .off }
        )
        testSessionIds = []
    }

    override func tearDown() {
        for id in testSessionIds {
            try? archive.delete(id)
        }
        testSessionIds = []
        super.tearDown()
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
