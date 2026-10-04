@testable import Emuqu
import XCTest

final class RawRRBackupTests: XCTestCase {
    private var backup = RawRRBackup()

    /// `RawRRBackup` has no private directory: every test writes into the
    /// app's real backup store. The ids already there when the test started
    /// are left alone; everything the test added is discarded afterwards so
    /// no backup outlives the test that made it.
    private lazy var idsBeforeTest = Set(backup.sessionIds(indexedSince: .distantPast))

    override func setUp() {
        super.setUp()
        _ = idsBeforeTest
    }

    override func tearDown() {
        for id in backup.sessionIds(indexedSince: .distantPast) where !idsBeforeTest.contains(id) {
            XCTAssertNoThrow(try backup.discardBackup(id), "Could not discard test backup \(id)")
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func makePoints(count: Int, startMs: Int64 = 0) -> [RRPoint] {
        var points: [RRPoint] = []
        var t = startMs
        for _ in 0 ..< count {
            points.append(RRPoint(t_ms: t, rr_ms: 800))
            t += 800
        }
        return points
    }

    // MARK: - Backup and Retrieve

    func testBackupAndRetrieve() throws {
        let sessionId = UUID()
        let points = makePoints(count: 100)

        let entry = try backup.backup(points: points, sessionId: sessionId, deviceId: "TestDevice")
        XCTAssertEqual(entry.id, sessionId)
        XCTAssertEqual(entry.beatCount, 100)
        XCTAssertEqual(entry.points.count, 100)
        XCTAssertFalse(entry.hash.isEmpty)

        let retrieved = try backup.retrieve(sessionId)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.beatCount, 100)
        XCTAssertEqual(retrieved?.id, sessionId)
        XCTAssertEqual(retrieved?.hash, entry.hash)
    }

    func testBackup_emptyPoints_throws() throws {
        let sessionId = UUID()
        XCTAssertThrowsError(try backup.backup(points: [], sessionId: sessionId))
    }

    func testRetrieve_nonExistentSession_returnsNil() throws {
        let result = try backup.retrieve(UUID())
        XCTAssertNil(result)
    }

    // MARK: - Mark as Archived

    func testMarkAsArchived() throws {
        let sessionId = UUID()
        let points = makePoints(count: 50)
        try backup.backup(points: points, sessionId: sessionId)

        XCTAssertTrue(backup.unarchivedSessionIds.contains(sessionId))

        backup.markAsArchived(sessionId)

        XCTAssertFalse(backup.unarchivedSessionIds.contains(sessionId))
    }

    func testMarkAsArchived_nonExistentSession_doesNotCrash() {
        backup.markAsArchived(UUID())
        // Should not crash
    }

    // MARK: - Incremental Backup

    func testIncrementalBackup_firstCall_writesImmediately() {
        let sessionId = UUID()
        let points = makePoints(count: 50)

        let result = backup.incrementalBackup(points: points, sessionId: sessionId)
        XCTAssertTrue(result)
    }

    func testIncrementalBackup_secondCallWithinInterval_skips() {
        let sessionId = UUID()
        let points = makePoints(count: 50)

        _ = backup.incrementalBackup(points: points, sessionId: sessionId)
        // Second call immediately after — should skip (within 60s interval)
        let result2 = backup.incrementalBackup(points: points, sessionId: sessionId)
        XCTAssertFalse(result2)
    }

    func testIncrementalBackup_forceFlag_writesImmediately() {
        let sessionId = UUID()
        let points = makePoints(count: 50)

        _ = backup.incrementalBackup(points: points, sessionId: sessionId)
        // Force should override the interval check
        let morePoints = makePoints(count: 60)
        let result2 = backup.incrementalBackup(points: morePoints, sessionId: sessionId, force: true)
        XCTAssertTrue(result2)
    }

    func testIncrementalBackup_emptyPoints_returnsFalse() {
        let sessionId = UUID()
        let result = backup.incrementalBackup(points: [], sessionId: sessionId)
        XCTAssertFalse(result)
    }

    // MARK: - Unarchived Count

    func testUnarchivedBackupCount() throws {
        let id1 = UUID()
        let id2 = UUID()
        let points = makePoints(count: 50)

        try backup.backup(points: points, sessionId: id1)
        try backup.backup(points: points, sessionId: id2)

        let initialCount = backup.unarchivedBackupCount
        XCTAssertGreaterThanOrEqual(initialCount, 2)

        backup.markAsArchived(id1)
        XCTAssertEqual(backup.unarchivedBackupCount, initialCount - 1)
    }

    // MARK: - Purge Old Backups

    func testPurgeOldBackups_keepsRecentBackups() throws {
        let sessionId = UUID()
        let points = makePoints(count: 50)
        try backup.backup(points: points, sessionId: sessionId)
        backup.markAsArchived(sessionId)

        // Purge with 90 day window — recent backup should survive
        try backup.purgeOldBackups(keepDays: 90)

        let retrieved = try backup.retrieve(sessionId)
        XCTAssertNotNil(retrieved)
    }

    // MARK: - Export to CSV

    func testExportToCSV() throws {
        let sessionId = UUID()
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 750)
        ]
        try backup.backup(points: points, sessionId: sessionId)

