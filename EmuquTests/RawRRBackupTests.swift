@testable import Emuqu
import UIKit
import XCTest

final class RawRRBackupTests: XCTestCase {
    /// A store in a folder of its own, made fresh for each test and removed
    /// after it, so backups other tests leave in the app's shared folder are
    /// never listed here and nothing this test writes outlives it.
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RawRRBackupTests-\(UUID().uuidString)", isDirectory: true)
    /// The unlock notifications the store listens on, so the host app's own
    /// activation never runs a repair during a test, and a post here reaches
    /// no other store.
    private let notifications = NotificationCenter()
    private lazy var backup = RawRRBackup(directory: directory, notificationCenter: notifications)

    /// The reconcile and repair the store queues at init run before the
    /// test, so neither writes into the folder while the test does.
    override func setUp() {
        super.setUp()
        backup.waitForQueuedWork()
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
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

    // MARK: - Switching a one-shot backup to the streaming format

    /// The switch writes the header and starts the points file before any
    /// point is in it. Interrupted there (a crash, a failed write), the
    /// one-shot backup is still the copy the index names, and still reads.
    func testAnInterruptedFormatSwitchLeavesTheOneShotBackupReadable() throws {
        let sessionId = UUID()
        try backup.backup(points: makePoints(count: 100), sessionId: sessionId)
        let oneShot = try XCTUnwrap(backup.index.first { $0.id == sessionId })

        try backup.startAppendFormat(sessionId: sessionId, deviceId: nil, existingEntry: oneShot)

        let fileName = try XCTUnwrap(oneShot.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.backupDirectory.appendingPathComponent(fileName).path))
        XCTAssertEqual(try backup.retrieve(sessionId)?.points.count, 100, "the switch destroyed the backup before replacing it")
    }

