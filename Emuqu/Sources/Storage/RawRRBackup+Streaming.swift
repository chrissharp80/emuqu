import CryptoKit
import Foundation

// The append-only streaming backup path, its helpers and error type. Members
// are internal rather than `private` because Swift's `private` does not reach
// across files.

extension RawRRBackup {
    // MARK: - Append-Only Backup (Streaming)

    /// Append only new points since the last backup. Constant cost per call.
    /// Returns once the points and the session's index row are both on disk;
    /// throws otherwise.
    ///
    /// Switching a one-shot backup to this format replaces it, so the switch
    /// follows `backup()`'s rule: never over a backup that holds more beats.
    func appendBackup(points: [RRPoint], sessionId: UUID, deviceId: String? = nil) throws {
        try mergeIndexIfLaunchReadFailed()
        indexLock.lock()
        let existingEntry = index.first { $0.id == sessionId }
        indexLock.unlock()
        let previousCount = existingEntry?.backedUpCount ?? 0
        // Nothing new to write: only an index save a failed write left owed.
        guard points.count > previousCount else { return try saveIndexIfOwed() }
        let pointsPath = pointsURL(for: sessionId)
        let switchesFormat = try startAppendFormatIfNew(existingEntry, sessionId: sessionId, deviceId: deviceId, newCount: points.count)
        try writeAppendData(try encodedLines(points[previousCount...], sessionId: sessionId), to: pointsPath, sessionId: sessionId) {
            try encodedLines(points[...], sessionId: sessionId)
        }
        try updateAppendIndex(sessionId: sessionId, existingEntry: existingEntry, beatCount: points.count)
        if switchesFormat, let legacyName = existingEntry?.fileName { removeReplacedLegacyFile(legacyName) }
    }

    /// The one-shot backup a format switch replaced, removed once the
    /// streaming copy and its index row are written. A failed removal leaves
    /// a file the index no longer names, which costs space; one still queued
    /// for re-encryption keeps the session queued, and
    /// `RawBackupSealer.reencrypt` removes it.
    private func removeReplacedLegacyFile(_ legacyName: String) {
        do {
            try fileManager.removeItem(at: backupDirectory.appendingPathComponent(legacyName))
        } catch {
            debugLog("[RawRRBackup] ⚠️ Failed to remove legacy file during format switch: \(error)")
        }
    }

    /// First backup for this session, or the first since a one-shot backup:
    /// write the header and start the points file, and return true. A
    /// one-shot backup it replaces stays on disk, and in the index, until the
    /// new file holds every point and the index names it (`appendBackup`):
    /// deleted first, a failed write or a crash in between left neither copy.
    private func startAppendFormatIfNew(
        _ existingEntry: BackupIndex?, sessionId: UUID, deviceId: String?, newCount: Int
    ) throws -> Bool {
        guard existingEntry == nil || existingEntry?.backedUpCount == nil else { return false }
        try refuseReplacingLargerBackup(existingEntry, newCount: newCount)
        try startAppendFormat(sessionId: sessionId, deviceId: deviceId, existingEntry: existingEntry)
        return true
    }

    /// Throws when the one-shot backup a format switch would replace holds
    /// more beats than the points about to replace it.
    private func refuseReplacingLargerBackup(_ existing: BackupIndex?, newCount: Int) throws {
        guard let existing, existing.beatCount > newCount else { return }
        throw BackupError.wouldReplaceLargerBackup(existing: existing.beatCount, new: newCount)
    }

    /// Write the session header and start the points file. A legacy
    /// single-file backup being replaced is left in place; `appendBackup`
    /// removes it once the new copy is written and indexed.
    ///
    /// Both files are written with `BackupProtection.appendable` named
    /// explicitly, so the overnight appends keep working while the device is
    /// locked.
    ///
    /// The header keeps a replaced one-shot backup's capture date: recovery
    /// uses it as the session start, and the moment of the switch is not that.
    func startAppendFormat(
        sessionId: UUID, deviceId: String?, existingEntry: BackupIndex?
    ) throws {
        let header = BackupHeader(id: sessionId, captureDate: existingEntry?.captureDate ?? Date(), deviceId: deviceId)
        try writeHeaderUnlessReadable(header)
        try keepOrStartPointsFile(sessionId)
    }

