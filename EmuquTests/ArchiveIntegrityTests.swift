import CloudKit
import CryptoKit
@testable import Emuqu
import os
import XCTest

/// Storage and archive integrity tests
final class ArchiveIntegrityTests: XCTestCase {
    /// Capture-and-restore, not fire-and-forget.
    ///
    /// `NSTimeZone.default` is **process-global**. A class that sets it to UTC
    /// in `class setUp()` and does not put it back leaks UTC into every test
    /// class that runs after it in the same process. `LiveReadinessTests`
    /// computes "today" from `Date()` against the current calendar, so between
    /// 19:00 and midnight US-Central (when the UTC date is already tomorrow)
    /// its tests would fail.
    private static let savedDefaultTimeZone = OSAllocatedUnfairLock<TimeZone?>(initialState: nil)
    override class func setUp() {
        super.setUp()
        // Pin to UTC so the hardcoded `Date(timeIntervalSince1970:)` anchors
        // used by the sleep-merge tests sit on the same calendar day on every
        // machine.
        savedDefaultTimeZone.withLock { $0 = NSTimeZone.default }
        NSTimeZone.default = TestTimeZone.utc

        // Resolve every lazily-initialized `static let` this
        // suite can reach BEFORE any test spawns threads.
        //
        // Without this, `testConcurrentAccess` hangs the entire test suite
        // forever: `static let` in Swift is a `dispatch_once`, and the first
        // touch of `DebugLogger.shared` runs an `init()` that calls
        // `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` —
        // a blocking XPC round-trip to containermanagerd. When N threads race
        // that once-token simultaneously on a cold process, one thread runs the
        // XPC call and the rest park in `_dispatch_once_wait`. Under
        // `DispatchQueue.concurrentPerform` the *calling* thread is enrolled as
        // a worker, so it parked too — and `concurrentPerform` cannot return
        // until every iteration finishes. Deadlock, with no timeout able to
        // fire (see the note on `testConcurrentAccess`).
        //
        // Warming them here is a single-threaded first touch, so the once-token
        // is already resolved by the time any test goes concurrent. This is
        // test-harness hygiene only — production resolves these on the main
        // thread during launch, long before any concurrent archive write.
        _ = DebugLogger.shared
        _ = EncryptionManager.shared
        _ = SessionArchive.sessionDecoder
        _ = SessionArchive.lightweightSessionDecoder
        _ = SessionArchive.sessionEncoder
        _ = SessionArchive.indexEncoder
    }

    override class func tearDown() {
        if let saved = savedDefaultTimeZone.withLock({ $0 }) { NSTimeZone.default = saved }
        savedDefaultTimeZone.withLock { $0 = nil }
        super.tearDown()
    }