    /// Completed, the switch holds every point and removes the one-shot file.
    func testACompletedFormatSwitchKeepsEveryPointAndRemovesTheOneShotFile() throws {
        let sessionId = UUID()
        try backup.backup(points: makePoints(count: 100), sessionId: sessionId)
        let fileName = try XCTUnwrap(backup.index.first { $0.id == sessionId }?.fileName)

        try backup.appendBackup(points: makePoints(count: 150), sessionId: sessionId)

        XCTAssertEqual(try backup.retrieve(sessionId)?.points.count, 150)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.backupDirectory.appendingPathComponent(fileName).path))
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

    /// Marking an id the store holds no backup of changes nothing: no row
    /// is added for it and another session's backup stays unarchived.
    func testMarkAsArchived_nonExistentSession_doesNotCrash() throws {
        let kept = UUID()
        try backup.backup(points: makePoints(count: 50), sessionId: kept)
        let unknown = UUID()

        backup.markAsArchived(unknown)

        XCTAssertFalse(backup.index.contains { $0.id == unknown }, "a row was added for an id with no backup")
        XCTAssertEqual(backup.unarchivedSessionIds, [kept])
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
        XCTAssertTrue(csv.hasPrefix("timestamp_ms,rr_ms,hr_bpm,wall_clock_ms\n"))
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

    // MARK: - One-shot file names

    /// Two backups of one session in the same instant write two files: a
    /// shared name let a failed index save restore the old row over the new
    /// bytes, and that backup then failed its hash check.
    func testBackup_twoWritesInOneMomentUseDistinctFiles() throws {
        let sessionId = UUID()
        try backup.backup(points: makePoints(count: 50), sessionId: sessionId)
        let first = try XCTUnwrap(backup.index.first { $0.id == sessionId }?.fileName)
        try backup.backup(points: makePoints(count: 60), sessionId: sessionId)
        let second = try XCTUnwrap(backup.index.first { $0.id == sessionId }?.fileName)

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.backupDirectory.appendingPathComponent(first).path))
        XCTAssertEqual(try backup.retrieve(sessionId)?.beatCount, 60)
    }

    /// The same clock reading never yields a name already taken.
    func testOneShotName_skipsTakenNames() {
        let sessionId = UUID()
        let now = Date(timeIntervalSince1970: 1_790_000_000.5)
        let taken: Set = ["\(sessionId.uuidString)_1790000000500.json", "\(sessionId.uuidString)_1790000000501.json"]

        let name = OneShotBackupName.make(for: sessionId, at: now) { taken.contains($0) }

        XCTAssertEqual(name, "\(sessionId.uuidString)_1790000000502.json")
    }

    /// Files from before the change carry whole seconds; both forms parse to
    /// milliseconds and order by time, not by text.
    func testOneShotName_parsesSecondAndMillisecondStamps() throws {
        let sessionId = UUID()
        let legacy = "\(sessionId.uuidString)_1790000001.json"
        let current = "\(sessionId.uuidString)_1790000000999.json"

        XCTAssertEqual(try XCTUnwrap(OneShotBackupName.parse(legacy)).writtenMs, 1_790_000_001_000)
        XCTAssertEqual(try XCTUnwrap(OneShotBackupName.parse(current)).id, sessionId)
        XCTAssertGreaterThan(OneShotBackupName.writtenMs(legacy), OneShotBackupName.writtenMs(current))
        XCTAssertNil(OneShotBackupName.parse("\(sessionId.uuidString)_header.json"))
        XCTAssertNil(OneShotBackupName.parse("\(sessionId.uuidString)_points.jsonl"))
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

    // MARK: - A points file that will not open

    /// A points file gone from disk is written again with every point so
    /// far, not the new batch alone, so the count the index stores is what
    /// the file holds.
    func testAMissingPointsFileIsRewrittenWithTheWholeNight() throws {
        let sessionId = UUID()
        try backup.appendBackup(points: makePoints(count: 50), sessionId: sessionId)
        try FileManager.default.removeItem(at: backup.pointsURL(for: sessionId))

        try backup.appendBackup(points: makePoints(count: 80), sessionId: sessionId)

        XCTAssertEqual(try backup.retrieve(sessionId)?.points.count, 80)
        XCTAssertEqual(backup.index.first { $0.id == sessionId }?.backedUpCount, 80)
    }

    /// A points file that neither opens nor reads (here a folder in its
    /// place) is set aside under a sibling name, and the night is written
    /// again in full beside it.
    func testAnUnreadablePointsFileIsSetAsideAndTheNightWrittenAgain() throws {
        let sessionId = UUID()
        let pointsURL = backup.pointsURL(for: sessionId)
        try backup.appendBackup(points: makePoints(count: 50), sessionId: sessionId)
        try FileManager.default.removeItem(at: pointsURL)
        try FileManager.default.createDirectory(at: pointsURL, withIntermediateDirectories: false)

        try backup.appendBackup(points: makePoints(count: 80), sessionId: sessionId)

        XCTAssertEqual(backup.corruptedSiblingNames(of: pointsURL).count, 1)
        XCTAssertEqual(try backup.retrieve(sessionId)?.points.count, 80)
    }

    /// Two set-asides in the same second take two names; one-second names
    /// collided and the second move failed.
    func testSettingAsideTwiceInOneMomentKeepsBothFiles() throws {
        let sessionId = UUID()
        let pointsURL = backup.pointsURL(for: sessionId)
        defer { backup.cleanupAppendFiles(for: sessionId) }

        for _ in 0 ..< 2 {
            try Data("{}\n".utf8).write(to: pointsURL)
            try backup.preserveCorruptedPointsFile(at: pointsURL, sessionId: sessionId)
        }

        XCTAssertEqual(backup.corruptedSiblingNames(of: pointsURL).count, 2)
    }

    /// A set-aside that fails throws, so the caller writes nothing over the
    /// file and does not advance the index.
    func testAFailedSetAsideThrows() {
        let sessionId = UUID()
        XCTAssertThrowsError(try backup.preserveCorruptedPointsFile(at: backup.pointsURL(for: sessionId), sessionId: sessionId))
    }

    // MARK: - Re-encryption queue

    /// The queue is shared by every store: a store that holds nothing of a
    /// queued session leaves it queued for the store that does.
    func testRepairLeavesASessionThisStoreDoesNotHoldQueued() {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        PendingEncryptionLedger.record(sessionId, in: .rawBackup)

        backup.sealer.reencrypt(sessionId, in: backup)

        XCTAssertTrue(PendingEncryptionLedger.pending(in: .rawBackup).contains(sessionId))
    }

    /// Discarding a backup takes it off the queue once every file is gone.
    func testDiscardTakesTheSessionOffTheQueue() throws {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        try backup.backup(points: makePoints(count: 50), sessionId: sessionId)
        PendingEncryptionLedger.record(sessionId, in: .rawBackup)

        try backup.discardBackup(sessionId)

        XCTAssertFalse(PendingEncryptionLedger.pending(in: .rawBackup).contains(sessionId))
    }

    /// A plaintext one-shot file a newer backup replaced is removed by the
    /// repair before the session leaves the queue.
    func testReencryptionRemovesASupersededPlaintextFile() throws {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        try backup.backup(points: makePoints(count: 50), sessionId: sessionId)
        let stale = backup.backupDirectory.appendingPathComponent("\(sessionId.uuidString)_1000000000000.json")
        try plainBackupFile(sessionId: sessionId, beats: 40).write(to: stale)
        PendingEncryptionLedger.record(sessionId, in: .rawBackup)

        backup.sealer.reencrypt(sessionId, in: backup)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        try requireEncryptionKey()
        XCTAssertFalse(PendingEncryptionLedger.pending(in: .rawBackup).contains(sessionId))
        XCTAssertEqual(try backup.retrieve(sessionId)?.points.count, 50)
    }

    /// A fuller plaintext file written after the indexed backup (a process
    /// killed between that write and its index save) becomes the backup, so
    /// listings and recovery read the most complete night, and the file the
    /// index missed is then retired.
    func testReencryptionAdoptsANewerFullerUnindexedFile() throws {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        let newer = try writeUnindexedFile(sessionId: sessionId, indexedBeats: 50, beats: 80, offsetMs: 1)

        backup.sealer.reencrypt(sessionId, in: backup)

        XCTAssertEqual(try backup.retrieve(sessionId)?.points.count, 80)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newer.path))
        try requireEncryptionKey()
        XCTAssertFalse(PendingEncryptionLedger.pending(in: .rawBackup).contains(sessionId))
    }

    /// A newer file holding fewer beats is neither adopted (`backup()` never
    /// replaces a fuller backup) nor removed (it is not older, so not provably
    /// replaced): it is kept, and the session stays queued.
    func testReencryptionKeepsANewerSmallerUnindexedFile() throws {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        let newer = try writeUnindexedFile(sessionId: sessionId, indexedBeats: 50, beats: 30, offsetMs: 1)

        backup.sealer.reencrypt(sessionId, in: backup)

        XCTAssertEqual(try RawRRBackup.decodeLegacyBackup(at: newer).points.count, 30)
        XCTAssertEqual(try backup.retrieve(sessionId)?.points.count, 50)
        XCTAssertTrue(PendingEncryptionLedger.pending(in: .rawBackup).contains(sessionId))
    }

    /// Discarding a backup removes every file of the session, indexed or
    /// not, so no beats are left that nothing lists.
    func testDiscardRemovesEveryFileOfTheSession() throws {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        let fuller = try writeUnindexedFile(sessionId: sessionId, indexedBeats: 50, beats: 80, offsetMs: 1)
        let replaced = try writeUnindexedFile(sessionId: sessionId, indexedBeats: nil, beats: 20, offsetMs: -1_000)
        try Data("{}\n".utf8).write(to: backup.pointsURL(for: sessionId))

        try backup.discardBackup(sessionId)

        XCTAssertEqual(try OneShotBackupName.files(of: sessionId, in: backup.backupDirectory), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fuller.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: replaced.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.pointsURL(for: sessionId).path))
        XCTAssertNil(backup.index.first { $0.id == sessionId })
    }

    /// A file that will not go makes the discard throw, and the row stays,
    /// so the backup is still listed (the Trash keeps it) rather than left on
    /// disk with nothing naming it. Here the file is a folder that cannot be
    /// emptied.
    func testADiscardThatLeavesAFileThrowsAndKeepsTheRow() throws {
        let sessionId = UUID()
        try backup.backup(points: makePoints(count: 50), sessionId: sessionId)
        let stuck = backup.backupDirectory.appendingPathComponent("\(sessionId.uuidString)_1000000000000.json", isDirectory: true)
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: stuck.appendingPathComponent("held"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stuck.path)
        defer {
            XCTAssertNoThrow(try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stuck.path))
            XCTAssertNoThrow(try FileManager.default.removeItem(at: stuck))
        }

        XCTAssertThrowsError(try backup.discardBackup(sessionId))

        XCTAssertNotNil(backup.index.first { $0.id == sessionId })
        XCTAssertTrue(FileManager.default.fileExists(atPath: stuck.path))
    }

    /// Of several fuller files the index missed, the one with the most beats
    /// is adopted, not the newest.
    func testReencryptionAdoptsTheFullestUnindexedFile() throws {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        _ = try writeUnindexedFile(sessionId: sessionId, indexedBeats: 50, beats: 80, offsetMs: 1)
        _ = try writeUnindexedFile(sessionId: sessionId, indexedBeats: nil, beats: 60, offsetMs: 2)

        backup.sealer.reencrypt(sessionId, in: backup)

        XCTAssertEqual(try backup.retrieve(sessionId)?.points.count, 80)
    }

    /// An encrypted file the index missed is adopted too, but only when the
    /// session is queued for another reason: the encrypted write itself took
    /// the session off the queue, so the repair never visits it alone. The
    /// test queues it by hand for that reason. Needs the key to write the
    /// sealed file.
    func testReencryptionAdoptsAnEncryptedUnindexedFileOfAQueuedSession() throws {
        try requireEncryptionKey()
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        let stale = try writeUnindexedFile(sessionId: sessionId, indexedBeats: 50, beats: 20, offsetMs: -1_000)
        let points = makePoints(count: 80)
        let indexedName = try XCTUnwrap(backup.index.first { $0.id == sessionId }?.fileName)
        let sealed = backup.backupDirectory.appendingPathComponent("\(sessionId.uuidString)_\(OneShotBackupName.writtenMs(indexedName) + 1).json")
        try RawBackupSealer.writeEntry(
            RawRRBackup.BackupEntry(id: sessionId, captureDate: Date(), deviceId: nil, points: points, hash: RawRRBackup.integrityHash(of: points)),
            to: sealed, sessionId: sessionId
        )
        PendingEncryptionLedger.record(sessionId, in: .rawBackup)

        backup.sealer.reencrypt(sessionId, in: backup)

        XCTAssertEqual(try backup.retrieve(sessionId)?.points.count, 80)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    /// A fuller file older than the row (its index save failed, then a
    /// shorter backup succeeded) is adopted too, and once adopted it is
    /// retired, so the next pass adopts nothing more.
    func testReencryptionAdoptsAnOlderFullerUnindexedFileOnce() throws {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        let older = try writeUnindexedFile(sessionId: sessionId, indexedBeats: 50, beats: 80, offsetMs: -1_000)

        backup.sealer.reencrypt(sessionId, in: backup)
        let adopted = backup.index.first { $0.id == sessionId }?.fileName
        backup.sealer.reencrypt(sessionId, in: backup)

        XCTAssertEqual(try backup.retrieve(sessionId)?.points.count, 80)
        XCTAssertFalse(FileManager.default.fileExists(atPath: older.path))
        XCTAssertEqual(backup.index.first { $0.id == sessionId }?.fileName, adopted)
    }

    /// A row with no write time (rebuilt from a header, its count known) gets
    /// nothing adopted over it.
    func testNothingIsAdoptedOverARowWithoutAWriteTime() throws {
        let sessionId = UUID()
        let directory = try directoryHoldingAFullerFile(of: sessionId)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let rebuilt = RawRRBackup.BackupIndex(
            id: sessionId, captureDate: Date(), fileName: nil, beatCount: 10, hash: "", archived: false, lastBackupTime: nil, backedUpCount: 10
        )

        XCTAssertNil(try OneShotBackupName.fullerUnindexedBackup(than: rebuilt, in: directory))
    }

    /// A row with no beat count (its points file could not be counted) gets
    /// nothing adopted over it, or that uncounted file would be replaced.
    func testNothingIsAdoptedOverARowWithoutACount() throws {
        let sessionId = UUID()
        let directory = try directoryHoldingAFullerFile(of: sessionId)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let uncounted = RawRRBackup.BackupIndex(
            id: sessionId, captureDate: Date(), fileName: nil, beatCount: 0, hash: "", archived: false, lastBackupTime: Date(), backedUpCount: nil
        )

        XCTAssertNil(try OneShotBackupName.fullerUnindexedBackup(than: uncounted, in: directory))
    }

    /// A temporary directory holding one plain 80-beat one-shot file of the
    /// session; the caller removes it.
    private func directoryHoldingAFullerFile(of sessionId: UUID) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawRRBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try plainBackupFile(sessionId: sessionId, beats: 80).write(to: directory.appendingPathComponent("\(sessionId.uuidString)_1790000000000.json"))
        return directory
    }

    /// Backs up `indexedBeats` points (when given), then writes a plain,
    /// unindexed one-shot file of `beats` points stamped `offsetMs` after the
    /// indexed file, and queues the session. Returns the file.
    private func writeUnindexedFile(sessionId: UUID, indexedBeats: Int?, beats: Int, offsetMs: Int64) throws -> URL {
        if let indexedBeats { try backup.backup(points: makePoints(count: indexedBeats), sessionId: sessionId) }
        let indexedName = try XCTUnwrap(backup.index.first { $0.id == sessionId }?.fileName)
        let stamp = OneShotBackupName.writtenMs(indexedName) + offsetMs
        let url = backup.backupDirectory.appendingPathComponent("\(sessionId.uuidString)_\(stamp).json")
        try plainBackupFile(sessionId: sessionId, beats: beats).write(to: url)
        PendingEncryptionLedger.record(sessionId, in: .rawBackup)
        return url
    }

    /// A one-shot backup file of `beats` points, written as plain JSON.
    private func plainBackupFile(sessionId: UUID, beats: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let points = makePoints(count: beats)
        return try encoder.encode(RawRRBackup.BackupEntry(
            id: sessionId, captureDate: Date(), deviceId: nil, points: points, hash: RawRRBackup.integrityHash(of: points)
        ))
    }

    /// A plaintext one-shot file no index row names may be the only copy of
    /// a night (a crash between its write and its row): it is kept, and so
    /// is its queue entry.
    func testReencryptionKeepsAnUnindexedPlaintextFileQueued() throws {
        let sessionId = UUID()
        let orphan = backup.backupDirectory.appendingPathComponent("\(sessionId.uuidString)_1000000000000.json")
        defer {
            PendingEncryptionLedger.clear(sessionId, in: .rawBackup)
            XCTAssertNoThrow(try FileManager.default.removeItem(at: orphan))
        }
        try Data("{}".utf8).write(to: orphan)
        PendingEncryptionLedger.record(sessionId, in: .rawBackup)

        backup.sealer.reencrypt(sessionId, in: backup)

        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(PendingEncryptionLedger.pending(in: .rawBackup).contains(sessionId))
    }
}