    /// A header already on disk that decodes is kept: it was written by this
    /// session's first append, whose index save never happened, and its date
    /// is the session's real start.
    private func writeHeaderUnlessReadable(_ header: BackupHeader) throws {
        let url = headerURL(for: header.id)
        if fileManager.fileExists(atPath: url.path),
           attempt("RawRRBackup.readExistingHeader", { try Self.decodedHeader(at: url) }) != nil {
            return
        }
        try lineEncoder.encode(header).write(to: url, options: [.atomic, BackupProtection.appendable])
    }

    /// Starts an empty points file, or keeps the one already there: a first
    /// append killed before its index save, or a session resumed after a
    /// relaunch, left beats in it that no row counts. The batch is appended
    /// after them and a read merges the two by time (`readAllPointLines`).
    /// One that does not read is set aside first, as `rewriteKeepingExisting`
    /// does, and throws when it cannot be.
    private func keepOrStartPointsFile(_ sessionId: UUID) throws {
        let url = pointsURL(for: sessionId)
        if fileManager.fileExists(atPath: url.path) {
            guard attempt("RawRRBackup.readExistingPoints", { try String(contentsOf: url, encoding: .utf8) }) == nil else { return }
            try preserveCorruptedPointsFile(at: url, sessionId: sessionId)
        }
        try Data().write(to: url, options: [BackupProtection.appendable])
    }

