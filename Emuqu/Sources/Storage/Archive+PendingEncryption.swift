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
///
/// Only a session that no longer exists leaves the ledger without being
/// rewritten. A read that fails for any other reason — most often a launch
/// in the background while the device is locked, when the file's protection
/// class keeps it closed — leaves it queued for the next launch; clearing it
/// there would leave the plaintext on disk with nothing left to repair it.
private func reencryptOne(_ id: UUID, in archive: SessionArchive) {
    let session: HRVSession
    do {
        guard let found = try archive.retrieveLightweight(id) else {
            PendingEncryptionLedger.clear(id)
            return
        }
        session = found
    } catch SessionArchive.ArchiveError.fileNotFound {
        PendingEncryptionLedger.clear(id)
        return
    } catch {
        debugLog("[Archive] re-encryption deferred for \(id.uuidString.prefix(8)) — file not readable yet: \(error)", level: .warning)
        return
    }
    do {
        _ = try archive._archive(session)
        PendingEncryptionLedger.clear(id)
    } catch {
        debugLog("[Archive] re-encryption failed for \(id.uuidString.prefix(8)): \(error)", level: .error)
    }
}