/// Streamed plaintext lines, the index reconcile, and the first append.
extension RawRRBackupTests {
    // MARK: - Streamed plaintext lines

    /// Without a key every line is plain JSON, reported as such, and still
    /// reads back.
    func testLinesEncodedWithoutAKeyArePlainAndReported() throws {
        let points = makePoints(count: 3)
        let encoded = try SealedJSONLines.encode(points, with: backup.lineEncoder, manager: nil)

        XCTAssertFalse(encoded.allSealed)
        XCTAssertTrue(SealedJSONLines.hasPlainLine(encoded.data))
        let decoder = JSONDecoder()
        let lines = try XCTUnwrap(String(bytes: encoded.data, encoding: .utf8)).split(separator: "\n")
        XCTAssertEqual(try lines.map { try backup.decodePointLine($0, decoder: decoder) }.map(\.t_ms), points.map(\.t_ms))
    }

    /// A batch written with plain lines queues its session; a sealed batch
    /// does not.
    func testStreamedPlainLinesQueueTheSession() throws {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }

        let data = try backup.encodedLines(makePoints(count: 3)[...], sessionId: sessionId)

        let sealed = SealedJSONLines.availableManager() != nil
        XCTAssertEqual(SealedJSONLines.hasPlainLine(data), !sealed)
        XCTAssertEqual(PendingEncryptionLedger.pending(in: .rawBackup).contains(sessionId), !sealed)
    }

    /// The repair seals every plain line of a streamed points file and only
    /// then takes the session off the queue; the beats still read.
    func testRepairSealsStreamedPlainLines() throws {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        let points = makePoints(count: 50)
        try backup.appendBackup(points: points, sessionId: sessionId)
        try SealedJSONLines.encode(points, with: backup.lineEncoder, manager: nil).data.write(to: backup.pointsURL(for: sessionId))
        PendingEncryptionLedger.record(sessionId, in: .rawBackup)

        backup.sealer.reencrypt(sessionId, in: backup)

        let plainLeft = SealedJSONLines.hasPlainLine(try Data(contentsOf: backup.pointsURL(for: sessionId)))
        XCTAssertEqual(plainLeft, SealedJSONLines.availableManager() == nil)
        XCTAssertEqual(PendingEncryptionLedger.pending(in: .rawBackup).contains(sessionId), plainLeft)
        XCTAssertEqual(try backup.retrieve(sessionId)?.points.count, 50)
    }

    /// While any points file of the session cannot be sealed (here a
    /// set-aside copy that will not read), the session stays queued.
    func testRepairKeepsTheSessionQueuedWhilePlainLinesMayRemain() throws {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        let points = makePoints(count: 50)
        try backup.appendBackup(points: points, sessionId: sessionId)
        try SealedJSONLines.encode(points, with: backup.lineEncoder, manager: nil).data.write(to: backup.pointsURL(for: sessionId))
        let unreadable = backup.backupDirectory.appendingPathComponent(backup.pointsURL(for: sessionId).lastPathComponent + ".corrupted_1")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false)
        PendingEncryptionLedger.record(sessionId, in: .rawBackup)

        backup.sealer.reencrypt(sessionId, in: backup)

        XCTAssertTrue(PendingEncryptionLedger.pending(in: .rawBackup).contains(sessionId))
    }

    // MARK: - Index reconcile

    /// A first append killed between its files and its index save leaves a
    /// header and points no row names; the reconcile lists them again.
    func testReconcileListsAStreamedBackupTheIndexMissed() throws {
        let sessionId = UUID()
        try backup.appendBackup(points: makePoints(count: 50), sessionId: sessionId)
        try dropRowKeepingFiles(sessionId)

        backup.reconcileIndexWithFiles()

        XCTAssertEqual(backup.index.first { $0.id == sessionId }?.backedUpCount, 50)
        XCTAssertEqual(try backup.retrieve(sessionId)?.points.count, 50)
    }

    /// A one-shot write killed before its row is listed again from its file.
    func testReconcileListsAOneShotFileTheIndexMissed() throws {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        try plainBackupFile(sessionId: sessionId, beats: 40)
            .write(to: backup.backupDirectory.appendingPathComponent("\(sessionId.uuidString)_1000000000000.json"))

        backup.reconcileIndexWithFiles()

        XCTAssertEqual(try backup.retrieve(sessionId)?.points.count, 40)
    }

    /// A session the user deleted forever is not listed again from files a
    /// delete left behind.
    func testReconcileDoesNotResurrectASessionDeletedForever() throws {
        let sessionId = UUID()
        let key = "sessionRecovery.forgottenBackupIds"
        let saved = UserDefaults.standard.stringArray(forKey: key)
        defer {
            UserDefaults.standard.set(saved, forKey: key)
            backup.cleanupAppendFiles(for: sessionId)
        }
        try backup.appendBackup(points: makePoints(count: 50), sessionId: sessionId)
        try dropRowKeepingFiles(sessionId)
        UserDefaults.standard.set((saved ?? []) + [sessionId.uuidString], forKey: key)

        backup.reconcileIndexWithFiles()

        XCTAssertNil(backup.index.first { $0.id == sessionId })
    }

    /// The first append for a session no row names keeps the beats already
    /// in its points file and appends after them.
    func testTheFirstAppendNeverTruncatesExistingPoints() throws {
        let sessionId = UUID()
        try backup.appendBackup(points: makePoints(count: 50), sessionId: sessionId)
        try dropRowKeepingFiles(sessionId)

        try backup.appendBackup(points: makePoints(count: 30, startMs: 1_000_000), sessionId: sessionId)

        XCTAssertEqual(try backup.retrieve(sessionId)?.points.count, 80)
    }

    /// Removes the session's row, in memory and on disk, leaving its files.
    private func dropRowKeepingFiles(_ sessionId: UUID) throws {
        backup.index.removeAll { $0.id == sessionId }
        try backup.saveIndex()
    }
}

