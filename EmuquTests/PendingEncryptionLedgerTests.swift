@testable import Emuqu
import XCTest

/// Pins the fail-closed behaviour of sensitive storage.
///
/// `SessionArchive+SessionCodec` and `RawRRBackup` both wrote
/// plaintext JSON whenever `EncryptionManager` was unavailable or `encrypt`
/// threw — same file path, same protection class, and in one of the three sites
/// no log line at all. Application-layer confidentiality on health data failed
/// OPEN, at precisely the moment the controls were already failing.
///
/// Refusing the write is not the fix. The realistic trigger is a background
/// write before the first unlock after a reboot, which is exactly when a
/// completed overnight recording is archived — throwing there loses a night the
/// user cannot regenerate, to protect a file that its protection class
/// (`.completeFileProtectionUnlessOpen`) already makes unreadable while locked.
///
/// So the contract these tests hold is narrower and stronger than "never write
/// plaintext":
///
///   1. Unencrypted bytes are written under a stricter protection class than
///      encrypted ones: complete-unless-open, unreadable once closed while locked.
///   2. Every unencrypted write is recorded, so it can be repaired.
///   3. The record survives a relaunch, because the repair runs at next launch.
///   4. Re-encryption clears the record; a purge clears all of them.
///
/// Fault injection proving no plaintext file is created on every failure path
/// would be the ideal. What is proven here is the reachable half — the format
/// decision and the ledger — because forcing a genuine Keychain outage needs a
/// device, and a test that fakes `EncryptionManager` would be testing the fake.
final class PendingEncryptionLedgerTests: XCTestCase {
    private static let stores = PendingEncryptionLedger.Store.allCases

    /// The ledger is process-global (UserDefaults plus its file copy) and the
    /// host app's own entries are in it: the only record that a file of the
    /// host's was written in plaintext. The tests never empty it. Each works
    /// on fresh ids, asserts only about those, and takes them out again in
    /// `tearDown`, so the host's entries are never removed, not even for the
    /// length of a test that is killed. The one exception is the purge test,
    /// which clears the whole ledger and puts the host's entries straight
    /// back.
    private var ownIds: [(UUID, PendingEncryptionLedger.Store)] = []

    /// A fresh id, removed from `store` after the test.
    private func newId(in store: PendingEncryptionLedger.Store = .session) -> UUID {
        let id = UUID()
        ownIds.append((id, store))
        return id
    }

    override func tearDown() {
        for (id, store) in ownIds {
            PendingEncryptionLedger.clear(id, in: store)
        }
        ownIds = []
        PendingEncryptionLedger.waitForPendingWrites()
        super.tearDown()
    }

    // MARK: - Protection class

    /// An unencrypted body is not written with the same options as an
    /// encrypted one: it gets complete-unless-open, which can be created while
    /// the device is locked (when the fallback runs) and cannot be reopened
    /// until it is unlocked.
    func testUnencryptedWritesUseCompleteUnlessOpenProtection() {
        let id = newId()
        let encrypted = archiveWriteOptions(for: .encrypted, sessionID: id)
        let plaintext = archiveWriteOptions(for: .plaintextPendingEncryption, sessionID: id)

        XCTAssertTrue(plaintext.contains(.completeFileProtectionUnlessOpen),
                      "Unencrypted health data must be writable while locked and unreadable once closed until unlock")
        XCTAssertFalse(plaintext.contains(.completeFileProtectionUntilFirstUserAuthentication),
                       "Until-first-unlock is the weaker class and must not be used for plaintext")
        XCTAssertTrue(encrypted.contains(.completeFileProtectionUntilFirstUserAuthentication))
        XCTAssertNotEqual(encrypted, plaintext, "The two formats must not write identically")
    }

    /// Both formats stay atomic: a torn write is a separate failure mode that
    /// neither format may introduce.
    func testBothFormatsWriteAtomically() {
        let id = newId()
        XCTAssertTrue(archiveWriteOptions(for: .encrypted, sessionID: id).contains(.atomic))
        XCTAssertTrue(archiveWriteOptions(for: .plaintextPendingEncryption, sessionID: id).contains(.atomic))
    }

