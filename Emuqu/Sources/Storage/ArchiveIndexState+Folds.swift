import Foundation

// MARK: - Ids the archive keeps under another id
//
// A recording folded into a same-night session it already held
// (`sameNightMerge`, a batch import's merge) has no entry of its own: its
// beats and answers are in the other session. A duplicate retired by the
// launch cleanup has its user content carried into the copy kept. Screens,
// backups and markers made before either still name the old id; the archive
// answers a write to that id on the session that holds it now, the Lost
// Sessions scan does not offer the recording's backup again, and the morning
// treats the night as saved. Kept across launches beside the index, since a
// raw backup and a recording marker outlive the launch that folded them.

extension ArchiveIndexState {
    /// Beside the index. Not a `.json` name, so the orphan scan never reads
    /// it as a session file.
    var foldedIndexFile: URL { archiveDirectory.appendingPathComponent("folded_recordings.map") }

    /// More hops than a real chain has (a recording folded into a copy the
    /// cleanup retired later): a cycle in a damaged file ends here.
    private static let maxFoldHops = 8

    /// The id the archive keeps `id` under: `id` itself while the index
    /// lists it, otherwise the session it was folded or retired into.
    /// Caller holds `archiveLock`.
    func resolvedId(_ id: UUID) -> UUID {
        var current = id
        for _ in 0 ..< Self.maxFoldHops {
            guard let next = foldedInto[current], !index.contains(where: { $0.sessionId == current }) else { break }
            current = next
        }
        return current
    }

    /// Remember that `id` is now kept under `keptId`, and save the list. A
    /// failed save is logged: the fold still holds for this launch. Caller
    /// holds `archiveLock`.
    func recordFold(of id: UUID, into keptId: UUID) {
        guard id != keptId, foldedInto[id] != keptId else { return }
        foldedInto[id] = keptId
        attempt("Archive.saveFoldedIndex") { try saveFoldedIndex() }
    }

    /// Read the list at launch. A missing file is an empty list; one that
    /// does not read is logged and left in place, and this launch starts
    /// from the folds it makes itself.
    func loadFoldedIndex() {
        guard fileManager.fileExists(atPath: foldedIndexFile.path) else { return }
        let pairs: [String: String]
        do {
            pairs = try SessionArchive.sessionDecoder.decode([String: String].self, from: Data(contentsOf: foldedIndexFile))
        } catch {
            debugLog("[Archive] Folded recordings list could not be read: \(error)", level: .error)
            return
        }
        for case let (fromId?, toId?) in pairs.map({ (UUID(uuidString: $0.key), UUID(uuidString: $0.value)) }) {
            foldedInto[fromId] = toId
        }
    }

    /// While "Delete All My Data" runs the save throws `PurgeGate.Refused`
    /// and writes nothing (`PurgeGate`).
    private func saveFoldedIndex() throws {
        try PurgeGate.admitWrite {
            let pairs = Dictionary(uniqueKeysWithValues: foldedInto.map { ($0.key.uuidString, $0.value.uuidString) })
            let data = try SessionArchive.indexEncoder.encode(pairs)
            try data.write(to: foldedIndexFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