        let csv = try backup.exportToCSV(sessionId)
        XCTAssertTrue(csv.hasPrefix("timestamp_ms,rr_ms,hr_bpm\n"))
        XCTAssertTrue(csv.contains("0,800,"))
        XCTAssertTrue(csv.contains("800,750,"))
    }

    func testExportToCSV_notFound_throws() throws {
        XCTAssertThrowsError(try backup.exportToCSV(UUID()))
    }

    // MARK: - Hash Integrity

    func testBackup_hashIsDeterministic() throws {
        let sessionId1 = UUID()
        let sessionId2 = UUID()
        let points = makePoints(count: 50)

        let entry1 = try backup.backup(points: points, sessionId: sessionId1)
        let entry2 = try backup.backup(points: points, sessionId: sessionId2)

        // Same data → same hash
        XCTAssertEqual(entry1.hash, entry2.hash)
    }

    // MARK: - Index-only window

    /// The launch-time interrupted-workout check narrows by this before it
    /// opens a single file. A backup made now is inside any window that began
    /// before it and outside any that begins after it.
    func testSessionIdsIndexedSince_includesABackupMadeInsideTheWindow() throws {
        let sessionId = UUID()
        try backup.backup(points: makePoints(count: 50), sessionId: sessionId)

        XCTAssertTrue(backup.sessionIds(indexedSince: Date().addingTimeInterval(-60)).contains(sessionId))
    }

    /// The other half, and the one that matters for launch time: a backup from
    /// before the window is not handed back, so its beat file is never read.
    func testSessionIdsIndexedSince_excludesABackupMadeBeforeTheWindow() throws {
        let sessionId = UUID()
        try backup.backup(points: makePoints(count: 50), sessionId: sessionId)

        XCTAssertFalse(backup.sessionIds(indexedSince: Date().addingTimeInterval(60)).contains(sessionId))
    }

    /// Archived backups stay in the window: whether a session was archived is
    /// the caller's question, answered against the archive itself.
    func testSessionIdsIndexedSince_keepsArchivedBackups() throws {
        let sessionId = UUID()
        try backup.backup(points: makePoints(count: 50), sessionId: sessionId)
        backup.markAsArchived(sessionId)

        XCTAssertTrue(backup.sessionIds(indexedSince: Date().addingTimeInterval(-60)).contains(sessionId))
    }

    // MARK: - allBackups

    func testAllBackups_returnsSortedByDate() throws {
        let id1 = UUID()
        let id2 = UUID()
        let points = makePoints(count: 50)

        try backup.backup(points: points, sessionId: id1)
        // Small delay to ensure different capture dates
        try backup.backup(points: points, sessionId: id2)

        let all = backup.allBackups()
        XCTAssertGreaterThanOrEqual(all.count, 2)
        // Sorted by captureDate descending
        if all.count >= 2 {
            XCTAssertGreaterThanOrEqual(all[0].captureDate, all[1].captureDate)
        }
    }

    // MARK: - BackupEntry computed properties

    func testBackupEntry_duration() throws {
        let sessionId = UUID()
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 750),
            RRPoint(t_ms: 1550, rr_ms: 810)
        ]
        let entry = try backup.backup(points: points, sessionId: sessionId)
        XCTAssertEqual(entry.duration, 1.55, accuracy: 0.001)
        XCTAssertEqual(entry.beatCount, 3)
    }

    // MARK: - Total Backup Size

    func testTotalBackupSize_nonZeroAfterBackup() throws {
        let sessionId = UUID()
        let points = makePoints(count: 100)
        try backup.backup(points: points, sessionId: sessionId)

        XCTAssertGreaterThan(backup.totalBackupSize, 0)
    }

    // MARK: - Overwrite existing backup

    func testBackup_overwritesSameSessionId() throws {
        let sessionId = UUID()
        let points1 = makePoints(count: 50)
        let points2 = makePoints(count: 100)

        try backup.backup(points: points1, sessionId: sessionId)
        try backup.backup(points: points2, sessionId: sessionId)

        let retrieved = try backup.retrieve(sessionId)
        XCTAssertEqual(retrieved?.beatCount, 100)
    }

    /// A strap fetch saved under an interrupted night's id must not delete the
    /// longer streamed copy.
    func testBackup_doesNotReplaceAStreamedBackupWithFewerBeats() throws {
        let sessionId = UUID()
        XCTAssertTrue(backup.incrementalBackup(points: makePoints(count: 500), sessionId: sessionId, force: true))
        XCTAssertThrowsError(try backup.backup(points: makePoints(count: 200), sessionId: sessionId))
        XCTAssertEqual(try backup.retrieve(sessionId)?.points.count, 500)
    }

    func testBackup_doesNotReplaceAOneShotBackupWithFewerBeats() throws {
        let sessionId = UUID()
        try backup.backup(points: makePoints(count: 300), sessionId: sessionId)
        XCTAssertThrowsError(try backup.backup(points: makePoints(count: 100), sessionId: sessionId))
        XCTAssertEqual(try backup.retrieve(sessionId)?.beatCount, 300)
    }

    /// Recovery dates the session by the backup, so it keeps the recording's
    /// start rather than the time of each write.
    func testBackup_keepsTheGivenStartDateAcrossRewrites() throws {
        let sessionId = UUID()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        try backup.backup(points: makePoints(count: 50), sessionId: sessionId, captureDate: start)
        try backup.backup(points: makePoints(count: 80), sessionId: sessionId)
        XCTAssertEqual(try backup.retrieve(sessionId)?.captureDate, start)
    }

    /// A backup first written without a start (stamped with the write time)
    /// takes the real start when a later write knows it.
    func testBackup_takesAKnownStartOverAWriteTimeStamp() throws {
        let sessionId = UUID()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        try backup.backup(points: makePoints(count: 50), sessionId: sessionId)
        try backup.backup(points: makePoints(count: 80), sessionId: sessionId, captureDate: start)
        XCTAssertEqual(try backup.retrieve(sessionId)?.captureDate, start)
    }
}