    // MARK: - The ledger records what needs repair

    /// Choosing the plaintext options is what enrols a session for repair. If
    /// these two ever came apart, a file would be written unencrypted and never
    /// fixed — silent, permanent, and exactly the original defect.
    func testChoosingPlaintextOptionsRecordsTheSession() {
        let id = newId()
        XCTAssertFalse(PendingEncryptionLedger.pending.contains(id))
        _ = archiveWriteOptions(for: .plaintextPendingEncryption, sessionID: id)
        XCTAssertTrue(PendingEncryptionLedger.pending.contains(id))
    }

    /// And an encrypted write clears it, which is how the repair pass finishes.
    func testChoosingEncryptedOptionsClearsTheSession() {
        let id = newId()
        _ = archiveWriteOptions(for: .plaintextPendingEncryption, sessionID: id)
        XCTAssertTrue(PendingEncryptionLedger.pending.contains(id))
        _ = archiveWriteOptions(for: .encrypted, sessionID: id)
        XCTAssertFalse(PendingEncryptionLedger.pending.contains(id))
    }

    func testRecordingIsIdempotent() {
        let id = newId()
        PendingEncryptionLedger.record(id)
        PendingEncryptionLedger.record(id)
        XCTAssertEqual(PendingEncryptionLedger.pending.filter { $0 == id }.count, 1)
    }

    func testClearingAnUnknownSessionIsHarmless() {
        let before = PendingEncryptionLedger.pending
        let known = newId()
        PendingEncryptionLedger.record(known)
        PendingEncryptionLedger.clear(UUID())
        XCTAssertEqual(PendingEncryptionLedger.pending, before.union([known]))
    }

    // MARK: - Survives the gap the repair has to cross

    /// The fallback happens in a background write before first unlock; the
    /// repair runs at the next launch. The record has to survive the process
    /// ending in between, or nothing is ever repaired. A relaunch reads the
    /// union of two copies, the `UserDefaults` list and a file written
    /// without data protection (the only one readable before the first
    /// unlock), so both must hold every id. The in-memory list a restart
    /// drops cannot be emptied from here, so this checks what the next
    /// process reads.
    func testPendingSetSurvivesProcessRestart() throws {
        let ids = Set([newId(), newId(), newId()])
        ids.forEach(PendingEncryptionLedger.record)
        PendingEncryptionLedger.waitForPendingWrites()

        let key = PendingEncryptionLedger.Store.session.rawValue
        let stored = Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
        XCTAssertTrue(ids.isSubset(of: stored), "the UserDefaults copy is missing an id")
        let file = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("PendingEncryption", isDirectory: true)
            .appendingPathComponent("\(key).json")
        let inFile = try Set(JSONDecoder().decode([String].self, from: Data(contentsOf: file)).compactMap(UUID.init(uuidString:)))
        XCTAssertTrue(ids.isSubset(of: inFile), "the file copy a locked relaunch reads is missing an id")
    }

    /// A record is in the file copy when `record` returns, before the
    /// plaintext bytes it covers are written: queued only, a kill in between
    /// left a plaintext file that nothing listed. Many records in a row, so a
    /// write that only queued would still be behind when the last returns.
    func testARecordIsInTheFileCopyBeforeItReturns() throws {
        let ids = (0 ..< 50).map { _ in newId() }
        ids.forEach(PendingEncryptionLedger.record)

        let key = PendingEncryptionLedger.Store.session.rawValue
        let file = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("PendingEncryption", isDirectory: true)
            .appendingPathComponent("\(key).json")
        let inFile = try Set(JSONDecoder().decode([String].self, from: Data(contentsOf: file)).compactMap(UUID.init(uuidString:)))
        XCTAssertTrue(Set(ids).isSubset(of: inFile), "a recorded id was not on disk when record returned")
        PendingEncryptionLedger.waitForPendingWrites()
    }

