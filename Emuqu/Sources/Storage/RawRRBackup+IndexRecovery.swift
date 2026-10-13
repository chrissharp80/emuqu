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

    /// A one-shot backup file, named `<uuid>_<digits>.json` (either stamp
    /// form, see `OneShotBackupName`), listed from its own contents (decrypted
    /// when sealed). Nil for any other file name, or one whose contents no
    /// longer decode.
    private func recoveredEntry(fromOneShotNamed name: String) -> BackupIndex? {
        guard OneShotBackupName.parse(name) != nil else { return nil }
        let url = backupDirectory.appendingPathComponent(name)
        guard let entry = attempt("RawRRBackup.decodeOneShot", { try Self.decodeLegacyBackup(at: url) }) else { return nil }
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

/// File names of one-shot backups: `<uuid>_<stamp>.json`.
///
/// The stamp is the write time in milliseconds, raised past any name already
/// taken, so no two writes share a file. Files written before this change
/// carry whole seconds (10 digits); `parse` reads both forms as milliseconds.
enum OneShotBackupName {
    /// A name for a backup of `sessionId` written at `now` for which
    /// `isTaken` is false.
    static func make(for sessionId: UUID, at now: Date, isTaken: (String) -> Bool) -> String {
        var stamp = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        while isTaken(name(sessionId, stamp)) { stamp += 1 }
        return name(sessionId, stamp)
    }

    /// The session id and write time (ms since 1970) a one-shot name holds,
    /// or nil for any other file name. A stamp shorter than 12 digits is in
    /// seconds.
    static func parse(_ fileName: String) -> (id: UUID, writtenMs: Int64)? {
        guard fileName.hasSuffix(".json") else { return nil }
        let parts = fileName.dropLast(".json".count).split(separator: "_")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
              parts[1].allSatisfy(\.isNumber), let stamp = Int64(parts[1]) else { return nil }
        return (id, parts[1].count < 12 ? stamp * 1000 : stamp)
    }

    /// Write time of a one-shot name in ms; 0 for nil or any other name.
    static func writtenMs(_ fileName: String?) -> Int64 {
        fileName.flatMap(parse)?.writtenMs ?? 0
    }

    private static func name(_ sessionId: UUID, _ stamp: Int64) -> String {
        "\(sessionId.uuidString)_\(stamp).json"
    }
}