    // `lazy` rather than assigned in `setUp`. The merge mode is injected
    // deliberately: a plain `SessionArchive()` reads
    // `SettingsManager.shared.settings.sessionMergeMode`, which is device-local
    // and can be `.off` on a test runner — that made
    // `testSameNightDuplicatePrevention` fail on some machines and not others.
    // The merge gap is injected for the same reason: a custom gap on the
    // runner would change which recordings count as one sleep.
    //
    // The directory is private to each test, so no other suite's sessions
    // (or a killed run's residue) are in it.
    let archiveDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ArchiveIntegrityTests-\(UUID().uuidString)", isDirectory: true)
    lazy var archive = SessionArchive(
        directory: archiveDirectory,
        sleepScheduleProvider: {
            SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0)
        },
        sessionMergeModeProvider: { .defaultGap },
        mergeGapProvider: { 4.5 * 3600 }
    )
    var testSessionIds: [UUID] = []
    var sessionCounter = 0

    override func setUp() {
        super.setUp()
        testSessionIds = []
        sessionCounter = 0
    }

    override func tearDown() {
        // Clean up test sessions
        for id in testSessionIds {
            _ = try? archive.delete(id)
        }
        testSessionIds = []
        try? FileManager.default.removeItem(at: archiveDirectory)
        super.tearDown()
    }

    // MARK: - Basic Archive Operations

    /// Test archiving and retrieving a session
    func testArchiveAndRetrieve() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)

        // Archive the session
        let entry = try archive.archive(session)

        XCTAssertEqual(entry.sessionId, session.id)
        XCTAssertNotNil(entry.fileHash)

        // Retrieve it back
        let retrieved = try archive.retrieve(session.id)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, session.id)
        XCTAssertEqual(
            try XCTUnwrap(retrieved?.startDate.timeIntervalSince1970),
            session.startDate.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    /// Test SHA256 hash verification
    func testHashVerification() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)

        let entry = try archive.archive(session)

        // Hash should be 64 hex characters (256 bits)
        XCTAssertEqual(entry.fileHash.count, 64)

        // Retrieve should verify hash automatically
        let retrieved = try archive.retrieve(session.id)
        XCTAssertNotNil(retrieved)
    }

    /// Test duplicate session handling
    func testDuplicateHandling() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)

        // Archive twice
        _ = try archive.archive(session)
        _ = try archive.archive(session)

        // Should only have one entry
        let entries = archive.store.entries
        let matchingEntries = entries.filter { $0.sessionId == session.id }
        XCTAssertEqual(matchingEntries.count, 1, "Should not create duplicate entries")
    }

    /// CloudKit uploads each id once, so a user's edit has to ask for another
    /// upload. A first write and a routine rewrite must not: a second device
    /// rewriting its older copy would otherwise replace the newer one in
    /// iCloud.
    func testOnlyAnEditAsksForReupload() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)
        let requested = OSAllocatedUnfairLock<[Set<UUID>]>(initialState: [])
        let sessionId = session.id
        let token = NotificationCenter.default.addObserver(
            forName: .flowRecoveryArchiveSessionsNeedReupload, object: nil, queue: nil
        ) { note in
            guard let ids = note.userInfo?["sessionIds"] as? Set<UUID>, ids.contains(sessionId) else { return }
            requested.withLock { $0.append(ids) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = try archive.archive(session)
        _ = try archive.archive(session)
        XCTAssertTrue(requested.withLock { $0.isEmpty }, "a first write and a routine rewrite stay local")
        _ = try archive.archive(session, skipSameNightMerge: false, requestingReupload: true)
        XCTAssertEqual(requested.withLock { $0 }, [[session.id]])
        try archive.update(session.id, requestingReupload: false) { $0.notes = "stamp" }
        XCTAssertEqual(requested.withLock { $0 }.count, 1, "a routine update stays local")
        try archive.update(session.id) { $0.notes = "edited" }
        XCTAssertEqual(requested.withLock { $0 }.count, 2)
    }

    /// An edit that asks for a re-upload is stamped with its time, in the file
    /// and the index, so another device holding the session can tell its copy
    /// is older. Routine writes keep the stamp they had.
    func testOnlyAnEditStampsModificationTime() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)
        _ = try archive.archive(session)
        XCTAssertNil(try XCTUnwrap(archive.retrieve(session.id)).modifiedAt, "a first write is not an edit")

        try archive.update(session.id) { $0.notes = "edited" }
        let stamped = try XCTUnwrap(try XCTUnwrap(archive.retrieve(session.id)).modifiedAt)
        XCTAssertEqual(stamped.timeIntervalSince1970, stamped.timeIntervalSince1970.rounded(.down))
        XCTAssertEqual(archive.entryById(session.id)?.modifiedAt, stamped)

        try archive.update(session.id, requestingReupload: false) { $0.notes = "routine" }
        XCTAssertEqual(try XCTUnwrap(archive.retrieve(session.id)).modifiedAt, stamped)
        XCTAssertEqual(archive.entryById(session.id)?.modifiedAt, stamped)
    }

    /// Deleting keeps the session's file, so Restore puts back what was
    /// deleted (notes, tags, type) instead of rebuilding from raw beats.
    func testDeletedSessionIsKeptWholeInTheTrash() throws {
        var session = createTestSession()
        session.notes = "kept"
        testSessionIds.append(session.id)
        _ = try archive.archive(session)
        try archive.delete(session.id)
        XCTAssertTrue(archive.store.trashedIds.contains(session.id))
        let kept = try XCTUnwrap(archive.store.trashedSession(session.id))
        XCTAssertEqual(kept.notes, "kept")
        XCTAssertEqual(kept.sessionType, session.sessionType)
        archive.store.discardTrashed(session.id)
        XCTAssertNil(archive.store.trashedSession(session.id))
    }

    /// Test session deletion
    func testDeletion() throws {
        let session = createTestSession()

        _ = try archive.archive(session)
        XCTAssertTrue(archive.store.exists(session.id))

        try archive.delete(session.id)
        XCTAssertFalse(archive.store.exists(session.id))

        let retrieved = try? archive.retrieve(session.id)
        XCTAssertNil(retrieved)
    }

    /// A session the Trash cannot take (here a file stands where its folder
    /// goes) stays archived and the delete throws. The file was deleted
    /// instead, losing the copy a restore brings back.
    func testADeleteTheTrashCannotTakeLeavesTheSessionArchived() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)
        _ = try archive.archive(session)
        XCTAssertTrue(FileManager.default.createFile(atPath: archive.store.trashDirectory.path, contents: Data()))

        XCTAssertThrowsError(try archive.delete(session.id))

        XCTAssertTrue(archive.store.exists(session.id))
        XCTAssertFalse(archive.store.wasIntentionallyDeleted(session.id))
        XCTAssertEqual(try archive.retrieve(session.id)?.id, session.id)
    }

    /// An entry whose file is already gone has nothing for the Trash to keep:
    /// it is deleted and tombstoned rather than refused on every attempt.
    func testASessionWhoseFileIsGoneCanStillBeDeleted() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)
        _ = try archive.archive(session)
        try FileManager.default.removeItem(at: archiveDirectory.appendingPathComponent("\(session.id.uuidString).json"))

        try archive.delete(session.id)

        XCTAssertFalse(archive.store.exists(session.id))
        XCTAssertTrue(archive.store.wasIntentionallyDeleted(session.id))
    }

    /// A deletion made on another device removes the file without the Trash,
    /// so a Trash that cannot take it does not stop the deletion.
    func testADeletionFromAnotherDeviceDoesNotNeedTheTrash() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)
        _ = try archive.archive(session)
        XCTAssertTrue(FileManager.default.createFile(atPath: archive.store.trashDirectory.path, contents: Data()))

        try archive.deleteWithoutTrash(session.id)

        XCTAssertFalse(archive.store.exists(session.id))
        XCTAssertTrue(archive.store.wasIntentionallyDeleted(session.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveDirectory.appendingPathComponent("\(session.id.uuidString).json").path))
    }

    /// A tombstoned session's file a failed delete left in the archive folder
    /// is removed with its Trash copy: once the tombstone is forgotten the
    /// orphan scan would adopt it back. A file of an id that is not
    /// tombstoned may be a live write, and an archived session's is live: both
    /// are kept.
    func testDiscardingTheTrashRemovesOnlyALeftoverFileOfATombstonedSession() throws {
        let kept = createTestSession()
        testSessionIds.append(kept.id)
        _ = try archive.archive(kept)
        let deletedId = UUID()
        let untombstonedId = UUID()
        try archive.store.markAsDeleted(deletedId)
        defer { attempt("test.forgetDeleted") { try archive.store.unmarkAsDeleted(deletedId) } }
        let leftover = archiveDirectory.appendingPathComponent("\(deletedId.uuidString).json")
        let notTombstoned = archiveDirectory.appendingPathComponent("\(untombstonedId.uuidString).json")
        try Data("{}".utf8).write(to: leftover)
        try Data("{}".utf8).write(to: notTombstoned)

        archive.store.discardTrashed(deletedId)
        archive.store.discardTrashed(untombstonedId)
        archive.store.discardTrashed(kept.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notTombstoned.path))
        XCTAssertEqual(try archive.retrieve(kept.id)?.id, kept.id)
    }

    /// While the index has not loaded, a tombstoned id's file may still be
    /// one the index lists: it is kept.
    func testDiscardingTheTrashKeepsALeftoverFileWhileTheIndexIsUnread() throws {
        let deletedId = UUID()
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        try Data("not an index".utf8).write(to: archiveDirectory.appendingPathComponent("index.json"))
        try JSONEncoder().encode([deletedId.uuidString]).write(to: archiveDirectory.appendingPathComponent("deleted.json"))
        let leftover = archiveDirectory.appendingPathComponent("\(deletedId.uuidString).json")
        try Data("{}".utf8).write(to: leftover)

        archive.store.discardTrashed(deletedId)

        XCTAssertFalse(archive.hasCompleteIndex)
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path))
    }

    // MARK: - Unreadable index files

    /// An index that does not decode and cannot be moved aside is left as it
    /// is: the next save throws instead of writing a near-empty list over it.
    func testAnUndecodableIndexThatCannotBeSetAsideIsNotWrittenOver() throws {
        let indexFile = archiveDirectory.appendingPathComponent("index.json")
        let unreadable = Data("not an index".utf8)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        try unreadable.write(to: indexFile)
        try occupySetAsideNames(of: indexFile)

        XCTAssertThrowsError(try archive.archive(createTestSession()))

        XCTAssertEqual(try Data(contentsOf: indexFile), unreadable)
        XCTAssertFalse(archive.hasCompleteIndex)
    }

    /// The same for the deleted list, whose loss let iCloud bring deleted
    /// sessions back.
    func testAnUndecodableDeletedListThatCannotBeSetAsideIsNotWrittenOver() throws {
        let deletedFile = archiveDirectory.appendingPathComponent("deleted.json")
        let unreadable = Data("not a list".utf8)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        try unreadable.write(to: deletedFile)
        try occupySetAsideNames(of: deletedFile)

        XCTAssertThrowsError(try archive.store.unmarkAsDeleted(UUID()))

        XCTAssertEqual(try Data(contentsOf: deletedFile), unreadable)
    }

    /// A deletion mark that cannot be saved is taken back out of memory, so a
    /// lost session the user tried to dismiss is still offered for recovery.
    func testADeletionMarkThatCannotBeSavedIsNotKept() throws {
        let id = UUID()
        // Built (and its directory made) before the directory is locked.
        XCTAssertTrue(archive.store.entries.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: archiveDirectory.path)
        defer {
            attempt("test.unlockArchiveDirectory") {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: archiveDirectory.path)
            }
        }

        XCTAssertThrowsError(try archive.store.markAsDeleted(id))

        XCTAssertFalse(archive.store.wasIntentionallyDeleted(id))
    }

    /// Puts a folder at every name the set-aside of `file` can take from a
    /// second ago to half a minute ahead, so its move fails.
    private func occupySetAsideNames(of file: URL) throws {
        let now = Int(Date().timeIntervalSince1970)
        for second in (now - 1) ... (now + 30) {
            let name = "\(file.lastPathComponent).unreadable_\(second)"
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent().appendingPathComponent(name), withIntermediateDirectories: false
            )
        }
    }

    // MARK: - Tag and Notes Management

    /// Test updating tags
    func testUpdateTags() throws {
        var session = createTestSession()
        session.tags = []
        testSessionIds.append(session.id)

        _ = try archive.archive(session)

        // Update with tags
        let newTags = [ReadingTag.morning, ReadingTag.stressed]
        try archive.updateTags(session.id, tags: newTags, notes: "Test note")

        let retrieved = try archive.retrieve(session.id)
        XCTAssertEqual(retrieved?.tags.count, 2)
        XCTAssertEqual(retrieved?.notes, "Test note")
    }

    /// Test filtering by tags
    func testTagFiltering() throws {
        // Create sessions with different tags
        var session1 = createTestSession()
        session1.tags = [ReadingTag.morning]
        testSessionIds.append(session1.id)

        var session2 = createTestSession()
        session2.tags = [ReadingTag.evening]
        testSessionIds.append(session2.id)

        var session3 = createTestSession()
        session3.tags = [ReadingTag.morning, ReadingTag.stressed]
        testSessionIds.append(session3.id)

        _ = try archive.archive(session1)
        _ = try archive.archive(session2)
        _ = try archive.archive(session3)

        // Filter for morning tag
        let morningEntries = archive.store.entries(includingTags: [ReadingTag.morning])

        let morningIds = Set(morningEntries.map(\.sessionId))
        XCTAssertTrue(morningIds.contains(session1.id))
        XCTAssertFalse(morningIds.contains(session2.id))
        XCTAssertTrue(morningIds.contains(session3.id))
    }

    // MARK: - Concurrency Safety

    /// Test concurrent archive operations
    ///
    /// The work dispatches onto a concurrent queue and bounds the wait with
    /// `DispatchGroup.wait(timeout:)`, which returns `.timedOut` instead of
    /// parking the caller forever. `DispatchQueue.concurrentPerform` would not
    /// do: it blocks the calling thread until every iteration returns, so a
    /// `wait(for:timeout:)` after it never runs and a wedged iteration hangs
    /// the whole suite (and the coverage gate and CI's `tests` job) instead of
    /// failing. A deadlock here surfaces as a red test in seconds.
    ///
    /// Errors are collected under a lock and asserted on the test thread —
    /// `XCTFail` from a worker thread is not guaranteed to be attributed to
    /// the right test.
    func testConcurrentAccess() {
        let sessions = (0 ..< 10).map { _ in createTestSession() }
        testSessionIds.append(contentsOf: sessions.map(\.id))

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.concurrent.archive", attributes: .concurrent)
        let failures = OSAllocatedUnfairLock<[String]>(initialState: [])
        let archive = archive

        for session in sessions {
            queue.async(group: group) {
                do {
                    _ = try archive.archive(session)
                } catch {
                    failures.withLock { $0.append("\(session.id.uuidString.prefix(8)): \(error)") }
                }
            }
        }

        // Real, enforceable bound. `.timedOut` means the archive path wedged.
        // Fail hard — a wedge is the exact regression this test exists to catch,
        // and skipping would hide it.
        if group.wait(timeout: .now() + 30) == .timedOut {
            XCTFail(
                "Concurrent archive did not complete within 30s — the archive write path is wedged. "
                    + "Capture with: sample $(pgrep -f EmuquTests) 3"
            )
            return
        }

        let collected = failures.withLock { $0 }
        XCTAssertTrue(collected.isEmpty, "Concurrent archive failed: \(collected.joined(separator: "; "))")

        for session in sessions {
            XCTAssertTrue(archive.store.exists(session.id))
        }
    }

    /// Twenty concurrent reads of one archived session all return it.
    ///
    /// Same shape as `testConcurrentAccess`, for the same reasons: the reads
    /// run on a concurrent queue and the wait is bounded with
    /// `DispatchGroup.wait(timeout:)`, so a wedged `retrieve` fails the test
    /// instead of hanging the suite, and failures are collected under a lock
    /// and asserted on the test thread.
    func testConcurrentReads() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)
        _ = try archive.archive(session)

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.concurrent.reads", attributes: .concurrent)
        let failures = OSAllocatedUnfairLock<[String]>(initialState: [])
        let archive = archive
        let sessionId = session.id

        for index in 0 ..< 20 {
            queue.async(group: group) {
                do {
                    if try archive.retrieve(sessionId) == nil {
                        failures.withLock { $0.append("read \(index): session not found") }
                    }
                } catch {
                    failures.withLock { $0.append("read \(index): \(error)") }
                }
            }
        }

        if group.wait(timeout: .now() + 30) == .timedOut {
            XCTFail("Concurrent reads did not complete within 30s — the archive read path is wedged.")
            return
        }

        let collected = failures.withLock { $0 }
        XCTAssertTrue(collected.isEmpty, "Concurrent reads failed: \(collected.joined(separator: "; "))")
    }

    // MARK: - Batch Operations

    /// Test batch archiving
    func testBatchArchive() throws {
        // Create sessions with well-separated start times to avoid "near duplicate" detection
        let baseDate = Date().addingTimeInterval(-86400 * 7) // 1 week ago
        let sessions = (0 ..< 20).map { i in
            // Space sessions 2 hours apart to avoid hasSessionNear() conflicts
            createTestSession(startDate: baseDate.addingTimeInterval(Double(i) * 2 * 3600))
        }
        testSessionIds.append(contentsOf: sessions.map(\.id))

        let count = try archive.store.archiveBatch(sessions)

        XCTAssertEqual(count, sessions.count, "Should archive all \(sessions.count) sessions. Got \(count)")

        // All should be retrievable
        for session in sessions {
            let retrieved = try archive.retrieve(session.id)
            XCTAssertNotNil(retrieved, "Should retrieve session \(session.id)")
        }
    }

    /// Test batch archive with duplicates
    func testBatchArchiveWithDuplicates() throws {
        var sessions = (0 ..< 10).map { _ in createTestSession() }

        // Add a duplicate (same session twice)
        sessions.append(sessions[0])

        testSessionIds.append(contentsOf: Set(sessions.map(\.id)))

        let count = try archive.store.archiveBatch(sessions)

        // The repeated session is skipped: ten unique sessions are written.
        XCTAssertEqual(count, 10)
        XCTAssertEqual(archive.store.entries.count, 10)
    }

    // MARK: - Integrity Verification

    /// Test integrity check
    func testIntegrityVerification() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)

        _ = try archive.archive(session)

        let results = archive.verifyIntegrity()

        XCTAssertNotNil(results[session.id])
        XCTAssertTrue(
            try XCTUnwrap(results[session.id]),
            "Integrity check should pass for valid session"
        )
    }

    /// Repair must hash the bytes-as-stored, not the
    /// decrypted plaintext. Hashing plaintext while the file on disk stays
    /// ciphertext makes the next `_retrieve` read the encrypted bytes, hash
    /// them, and fail with `ArchiveError.hashMismatch`, leaving "Hash mismatch
    /// for session <id>" in the error catalog after the manual repair button.
    ///
    /// This test reproduces the scenario:
    ///   1. Archive a session with encryption ON (the production path).
    ///   2. Corrupt the index hash so repair has work to do.
    ///   3. Run `repairArchive()`.
    ///   4. `retrieve()` must succeed — i.e., the rebuilt hash must
    ///      match the (still-encrypted) bytes on disk.
    func testRepairPreservesEncryptedFileIntegrity() throws {
        // Encryption must be available for this test to be meaningful;
        // without it, the file would be plaintext and the case doesn't apply.
        try XCTSkipUnless(EncryptionManager.shared.isAvailable, "Encryption unavailable on this test runner")

        let session = createTestSession()
        testSessionIds.append(session.id)
        let entry = try archive.archive(session)

        // Sanity: the file on disk should be encrypted (starts with the "FR" magic).
        let fileURL = archive.resolveFileURL(for: entry)
        let onDisk = try Data(contentsOf: fileURL)
        XCTAssertTrue(ArchiveStore.looksEncrypted(onDisk), "Archived session should be encrypted on disk")

        // Forge a bad hash in the index file to simulate corruption that
        // repair would normally fix.
        let archiveDir = fileURL.deletingLastPathComponent()
        let indexURL = archiveDir.appendingPathComponent("index.json")
        var indexData = try SessionArchive.indexJSON(Data(contentsOf: indexURL))
        if let str = String(data: indexData, encoding: .utf8) {
            let mutated = str.replacingOccurrences(of: entry.fileHash, with: String(repeating: "0", count: 64))
            indexData = Data(mutated.utf8)
            try indexData.write(to: indexURL, options: .atomic)
        }

        // Fresh archive picks up the corrupted index. `retrieve` should
        // fail before repair.
        let cold = SessionArchive(
            directory: archiveDirectory,
            sleepScheduleProvider: { SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0) },
            sessionMergeModeProvider: { .defaultGap }
        )
        XCTAssertThrowsError(try cold.retrieve(session.id), "Corrupt-hash entry must throw on retrieve")

        // Run repair.
        let recovered = try cold.repairArchive()
        XCTAssertGreaterThan(recovered, 0, "Repair should rebuild at least one entry")

        // Now retrieve must succeed — repair rebuilt the hash from the
        // bytes-as-stored (ciphertext), matching `_retrieve`'s integrity
        // contract.
        let retrieved = try cold.retrieve(session.id)
        XCTAssertNotNil(retrieved, "Repair should have rebuilt a usable index for the encrypted file")
        XCTAssertEqual(retrieved?.id, session.id)
    }

    /// A repair whose rebuilt index cannot be written throws, so the
    /// diagnostics page reports the failure instead of "Repair complete".
    func testRepairThrowsWhenTheRebuiltIndexCannotBeSaved() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)
        _ = try archive.archive(session)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: archiveDirectory.path)
        defer {
            attempt("test.unlockArchiveDirectory") {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: archiveDirectory.path)
            }
        }

        XCTAssertThrowsError(try archive.repairArchive())
    }

    /// Test detecting nearby sessions
    func testHasSessionNear() throws {
        let baseDate = Date()
        let session = createTestSession(startDate: baseDate)
        testSessionIds.append(session.id)

        _ = try archive.archive(session)

        // Should find session within tolerance
        XCTAssertTrue(archive.store.hasSessionNear(date: baseDate.addingTimeInterval(10 * 60), toleranceMinutes: 30))

        // Should not find session outside tolerance
        XCTAssertFalse(archive.store.hasSessionNear(date: baseDate.addingTimeInterval(60 * 60), toleranceMinutes: 30))
    }

    // MARK: - Edge Cases

    /// Test empty archive
    func testEmptyArchive() {
        // A fresh private directory holds no sessions and no integrity results.
        XCTAssertTrue(archive.store.entries.isEmpty)
        XCTAssertTrue(archive.verifyIntegrity().isEmpty)
    }

    /// Test retrieving non-existent session
    func testRetrieveNonExistent() throws {
        let fakeId = UUID()
        let retrieved = try archive.retrieve(fakeId)
        XCTAssertNil(retrieved)
    }

    /// Test deleting non-existent session
    func testDeleteNonExistent() throws {
        let fakeId = UUID()
        XCTAssertNoThrow(try archive.delete(fakeId))
    }
}