    /// The header file at `url`, decoded.
    static func decodedHeader(at url: URL) throws -> BackupHeader {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupHeader.self, from: Data(contentsOf: url))
    }

    /// Encode points as JSONL, one line per point, each sealed with
    /// `EncryptionManager` and base64-encoded (`SealedJSONLines`), the
    /// app-layer encryption one-shot backups and archived sessions get. When
    /// the key cannot be reached, or sealing throws, the rest of the batch is
    /// plain JSON lines: that is logged and the session is queued in
    /// `PendingEncryptionLedger` before anything is written, and
    /// `RawBackupSealer.reencrypt` seals them later. Both kinds read back
    /// (`decodePointLine`).
    func encodedLines(_ points: ArraySlice<RRPoint>, sessionId: UUID) throws -> Data {
        let encoded = try SealedJSONLines.encode(points, with: lineEncoder, manager: SealedJSONLines.availableManager())
        if !encoded.allSealed {
            debugLog("[RawRRBackup] \(points.count) streamed beats of \(sessionId.uuidString.prefix(8)) appended WITHOUT app-layer encryption", level: .error)
            PendingEncryptionLedger.record(sessionId, in: .rawBackup)
        }
        return encoded.data
    }

    /// One point from a line of the points file, sealed or plain.
    func decodePointLine(_ line: Substring, decoder: JSONDecoder) throws -> RRPoint {
        try decoder.decode(RRPoint.self, from: SealedJSONLines.open(line, with: AppDependencies.current.storage.encryptionManager))
    }

    /// Append to the points file through `JSONLinesFile.append`, which cuts
    /// off a line torn by a kill mid-write before appending, so the batch
    /// does not fuse with that fragment into a line no read decodes. A failed
    /// write throws to the caller, which logs it and retries on the next
    /// interval with the beats still buffered.
    ///
    /// A file that is missing, or that would not open or read and was set
    /// aside, is replaced by a fresh one holding every point so far
    /// (`allLines`), so the count the caller then indexes is what the file
    /// holds.
    func writeAppendData(
        _ appendData: Data, to pointsPath: URL, sessionId: UUID, allLines: () throws -> Data
    ) throws {
        switch JSONLinesFile.append(appendData, toExisting: pointsPath) {
        case .appended: return
        case let .writeFailed(error): throw error
        case .couldNotOpen: break
        }
        if fileManager.fileExists(atPath: pointsPath.path),
           try rewriteKeepingExisting(appendData, at: pointsPath, sessionId: sessionId) {
            return
        }
        do {
            try allLines().write(to: pointsPath, options: [BackupProtection.appendable])
        } catch {
            debugLog("[RawRRBackup] ERROR: Fallback write failed for \(sessionId.uuidString.prefix(8)): \(error); the beats stay buffered for the next attempt", level: .error)
            throw error
        }
    }

    /// The handle would not open but the bytes may still read: carry their
    /// complete lines (`JSONLinesFile.completeLines`) into the rewrite so the
    /// night so far is not left behind in a file only recovery knows to look
    /// for. False when they don't read either; the file is then set aside for
    /// recovery and the caller writes a fresh one. Throws when it cannot be
    /// set aside, so nothing is written over it.
    private func rewriteKeepingExisting(_ appendData: Data, at pointsPath: URL, sessionId: UUID) throws -> Bool {
        guard let existing = attempt("RawRRBackup.readForRewrite", { try Data(contentsOf: pointsPath) }) else {
            try preserveCorruptedPointsFile(at: pointsPath, sessionId: sessionId)
            return false
        }
        try (JSONLinesFile.completeLines(of: existing) + appendData).write(to: pointsPath, options: [.atomic, BackupProtection.appendable])
        return true
    }

    /// File exists, won't open and won't read. Preserved for recovery:
    /// `readAllPointLines` reads these alongside the live file. Named
    /// `.corrupted_<ms>`, raised past any name taken, so a second failure in
    /// the same moment does not collide with the first. Throws when the move
    /// fails: the caller must not write over the file, and the batch stays
    /// buffered for the next interval.
    func preserveCorruptedPointsFile(at pointsPath: URL, sessionId: UUID) throws {
        let prefix = pointsPath.lastPathComponent + ".corrupted_"
        var stamp = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
        while fileManager.fileExists(atPath: backupDirectory.appendingPathComponent(prefix + "\(stamp)").path) { stamp += 1 }
        debugLog("[RawRRBackup] WARNING: FileHandle failed on existing points file for \(sessionId.uuidString.prefix(8)); renaming to \(prefix)\(stamp) for recovery")
        do {
            try fileManager.moveItem(at: pointsPath, to: backupDirectory.appendingPathComponent(prefix + "\(stamp)"))
        } catch {
            debugLog("[RawRRBackup] WARNING: Failed to preserve corrupted points file for \(sessionId.uuidString.prefix(8)): \(error)", level: .warning)
            throw BackupError.couldNotSetAside(pointsPath.lastPathComponent)
        }
    }

    /// No per-backup hash in the append format — integrity is count-based.
    func updateAppendIndex(
        sessionId: UUID, existingEntry: BackupIndex?, beatCount: Int
    ) throws {
        let now = Date()
        let updatedEntry = BackupIndex(
            id: sessionId,
            captureDate: existingEntry?.captureDate ?? now,
            fileName: nil,
            beatCount: beatCount,
            hash: "",
            archived: existingEntry?.archived ?? false,
            lastBackupTime: now,
            backedUpCount: beatCount
        )
        indexLock.lock()
        index.removeAll { $0.id == sessionId }
        index.append(updatedEntry)
        indexLock.unlock()
        try saveIndex()
    }

    /// Read a backup stored in append-only format (header + JSONL points)
    func retrieveAppendFormat(sessionId: UUID, indexEntry: BackupIndex) throws -> BackupEntry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header = try Self.decodedHeader(at: headerURL(for: sessionId))
        let points = try readAllPointLines(sessionId: sessionId, decoder: decoder)
        guard !points.isEmpty else {
            throw BackupError.noDataToBackup
        }
        checkRecoveredCount(points.count, against: indexEntry, sessionId: sessionId)
        return BackupEntry(
            id: header.id,
            captureDate: header.captureDate,
            deviceId: header.deviceId,
            points: points,
            // Hash over the recovered points, for BackupEntry compatibility.
            hash: try Self.integrityHash(of: points)
        )
    }

    /// Decode the JSONL points file line by line, skipping corrupted lines
    /// (e.g. a truncated write from a crash).
    /// The live points file plus any `.corrupted_*` sibling an earlier append
    /// set aside, merged in time order. Those siblings hold the beats from
    /// before the append failed; reading the live file alone recovered only
    /// what came after.
    ///
    /// Always merged by timestamp, so a beat written twice (an append retried
    /// after a partial write) is recovered once. Without siblings the live
    /// file must exist.
    func readAllPointLines(sessionId: UUID, decoder: JSONDecoder) throws -> [RRPoint] {
        let livePath = pointsURL(for: sessionId)
        let siblings = corruptedSiblingNames(of: livePath)
        var byTime: [Int64: RRPoint] = [:]
        for name in siblings {
            let url = backupDirectory.appendingPathComponent(name)
            for point in (attempt("RawRRBackup.readSibling") { try readPointLines(at: url, sessionId: sessionId, decoder: decoder) } ?? []) {
                byTime[point.t_ms] = point
            }
        }
        if siblings.isEmpty || fileManager.fileExists(atPath: livePath.path) {
            for point in try readPointLines(at: livePath, sessionId: sessionId, decoder: decoder) {
                byTime[point.t_ms] = point
            }
        }
        return byTime.values.sorted { $0.t_ms < $1.t_ms }
    }

    /// Names of the `.corrupted_*` files set aside from this points file.
    func corruptedSiblingNames(of livePath: URL) -> [String] {
        let prefix = livePath.lastPathComponent + ".corrupted_"
        return (attempt("RawRRBackup.listSiblings") {
            try fileManager.contentsOfDirectory(atPath: backupDirectory.path)
        } ?? []).filter { $0.hasPrefix(prefix) }
    }

    /// Lines that do not decode (a torn write, or a sealed line whose key is
    /// not on this device) are skipped and counted in one log line.
    func readPointLines(at pointsPath: URL, sessionId: UUID, decoder: JSONDecoder) throws -> [RRPoint] {
        let pointsString = try String(contentsOf: pointsPath, encoding: .utf8)
        let lines = pointsString.split(separator: "\n", omittingEmptySubsequences: true)
        var points: [RRPoint] = []
        points.reserveCapacity(lines.count)
        var skipped = 0
        for line in lines {
            do {
                points.append(try decodePointLine(line, decoder: decoder))
            } catch {
                skipped += 1
            }
        }
        if skipped > 0 {
            debugLog("[RawRRBackup] Skipped \(skipped) unreadable line(s) in \(sessionId.uuidString.prefix(8))")
        }
        return points
    }

    /// Integrity check. Reconcile a permanently-truncated backup
    /// instead of warning about it on every single launch. When the on-disk
    /// points are FEWER than the index claims and this backup is not the live
    /// recording (its last write is old), the missing beats were lost to a
    /// torn write long ago and will never arrive. Rewriting the stored count
    /// down to what actually survived on disk stops the once-per-launch
    /// "Count mismatch" warning (the bulk of the recurring errors the user
    /// sees) AND lets the recovery archiver's beat-count guard — which refuses
    /// to retire a backup whose index count dwarfs the archived beats — finally
    /// retire these orphans instead of re-failing them forever.
    func checkRecoveredCount(_ recovered: Int, against indexEntry: BackupIndex, sessionId: UUID) {
        guard let expectedCount = indexEntry.backedUpCount, recovered != expectedCount else { return }
        let isStaleClosedBackup = indexEntry.lastBackupTime.map { Date().timeIntervalSince($0) > 600 } ?? true
        guard recovered < expectedCount, isStaleClosedBackup else {
            // Live recording, or the file somehow has MORE than claimed —
            // don't touch the count; just surface it.
            debugLog("[RawRRBackup] Count mismatch for \(sessionId.uuidString.prefix(8)): expected \(expectedCount), got \(recovered)", level: .warning)
            return
        }
        reconcileBeatCount(sessionId: sessionId, to: recovered, claimed: expectedCount)
    }

    // MARK: - Private

    func createBackupDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: backupDirectory.path) {
            do {
                try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            } catch {
                debugLog("[RawRRBackup] ⚠️ Failed to create backup directory: \(error)")
            }
        }
        do {
            try fileManager.setAttributes([.protectionKey: BackupProtection.appendableClass], ofItemAtPath: backupDirectory.path)
        } catch {
            debugLog("[RawRRBackup] WARN: Failed to set file protection on backup dir: \(error)", level: .warning)
        }
        migrateExistingFileProtection()
    }

    /// Migrate EXISTING files in the backup directory
    /// from the old `.complete` protection class to
    /// `BackupProtection.appendableClass`. The directory-level
    /// attribute change only affects NEW files; pre-existing
    /// header / points / index files inherit their protection
    /// class from creation time and stay unwritable when locked
    /// until we explicitly re-set them. One-time pass at startup
    /// (the next recording's writes go through unblocked).
    ///
    /// Failures are counted and logged once rather than per file: if the
    /// files are genuinely locked (device just booted, no first-unlock yet), a
    /// warning per file would spam, and the next launch retries anyway.
    ///
    /// A one-shot file of a session still waiting for re-encryption keeps
    /// the plaintext class it was written with (`BackupProtection.plaintext`
    /// or the older `.complete`); that class stands in for the missing
    /// encryption until the rewrite. The append files of such a session are
    /// migrated like any other: they must stay writable while locked.
    func migrateExistingFileProtection() {
        let contents = attempt("RawRRBackup.listForProtection") {
            try fileManager.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } ?? []
        let pending = PendingEncryptionLedger.pending(in: .rawBackup)
        let isPendingPlaintext = { (url: URL) in OneShotBackupName.parse(url.lastPathComponent).map { pending.contains($0.id) } ?? false }
        var failures = 0
        for fileURL in contents where !isPendingPlaintext(fileURL) {
            do {
                try fileManager.setAttributes([.protectionKey: BackupProtection.appendableClass], ofItemAtPath: fileURL.path)
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            debugLog("[RawRRBackup] \(failures) backup file(s) kept their old protection class; retried next launch")
        }
    }

    /// The append-format files of a session: its header, points file and any
    /// `.corrupted_*` points files set aside from it.
    func appendFiles(of sessionId: UUID) -> [URL] {
        [headerURL(for: sessionId)] + appendPointFiles(of: sessionId)
    }

    /// The points file of a session and any set aside from it.
    func appendPointFiles(of sessionId: UUID) -> [URL] {
        let points = pointsURL(for: sessionId)
        return [points] + corruptedSiblingNames(of: points).map { backupDirectory.appendingPathComponent($0) }
    }

    /// Remove the append-only files of a session (`appendFiles`), returning
    /// any still on disk; each failure is logged.
    @discardableResult
    func cleanupAppendFiles(for sessionId: UUID) -> [URL] {
        BackupFiles.remove(appendFiles(of: sessionId), using: fileManager)
    }

    /// A read error (the file locked by data protection, EPERM) is not
    /// corruption: the file is left in place, `indexReadFailed` is set, and
    /// `saveIndex` reads it again before writing. Only bytes that read but do
    /// not decode are rebuilt from the backup files; when they cannot be moved
    /// aside, `indexReadFailed` is set as for a failed read.
    func loadIndex() {
        guard fileManager.fileExists(atPath: indexFile.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: indexFile)
        } catch {
            debugLog("[RawRRBackup] Failed to read index: \(error) — keeping it and retrying before the next save", level: .error)
            indexLock.withLock { indexReadFailed = true }
            return
        }
        let loaded = decodedIndexOrRecovered(data)
        indexLock.withLock { (index, indexReadFailed) = (loaded.entries, !loaded.replaceable) }
    }

    /// The index in `data`, or the one rebuilt from the backup files when it
    /// does not decode. `replaceable` is false when it did not decode and
    /// could not be moved aside: a save must not write over it.
    private func decodedIndexOrRecovered(_ data: Data) -> (entries: [BackupIndex], replaceable: Bool) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try (decoder.decode([BackupIndex].self, from: data), true)
        } catch {
            debugLog("[RawRRBackup] Failed to decode index: \(error)", level: .error)
            return recoverIndexFromFiles()
        }
    }

    /// Read the index that failed to load at launch and add the backups it
    /// lists to the in-memory index (its own rows win). Throws while the file
    /// still cannot be read, or does not decode and cannot be moved aside, so
    /// a save never writes the partial in-memory list over the only list of
    /// the user's backups. Caller holds `indexLock`.
    private func mergeIndexThatFailedToLoad() throws {
        guard indexReadFailed else { return }
        guard fileManager.fileExists(atPath: indexFile.path) else {
            // Removed since (a purge): nothing left to merge or to protect.
            indexReadFailed = false
            return
        }
        let onDisk = decodedIndexOrRecovered(try Data(contentsOf: indexFile))
        guard onDisk.replaceable else { throw BackupError.couldNotSetAside(indexFile.lastPathComponent) }
        indexReadFailed = false
        let known = Set(index.map(\.id))
        index += onDisk.entries.filter { !known.contains($0.id) }
        debugLog("[RawRRBackup] index re-read after a failed launch read: \(index.count) backups")
    }

    /// Merge the on-disk index into memory when the launch read failed, so a
    /// write decides against every stored backup, not only the ones written
    /// since. Throws while the file still cannot be read.
    func mergeIndexIfLaunchReadFailed() throws {
        indexLock.lock()
        defer { indexLock.unlock() }
        try mergeIndexThatFailedToLoad()
    }

    /// Writes the in-memory index. Until a write lands, `indexSaveOwed`
    /// stays set: memory then holds rows the file does not, and
    /// `saveIndexIfOwed` writes them on the next append or unlock.
    func saveIndex() throws {
        indexLock.lock()
        defer { indexLock.unlock() }
        indexSaveOwed = true
        try mergeIndexThatFailedToLoad()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        // Protection class. The index needs to be writable
        // while the device is locked (the active recording's
        // `incrementalBackup` updates the index every few seconds).
        try data.write(to: indexFile, options: [.atomic, BackupProtection.appendable])
        indexSaveOwed = false
    }

    /// Saves the index when the last save threw (`indexSaveOwed`); nothing
    /// otherwise. Throws when the save throws again.
    func saveIndexIfOwed() throws {
        guard indexLock.withLock({ indexSaveOwed }) else { return }
        try saveIndex()
    }

    // MARK: - Errors

    enum BackupError: Error, LocalizedError {
        case noDataToBackup
        case hashMismatch
        case notFound
        case wouldReplaceLargerBackup(existing: Int, new: Int)
        /// An unreadable file could not be moved aside, so it was not written over.
        case couldNotSetAside(String)
        /// Files of a backup being removed are still on disk; its row is kept.
        case couldNotRemove([String])

        var errorDescription: String? {
            switch self {
            case .noDataToBackup:
                "No RR data to backup"
            case .hashMismatch:
                "Backup data integrity check failed"
            case .notFound:
                "Backup not found"
            case let .wouldReplaceLargerBackup(existing, new):
                "Kept the existing backup: it holds \(existing) beats, the new data \(new)"
            case let .couldNotSetAside(fileName):
                "Kept \(fileName): it could not be read or moved aside"
            case let .couldNotRemove(fileNames):
                "Kept the backup: \(fileNames.joined(separator: ", ")) could not be removed"
            }
        }
    }
}

