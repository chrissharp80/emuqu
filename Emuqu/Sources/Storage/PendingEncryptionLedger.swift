import Foundation

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
/// recorded here, and `SessionArchive.reencryptPendingSessions()` repairs it on
/// the next launch where the key is available. Confidentiality is restored
/// without ever putting the recording at risk.
///
/// Deliberately a plain `UserDefaults` list rather than a file: it must be
/// readable at launch, it holds no health data — only UUIDs — and it must not
/// itself depend on the encryption that is currently broken.
enum PendingEncryptionLedger {
    private static let key = "storage.pendingReencryption.sessionIDs"

    /// Session IDs whose on-disk bytes are not encrypted.
    static var pending: Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    /// Record that `id` was written without encryption.
    ///
    /// Logged at `.error`, not `.warning`: a downgraded confidentiality
    /// guarantee on health data is not a routine event, and the whole point of
    /// this change is that it stops being invisible.
    static func record(_ id: UUID) {
        var ids = pending
        guard ids.insert(id).inserted else { return }
        persist(ids)
        debugLog(
            "[Storage] session \(id.uuidString.prefix(8)) written WITHOUT app-layer encryption "
                + "(key unavailable); queued for re-encryption. Pending: \(ids.count)",
            level: .error
        )
    }

    /// Clear `id` after its bytes have been rewritten encrypted.
    static func clear(_ id: UUID) {
        var ids = pending
        guard ids.remove(id) != nil else { return }
        persist(ids)
    }

    /// Drop every entry. Used by the data purge, where the files themselves go.
    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func persist(_ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map(\.uuidString).sorted(), forKey: key)
    }
}
