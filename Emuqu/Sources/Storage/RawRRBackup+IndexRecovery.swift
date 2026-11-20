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
        let names = attempt("RawRRBackup.listForRecovery") {
            try fileManager.contentsOfDirectory(atPath: backupDirectory.path)
        } ?? []
        let fromHeaders = names.filter { $0.hasSuffix("_header.json") }.compactMap(recoveredEntry(fromHeaderNamed:))
        let headerIds = Set(fromHeaders.map(\.id))
        let oneShots = latestOneShotPerSession(names.compactMap(recoveredEntry(fromOneShotNamed:)))
            .filter { !headerIds.contains($0.id) }
        let entries = fromHeaders + oneShots
        debugLog("[RawRRBackup] index unreadable — rebuilt \(fromHeaders.count) entries from headers, \(oneShots.count) from one-shot files", level: .warning)
        return (entries, movedAside)
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

extension OneShotBackupName {
    /// Every one-shot file of `sessionId` in `directory`, indexed or not.
    /// Throws when the listing fails.
    static func files(of sessionId: UUID, in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { parse($0)?.id == sessionId }
            .map { directory.appendingPathComponent($0) }
    }

    /// One-shot files of `sessionId` in `directory`, other than `current`,
    /// still in plain JSON. Throws when the listing or a read fails.
    static func plaintextFiles(of sessionId: UUID, in directory: URL, except current: String?) throws -> [URL] {
        try files(of: sessionId, in: directory)
            .filter { $0.lastPathComponent != current }
            .filter { try !ArchiveStore.looksEncrypted(Data(contentsOf: $0, options: .alwaysMapped)) }
    }

    /// When the indexed backup was written, in ms: its one-shot file's stamp,
    /// or a streaming backup's last append; 0 when neither is known.
    static func indexedMs(_ entry: RawRRBackup.BackupIndex) -> Int64 {
        entry.fileName != nil
            ? writtenMs(entry.fileName)
            : Int64((entry.lastBackupTime?.timeIntervalSince1970 ?? 0) * 1000)
    }

    /// The fullest one-shot backup of the session the index does not name,
    /// plain or encrypted, holding more beats than the row, decoded; nil when
    /// there is none. Such a file is left by a write whose index save never
    /// happened (killed, or the save failed and a shorter backup followed);
    /// `backup()` takes it, so the repair adopts it. More, not as many: the
    /// adopted source then holds as many as the new row and is not adopted
    /// again, and a plain one is retired as superseded. Nil when the row's
    /// write time or beat count is unknown (a row rebuilt from a header),
    /// whose uncounted points file `backup()` would replace. One decoded
    /// candidate is held at a time beside the fullest so far.
    static func fullerUnindexedBackup(than entry: RawRRBackup.BackupIndex, in directory: URL) throws -> RawRRBackup.BackupEntry? {
        let indexedBeats = entry.backedUpCount ?? (entry.fileName != nil ? entry.beatCount : nil)
        guard indexedMs(entry) > 0, let indexedBeats else { return nil }
        var fullest: RawRRBackup.BackupEntry?
        for url in try files(of: entry.id, in: directory) where url.lastPathComponent != entry.fileName {
            guard let found = attempt("RawRRBackup.readUnindexedFile", { try RawRRBackup.decodeLegacyBackup(at: url) }),
                  found.id == entry.id, found.points.count > (fullest?.points.count ?? indexedBeats) else { continue }
            fullest = found
        }
        return fullest
    }

    /// Whether `url`, a one-shot file the index does not name, was provably
    /// replaced by `entry`: written before the indexed backup (its file, or a
    /// streaming backup's last append) and holding no more beats. A process
    /// killed between a newer write and its index save leaves a file that is
    /// later, and may hold the most of the night; that one, one without a row
    /// or a date to compare, and one that does not decode are not replaced.
    static func isSuperseded(_ url: URL, by entry: RawRRBackup.BackupIndex?) -> Bool {
        guard let entry else { return false }
        guard writtenMs(url.lastPathComponent) < indexedMs(entry),
              let beats = attempt("RawRRBackup.readReplacedFile", { try RawRRBackup.decodeLegacyBackup(at: url).points.count })
        else { return false }
        return beats <= (entry.backedUpCount ?? entry.beatCount)
    }
}