/// The protection classes backup files are written with. The app has no
/// data-protection entitlement, so a write that names no class gets
/// until-first-unlock; every write here names its class explicitly anyway.
enum BackupProtection {
    /// Sealed one-shot files, and every file appended to while the device
    /// may be locked (headers, points, the index, workout streams): readable
    /// and writable from the first unlock after a boot.
    static let appendable: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication
    /// `appendable` as a file attribute, for folders and the migration walk.
    static let appendableClass = FileProtectionType.completeUntilFirstUserAuthentication
    /// A whole file written in plain JSON because the key was out of reach.
    /// It can be created while the device is locked, which is when that
    /// happens, and once closed it is unreadable until the next unlock.
    static let plaintext: Data.WritingOptions = .completeFileProtectionUnlessOpen
}

/// JSON Lines whose lines are each sealed with `EncryptionManager` and
/// base64-encoded: the streamed files of `RawRRBackup` and
/// `WorkoutTrackBackup`. A line that could not be sealed is plain JSON.
/// Sealed bytes start with the `FR` framing, so a sealed line starts with
/// `R`, which no JSON value does; the first byte tells the two apart.
enum SealedJSONLines {
    enum Failure: Error {
        /// A line that is neither JSON nor base64.
        case unreadableLine
    }

    private static let newline = UInt8(ascii: "\n")
    private static let jsonLeadBytes = Set("{[\"-0123456789tfn".utf8)

