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

    /// Serializes the read-modify-write of each list. The archive writer and
    /// detached backup writes record at the same time, and two unguarded
    /// writes each dropped the other's id.
    private static let lock = OSAllocatedUnfairLock()

    /// Session IDs whose on-disk bytes are not encrypted.
    static var pending: Set<UUID> { pending(in: .session) }

    /// Ids whose on-disk bytes in `store` are not encrypted.
    static func pending(in store: Store) -> Set<UUID> {
        lock.withLockUnchecked { stored(store) }
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
        let count: Int? = lock.withLockUnchecked {
            var ids = stored(store)
            guard ids.insert(id).inserted else { return nil }
            persist(ids, store)
            return ids.count
        }
        guard let count else { return }
        debugLog(
            "[Storage] \(store == .session ? "session" : "raw backup") \(id.uuidString.prefix(8)) written WITHOUT app-layer "
                + "encryption (key unavailable); queued for re-encryption. Pending: \(count)",
            level: .error
        )
    }

    /// Clear `id` after its bytes have been rewritten encrypted.
    static func clear(_ id: UUID, in store: Store) {
        lock.withLockUnchecked {
            var ids = stored(store)
            guard ids.remove(id) != nil else { return }
            persist(ids, store)
        }
    }

    /// Drop every entry. Used by the data purge, where the files themselves go.
    static func clearAll() {
        lock.withLockUnchecked {
            UserDefaults.standard.removeObject(forKey: Store.session.rawValue)
            UserDefaults.standard.removeObject(forKey: Store.rawBackup.rawValue)
        }
    }

    private static func stored(_ store: Store) -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: store.rawValue) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private static func persist(_ ids: Set<UUID>, _ store: Store) {
        UserDefaults.standard.set(ids.map(\.uuidString).sorted(), forKey: store.rawValue)
    }
}
