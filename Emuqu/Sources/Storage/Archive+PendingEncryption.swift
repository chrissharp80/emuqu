import Foundation

// Storage-confidentiality policy for the archive. None of this is archive
// *state*: it is a decision about how bytes are written and a repair pass
// over them.

/// The write options a given disk format demands.
///
/// An unencrypted body is written with `.completeFileProtectionUnlessOpen`,
/// not the usual `.completeFileProtectionUntilFirstUserAuthentication`. The
/// fallback runs while the device is locked, mostly before the first unlock
/// after a reboot, when the key is unreachable: a file of this class can be
/// created then (`.completeFileProtection` cannot be written while locked),
/// and once closed it cannot be opened again until the device is unlocked.
/// That stands in for the application-layer encryption until the repair pass
/// restores it.
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
        return [.atomic, .completeFileProtectionUnlessOpen]
    }
}

/// Whether `filename` (relative to the archive directory) is a copy of a
/// session in `pending`: its file `<id>.json`, its Trash file
/// `Trash/<id>.session`, or a duplicate quarantined as `<id>.json` or
/// `<id>.<stamp>.json`. Plaintext whose `.completeFileProtectionUnlessOpen`
/// the launch protection walk (`SessionArchive.upgradeExistingFileProtection`)
/// must not lower.
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
///
/// Every session file the archive writes goes through here, so this is where
/// "Delete All My Data" stops them (`PurgeGate`): while a purge runs the write
/// throws `PurgeGate.Refused` and touches neither the file nor the ledger.
func writeArchiveBytes(
    _ data: Data, to url: URL,
    format: SessionArchive.SessionFileCodec.DiskFormat,
    sessionID: UUID
) throws {
    let wasPending = PendingEncryptionLedger.pending.contains(sessionID)
    do {
        try PurgeGate.admitWrite {
            try data.write(to: url, options: archiveWriteOptions(for: format, sessionID: sessionID))
        }
    } catch let refused as PurgeGate.Refused {
        throw refused
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
    guard archive.encryption.isAvailable else {
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
    if archive.store.exists(id) {
        reencryptArchived(id, in: archive)
        if !parkedEncrypted { PendingEncryptionLedger.record(id) }
    } else if parkedEncrypted, !parked.isEmpty || archive.store.wasIntentionallyDeleted(id) {
        PendingEncryptionLedger.clear(id)
    }
}

/// Rewrite the archived session encrypted. The write clears it from the ledger
/// only if it really came out encrypted (`archiveWriteOptions`); an `encrypt`
/// that throws again writes plaintext and keeps it queued. The index hash is
/// refreshed because the bytes on disk change.
///
/// An index entry whose file is gone (`fileNotFound`) has no plaintext left
/// there, and leaves the ledger once every parked copy is encrypted
/// (`clearOnceParkedCopiesAreEncrypted`). Any other failed read leaves it
/// queued for the next launch: most often a launch in the background while the
/// device is locked, when the file's protection class keeps it closed.
/// Clearing it there would leave the plaintext on disk with nothing left to
/// repair it.
///
/// The read and the write happen under one lock (`SessionArchive.update`,
/// with no change and no re-upload): an edit saved between a separate read
/// and write would be overwritten by the copy read before it.
private func reencryptArchived(_ id: UUID, in archive: SessionArchive) {
    do {
        try archive.update(id, requestingReupload: false) { _ in }
    } catch SessionArchive.ArchiveError.fileNotFound {
        clearOnceParkedCopiesAreEncrypted(id, in: archive)
    } catch {
        debugLog("[Archive] re-encryption deferred for \(id.uuidString.prefix(8)) — not rewritten: \(error)", level: .warning)
    }
}

/// Clear the entry of an indexed session whose file is gone, once every
/// parked copy is encrypted. A delete can move the file into the Trash after
/// `reencryptOne` handled the parked copies, so they are handled again here;
/// one that cannot be listed or rewritten keeps the entry queued.
private func clearOnceParkedCopiesAreEncrypted(_ id: UUID, in archive: SessionArchive) {
    guard let parked = archive.store.parkedCopies(of: id),
          parked.allSatisfy({ reencryptParkedCopy($0, id: id, in: archive) }) else { return }
    PendingEncryptionLedger.clear(id)
}

/// Rewrite a Trash or quarantine copy encrypted, in place, unless it already
/// is. Under `archiveLock`, which `delete` holds while it moves a file into
/// the Trash, so a newer copy is not overwritten with these bytes. False when
/// it could not be read, encrypted or written, the write refused while
/// "Delete All My Data" runs (`PurgeGate`) included.
private func reencryptParkedCopy(_ url: URL, id: UUID, in archive: SessionArchive) -> Bool {
    archive.archiveLock.lock()
    defer { archive.archiveLock.unlock() }
    do {
        let stored = try Data(contentsOf: url)
        guard !ArchiveStore.looksEncrypted(stored) else { return true }
        let sealed = try archive.encryption.encrypt(ArchiveStore.plaintextBytes(stored, id: id, encryption: archive.encryption))
        try PurgeGate.admitWrite {
            try sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return true
    } catch {
        debugLog("[Archive] re-encryption deferred for \(url.lastPathComponent): \(error)", level: .warning)
        return false
    }
}
