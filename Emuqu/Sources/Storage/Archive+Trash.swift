import Foundation

// Deleted sessions' files, kept until they are restored or deleted for good.

extension ArchiveStore {
    // MARK: - Trash

    /// Where deleted sessions' files wait until they are restored or deleted
    /// for good.
    var trashDirectory: URL {
        archive.archiveDirectory.appendingPathComponent("Trash", isDirectory: true)
    }

    private func trashURL(for id: UUID) -> URL {
        trashDirectory.appendingPathComponent("\(id.uuidString).session")
    }

    /// Where duplicate cleanup moves the files of the sessions it retires.
    var quarantineDirectory: URL {
        archive.archiveDirectory.appendingPathComponent("QuarantinedDuplicates", isDirectory: true)
    }

    /// The session's files held outside the index: its Trash file and every
    /// duplicate of it in quarantine (`<id>.json`, `<id>.<stamp>.json`). Nil
    /// when the quarantine folder exists but cannot be listed, so a caller
    /// cannot take "none" for an answer it does not have.
    func parkedCopies(of id: UUID) -> [URL]? {
        let fm = archive.fileManager
        let trashed = [trashURL(for: id)].filter { fm.fileExists(atPath: $0.path) }
        guard fm.fileExists(atPath: quarantineDirectory.path) else { return trashed }
        guard let names = attempt("Archive.listQuarantine", { try fm.contentsOfDirectory(atPath: quarantineDirectory.path) }) else {
            return nil
        }
        let quarantined = names.filter { $0.hasPrefix(id.uuidString) && $0.hasSuffix(".json") }
        return trashed + quarantined.map { quarantineDirectory.appendingPathComponent($0) }
    }