/// A torn last line, an index save that throws, and the repair run on unlock.
extension RawRRBackupTests {
    // MARK: - Torn last line

    /// A kill part way through a line leaves the points file ending in a
    /// fragment. The next append cuts it off, so the batch does not fuse
    /// with it into a line no read decodes, and every beat reads back.
    func testAnAppendAfterATornLineKeepsEveryBeat() throws {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        let points = makePoints(count: 60)
        try backup.appendBackup(points: Array(points[..<40]), sessionId: sessionId)
        let url = backup.pointsURL(for: sessionId)
        let fragment = try backup.encodedLines(points[40 ..< 41], sessionId: sessionId).prefix(12)
        try (Data(contentsOf: url) + fragment).write(to: url)

        try backup.appendBackup(points: points, sessionId: sessionId)

        XCTAssertEqual(try backup.retrieve(sessionId)?.points.map(\.t_ms), points.map(\.t_ms))
        XCTAssertEqual(try Data(contentsOf: url).filter { $0 == UInt8(ascii: "\n") }.count, 60)
    }

    /// The complete lines of a file's bytes: all of them, up to the last
    /// newline, or none.
    func testCompleteLinesDropOnlyATornTail() {
        XCTAssertEqual(JSONLinesFile.completeLines(of: Data("a\nb\n".utf8)), Data("a\nb\n".utf8))
        XCTAssertEqual(JSONLinesFile.completeLines(of: Data("a\nb".utf8)), Data("a\n".utf8))
        XCTAssertEqual(JSONLinesFile.completeLines(of: Data("ab".utf8)), Data())
        XCTAssertEqual(JSONLinesFile.completeLines(of: Data()), Data())
    }

