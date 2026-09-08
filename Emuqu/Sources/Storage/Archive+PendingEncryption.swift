import Foundation

// Storage-confidentiality policy for the archive, deliberately at file scope.
//
// `SessionArchive` is already over the 1,500 aggregate-line budget for
// central types. None of this is archive *state* — it is a decision about how
// bytes are written and a repair pass over them — so it lives beside the type
// rather than inside it. See docs/adr/README.md, decision 001.

/// The write options a given disk format demands.
///
/// An unencrypted body is written with
/// `.completeFileProtection`, not the usual
/// `.completeFileProtectionUntilFirstUserAuthentication`. That is the
/// strictest class iOS offers — the file is unreadable whenever the device
/// is locked, not merely before first unlock — and it is what stands in for
/// the application-layer encryption until the repair pass restores it.
func archiveWriteOptions(
for format: SessionArchive.SessionFileCodec.DiskFormat,
sessionID: UUID
) -> Data.WritingOptions {
    switch format {
    case .encrypted:
        PendingEncryptionLedger.clear(sessionID)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    case .plaintextPendingEncryption:
        PendingEncryptionLedger.record(sessionID)
        return [.atomic, .completeFileProtection]
    }
}

/// Re-encrypt sessions that were written without application-layer
/// encryption because the key was unreachable at write time.
///
/// Runs at launch, which is where the Keychain is
/// reachable — the fallback happens in background writes before the first
/// unlock after a reboot, and this is the first moment afterwards that can
/// repair it. A no-op in the overwhelmingly common case where the ledger is
/// empty, so it costs nothing on a normal launch.
func reencryptPendingSessions(in archive: SessionArchive) {
    let pending = PendingEncryptionLedger.pending
    guard !pending.isEmpty else { return }
    guard AppDependencies.current.storage.encryptionManager.isAvailable else {
        debugLog("[Archive] \(pending.count) session(s) await re-encryption; key still unavailable", level: .error)
        return
    }
    debugLog("[Archive] re-encrypting \(pending.count) session(s) written under a locked Keychain")
    for id in pending {
    reencryptOne(id, in: archive)
    }
}

/// Rewrite one session encrypted, and clear it from the ledger on success.
/// The index hash is refreshed because the bytes on disk change.
private func reencryptOne(_ id: UUID, in archive: SessionArchive) {
    guard let session = archive.retrieveLightweightOrLog(id, caller: "reencryptPending") else {
        // The file is gone — nothing left to protect, so stop tracking it.
        PendingEncryptionLedger.clear(id)
        return
    }
    do {
        _ = try archive._archive(session)
        PendingEncryptionLedger.clear(id)
    } catch {
        debugLog("[Archive] re-encryption failed for \(id.uuidString.prefix(8)): \(error)", level: .error)
    }
}
