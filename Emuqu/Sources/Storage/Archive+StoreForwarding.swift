import Foundation

// The persistence mechanics live in `ArchiveStore`, keeping ~900 lines
// off `SessionArchive`, which keeps the API callers hold.

extension SessionArchive {
    func _archive(_ session: HRVSession, skipSameNightMerge: Bool = false) throws -> SessionArchiveEntry {
        try store._archive(session, skipSameNightMerge: skipSameNightMerge)
    }

    func _retrieve(_ id: UUID) throws -> HRVSession? { try store._retrieve(id) }
    func archiveBatch(_ sessions: [HRVSession]) throws -> Int { try store.archiveBatch(sessions) }
    func delete(_ id: UUID) throws { try store.delete(id) }
    func entryById(_ id: UUID) -> SessionArchiveEntry? { store.entryById(id) }
    func exists(_ id: UUID) -> Bool { store.exists(id) }
    func forgetDeletedSession(_ id: UUID) throws { try store.forgetDeletedSession(id) }
    func trashedSession(_ id: UUID) -> HRVSession? { store.trashedSession(id) }
    func discardTrashed(_ id: UUID) { store.discardTrashed(id) }
    func expireTrash(keepDays: Int = 90) { store.expireTrash(keepDays: keepDays) }
    var trashedIds: Set<UUID> { store.trashedIds }
    func markAsDeleted(_ id: UUID) throws { try store.markAsDeleted(id) }
    func unmarkAsDeleted(_ id: UUID) throws { try store.unmarkAsDeleted(id) }
    func sessionExists(for date: Date) -> Bool { store.sessionExists(for: date) }
    func wasIntentionallyDeleted(_ id: UUID) -> Bool { store.wasIntentionallyDeleted(id) }
    func deletionTime(of id: UUID) -> Date? { store.deletionTime(of: id) }
    func linkedSegments(for session: HRVSession) -> [LinkedSegmentInfo]? { store.linkedSegments(for: session) }

    var entries: [SessionArchiveEntry] { store.entries }

    func entries(from startDate: Date, to endDate: Date) -> [SessionArchiveEntry] {
        store.entries(from: startDate, to: endDate)
    }

    func entries(
        includingTags includeTags: [ReadingTag], excludingTags excludeTags: [ReadingTag] = []
    ) -> [SessionArchiveEntry] {
        store.entries(includingTags: includeTags, excludingTags: excludeTags)
    }
    var deletedIds: Set<UUID> { store.deletedIds }

    func hasSessionNear(date: Date, toleranceMinutes: Int = 30) -> Bool {
        store.hasSessionNear(date: date, toleranceMinutes: toleranceMinutes)
    }

    /// Replace a session's tags and notes. `notes` is the whole new value:
    /// every caller passes nil for an empty field, so nil clears the note.
    func updateTags(_ id: UUID, tags: [ReadingTag], notes: String? = nil) throws {
        try update(id) { session in
            session.tags = tags
            session.notes = notes
        }
    }

    /// Pure helpers — no archive state — so they forward to the type.
    static func loadAndDecodeSessionFile(at fileURL: URL, decoder: JSONDecoder) throws -> HRVSession {
        try ArchiveStore.loadAndDecodeSessionFile(at: fileURL, decoder: decoder)
    }

    static func looksEncrypted(_ data: Data) -> Bool { ArchiveStore.looksEncrypted(data) }

    static func normalizedSplitNightSegments(
        currentSessionId: UUID,
        currentStartDate: Date,
        currentEndDate: Date,
        linkedSegments: [LinkedSegmentInfo]
    ) -> [LinkedSegmentInfo] {
        ArchiveStore.normalizedSplitNightSegments(
            currentSessionId: currentSessionId, currentStartDate: currentStartDate,
            currentEndDate: currentEndDate, linkedSegments: linkedSegments
        )
    }
}