    // MARK: - Index save that throws

    /// The points reach the file but the index save throws: the call reports
    /// false, the next one retries the save without waiting out the interval
    /// (with no new points too), and reports true only once the row is on
    /// disk. No point is appended twice.
    func testAFailedIndexSaveIsRetriedAndReportedUntilItLands() throws {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        let points = makePoints(count: 60)
        XCTAssertTrue(backup.incrementalBackup(points: Array(points[..<30]), sessionId: sessionId))
        try blockIndexFile()

        XCTAssertFalse(backup.incrementalBackup(points: points, sessionId: sessionId, force: true))
        XCTAssertFalse(backup.incrementalBackup(points: points, sessionId: sessionId), "not retried before the interval")
        try FileManager.default.removeItem(at: backup.indexFile)
        // `interval: 0` stands in for the interval having passed.
        XCTAssertTrue(backup.incrementalBackup(points: points, sessionId: sessionId, interval: 0))

        XCTAssertEqual(try storedIndex().first { $0.id == sessionId }?.backedUpCount, 60)
        let lines = try Data(contentsOf: backup.pointsURL(for: sessionId)).filter { $0 == UInt8(ascii: "\n") }.count
        XCTAssertEqual(lines, 60)
        XCTAssertFalse(backup.incrementalBackup(points: points, sessionId: sessionId), "nothing owed: throttled again")
    }

