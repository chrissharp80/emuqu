import Foundation

// How the archive tells which on-disk files and sessions its index already
// holds, and the boot pass that keeps one entry per session with its file
// named the way current builds name it.

extension SessionArchive {
    /// The file names and session ids an index points at. A legacy entry
    /// stores an absolute path whose container changes with a reinstall or a
    /// restore, so a file counts as indexed by its last path component, and a
    /// session counts as indexed by its id whatever its file is called.
    struct IndexedFiles {
        let fileNames: Set<String>
        let sessionIds: Set<UUID>

        init(_ entries: [SessionArchiveEntry]) {
            fileNames = Set(entries.map { ($0.filePath as NSString).lastPathComponent })
            sessionIds = Set(entries.map(\.sessionId))
        }

        func contains(fileNamed name: String) -> Bool {
            fileNames.contains((name as NSString).lastPathComponent)
        }
    }

    /// At boot, under the lock: rewrite a legacy absolute file path to the
    /// bare name when the file is in this archive directory, and collapse
    /// entries of one session id into the one entry whose hash matches its
    /// file. Every reader resolves a bare name to the same file
    /// (`resolveFileURL`), so the rewrite changes no read; a path whose file
    /// is elsewhere is left as it is. Saved only when something changed.
    func normalizeIndexIdentity() {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        guard !state.indexReadFailed, !state.indexDecodeFailed else { return }
        let rewritten = rewriteLegacyFilePaths()
        let collapsed = collapseSameSessionEntries()
        guard rewritten || collapsed else { return }
        state.sortedEntriesCache = nil
        state.sessionIdLookup = nil
        attempt("Archive.normalizeIndex") { try state.saveIndex() }
        debugLog("[Archive] index normalised: legacy paths \(rewritten), same-session entries collapsed \(collapsed)")
    }

    /// True when any absolute path became a bare name. Caller holds the lock.
    private func rewriteLegacyFilePaths() -> Bool {
        var changed = false
        for position in state.index.indices where state.index[position].filePath.hasPrefix("/") {
            let name = (state.index[position].filePath as NSString).lastPathComponent
            guard fileManager.fileExists(atPath: archiveDirectory.appendingPathComponent(name).path) else { continue }
            state.index[position].filePath = name
            changed = true
        }
        return changed
    }

    /// True when any session id had more than one entry. The kept entry is
    /// the one whose hash matches the file on disk, else the last written,
    /// at the position of the first. Caller holds the lock.
    private func collapseSameSessionEntries() -> Bool {
        let groups = Dictionary(grouping: state.index.indices, by: { state.index[$0].sessionId })
        let repeated = groups.values.filter { $0.count > 1 }
        guard !repeated.isEmpty else { return false }
        var dropped = Set<Int>()
        for positions in repeated {
            let kept = positions.first(where: entryMatchesItsFile) ?? positions[positions.count - 1]
            state.index[positions[0]] = state.index[kept]
            dropped.formUnion(positions.dropFirst())
        }
        state.index = state.index.indices.filter { !dropped.contains($0) }.map { state.index[$0] }
        return true
    }

    /// Whether the entry's stored hash is the hash of its file's bytes.
    private func entryMatchesItsFile(_ position: Int) -> Bool {
        let entry = state.index[position]
        guard let data = attempt("Archive.readForIndexCollapse", { try Data(contentsOf: state.resolveFileURL(for: entry)) }) else { return false }
        return SessionFileCodec.sha256Hex(data) == entry.fileHash
    }
}