// MARK: - Deleting from the Trash for good

extension ArchiveIntegrityTests {
    /// A Trash file that will not go keeps the session in the Trash with its
    /// deletion mark: it is neither forgotten nor left for a pull to bring back.
    @MainActor
    func testAFailedTrashRemovalKeepsTheDeletionMark() throws {
        let (service, _) = trashService()
        let session = createTestSession()
        _ = try archive.archive(session)
        try archive.delete(session.id)
        let trash = archive.store.trashDirectory
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: trash.path)
        defer { attempt("test.unlockTrash") { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trash.path) } }

        XCTAssertFalse(service.permanentlyDelete(session.id))

        XCTAssertTrue(archive.store.wasIntentionallyDeleted(session.id))
        XCTAssertTrue(archive.store.trashedIds.contains(session.id))
        XCTAssertFalse(ForgottenSessions.ids.contains(session.id))
    }

    /// Deleting forever keeps the deletion mark until iCloud confirms the
    /// deletion, so the full sync keeps sending it; once confirmed, the mark
    /// is dropped.
    @MainActor
    func testATombstoneIsNotForgottenBeforeICloudConfirmsIt() throws {
        let (service, _) = trashService()
        let sync = CloudKitSyncManager.shared
        let wasZoneCreated = sync.zoneCreated
        let key = CloudDeletionCoordinator.confirmedTombstonesKey
        let confirmed = UserDefaults.standard.dictionary(forKey: key)
        sync.zoneCreated = true
        defer {
            sync.zoneCreated = wasZoneCreated
            UserDefaults.standard.set(confirmed, forKey: key)
        }
        let session = createTestSession()
        _ = try archive.archive(session)
        try archive.delete(session.id)

        XCTAssertTrue(service.permanentlyDelete(session.id))
        XCTAssertTrue(archive.store.wasIntentionallyDeleted(session.id), "forgotten before iCloud confirmed the deletion")
        XCTAssertTrue(ForgottenSessions.ids.contains(session.id))

        UserDefaults.standard.set([session.id.uuidString: Date().timeIntervalSince1970], forKey: key)
        XCTAssertTrue(service.permanentlyDelete(session.id))
        XCTAssertFalse(archive.store.wasIntentionallyDeleted(session.id))
    }

    /// One session removed whose Apple Health samples would not go, and one
    /// the Trash could not remove: both counted, and Health is asked only
    /// about the session that was removed.
    @MainActor
    func testTheTrashOutcomeCountsWhatWasNotRemoved() async throws {
        let (service, _) = trashService()
        let removable = createTestSession()
        _ = try archive.archive(removable)
        try archive.delete(removable.id)
        // A file of an id the archive neither lists nor tombstones may be a
        // live write, so it is never removed and the id stays.
        let stuck = UUID()
        try Data("{}".utf8).write(to: archiveDirectory.appendingPathComponent("\(stuck.uuidString).json"))
        var askedHealth: [UUID] = []

        let outcome = await service.permanentlyDelete([removable.id, stuck]) { id, _ in
            askedHealth.append(id)
            return false
        }

        XCTAssertEqual(outcome, TrashDeletionOutcome(kept: 1, healthSamplesKept: 1))
        XCTAssertEqual(askedHealth, [removable.id])
    }

    /// The route a workout filed in the trail history goes with it; another
    /// workout's trail and a Get Me Back trail stay.
    @MainActor
    func testTheBreadcrumbTrailIsRemovedWithItsWorkout() throws {
        let (service, trails) = trashService()
        let workout = createTestSession()
        _ = try archive.archive(workout)
        try archive.delete(workout.id)
        let other = UUID()
        trails.archive(trail(sessionId: workout.id))
        trails.archive(trail(sessionId: other))
        trails.archive(trail(sessionId: nil))

        XCTAssertTrue(service.permanentlyDelete(workout.id))

        let left = trails.loadArchive()
        XCTAssertEqual(left.count, 2)
        XCTAssertFalse(left.contains { $0.sessionId == workout.id })
        XCTAssertTrue(left.contains { $0.sessionId == other })
    }

    /// A session deleted forever is not brought back by a pull, even when
    /// iCloud still holds a live copy of it. The same record, once the
    /// session is not on the deleted-forever list, is imported: so the
    /// refusal is the list's, not a record the pull could not read. The pull
    /// runs on a sync manager of the test's own over this test's archive,
    /// never the host's.
    @MainActor
    func testAForgottenSessionIsNotReimportedOnPull() async throws {
        let syncDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveIntegritySync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDirectory, withIntermediateDirectories: true)
        let host = HostDefaults.setAside(HostDefaults.cloudSyncBookkeeping)
        defer {
            host.restore()
            attempt("test.removeSyncDirectory") { try FileManager.default.removeItem(at: syncDirectory) }
        }
        let manager = CloudKitSyncManager.isolated(archive: archive, directory: syncDirectory)
        let session = createTestSession()
        testSessionIds.append(session.id)
        let record = try liveRecord(of: session)

        let outcome = await manager.pull.processRemoteRecord(record, forgotten: [session.id])

        XCTAssertEqual(outcome.new, 0)
        XCTAssertNil(outcome.backfillId)
        XCTAssertFalse(archive.store.exists(session.id))
        XCTAssertFalse(manager.state.uploadedSessionIds.contains(session.id))

        let imported = await manager.pull.processRemoteRecord(record, forgotten: [])

        XCTAssertEqual(imported.new, 1, "the record itself could not be imported")
        XCTAssertTrue(archive.store.exists(session.id))
    }

    // MARK: Sealed index

    /// The index holds health values, so it is sealed on disk; it reads back.
    func testTheIndexIsSealedAndReadsBack() throws {
        var session = createTestSession()
        session.notes = "slept badly"
        testSessionIds.append(session.id)
        _ = try archive.archive(session)

        let stored = try Data(contentsOf: archiveDirectory.appendingPathComponent("index.json"))
        XCTAssertTrue(ArchiveStore.looksEncrypted(stored))
        XCTAssertNil(stored.range(of: Data("slept badly".utf8)))
        XCTAssertEqual(reopenedArchive().entryById(session.id)?.notes, "slept badly")
    }

    /// An index written as plain JSON, by a build that did not seal it,
    /// still loads, and the next save seals it.
    func testAPlainIndexStillLoadsAndIsSealedOnTheNextSave() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)
        _ = try archive.archive(session)
        let indexURL = archiveDirectory.appendingPathComponent("index.json")
        try SessionArchive.indexEncoder.encode(archive.store.entries).write(to: indexURL)

        let reopened = reopenedArchive()
        XCTAssertNotNil(reopened.entryById(session.id))
        _ = try reopened.archive(createTestSession())

        XCTAssertTrue(ArchiveStore.looksEncrypted(try Data(contentsOf: indexURL)))
        XCTAssertNotNil(reopenedArchive().entryById(session.id))
    }

    /// An index on disk as plain JSON, as written while the key was
    /// unavailable, is sealed by the launch repair without any other save.
    func testThePlainIndexIsResealedOnceTheKeyIsBack() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)
        _ = try archive.archive(session)
        let indexURL = archiveDirectory.appendingPathComponent("index.json")
        try SessionArchive.indexEncoder.encode(archive.store.entries).write(to: indexURL)

        let reopened = reopenedArchive()
        reopened.resealPlainIndexIfNeeded()

        XCTAssertTrue(ArchiveStore.looksEncrypted(try Data(contentsOf: indexURL)))
        XCTAssertNotNil(reopenedArchive().entryById(session.id))
    }

    // MARK: Helpers

    /// A recovery service over this test's archive, with the trail history
    /// and the raw backups in this test's folder. The deleted-forever list is
    /// put back afterwards.
    @MainActor
    private func trashService() -> (SessionRecoveryService, BreadcrumbStore) {
        let trails = BreadcrumbStore(fileURL: archiveDirectory.appendingPathComponent("Breadcrumbs/active.json"))
        let forgotten = UserDefaults.standard.stringArray(forKey: ForgottenSessions.defaultsKey)
        addTeardownBlock {
            UserDefaults.standard.set(forgotten, forKey: ForgottenSessions.defaultsKey)
        }
        let service = SessionRecoveryService(
            archive: archive,
            rawBackup: RawRRBackup(directory: archiveDirectory.appendingPathComponent(AppConfig.backupDirectoryName, isDirectory: true)),
            artifactDetector: ArtifactDetector(),
            windowSelector: WindowSelector(), cloudSyncManager: .shared,
            baselineTracker: BaselineTracker(baselineFile: archiveDirectory.appendingPathComponent("HRVBaseline.json")),
            settingsManager: .shared, breadcrumbStore: trails
        )
        return (service, trails)
    }

    private func trail(sessionId: UUID?) -> BreadcrumbTrail {
        BreadcrumbTrail(
            startedAt: Date(), origin: nil, fixes: [], label: nil, resolvedOriginLabel: nil,
            isWorkoutTrack: sessionId != nil, sessionId: sessionId
        )
    }

    /// The iCloud record a device that still held the session would upload.
    private func liveRecord(of session: HRVSession) throws -> CKRecord {
        standInForConfirmedICloudAccount()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try CloudPayloadCodec.sealForUpload(DataCompression.compress(encoder.encode(session)))
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let file = archiveDirectory.appendingPathComponent("\(session.id.uuidString).asset")
        try payload.write(to: file)
        let zone = CKRecordZone.ID(zoneName: "ArchiveIntegrityTests", ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: "HRVSession", recordID: CKRecord.ID(recordName: session.id.uuidString, zoneID: zone))
        record["sessionData"] = CKAsset(fileURL: file)
        return record
    }
}