    /// A clear reaches disk too, so a relaunch does not re-encrypt a file
    /// that is already encrypted.
    func testClearIsPersisted() {
        let kept = newId()
        let cleared = newId()
        PendingEncryptionLedger.record(kept)
        PendingEncryptionLedger.record(cleared)
        PendingEncryptionLedger.clear(cleared)
        PendingEncryptionLedger.waitForPendingWrites()
        let stored = UserDefaults.standard.stringArray(forKey: PendingEncryptionLedger.Store.session.rawValue) ?? []
        XCTAssertTrue(stored.contains(kept.uuidString))
        XCTAssertFalse(stored.contains(cleared.uuidString), "the clear did not reach disk")
    }

    // MARK: - No UserDefaults write on the caller's thread

    /// Callers hold `archiveLock` or run on `RawRRBackup.appendQueue`. A
    /// UserDefaults write posts its change notification on the writing
    /// thread, where SwiftUI's observer waits for the main thread — which may
    /// be waiting for that same lock. The ledger must write on its own queue.
    func testRecordAndClearDoNotWriteUserDefaultsOnTheCallingThread() {
        let probe = CallingThreadProbe()
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { _ in probe.noteChange() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let id = newId()
        ownIds.append((id, .rawBackup))
        probe.whileCalling {
            PendingEncryptionLedger.record(id)
            PendingEncryptionLedger.record(id, in: .rawBackup)
            PendingEncryptionLedger.clear(id)
            PendingEncryptionLedger.clear(id, in: .rawBackup)
        }
        PendingEncryptionLedger.waitForPendingWrites()
        XCTAssertEqual(probe.changesOnCallingThread, 0, "The ledger wrote UserDefaults on the caller's thread")
    }

    /// A purge deletes the files, so the entries pointing at them must go too —
    /// otherwise the next launch tries to re-encrypt data the user erased.
    ///
    /// The one test that empties the whole ledger: the host's entries are
    /// read first and recorded again as soon as the assertion is made, so
    /// they are gone only for the moment the check takes.
    func testPurgeClearsEveryPendingEntry() {
        let host = Dictionary(uniqueKeysWithValues: Self.stores.map { ($0, PendingEncryptionLedger.pending(in: $0)) })
        defer {
            for (store, ids) in host {
                ids.forEach { PendingEncryptionLedger.record($0, in: store) }
            }
            PendingEncryptionLedger.waitForPendingWrites()
        }
        for store in Self.stores {
            PendingEncryptionLedger.record(newId(in: store), in: store)
        }
        XCTAssertFalse(Self.stores.contains { PendingEncryptionLedger.pending(in: $0).isEmpty })
        PendingEncryptionLedger.clearAll()
        XCTAssertTrue(Self.stores.allSatisfy { PendingEncryptionLedger.pending(in: $0).isEmpty })
    }

    // MARK: - Launch protection walk

    /// The walk that lowers archive files to "until first unlock" skips the
    /// session files still written in plaintext.
    func testOnlyAPendingSessionFileCountsAsPendingPlaintext() {
        let pending = UUID()
        let encrypted = UUID()
        let ids: Set<UUID> = [pending]
        XCTAssertTrue(isPendingPlaintextSessionFile("\(pending.uuidString).json", pending: ids))
        XCTAssertTrue(isPendingPlaintextSessionFile("sub/\(pending.uuidString).json", pending: ids))
        XCTAssertFalse(isPendingPlaintextSessionFile("\(encrypted.uuidString).json", pending: ids))
        XCTAssertFalse(isPendingPlaintextSessionFile("index.json", pending: ids))
        XCTAssertFalse(isPendingPlaintextSessionFile(pending.uuidString, pending: ids))
    }

    /// A pending session's copy in the Trash or in quarantine is plaintext
    /// too, and keeps its stricter class.
    func testTrashedAndQuarantinedCopiesOfAPendingSessionCountAsPendingPlaintext() {
        let pending = UUID()
        let ids: Set<UUID> = [pending]
        XCTAssertTrue(isPendingPlaintextSessionFile("Trash/\(pending.uuidString).session", pending: ids))
        XCTAssertTrue(isPendingPlaintextSessionFile("QuarantinedDuplicates/\(pending.uuidString).json", pending: ids))
        XCTAssertTrue(isPendingPlaintextSessionFile("QuarantinedDuplicates/\(pending.uuidString).1790000000000.json", pending: ids))
        XCTAssertFalse(isPendingPlaintextSessionFile("Trash/\(UUID().uuidString).session", pending: ids))
    }

    // MARK: - Archive repair pass

    /// The ledger is shared by every archive in the process: an id this
    /// archive neither lists, nor tombstones, nor holds a copy of may be
    /// another archive's session, and stays queued.
    func testRepairKeepsAnIdThisArchiveDoesNotKnow() throws {
        let archive = try makeArchive()
        let foreign = newId()
        PendingEncryptionLedger.record(foreign)

        reencryptPendingSessions(in: archive)

        XCTAssertTrue(PendingEncryptionLedger.pending.contains(foreign))
    }

    /// A session deleted here whose files are gone leaves the queue; the same
    /// session stays queued while the index has not loaded, since the
    /// session may still be on disk.
    func testRepairClearsADeletedSessionOnlyOnceTheIndexHasLoaded() throws {
        let deleted = newId()
        let unread = try makeArchive(deleted: [deleted], index: Data("not an index".utf8))
        PendingEncryptionLedger.record(deleted)

        reencryptPendingSessions(in: unread)
        XCTAssertTrue(PendingEncryptionLedger.pending.contains(deleted), "cleared while the index was unread")

        try requireEncryptionKey()
        reencryptPendingSessions(in: try makeArchive(deleted: [deleted]))
        XCTAssertFalse(PendingEncryptionLedger.pending.contains(deleted))
    }

    /// An indexed session whose file is gone has no plaintext left to repair:
    /// it leaves the queue instead of staying there for good.
    func testRepairClearsAnIndexedSessionWhoseFileIsGone() throws {
        let archive = try makeArchive()
        var session = HRVSession(startDate: Date(timeIntervalSince1970: 1_790_000_000), sessionType: .quick)
        session.endDate = session.startDate.addingTimeInterval(300)
        _ = try archive.archive(session)
        try FileManager.default.removeItem(at: archive.archiveDirectory.appendingPathComponent("\(session.id.uuidString).json"))
        ownIds.append((session.id, .session))
        PendingEncryptionLedger.record(session.id)

        try requireEncryptionKey()
        reencryptPendingSessions(in: archive)

        XCTAssertFalse(PendingEncryptionLedger.pending.contains(session.id))
        XCTAssertTrue(archive.store.exists(session.id))
    }

    /// An indexed session whose file is gone while a plaintext copy of it sits
    /// in the Trash leaves the queue with that copy encrypted. This pins the
    /// end state; the race that moves the file into the Trash during the pass
    /// is not reproduced.
    func testRepairEncryptsTheTrashCopyOfAnIndexedSessionWhoseFileIsGone() throws {
        let archive = try makeArchive()
        var session = HRVSession(startDate: Date(timeIntervalSince1970: 1_790_000_000), sessionType: .quick)
        session.endDate = session.startDate.addingTimeInterval(300)
        _ = try archive.archive(session)
        let file = archive.archiveDirectory.appendingPathComponent("\(session.id.uuidString).json")
        let trashed = archive.store.trashDirectory.appendingPathComponent("\(session.id.uuidString).session")
        try FileManager.default.createDirectory(at: archive.store.trashDirectory, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: file)
        try SessionArchive.sessionEncoder.encode(session).write(to: trashed)
        ownIds.append((session.id, .session))
        PendingEncryptionLedger.record(session.id)

        try requireEncryptionKey()
        reencryptPendingSessions(in: archive)

        XCTAssertTrue(ArchiveStore.looksEncrypted(try Data(contentsOf: trashed)))
        XCTAssertFalse(PendingEncryptionLedger.pending.contains(session.id))
    }

    /// A plaintext copy in the Trash is encrypted in place, and still
    /// restores.
    func testRepairEncryptsAPlaintextCopyInTheTrash() throws {
        let archive = try makeArchive()
        var session = HRVSession(startDate: Date(timeIntervalSince1970: 1_790_000_000), sessionType: .quick)
        session.endDate = session.startDate.addingTimeInterval(300)
        _ = try archive.archive(session)
        try archive.delete(session.id)
        let trashed = archive.store.trashDirectory.appendingPathComponent("\(session.id.uuidString).session")
        try SessionArchive.sessionEncoder.encode(session).write(to: trashed)
        ownIds.append((session.id, .session))
        PendingEncryptionLedger.record(session.id)

        try requireEncryptionKey()
        reencryptPendingSessions(in: archive)

        XCTAssertTrue(ArchiveStore.looksEncrypted(try Data(contentsOf: trashed)))
        XCTAssertFalse(PendingEncryptionLedger.pending.contains(session.id))
        XCTAssertEqual(archive.store.trashedSession(session.id)?.id, session.id)
    }

    /// An archive in its own folder, removed after the test, holding the
    /// given tombstones and, when given, these bytes as its index.
    private func makeArchive(deleted: [UUID] = [], index: Data? = nil) throws -> SessionArchive {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingEncryptionLedgerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        if !deleted.isEmpty {
            try JSONEncoder().encode(deleted.map(\.uuidString)).write(to: directory.appendingPathComponent("deleted.json"))
        }
        try index?.write(to: directory.appendingPathComponent("index.json"))
        return SessionArchive(directory: directory)
    }

    // MARK: - Raw backup rewrite

    /// A rewrite that fails leaves the old plaintext on disk, so its repair
    /// entry must survive; a first write that fails queues nothing.
    func testAFailedBackupWriteLeavesTheQueueAsItWas() {
        let queued = newId(in: .rawBackup)
        let fresh = newId(in: .rawBackup)
        PendingEncryptionLedger.record(queued, in: .rawBackup)
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingEncryptionLedgerTests-missing-\(UUID().uuidString)", isDirectory: true)

        for id in [queued, fresh] {
            let entry = RawRRBackup.BackupEntry(id: id, captureDate: Date(), deviceId: nil, points: [], hash: "")
            XCTAssertThrowsError(try RawBackupSealer.writeEntry(entry, to: missingDirectory.appendingPathComponent("\(id).json"), sessionId: id))
        }

        let pending = PendingEncryptionLedger.pending(in: .rawBackup)
        XCTAssertTrue(pending.contains(queued), "a failed rewrite dropped the backup's re-encryption entry")
        XCTAssertFalse(pending.contains(fresh), "a write that never landed was queued")
    }

    // MARK: - No silent path back

    /// A `try? encrypt(...) ?? plaintext` shape would produce identical bytes for
    /// both formats with no way to tell them apart. Through a real archive
    /// write, the bytes on disk and the ledger must agree: with the key, the
    /// file is ciphertext and the session is not queued for repair.
    func testDiskFormatDistinguishesTheTwoOutcomes() throws {
        try requireEncryptionKey()
        let archive = try makeArchive()
        var session = HRVSession(startDate: Date(timeIntervalSince1970: 1_790_000_000), sessionType: .quick)
        session.endDate = session.startDate.addingTimeInterval(300)
        ownIds.append((session.id, .session))

        _ = try archive.archive(session)

        let bytes = try Data(contentsOf: archive.archiveDirectory.appendingPathComponent("\(session.id.uuidString).json"))
        XCTAssertTrue(ArchiveStore.looksEncrypted(bytes), "An archive write with the key available wrote plaintext")
        XCTAssertFalse(PendingEncryptionLedger.pending.contains(session.id),
                       "An encrypted write left its session queued for re-encryption")
    }
}

/// Counts UserDefaults change notifications posted on the thread that is
/// inside `whileCalling`.
private final class CallingThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callingThread: Thread?
    private var count = 0

    var changesOnCallingThread: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func whileCalling(_ body: () -> Void) {
        lock.lock()
        callingThread = Thread.current
        lock.unlock()
        body()
        lock.lock()
        callingThread = nil
        lock.unlock()
    }

    func noteChange() {
        lock.lock()
        defer { lock.unlock() }
        if let callingThread, callingThread === Thread.current { count += 1 }
    }
}
