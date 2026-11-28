import Foundation

// MARK: - Moves interrupted between a file and the index

// A delete, a restore from the Trash and duplicate cleanup each change the
// index (or the deletion list) and move a file, in two steps. A kill between
// them leaves a state no screen offers a way out of. At launch, before the
// orphan scan, each such state is finished the way the change meant it:
//
// - delete, killed after the deletion mark was saved and before the index
//   was: the session is listed and marked deleted, so it still shows while
//   every write to it is refused. The delete is finished.
// - restore from the Trash, killed after the deletion mark was dropped and
//   before the session was written back: its Trash file has neither a mark
//   nor an entry, so neither the Trash nor History lists it. The file goes
//   back to the archive folder, where the orphan scan adopts it.
// - duplicate cleanup, killed after the copy's file moved into quarantine
//   and before the index dropped it: the index names a file that is not
//   there, so every read of the copy fails and the next cleanup cannot read
//   it to retire it. The quarantined file with exactly the bytes the entry's
//   hash names goes back, and the next cleanup retires it whole.
//
// Each needs both lists loaded: with either read only in part, a listed or
// unmarked session may be live.

extension ArchiveStore {
    func finishInterruptedMoves() {
        state.archiveLock.lock()
        defer { state.archiveLock.unlock() }
        guard !state.indexReadFailed, !state.indexDecodeFailed, !state.deletedIndexReadFailed,
              let names = attempt("Archive.listForInterruptedMoves", {
                  try state.fileManager.contentsOfDirectory(atPath: state.archiveDirectory.path)
              }) else { return }
        finishInterruptedDrops()
        putBackInterruptedRestores(present: Set(names))
        returnInterruptedQuarantines(present: Set(names))
    }

    /// Drops the entries of sessions marked deleted. Their files are moved to
    /// the Trash by `finishInterruptedDeletes`, which runs next. A save that
    /// fails puts the entries back for the next launch. Caller holds the lock.
    private func finishInterruptedDrops() {
        let deleted = state.deletedSessionIds
        let preIndex = state.index
        state.index.removeAll { deleted.contains($0.sessionId) }
        guard state.index.count != preIndex.count else { return }
        state.sortedEntriesCache = nil
        state.sessionIdLookup = nil
        guard attempt("Archive.finishInterruptedDrop", { try state.saveIndex() }) != nil else {
            state.index = preIndex
            return
        }
        debugLog("[Archive] \(preIndex.count - state.index.count) session(s) left listed by an interrupted delete — removed", level: .warning)
    }

    /// Moves back each Trash file whose session is neither marked deleted,
    /// listed, nor deleted forever. Caller holds the lock.
    private func putBackInterruptedRestores(present names: Set<String>) {
        let forgotten = ForgottenSessions.ids
        let stranded = trashedIds.filter {
            !state.deletedSessionIds.contains($0) && entryById($0) == nil && !forgotten.contains($0)
                && !names.contains("\($0.uuidString).json")
        }
        for id in stranded {
            let destination = state.archiveDirectory.appendingPathComponent("\(id.uuidString).json")
            let trashed = trashDirectory.appendingPathComponent("\(id.uuidString).session")
            guard attempt("Archive.putBackInterruptedRestore", { try state.fileManager.moveItem(at: trashed, to: destination) }) != nil else { continue }
            debugLog("[Archive] \(id.uuidString.prefix(8)) was left in the Trash by an interrupted restore — put back", level: .warning)
        }
    }

    /// Puts back the quarantined copy of each listed session whose file is
    /// missing. Caller holds the lock.
    private func returnInterruptedQuarantines(present names: Set<String>) {
        let missing = state.index.filter { !names.contains(($0.filePath as NSString).lastPathComponent) }
        guard !missing.isEmpty, state.fileManager.fileExists(atPath: quarantineDirectory.path),
              let quarantined = attempt("Archive.listQuarantineForReturn", {
                  try state.fileManager.contentsOfDirectory(atPath: quarantineDirectory.path)
              }) else { return }
        for entry in missing {
            returnQuarantinedCopy(of: entry, among: quarantined)
        }
    }

    /// The copy in quarantine whose bytes hash to `entry.fileHash`, moved
    /// back to where the index expects it. Caller holds the lock.
    private func returnQuarantinedCopy(of entry: SessionArchiveEntry, among names: [String]) {
        let id = entry.sessionId.uuidString
        let candidates = names.filter { $0.hasPrefix(id) && $0.hasSuffix(".json") }
            .map { quarantineDirectory.appendingPathComponent($0) }
        guard let copy = candidates.first(where: { url in
            attempt("Archive.readQuarantinedCopy", { try Data(contentsOf: url) })
                .map { SessionArchive.SessionFileCodec.sha256Hex($0) == entry.fileHash } ?? false
        }) else { return }
        let original = state.resolveFileURL(for: entry)
        guard attempt("Archive.returnQuarantinedCopy", { try state.fileManager.moveItem(at: copy, to: original) }) != nil else { return }
        debugLog("[Archive] \(id.prefix(8)) was left in quarantine by an interrupted duplicate cleanup — put back", level: .warning)
    }
}
