import Foundation

// Rebuilding the backup index when its file cannot be read.
//
// The index is the only list Trash and Lost Sessions read. Emptying it on a
// failed load and saving over the file on the next append made every backup
// on disk invisible, though the backups themselves were intact. Each
// append-format backup keeps a header beside its points, which is enough to
// list it again.

extension RawRRBackup {
    /// Moves the unreadable index aside — a rename works even when the bytes
    /// cannot be read — and lists every backup that still has a header.
    func recoverIndexFromHeaders() -> [BackupIndex] {
        let aside = indexFile.deletingLastPathComponent()
            .appendingPathComponent("\(indexFile.lastPathComponent).unreadable_\(Int(Date().timeIntervalSince1970))")
        _ = attempt("RawRRBackup.preserveIndex") { try fileManager.moveItem(at: indexFile, to: aside) }
        let names = attempt("RawRRBackup.listForRecovery") {
            try fileManager.contentsOfDirectory(atPath: backupDirectory.path)
        } ?? []
        let entries = names.filter { $0.hasSuffix("_header.json") }.compactMap(recoveredEntry(fromHeaderNamed:))
        debugLog("[RawRRBackup] index unreadable — rebuilt \(entries.count) entries from backup headers", level: .warning)
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
}
