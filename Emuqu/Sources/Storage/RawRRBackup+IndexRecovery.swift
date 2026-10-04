import Foundation

// Rebuilding the backup index when its file does not decode.
//
// The index is the only list Trash and Lost Sessions read. Emptying it on a
// failed load and saving over the file on the next append made every backup
// on disk invisible, though the backups themselves were intact. Both backup
// formats can be listed again from their own files: an append-format backup
// keeps a header beside its points, and a one-shot backup
// (`<uuid>_<timestamp>.json`, a strap fetch or a cloud recovery) carries its
// own id, date and hash.

extension RawRRBackup {
    /// Moves the undecodable index aside — a rename works even when the bytes
    /// cannot be read — and lists every backup that can still be identified.
    func recoverIndexFromFiles() -> [BackupIndex] {
        let aside = indexFile.deletingLastPathComponent()
            .appendingPathComponent("\(indexFile.lastPathComponent).unreadable_\(Int(Date().timeIntervalSince1970))")
        _ = attempt("RawRRBackup.preserveIndex") { try fileManager.moveItem(at: indexFile, to: aside) }
        let names = attempt("RawRRBackup.listForRecovery") {
            try fileManager.contentsOfDirectory(atPath: backupDirectory.path)
        } ?? []
        let fromHeaders = names.filter { $0.hasSuffix("_header.json") }.compactMap(recoveredEntry(fromHeaderNamed:))
        let headerIds = Set(fromHeaders.map(\.id))
        let oneShots = latestOneShotPerSession(names.compactMap(recoveredEntry(fromOneShotNamed:)))
            .filter { !headerIds.contains($0.id) }
        let entries = fromHeaders + oneShots
        debugLog("[RawRRBackup] index unreadable — rebuilt \(fromHeaders.count) entries from headers, \(oneShots.count) from one-shot files", level: .warning)
        return entries
    }

    /// Not marked archived: a backup listed in Lost Sessions that turns out to
    /// be archived is retired by the next reconcile, while one wrongly marked
    /// archived would be purged. The count is left unknown when the points
    /// cannot be read, so the next append rewrites the file in full rather
    /// than appending at a guessed offset.
    private func recoveredEntry(fromHeaderNamed name: String) -> BackupIndex? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let url = backupDirectory.appendingPathComponent(name)
        guard let data = attempt("RawRRBackup.readHeader", { try Data(contentsOf: url) }),
              let header = attempt("RawRRBackup.decodeHeader", { try decoder.decode(BackupHeader.self, from: data) })
        else { return nil }
        let count = attempt("RawRRBackup.countRecovered") {
            try readPointLines(at: pointsURL(for: header.id), sessionId: header.id, decoder: decoder).count
        }
        return BackupIndex(
            id: header.id, captureDate: header.captureDate, fileName: nil, beatCount: count ?? 0,
            hash: "", archived: false, lastBackupTime: nil, backedUpCount: count
        )
    }

    /// A one-shot backup file, named `<uuid>_<digits>.json`, listed from its
    /// own contents (decrypted when sealed). Nil for any other file name, or
    /// one whose contents no longer decode.
    private func recoveredEntry(fromOneShotNamed name: String) -> BackupIndex? {
        guard name.hasSuffix(".json") else { return nil }
        let parts = name.dropLast(".json".count).split(separator: "_")
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
              parts[1].allSatisfy(\.isNumber) else { return nil }
        let url = backupDirectory.appendingPathComponent(name)
        guard let entry = attempt("RawRRBackup.decodeOneShot", { try Self.decodeLegacyBackup(at: url) }) else { return nil }
        return BackupIndex(
            id: entry.id, captureDate: entry.captureDate, fileName: name, beatCount: entry.points.count,
            hash: entry.hash, archived: false, lastBackupTime: nil, backedUpCount: nil
        )
    }

    /// A newer one-shot backup replaces the older file for the same session;
    /// should both still be on disk, the newest name (largest timestamp) wins.
    private func latestOneShotPerSession(_ entries: [BackupIndex]) -> [BackupIndex] {
        Dictionary(grouping: entries, by: \.id).values.compactMap { group in
            group.max { ($0.fileName ?? "") < ($1.fileName ?? "") }
        }
    }
}