    /// The stored manager when its key can be reached, else nil.
    static func availableManager() -> EncryptionManager? {
        let manager = AppDependencies.current.storage.encryptionManager
        return manager.isAvailable ? manager : nil
    }

    /// One newline-terminated line per item. Lines are sealed while
    /// `manager` is non-nil; after the first sealing failure, which is
    /// logged, the rest of the batch is plain. `allSealed` is false when any
    /// line is plain. Throws only when an item does not encode.
    static func encode<Item: Encodable>(
        _ items: some Sequence<Item>, with encoder: JSONEncoder, manager: EncryptionManager?
    ) throws -> (data: Data, allSealed: Bool) {
        var sealer = manager
        var data = Data()
        for item in items {
            data.append(sealedOrPlain(try encoder.encode(item), sealer: &sealer))
            data.append(newline)
        }
        return (data, sealer != nil || data.isEmpty)
    }

    /// The sealed line, or the JSON itself once `sealer` is nil or sealing
    /// throws (which sets `sealer` to nil).
    private static func sealedOrPlain(_ json: Data, sealer: inout EncryptionManager?) -> Data {
        guard let manager = sealer else { return json }
        do {
            return try manager.encrypt(json).base64EncodedData()
        } catch {
            debugLog("[SealedJSONLines] sealing a line failed: \(error)", level: .error)
            sealer = nil
            return json
        }
    }

