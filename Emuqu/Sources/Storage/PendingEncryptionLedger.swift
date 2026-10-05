import Foundation
import os

/// Sessions written to disk without application-layer encryption, awaiting
/// re-encryption once the key is reachable again.
///
/// ## Why this exists
///
/// Without this ledger, `Archive` and `RawRRBackup` silently fall
/// back to writing plaintext JSON whenever `EncryptionManager` is unavailable
/// or `encrypt` throws. File protection still applies, but the application layer
/// — the part that survives a filesystem image or a device backup — is
/// downgraded with no signal, at exactly the moment the controls are failing.
///
/// The obvious fix, refusing the write, is worse. The realistic trigger is a
/// background write before the first unlock after a reboot, and that is
/// precisely when a completed overnight recording is archived. Throwing there
/// loses a night of data the user cannot regenerate, to protect a file that
/// `.completeFileProtection` already makes unreadable while the device is
/// locked.
///
/// So the write proceeds under the strictest protection class, the session is
/// recorded here, and `reencryptPendingSessions(in:)` (archive) or
/// `RawRRBackup.reencryptPendingBackups()` repairs it on
/// the next launch where the key is available. Confidentiality is restored
/// without ever putting the recording at risk.
///
/// Deliberately a plain `UserDefaults` list rather than a file: it must be
/// readable at launch, it holds no health data — only UUIDs — and it must not
/// itself depend on the encryption that is currently broken.
///
/// Archive sessions and raw RR backups are listed apart: each store's repair
/// pass rewrites its own files, and an encrypted write in one store says
/// nothing about the other's file for the same id.
enum PendingEncryptionLedger {
    /// Which files an id refers to.
    enum Store: String {
        case session = "storage.pendingReencryption.sessionIDs"
        case rawBackup = "storage.pendingReencryption.rawBackupIDs"
    }

    /// The lists, read from `UserDefaults` on first use and kept here after.
    /// The lock serializes each read-modify-write: the archive writer and
    /// detached backup writes record at the same time, and two unguarded
    /// writes each dropped the other's id.
    private static let cache = OSAllocatedUnfairLock(initialState: [Store: Set<UUID>]())

    /// Callers hold `archiveLock` or run on `RawRRBackup.appendQueue`, and a
    /// `UserDefaults` write posts its change notification synchronously on the
    /// writing thread; SwiftUI's observer then waits for the main thread, which
    /// can itself be waiting for that lock or queue. Writes therefore go
    /// through this serial queue, outside every caller's lock. Each write
    /// stores the list as it is when the write runs, so the last one to run
    /// leaves the newest list on disk. The cost is a window of milliseconds in
    /// which an entry exists only in memory; a process killed inside it loses
    /// the entry, the trade `ArchiveStore.recordDeletionTime` makes too.
    private static let persistQueue = DispatchQueue(label: "storage.pendingReencryption.persist", qos: .utility)

    /// Session IDs whose on-disk bytes are not encrypted.
    static var pending: Set<UUID> { pending(in: .session) }

    /// Ids whose on-disk bytes in `store` are not encrypted.
    static func pending(in store: Store) -> Set<UUID> {
        cache.withLockUnchecked { ids(store, in: &$0) }
    }

    /// Record that session `id` was written without encryption.
    static func record(_ id: UUID) { record(id, in: .session) }

    /// Clear session `id` after its bytes have been rewritten encrypted.
    static func clear(_ id: UUID) { clear(id, in: .session) }

    /// Record that `id` was written without encryption.
    ///
    /// Logged at `.error`, not `.warning`: a downgraded confidentiality
    /// guarantee on health data is not a routine event, and the whole point of
    /// this change is that it stops being invisible.
    static func record(_ id: UUID, in store: Store) {
        let count: Int? = cache.withLockUnchecked { lists in
            var ids = ids(store, in: &lists)
            guard ids.insert(id).inserted else { return nil }
            lists[store] = ids
            return ids.count
        }
        guard let count else { return }
        schedulePersist(store)
        debugLog(
            "[Storage] \(store == .session ? "session" : "raw backup") \(id.uuidString.prefix(8)) written WITHOUT app-layer "
                + "encryption (key unavailable); queued for re-encryption. Pending: \(count)",
            level: .error
        )
    }

    /// Clear `id` after its bytes have been rewritten encrypted.
    static func clear(_ id: UUID, in store: Store) {
        let changed: Bool = cache.withLockUnchecked { lists in
            var ids = ids(store, in: &lists)
            guard ids.remove(id) != nil else { return false }
            lists[store] = ids
            return true
        }
        if changed { schedulePersist(store) }
    }

    /// Drop every entry. Used by the data purge, where the files themselves go.
    static func clearAll() {
        cache.withLockUnchecked { $0 = [.session: [], .rawBackup: []] }
        schedulePersist(.session)
        schedulePersist(.rawBackup)
    }

    /// Block until every scheduled write has reached `UserDefaults`. For tests
    /// and other background callers only; never call it from the main thread,
    /// which is the thread the queue exists to keep out of the wait.
    static func waitForPendingWrites() {
        persistQueue.sync {}
    }

    /// The cached list for `store`, loaded from `UserDefaults` the first time.
    /// A read posts no change notification, so it is safe under a caller's lock.
    private static func ids(_ store: Store, in lists: inout [Store: Set<UUID>]) -> Set<UUID> {
        if let cached = lists[store] { return cached }
        let raw = UserDefaults.standard.stringArray(forKey: store.rawValue) ?? []
        let loaded = Set(raw.compactMap(UUID.init(uuidString:)))
        lists[store] = loaded
        return loaded
    }

    private static func schedulePersist(_ store: Store) {
        persistQueue.async {
            let ids = cache.withLockUnchecked { $0[store] ?? [] }
            if ids.isEmpty {
                UserDefaults.standard.removeObject(forKey: store.rawValue)
            } else {
                UserDefaults.standard.set(ids.map(\.uuidString).sorted(), forKey: store.rawValue)
            }
        }
    }
}
