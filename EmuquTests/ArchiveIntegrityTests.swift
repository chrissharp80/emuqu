import CryptoKit
@testable import Emuqu
import os
import XCTest

/// Storage and archive integrity tests
final class ArchiveIntegrityTests: XCTestCase {
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
        sessionMergeModeProvider: { .defaultGap }
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
            try? archive.delete(id)
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
        let entries = archive.entries
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
        XCTAssertTrue(archive.trashedIds.contains(session.id))
        let kept = try XCTUnwrap(archive.trashedSession(session.id))
        XCTAssertEqual(kept.notes, "kept")
        XCTAssertEqual(kept.sessionType, session.sessionType)
        archive.discardTrashed(session.id)
        XCTAssertNil(archive.trashedSession(session.id))
    }

    /// Test session deletion
    func testDeletion() throws {
        let session = createTestSession()

        _ = try archive.archive(session)
        XCTAssertTrue(archive.exists(session.id))

        try archive.delete(session.id)
        XCTAssertFalse(archive.exists(session.id))

        let retrieved = try? archive.retrieve(session.id)
        XCTAssertNil(retrieved)
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
        let morningEntries = archive.entries(includingTags: [ReadingTag.morning])

        let morningIds = Set(morningEntries.map(\.sessionId))
        XCTAssertTrue(morningIds.contains(session1.id))
        XCTAssertFalse(morningIds.contains(session2.id))
        XCTAssertTrue(morningIds.contains(session3.id))
    }

    // MARK: - Concurrency Safety

    /// Test concurrent archive operations
    /// A previous implementation drove the
    /// concurrency with `DispatchQueue.concurrentPerform` and then called
    /// `wait(for:timeout: 5.0)`.
    ///
    /// That timeout was **inert**: `concurrentPerform` blocks the calling
    /// thread until every iteration returns, so control never reached
    /// `wait(for:)`. When the iterations wedged, the test did not fail after
    /// 5 seconds — it hung forever, taking the whole suite (and therefore the
    /// coverage gate and CI's `tests` job) with it. Observed at 5+ minutes
    /// before being killed, reproduced 2/2.
    ///
    /// The replacement dispatches onto a concurrent queue and bounds the wait
    /// with `DispatchGroup.wait(timeout:)`, which returns `.timedOut` instead
    /// of parking the caller forever. A regression of the original deadlock
    /// now surfaces as a red test in seconds rather than a frozen suite.
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
            XCTAssertTrue(archive.exists(session.id))
        }
    }

    /// Test concurrent reads
    func testConcurrentReads() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)
        _ = try archive.archive(session)

        let expectation = expectation(description: "Concurrent reads")
        expectation.expectedFulfillmentCount = 20
        let archive = archive

        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            do {
                let retrieved = try archive.retrieve(session.id)
                XCTAssertNotNil(retrieved)
                expectation.fulfill()
            } catch {
                XCTFail("Concurrent read failed: \(error)")
            }
        }

        wait(for: [expectation], timeout: 5.0)
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

        let count = try archive.archiveBatch(sessions)

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

        let count = try archive.archiveBatch(sessions)

        // The repeated session is skipped: ten unique sessions are written.
        XCTAssertEqual(count, 10)
        XCTAssertEqual(archive.entries.count, 10)
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
    /// decrypted plaintext. Before the fix, `Archive+Repair.swift`
    /// reassigned `jsonData = decrypted` and then hashed plaintext while
    /// the file on disk stayed as ciphertext. The next `_retrieve` read
    /// the encrypted bytes from disk, hashed them, and failed with
    /// `ArchiveError.hashMismatch`. Symptom in a beta debug log:
    /// "Hash mismatch for session <id>" persisted in the error catalog
    /// after the user ran the manual repair button.
    ///
    /// This test reproduces the scenario:
    ///   1. Archive a session with encryption ON (the production path).
    ///   2. Corrupt the index hash so repair has work to do.
    ///   3. Run `repairArchive()`.
    ///   4. `retrieve()` must succeed — i.e., the rebuilt hash must
    ///      match the (still-encrypted) bytes on disk.
    func testRepairPreservesEncryptedFileIntegrity() throws {
        // Encryption must be available for this test to be meaningful;
        // without it, the file would be plaintext and the bug doesn't apply.
        try XCTSkipUnless(EncryptionManager.shared.isAvailable, "Encryption unavailable on this test runner")

        let session = createTestSession()
        testSessionIds.append(session.id)
        let entry = try archive.archive(session)

        // Sanity: the file on disk should be encrypted (starts with the "FR" magic).
        let fileURL = archive.resolveFileURL(for: entry)
        let onDisk = try Data(contentsOf: fileURL)
        XCTAssertTrue(SessionArchive.looksEncrypted(onDisk), "Archived session should be encrypted on disk")

        // Forge a bad hash in the index file to simulate corruption that
        // repair would normally fix.
        let archiveDir = fileURL.deletingLastPathComponent()
        let indexURL = archiveDir.appendingPathComponent("index.json")
        var indexData = try Data(contentsOf: indexURL)
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
        let recovered = cold.repairArchive()
        XCTAssertGreaterThan(recovered, 0, "Repair should rebuild at least one entry")

        // Now retrieve must succeed — repair rebuilt the hash from the
        // bytes-as-stored (ciphertext), matching `_retrieve`'s integrity
        // contract.
        let retrieved = try cold.retrieve(session.id)
        XCTAssertNotNil(retrieved, "Repair should have rebuilt a usable index for the encrypted file")
        XCTAssertEqual(retrieved?.id, session.id)
    }

    /// Test detecting nearby sessions
    func testHasSessionNear() throws {
        let baseDate = Date()
        let session = createTestSession(startDate: baseDate)
        testSessionIds.append(session.id)

        _ = try archive.archive(session)

        // Should find session within tolerance
        XCTAssertTrue(archive.hasSessionNear(date: baseDate.addingTimeInterval(10 * 60), toleranceMinutes: 30))

        // Should not find session outside tolerance
        XCTAssertFalse(archive.hasSessionNear(date: baseDate.addingTimeInterval(60 * 60), toleranceMinutes: 30))
    }

    // MARK: - Edge Cases

    /// Test empty archive
    func testEmptyArchive() {
        // A fresh private directory holds no sessions and no integrity results.
        XCTAssertTrue(archive.entries.isEmpty)
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