    /// The JSON a line holds: the line itself when plain, else opened.
    static func open(_ line: Substring, with manager: EncryptionManager) throws -> Data {
        let bytes = Data(line.utf8)
        guard !isPlain(bytes) else { return bytes }
        guard let sealed = Data(base64Encoded: bytes) else { throw Failure.unreadableLine }
        return try manager.decrypt(sealed)
    }

    /// Whether a line is plain JSON.
    static func isPlain(_ line: Data) -> Bool {
        line.first.map { jsonLeadBytes.contains($0) } ?? false
    }

    /// Whether any line of `data` is plain JSON.
    static func hasPlainLine(_ data: Data) -> Bool {
        data.split(separator: newline).contains(where: isPlain)
    }

    /// `data` with each plain line sealed and every other byte as it was,
    /// a trailing line without its newline included.
    static func resealed(_ data: Data, with manager: EncryptionManager) throws -> Data {
        let lines = try data.split(separator: newline, omittingEmptySubsequences: false).map { line in
            try isPlain(line) ? manager.encrypt(line).base64EncodedData() : line
        }
        return Data(lines.joined(separator: [newline]))
    }

    /// Rewrites the file at `url` with every plain line sealed, atomically
    /// and with `BackupProtection.appendable`, the class it was created
    /// with. True once the file read back holds no plain line; a file with
    /// none is not rewritten. Throws when it cannot be read, sealed or
    /// written.
    static func resealFile(at url: URL, with manager: EncryptionManager) throws -> Bool {
        let data = try Data(contentsOf: url)
        guard hasPlainLine(data) else { return true }
        try resealed(data, with: manager).write(to: url, options: [.atomic, BackupProtection.appendable])
        return try !hasPlainLine(Data(contentsOf: url))
    }
}

