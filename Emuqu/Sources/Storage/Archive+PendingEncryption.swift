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

/// Whether `filename` (relative to the archive directory) is a copy of a
/// session in `pending`: its file `<id>.json`, its Trash file
/// `Trash/<id>.session`, or a duplicate quarantined as `<id>.json` or
/// `<id>.<stamp>.json`. Plaintext whose `.completeFileProtection` the launch
/// protection walk (`SessionArchive.upgradeExistingFileProtection`) must not
/// lower.
func isPendingPlaintextSessionFile(_ filename: String, pending: Set<UUID>) -> Bool {
    let name = (filename as NSString).lastPathComponent
    guard ["json", "session"].contains((name as NSString).pathExtension),
          let id = UUID(uuidString: String(name.prefix(36))) else { return false }
    return pending.contains(id)
}

/// Write archive bytes with the protection class their format demands.
///
/// `archiveWriteOptions` brings the ledger in line before the write; when the
/// write then throws, nothing new reached disk, so the id's ledger entry is
/// put back as it was. Otherwise a failed encrypted write would leave a
/// plaintext file no longer queued for re-encryption, and a failed plaintext
/// write would queue bytes that were never written.
func writeArchiveBytes(
    _ data: Data, to url: URL,
    format: SessionArchive.SessionFileCodec.DiskFormat,
    sessionID: UUID
) throws {
    let wasPending = PendingEncryptionLedger.pending.contains(sessionID)
    do {
        try data.write(to: url, options: archiveWriteOptions(for: format, sessionID: sessionID))
    } catch {
        if wasPending { PendingEncryptionLedger.record(sessionID) } else { PendingEncryptionLedger.clear(sessionID) }
        throw error
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
    // An index that did not load lists only part of the archive: a pending id
    // missing from it may still have its plaintext file here.
    guard archive.hasCompleteIndex else {
        debugLog("[Archive] \(pending.count) session(s) await re-encryption; index not loaded, retried next launch", level: .warning)
        return
    }
    debugLog("[Archive] re-encrypting \(pending.count) session(s) written under a locked Keychain")
    for id in pending {
        reencryptOne(id, in: archive)
    }
}

/// Rewrite every copy this archive holds of one session encrypted: the
/// archived file, through the archive's own write, and any copy in the Trash
/// or in quarantine, in place.
///
/// The id leaves the ledger only once no copy here is still plaintext. The
/// archived rewrite clears it (`archiveWriteOptions`), so it is recorded again
/// while a parked copy could not be rewritten. A session not in the index
/// leaves the ledger once its parked copies are encrypted, when it has one or
/// a tombstone says it was deleted here. An id this archive neither lists,
/// tombstones nor holds a copy of stays queued: the ledger is shared by every
/// archive in the process, so it may be another archive's session.
private func reencryptOne(_ id: UUID, in archive: SessionArchive) {
    guard let parked = archive.store.parkedCopies(of: id) else { return }
    let parkedEncrypted = parked.map { reencryptParkedCopy($0, id: id, in: archive) }.allSatisfy { $0 }
    if archive.exists(id) {
        reencryptArchived(id, in: archive)
        if !parkedEncrypted { PendingEncryptionLedger.record(id) }
    } else if parkedEncrypted, !parked.isEmpty || archive.wasIntentionallyDeleted(id) {
        PendingEncryptionLedger.clear(id)
    }
}

/// Rewrite the archived session encrypted. The write clears it from the ledger
/// only if it really came out encrypted (`archiveWriteOptions`); an `encrypt`
/// that throws again writes plaintext and keeps it queued. The index hash is
/// refreshed because the bytes on disk change.
///
/// An index entry whose file is gone (`fileNotFound`) has no plaintext left
/// here to repair, and leaves the ledger; its Trash and quarantine copies were
/// handled before this runs (`reencryptOne`). Any other failed read leaves it
/// queued for the next launch: most often a launch in the background while the
/// device is locked, when the file's protection class keeps it closed.
/// Clearing it there would leave the plaintext on disk with nothing left to
/// repair it.
private func reencryptArchived(_ id: UUID, in archive: SessionArchive) {
    let session: HRVSession
    do {
        guard let found = try archive.retrieveLightweight(id) else { return }
        session = found
    } catch SessionArchive.ArchiveError.fileNotFound {
        PendingEncryptionLedger.clear(id)
        return
    } catch {
        debugLog("[Archive] re-encryption deferred for \(id.uuidString.prefix(8)) — file not readable yet: \(error)", level: .warning)
        return
    }
    do {
        // Through the locked entry point: `_archive` expects its caller to hold
        // `archiveLock`, and this runs from a detached migration beside every
        // other writer. Same-night merge is skipped — this rewrites one file's
        // encoding, it does not archive a new night.
        try archive.archive(session, skipSameNightMerge: true)
    } catch {
        debugLog("[Archive] re-encryption failed for \(id.uuidString.prefix(8)): \(error)", level: .error)
    }
}

/// Rewrite a Trash or quarantine copy encrypted, in place, unless it already
/// is. Under `archiveLock`, which `delete` holds while it moves a file into
/// the Trash, so a newer copy is not overwritten with these bytes. False when
/// it could not be read, encrypted or written.
private func reencryptParkedCopy(_ url: URL, id: UUID, in archive: SessionArchive) -> Bool {
    archive.archiveLock.lock()
    defer { archive.archiveLock.unlock() }
    do {
        let stored = try Data(contentsOf: url)
        guard !ArchiveStore.looksEncrypted(stored) else { return true }
        let sealed = try AppDependencies.current.storage.encryptionManager.encrypt(ArchiveStore.plaintextBytes(stored, id: id))
        try sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return true
    } catch {
        debugLog("[Archive] re-encryption deferred for \(url.lastPathComponent): \(error)", level: .warning)
        return false
    }
}
