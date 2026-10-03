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

    /// The file is kept, not erased. Restore used to rebuild the session
    /// from its raw beats, which lost its tags, notes, morning feeling and
    /// sleep edits, and brought a workout back as an overnight reading.
    func moveToTrash(_ fileURL: URL, id: UUID) {
        let fm = archive.fileManager
        do {
            try fm.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            let destination = trashURL(for: id)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: fileURL, to: destination)
        } catch {
            debugLog("[Archive] ⚠️ Could not keep session \(id.uuidString.prefix(8)) in the trash, deleting it: \(error)", level: .warning)
            removeQuietly(fileURL, id: id)
        }
    }

    /// The raw backup still holds the beats, so a file that cannot be moved
    /// is removed as before.
    private func removeQuietly(_ fileURL: URL, id: UUID) {
        do {
            try archive.fileManager.removeItem(at: fileURL)
        } catch {
            debugLog("[Archive] ⚠️ Failed to delete file for session \(id.uuidString.prefix(8)): \(error)")
        }
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

    /// Help says deleted sessions are kept for 90 days; without this they
    /// were kept for ever. Aged by the recorded deletion time, or the file's
    /// own date when none was recorded.
    func expireTrash(keepDays: Int = 90) {
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        for id in trashedIds where (deletionTime(of: id) ?? trashFileDate(id) ?? Date()) < cutoff {
            discardTrashed(id)
        }
    }

    private func trashFileDate(_ id: UUID) -> Date? {
        do {
            return try archive.fileManager.attributesOfItem(atPath: trashURL(for: id).path)[.modificationDate] as? Date
        } catch {
            return nil
        }
    }

    func discardTrashed(_ id: UUID) {
        let url = trashURL(for: id)
        guard archive.fileManager.fileExists(atPath: url.path) else { return }
        do {
            try archive.fileManager.removeItem(at: url)
        } catch {
            debugLog("[Archive] ⚠️ Could not empty trashed session \(id.uuidString.prefix(8)): \(error)", level: .warning)
        }
    }
}