/// Removing a backup's files.
enum BackupFiles {
    /// Removes each file and returns those still on disk afterwards. A file
    /// already gone counts as removed; any other failure is logged.
    static func remove(_ urls: [URL], using fileManager: FileManager) -> [URL] {
        for url in urls where fileManager.fileExists(atPath: url.path) {
            attempt("BackupFiles.remove") { try fileManager.removeItem(at: url) }
        }
        return urls.filter { fileManager.fileExists(atPath: $0.path) }
    }
}

/// Appending to a newline-terminated JSON Lines file that a process killed
/// mid-write may have left ending in part of a line: the raw RR points file,
/// the workout streams and the diagnostics logs. Appended after such a
/// fragment, the next line fuses with it into one line that decodes as
/// neither, so the fragment is cut off first; the writer's own count of
/// complete lines on disk then says the cut line is written again.
enum JSONLinesFile {
    enum AppendOutcome {
        case appended
        /// No read/write handle opened; nothing was written.
        case couldNotOpen
        /// Cutting the torn tail, seeking or writing threw.
        case writeFailed(any Error)
    }

    private static let newline = UInt8(ascii: "\n")

    /// Appends `data` to the file at `url` through a read/write handle,
    /// after cutting off a torn last line (`dropTornTail`). The throwing
    /// `FileHandle` calls: `seekToEndOfFile()` / `write(_:)` raise an
    /// Objective-C exception on a full disk, which Swift cannot catch. A
    /// write that throws is cut back to where it started, so the batch the
    /// caller retries is not in the file twice.
    static func append(_ data: Data, toExisting url: URL) -> AppendOutcome {
        guard let handle = attempt("JSONLinesFile.open", { try FileHandle(forUpdating: url) }) else { return .couldNotOpen }
        defer { attempt("JSONLinesFile.close") { try handle.close() } }
        let start: UInt64
        do {
            try dropTornTail(handle)
            start = try handle.seekToEnd()
        } catch {
            return .writeFailed(error)
        }
        do {
            try handle.write(contentsOf: data)
            return .appended
        } catch {
            attempt("JSONLinesFile.truncateFailedAppend") { try handle.truncate(atOffset: start) }
            return .writeFailed(error)
        }
    }

    /// Truncates the file after its last newline when it does not end with
    /// one. The usual case reads one byte; only a torn file reads its tail
    /// (a line is far shorter than 64 KB).
    static func dropTornTail(_ handle: FileHandle) throws {
        let end = try handle.seekToEnd()
        guard end > 0 else { return }
        try handle.seek(toOffset: end - 1)
        guard try handle.read(upToCount: 1)?.first != newline else { return }
        let tailStart = end > 65_536 ? end - 65_536 : 0
        try handle.seek(toOffset: tailStart)
        let tail = try handle.readToEnd() ?? Data()
        guard let lastNewline = tail.lastIndex(of: newline) else {
            if tailStart == 0 { try handle.truncate(atOffset: 0) }
            return
        }
        try handle.truncate(atOffset: tailStart + UInt64(lastNewline - tail.startIndex + 1))
    }

    /// `data` up to and including its last newline: all of it when it ends
    /// with one, nothing when it holds none.
    static func completeLines(of data: Data) -> Data {
        guard let last = data.last, last != newline else { return data }
        guard let lastNewline = data.lastIndex(of: newline) else { return Data() }
        return data[data.startIndex ... lastNewline]
    }
}