    /// A one-shot backup whose index save throws puts the previous row back,
    /// so nothing is owed and no retry runs for it.
    func testAOneShotBackupWhoseIndexSaveThrewOwesNothing() throws {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        try blockIndexFile()

        XCTAssertThrowsError(try backup.backup(points: makePoints(count: 100), sessionId: sessionId))

        XCTAssertNil(backup.existingIndexEntry(sessionId))
        XCTAssertFalse(backup.indexLock.withLock { backup.indexSaveOwed })
    }

    /// An archived flag whose save threw reaches the file on the next repair
    /// run on unlock.
    func testAnArchivedFlagWhoseSaveThrewIsSavedOnUnlock() throws {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        try backup.backup(points: makePoints(count: 100), sessionId: sessionId)
        try blockIndexFile()
        backup.markAsArchived(sessionId)
        try FileManager.default.removeItem(at: backup.indexFile)

        backup.repairAfterUnlock()
        backup.waitForQueuedWork()

        XCTAssertEqual(try storedIndex().first { $0.id == sessionId }?.archived, true)
    }

    // MARK: - Repair on unlock

    /// Protected data becoming available reseals a session queued with
    /// plain lines, as a launch does.
    func testUnlockResealsAQueuedSession() throws {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        let points = makePoints(count: 50)
        try plainStreamedBackup(points, sessionId: sessionId)

        notifications.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        backup.waitForQueuedWork()

        let plainLeft = SealedJSONLines.hasPlainLine(try Data(contentsOf: backup.pointsURL(for: sessionId)))
        XCTAssertEqual(plainLeft, SealedJSONLines.availableManager() == nil)
        XCTAssertEqual(PendingEncryptionLedger.pending(in: .rawBackup).contains(sessionId), plainLeft)
        XCTAssertEqual(try backup.retrieve(sessionId)?.points.map(\.t_ms), points.map(\.t_ms))
    }

