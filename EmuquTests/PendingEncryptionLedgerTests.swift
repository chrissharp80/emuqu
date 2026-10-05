@testable import Emuqu
import XCTest

/// Pins the fail-closed behaviour of sensitive storage.
///
/// `Archive+SessionCodec` and `RawRRBackup` both wrote
/// plaintext JSON whenever `EncryptionManager` was unavailable or `encrypt`
/// threw — same file path, same protection class, and in one of the three sites
/// no log line at all. Application-layer confidentiality on health data failed
/// OPEN, at precisely the moment the controls were already failing.
///
/// Refusing the write is not the fix. The realistic trigger is a background
/// write before the first unlock after a reboot, which is exactly when a
/// completed overnight recording is archived — throwing there loses a night the
/// user cannot regenerate, to protect a file that `.completeFileProtection`
/// already makes unreadable while locked.
///
/// So the contract these tests hold is narrower and stronger than "never write
/// plaintext":
///
///   1. Unencrypted bytes are written under the STRICTEST protection class.
///   2. Every unencrypted write is recorded, so it can be repaired.
///   3. The record survives a relaunch, because the repair runs at next launch.
///   4. Re-encryption clears the record; a purge clears all of them.
///
/// Fault injection proving no plaintext file is created on every failure path
/// would be the ideal. What is proven here is the reachable half — the format
/// decision and the ledger — because forcing a genuine Keychain outage needs a
/// device, and a test that fakes `EncryptionManager` would be testing the fake.
final class PendingEncryptionLedgerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PendingEncryptionLedger.clearAll()
    }

    override func tearDown() {
        PendingEncryptionLedger.clearAll()
        super.tearDown()
    }

    // MARK: - Protection class

    /// The whole point of the change: an unencrypted body must not be written
    /// with the same options as an encrypted one.
    func testUnencryptedWritesUseTheStrictestProtectionClass() {
        let id = UUID()
        let encrypted = archiveWriteOptions(for: .encrypted, sessionID: id)
        let plaintext = archiveWriteOptions(for: .plaintextPendingEncryption, sessionID: id)

        XCTAssertTrue(plaintext.contains(.completeFileProtection),
                      "Unencrypted health data must be unreadable whenever the device is locked")
        XCTAssertFalse(plaintext.contains(.completeFileProtectionUntilFirstUserAuthentication),
                       "Until-first-unlock is the weaker class and must not be used for plaintext")
        XCTAssertTrue(encrypted.contains(.completeFileProtectionUntilFirstUserAuthentication))
        XCTAssertNotEqual(encrypted, plaintext, "The two formats must not write identically")
    }

    /// Both formats stay atomic — a torn write is a separate failure mode and
    /// this change must not introduce one.
    func testBothFormatsWriteAtomically() {
        let id = UUID()
        XCTAssertTrue(archiveWriteOptions(for: .encrypted, sessionID: id).contains(.atomic))
        XCTAssertTrue(archiveWriteOptions(for: .plaintextPendingEncryption, sessionID: id).contains(.atomic))
    }

    // MARK: - The ledger records what needs repair

    /// Choosing the plaintext options is what enrols a session for repair. If
    /// these two ever came apart, a file would be written unencrypted and never
    /// fixed — silent, permanent, and exactly the original defect.
    func testChoosingPlaintextOptionsRecordsTheSession() {
        let id = UUID()
        XCTAssertFalse(PendingEncryptionLedger.pending.contains(id))
        _ = archiveWriteOptions(for: .plaintextPendingEncryption, sessionID: id)
        XCTAssertTrue(PendingEncryptionLedger.pending.contains(id))
    }

    /// And an encrypted write clears it, which is how the repair pass finishes.
    func testChoosingEncryptedOptionsClearsTheSession() {
        let id = UUID()
        _ = archiveWriteOptions(for: .plaintextPendingEncryption, sessionID: id)
        XCTAssertTrue(PendingEncryptionLedger.pending.contains(id))
        _ = archiveWriteOptions(for: .encrypted, sessionID: id)
        XCTAssertFalse(PendingEncryptionLedger.pending.contains(id))
    }

    func testRecordingIsIdempotent() {
        let id = UUID()
        PendingEncryptionLedger.record(id)
        PendingEncryptionLedger.record(id)
        XCTAssertEqual(PendingEncryptionLedger.pending.filter { $0 == id }.count, 1)
    }

    func testClearingAnUnknownSessionIsHarmless() {
        let known = UUID()
        PendingEncryptionLedger.record(known)
        PendingEncryptionLedger.clear(UUID())
        XCTAssertEqual(PendingEncryptionLedger.pending, [known])
    }

    // MARK: - Survives the gap the repair has to cross

    /// The fallback happens in a background write before first unlock; the
    /// repair runs at the next launch. The record has to survive the process
    /// ending in between, or nothing is ever repaired.
    func testPendingSetSurvivesProcessRestart() {
        let ids = [UUID(), UUID(), UUID()]
        ids.forEach(PendingEncryptionLedger.record)
        // The ledger is backed by UserDefaults precisely so it outlives the
        // process — and so it does not depend on the encryption that is broken.
        PendingEncryptionLedger.waitForPendingWrites()
        let stored = UserDefaults.standard.stringArray(forKey: PendingEncryptionLedger.Store.session.rawValue) ?? []
        XCTAssertEqual(Set(stored.compactMap(UUID.init(uuidString:))), Set(ids))
        XCTAssertEqual(PendingEncryptionLedger.pending, Set(ids))
    }

    /// A clear reaches disk too, so a relaunch does not re-encrypt a file
    /// that is already encrypted.
    func testClearIsPersisted() {
        let kept = UUID()
        let cleared = UUID()
        PendingEncryptionLedger.record(kept)
        PendingEncryptionLedger.record(cleared)
        PendingEncryptionLedger.clear(cleared)
        PendingEncryptionLedger.waitForPendingWrites()
        let stored = UserDefaults.standard.stringArray(forKey: PendingEncryptionLedger.Store.session.rawValue) ?? []
        XCTAssertEqual(stored, [kept.uuidString])
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
        let id = UUID()
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
    func testPurgeClearsEveryPendingEntry() {
        [UUID(), UUID()].forEach(PendingEncryptionLedger.record)
        XCTAssertFalse(PendingEncryptionLedger.pending.isEmpty)
        PendingEncryptionLedger.clearAll()
        XCTAssertTrue(PendingEncryptionLedger.pending.isEmpty)
    }

    // MARK: - No silent path back

    /// A guard against the specific regression: someone restoring the old
    /// `try? encrypt(...) ?? plaintext` shape would produce identical bytes for
    /// both formats with no way to tell them apart. The format enum existing
    /// and being exhaustive is what makes that impossible to do accidentally.
    func testDiskFormatDistinguishesTheTwoOutcomes() {
        let formats: [SessionArchive.SessionFileCodec.DiskFormat] = [.encrypted, .plaintextPendingEncryption]
        let ids = formats.map { _ in UUID() }
        let options = zip(formats, ids).map { archiveWriteOptions(for: $0, sessionID: $1) }
        XCTAssertEqual(Set(options.map(\.rawValue)).count, 2,
                       "Encrypted and plaintext writes must be distinguishable at the call site")
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
