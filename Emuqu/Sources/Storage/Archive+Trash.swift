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

    /// The file is kept, not erased. Restore used to rebuild the session
    /// from its raw beats, which lost its tags, notes, morning feeling and
    /// sleep edits, and brought a workout back as an overnight reading.
    ///
    /// The moved file is dated now: a move keeps the date of the session's
    /// last write, and `expiredDeletionIds` falls back to the file's date when no
    /// deletion time is recorded, which discarded an old session's file at
    /// the next launch instead of after 90 days.
    ///
    /// Throws when the file could not be moved; it is then left where it was,
    /// so the caller can put the session back in the index. Deleting it there
    /// lost the copy the Trash exists to keep.
    func moveToTrash(_ fileURL: URL, id: UUID) throws {
        let fm = archive.fileManager
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

    /// Removes the Trash file. A session then neither in the index nor in
    /// quarantine has no file left here, so a re-encryption entry for it has
    /// nothing left to repair and is cleared.
    func discardTrashed(_ id: UUID) {
        let url = trashURL(for: id)
        guard archive.fileManager.fileExists(atPath: url.path) else { return }
        do {
            try archive.fileManager.removeItem(at: url)
        } catch {
            debugLog("[Archive] ⚠️ Could not empty trashed session \(id.uuidString.prefix(8)): \(error)", level: .warning)
            return
        }
        if !exists(id), parkedCopies(of: id)?.isEmpty == true { PendingEncryptionLedger.clear(id) }
    }
}
