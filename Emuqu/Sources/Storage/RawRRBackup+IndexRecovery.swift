import Foundation

// Rebuilding the backup index when its file does not decode.
//
// The index is the only list Trash and Lost Sessions read. Emptying it on a
// failed load and saving over the file on the next append made every backup
// on disk invisible, though the backups themselves were intact. Both backup
// formats can be listed again from their own files: an append-format backup
// keeps a header beside its points, and a one-shot backup
// (`<uuid>_<stamp>.json`, a strap fetch or a cloud recovery) carries its
// own id, date and hash.

extension RawRRBackup {
    /// Moves the undecodable index aside — a rename works even when the bytes
    /// cannot be read — and lists every backup that can still be identified.
    /// `replaceable` is false when the move failed: the file is still at
    /// `indexFile`, and the caller keeps every save from writing over it.
    func recoverIndexFromFiles() -> (entries: [BackupIndex], replaceable: Bool) {
        let aside = indexFile.deletingLastPathComponent()
            .appendingPathComponent("\(indexFile.lastPathComponent).unreadable_\(Int(Date().timeIntervalSince1970))")
        let movedAside = attempt("RawRRBackup.preserveIndex") { try fileManager.moveItem(at: indexFile, to: aside) } != nil
        let entries = entriesOnDisk(skipping: [])
        debugLog("[RawRRBackup] index unreadable — rebuilt \(entries.count) entries from headers and one-shot files", level: .warning)
        return (entries, movedAside)
    }

    /// Adds a row for each backup on disk the index does not name, and
    /// saves: a session whose first append wrote its header and points but
    /// was killed before the index save, a one-shot write killed before its
    /// row, or every backup when the index file is missing. Ids the user
    /// deleted forever (`forgottenBackupIds`) are skipped; a session in the
    /// Trash is listed again, where the Trash shows it. Nothing happens while
    /// the index could not be read. Runs on `appendQueue`
    /// (`reconcileIndexInBackground`).
    func reconcileIndexWithFiles() {
        let known: Set<UUID>? = indexLock.withLock { indexReadFailed ? nil : Set(index.map(\.id)) }
        guard let known else { return }
        let found = entriesOnDisk(skipping: known.union(Self.forgottenBackupIds()))
        guard !found.isEmpty else { return }
        indexLock.withLock {
            let listed = Set(index.map(\.id))
            index += found.filter { !listed.contains($0.id) }
        }
        debugLog("[RawRRBackup] listed \(found.count) backup(s) on disk the index did not name", level: .warning)
        attempt("RawRRBackup.saveReconciledIndex") { try saveIndex() }
    }

    /// Sessions the user deleted forever (`ForgottenSessions`).
    static func forgottenBackupIds() -> Set<UUID> {
        ForgottenSessions.ids
    }

    /// A row for every backup in the folder whose id is not in `skipped`:
    /// from its header for the append format, else from its newest one-shot
    /// file. Only files of ids not skipped are read.
    private func entriesOnDisk(skipping skipped: Set<UUID>) -> [BackupIndex] {
        let names = (attempt("RawRRBackup.listForRecovery") {
            try fileManager.contentsOfDirectory(atPath: backupDirectory.path)
        } ?? []).filter { UUID(uuidString: String($0.prefix(36))).map { !skipped.contains($0) } ?? false }
        let fromHeaders = names.filter { $0.hasSuffix("_header.json") }.compactMap(recoveredEntry(fromHeaderNamed:))
        let headerIds = Set(fromHeaders.map(\.id))
        let oneShots = latestOneShotPerSession(names.compactMap(recoveredEntry(fromOneShotNamed:)))
            .filter { !headerIds.contains($0.id) }
        return fromHeaders + oneShots
    }

    /// Not marked archived: a backup listed in Lost Sessions that turns out to
    /// be archived is retired by the next reconcile, while one wrongly marked
    /// archived would be purged. The count is left unknown when the points
    /// cannot be read, so the next append writes every point again rather
    /// than appending at a guessed offset (`startAppendFormat` keeps or sets
    /// aside what the file held).
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

    /// A one-shot backup file, named `<uuid>_<digits>.json` (either stamp
    /// form, see `OneShotBackupName`), listed from its own contents (decrypted
    /// when sealed). Nil for any other file name, or one whose contents no
    /// longer decode.
    private func recoveredEntry(fromOneShotNamed name: String) -> BackupIndex? {
        guard OneShotBackupName.parse(name) != nil else { return nil }
        let url = backupDirectory.appendingPathComponent(name)
        guard let entry = attempt("RawRRBackup.decodeOneShot", { try Self.decodeLegacyBackup(at: url, encryption: encryption) }) else { return nil }
        return BackupIndex(
            id: entry.id, captureDate: entry.captureDate, fileName: name, beatCount: entry.points.count,
            hash: entry.hash, archived: false, lastBackupTime: nil, backedUpCount: nil
        )
    }

    /// A newer one-shot backup replaces the older file for the same session;
    /// should both still be on disk, the latest write time wins. Compared as
    /// times, not as text: a seconds stamp and a milliseconds stamp do not
    /// sort by their characters.
    private func latestOneShotPerSession(_ entries: [BackupIndex]) -> [BackupIndex] {
        Dictionary(grouping: entries, by: \.id).values.compactMap { group in
            group.max { OneShotBackupName.writtenMs($0.fileName) < OneShotBackupName.writtenMs($1.fileName) }
        }
    }
}
