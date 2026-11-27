import Foundation

// The archive operations whose mechanics live in `ArchiveStore`.

extension SessionArchive {
    /// Move a session to the Trash. Like `archive(_:)` and `update`, a change
    /// is announced (`.flowRecoveryArchiveChanged`), so every observer of the
    /// archive refreshes without the caller having to. Returns false, having
    /// done nothing, for an id the archive does not hold.
    /// `deletedAt` is when the deletion was made, for one applied from
    /// another device (nil: now).
    @discardableResult
    func delete(_ id: UUID, deletedAt: Date? = nil) throws -> Bool {
        let removed = try store.delete(id, deletedAt: deletedAt)
        if removed { NotificationCenter.default.post(name: .flowRecoveryArchiveChanged, object: id) }
        return removed
    }

    /// A session another device restored after this one deleted it: the
    /// local deletion is dropped and the session written as one step. A write
    /// that fails puts the deletion back with its original time, so the
    /// session stays in this device's Trash and the next pull tries again.
    /// The Trash copy is removed once the session is in the archive.
    func archiveRestoredFromAnotherDevice(_ session: HRVSession) throws {
        let deletedAt = store.deletionTime(of: session.id)
        try store.unmarkAsDeleted(session.id)
        do {
            try archive(session, skipSameNightMerge: true)
        } catch {
            store.reinstateDeletion(session.id, deletedAt: deletedAt)
            throw error
        }
        store.discardTrashed(session.id)
        debugLog("[Archive] \(session.id.uuidString.prefix(8)) was restored on another device — this device's deletion dropped", level: .info)
    }

    /// A deletion made on another device at `deletedAt`; announced like `delete`.
    @discardableResult
    func deleteWithoutTrash(_ id: UUID, deletedAt: Date? = nil) throws -> Bool {
        let removed = try store.deleteWithoutTrash(id, deletedAt: deletedAt)
        if removed { NotificationCenter.default.post(name: .flowRecoveryArchiveChanged, object: id) }
        return removed
    }
    /// Takes `archiveLock` around the lookup, which reads `index` and fills
    /// `sessionIdLookup`. Code already holding the lock calls
    /// `store.entryById` directly: `NSLock` is not re-entrant.
    func entryById(_ id: UUID) -> SessionArchiveEntry? {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        return store.entryById(id)
    }
    /// Drop the deletion mark of a session deleted forever: the same removal
    /// from the deleted list as `unmarkAsDeleted`. Called only once iCloud
    /// has confirmed the deletion or this device has never synced
    /// (`CloudDeletionCoordinator.tombstoneIsSettled`).
    func forgetDeletedSession(_ id: UUID) throws { try store.unmarkAsDeleted(id) }
    @discardableResult
    func sessionExists(for date: Date) -> Bool { store.sessionExists(for: date) }
    func linkedSegments(for session: HRVSession) -> [LinkedSegmentInfo]? { store.linkedSegments(for: session) }

    /// Archive `session` and return the night that now holds it: `session`
    /// itself, or the night already archived that the archive folded it into
    /// (a second recording of the same night), read whole. That night is what
    /// the baseline, Apple Health and iCloud then take; the recording under
    /// its own id would put a second copy of the night there. `session` when
    /// that night cannot be read (logged).
    func archiveReturningNight(_ session: HRVSession) throws -> HRVSession {
        let entry = try archive(session)
        guard entry.sessionId != session.id else { return session }
        return retrieveOrLog(entry.sessionId, caller: "SessionArchive.archiveReturningNight") ?? session
    }

    /// Replace a session's tags and notes. `notes` is the whole new value:
    /// every caller passes nil for an empty field, so nil clears the note.
    func updateTags(_ id: UUID, tags: [ReadingTag], notes: String? = nil) throws {
        try update(id) { session in
            session.tags = tags
            session.notes = notes
        }
    }

}