    /// The file is kept, not erased, so a restore brings the session back as
    /// it was. Rebuilding it from its raw beats would lose its tags, notes,
    /// morning feeling and sleep edits, and bring a workout back as an
    /// overnight reading.
    ///
    /// The moved file is dated now: a move keeps the date of the session's
    /// last write, and `expiredDeletionIds` falls back to the file's date when no
    /// deletion time is recorded, which would discard an old session's file at
    /// the next launch instead of after 90 days.
    ///
    /// Throws when the file could not be moved; it is then left where it was,
    /// so the caller can put the session back in the index. Deleting it there
    /// lost the copy the Trash exists to keep. A file that is not there has
    /// nothing to keep, and is not an error: an index entry whose file is gone
    /// must still be deletable.
    func moveToTrash(_ fileURL: URL, id: UUID) throws {
        let fm = archive.fileManager
        guard fm.fileExists(atPath: fileURL.path) else { return }
        try fm.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let destination = trashURL(for: id)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: fileURL, to: destination)
        attempt("Archive.trash.dateMove") { try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path) }
    }

    /// The deleted session exactly as it was archived, or nil when it was
    /// deleted before the trash kept files (or the file cannot be read).
    func trashedSession(_ id: UUID) -> HRVSession? {
        let url = trashURL(for: id)
        guard archive.fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let plaintext = try Self.plaintextBytes(Data(contentsOf: url), id: id)
            return try SessionArchive.sessionDecoder.decode(HRVSession.self, from: plaintext)
        } catch {
            debugLog("[Archive] ⚠️ Trashed session \(id.uuidString.prefix(8)) could not be read: \(error)", level: .warning)
            return nil
        }
    }

    /// Ids of every session file held in the trash.
    var trashedIds: Set<UUID> {
        guard archive.fileManager.fileExists(atPath: trashDirectory.path) else { return [] }
        do {
            let names = try archive.fileManager.contentsOfDirectory(atPath: trashDirectory.path)
            return Set(names.compactMap { UUID(uuidString: ($0 as NSString).deletingPathExtension) })
        } catch {
            debugLog("[Archive] ⚠️ Could not list the trash: \(error)", level: .warning)
            return []
        }
    }

    /// Deleted sessions older than `keepDays`: Help says deleted sessions are
    /// kept for 90 days. Covers every deleted id, trashed file or not (a
    /// deleted session with only a raw backup is listed in the Trash too).
    /// Aged by the recorded deletion time, or the trashed file's own date
    /// when none was recorded (set to the deletion moment by `moveToTrash`);
    /// an id with neither is never treated as expired. The caller removes
    /// each one completely (`SessionRecoveryService.permanentlyDelete`).
    func expiredDeletionIds(keepDays: Int = 90) -> [UUID] {
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        return deletedIds.union(trashedIds).filter { id in
            (deletionTime(of: id) ?? trashFileDate(id) ?? Date()) < cutoff
        }
    }

    private func trashFileDate(_ id: UUID) -> Date? {
        do {
            return try archive.fileManager.attributesOfItem(atPath: trashURL(for: id).path)[.modificationDate] as? Date
        } catch {
            return nil
        }
    }

    /// Removes, under `archiveLock`, the `<id>.json` a failed delete left in
    /// the archive folder (`removeLeftover`) and then the Trash file, so a
    /// write of the session between the index check and a removal cannot have
    /// its file deleted. The leftover goes first: when either removal fails,
    /// the Trash file is still there and the session stays listed in the
    /// Trash. A session the index lists keeps its file; only its Trash file
    /// goes. A session not in the index whose Trash file this removed, or
    /// which is tombstoned, and which has no quarantined copy, leaves the
    /// re-encryption queue; an id with neither a copy nor a tombstone stays
    /// queued (it may be another archive's).
    ///
    /// True when neither file is left. False when one could not be removed
    /// (logged), or the leftover is kept because it may be a live file.
    @discardableResult
    func discardTrashed(_ id: UUID) -> Bool {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        let trashFile = trashURL(for: id)
        guard entryById(id) == nil else { return removeQuietly(trashFile, id: id) }
        let hadTrashFile = archive.fileManager.fileExists(atPath: trashFile.path)
        let tombstoned = archive.deletedSessionIds.contains(id)
        guard removeLeftover(of: id, tombstoned: tombstoned), removeQuietly(trashFile, id: id) else { return false }
        if hadTrashFile || tombstoned, parkedCopies(of: id)?.isEmpty == true { PendingEncryptionLedger.clear(id) }
        return true
    }

    /// The `<id>.json` a failed delete left in the archive folder, removed
    /// only for a tombstoned id while the index is complete: otherwise it may
    /// be the session's live file. True when no such file remains. Caller
    /// holds `archiveLock`.
    private func removeLeftover(of id: UUID, tombstoned: Bool) -> Bool {
        let leftover = archive.archiveDirectory.appendingPathComponent("\(id.uuidString).json")
        guard archive.fileManager.fileExists(atPath: leftover.path) else { return true }
        guard tombstoned, !archive.indexReadFailed, !archive.indexDecodeFailed else { return false }
        return removeQuietly(leftover, id: id)
    }

    /// Removes `url` if it is there; false (logged) when the removal failed.
    private func removeQuietly(_ url: URL, id: UUID) -> Bool {
        guard archive.fileManager.fileExists(atPath: url.path) else { return true }
        do {
            try archive.fileManager.removeItem(at: url)
            return true
        } catch {
            debugLog("[Archive] ⚠️ Could not remove \(url.lastPathComponent) of deleted session \(id.uuidString.prefix(8)): \(error)", level: .warning)
            return false
        }
    }
}

/// Sessions the user deleted forever on this device. Neither pull brings
/// back a copy iCloud still holds of one (a session record or a live backup),
/// and the orphan scan does not adopt a file of one. Kept in `UserDefaults`,
/// the most recent `limit` ids. An id that drops off the end is still covered
/// by its iCloud tombstone: a deletion mark is forgotten only once iCloud has
/// confirmed it (`CloudDeletionCoordinator.tombstoneIsSettled`).
enum ForgottenSessions {
    static let defaultsKey = "sessionRecovery.forgottenBackupIds"
    private static let limit = 500

    static var ids: Set<UUID> {
        Set((UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    /// Adds `id` as the most recent, dropping the oldest beyond `limit`.
    static func remember(_ id: UUID) {
        let defaults = UserDefaults.standard
        let kept = (defaults.stringArray(forKey: defaultsKey) ?? []).filter { $0 != id.uuidString }
        defaults.set(Array((kept + [id.uuidString]).suffix(limit)), forKey: defaultsKey)
    }
}