    /// The reseal rewrites the live points file while appends to it keep
    /// arriving from other threads. It runs between appends, never under
    /// one, so no appended beat is lost or written twice.
    func testUnlockResealLeavesAppendsInFlightIntact() throws {
        let sessionId = UUID()
        defer { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
        let points = makePoints(count: 240)
        try plainStreamedBackup(Array(points[..<40]), sessionId: sessionId)
        let store = backup

        DispatchQueue.concurrentPerform(iterations: 200) { step in
            if step % 50 == 25 { store.repairAfterUnlock() }
            store.incrementalBackup(points: Array(points[..<(41 + step)]), sessionId: sessionId, force: true)
        }
        backup.waitForQueuedWork()

        XCTAssertEqual(try backup.retrieve(sessionId)?.points.map(\.t_ms), points.map(\.t_ms))
        let data = try Data(contentsOf: backup.pointsURL(for: sessionId))
        XCTAssertEqual(data.filter { $0 == UInt8(ascii: "\n") }.count, 240)
        XCTAssertEqual(SealedJSONLines.hasPlainLine(data), SealedJSONLines.availableManager() == nil)
    }

    /// A streamed backup of `points` whose file holds them as plain lines,
    /// queued for re-encryption.
    private func plainStreamedBackup(_ points: [RRPoint], sessionId: UUID) throws {
        try backup.appendBackup(points: points, sessionId: sessionId)
        try SealedJSONLines.encode(points, with: backup.lineEncoder, manager: nil).data.write(to: backup.pointsURL(for: sessionId))
        PendingEncryptionLedger.record(sessionId, in: .rawBackup)
    }

    /// A folder, not empty, where the index file goes, so every save throws
    /// until the test removes it.
    private func blockIndexFile() throws {
        if FileManager.default.fileExists(atPath: backup.indexFile.path) {
            try FileManager.default.removeItem(at: backup.indexFile)
        }
        try FileManager.default.createDirectory(at: backup.indexFile, withIntermediateDirectories: false)
        try Data().write(to: backup.indexFile.appendingPathComponent("blocker"))
    }

    /// The index rows on disk.
    private func storedIndex() throws -> [RawRRBackup.BackupIndex] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([RawRRBackup.BackupIndex].self, from: Data(contentsOf: backup.indexFile))
    }
}
