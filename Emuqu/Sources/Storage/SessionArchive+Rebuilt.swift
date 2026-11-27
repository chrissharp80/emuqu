import Foundation

// A session rebuilt from its recording (a repaired series, a recovery from the
// raw backup, a night processed again, a workout rebuilt from Apple Health) is
// written over the archived copy of the same id. What the user set on that
// copy is not in the rebuild, so it is carried across here, from the copy as
// stored at the write, by one rule (`SessionMerger.keepUserEdits`).

extension SessionArchive {
    /// Writes `rebuilt` over the archived copy of its id, under the archive's
    /// lock, keeping the user's edits and the edit stamp of that copy. Nil,
    /// with nothing written, when the archive does not hold the id.
    func rewriteKeepingUserEdits(_ rebuilt: HRVSession, requestingReupload: Bool = false) throws -> HRVSession? {
        guard store.exists(rebuilt.id) else { return nil }
        var written: HRVSession?
        try update(rebuilt.id, requestingReupload: requestingReupload) { stored in
            var replacement = rebuilt
            SessionMerger.keepUserEdits(of: stored, in: &replacement)
            stored = replacement
            written = stored
        }
        return written
    }

    /// `rewriteKeepingUserEdits` when the archive holds the id, otherwise a
    /// new session archived as `archive(_:skipSameNightMerge:requestingReupload:)`
    /// archives it. Returns the entry that now holds it.
    @discardableResult
    func archiveRebuilt(_ rebuilt: HRVSession, requestingReupload: Bool = false) throws -> SessionArchiveEntry {
        guard try rewriteKeepingUserEdits(rebuilt, requestingReupload: requestingReupload) != nil else {
            return try archive(rebuilt, skipSameNightMerge: false, requestingReupload: requestingReupload)
        }
        guard let entry = entryById(rebuilt.id) else { throw ArchiveError.fileNotFound }
        return entry
    }
}
