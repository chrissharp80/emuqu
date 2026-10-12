import CryptoKit
import Foundation

// The append-only streaming backup path, its helpers and error type. Members
// are internal rather than `private` because Swift's `private` does not reach
// across files.

extension RawRRBackup {
    // MARK: - Append-Only Backup (Streaming)

    /// Append only new points since the last backup. Constant cost per call.
    ///
    /// Switching a one-shot backup to this format replaces it, so the switch
    /// follows `backup()`'s rule: never over a backup that holds more beats.
    func appendBackup(points: [RRPoint], sessionId: UUID, deviceId: String? = nil) throws {
        try mergeIndexIfLaunchReadFailed()
        indexLock.lock()
        let existingEntry = index.first { $0.id == sessionId }
        indexLock.unlock()
        let previousCount = existingEntry?.backedUpCount ?? 0
        // Nothing new to write
        guard points.count > previousCount else { return }
        let pointsPath = pointsURL(for: sessionId)
        let switchesFormat = try startAppendFormatIfNew(existingEntry, sessionId: sessionId, deviceId: deviceId, newCount: points.count)
        let newPoints = points[previousCount...]
        try writeAppendData(try encodedLines(newPoints), to: pointsPath, sessionId: sessionId, count: newPoints.count)
        try updateAppendIndex(sessionId: sessionId, existingEntry: existingEntry, beatCount: points.count)
        if switchesFormat, let legacyName = existingEntry?.fileName { removeReplacedLegacyFile(legacyName) }
    }

    /// The one-shot backup a format switch replaced, removed once the
    /// streaming copy and its index row are written. A failed removal leaves
    /// a file the index no longer names, which costs space and nothing else.
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

    /// Write the session header and start a fresh points file. A legacy
    /// single-file backup being replaced is left in place; `appendBackup`
    /// removes it once the new copy is written and indexed.
    ///
    /// Explicit `.completeFileProtectionUntilFirstUserAuthentication`
    /// on both writes. Without this option `Data.write(to:)` falls back to
    /// iOS's default `.complete` protection — which locks the file out when
    /// the device locks, breaking every overnight backup write (an
    /// iPhone 11 log: 29,067 RR points lost). Directory protection is set
    /// correctly in `createBackupDirectoryIfNeeded`, but new file creation
    /// doesn't inherit it on iOS — it must be passed explicitly.
    ///
    /// The header keeps a replaced one-shot backup's capture date: recovery
    /// uses it as the session start, and the moment of the switch is not that.
    func startAppendFormat(
        sessionId: UUID, deviceId: String?, existingEntry: BackupIndex?
    ) throws {
        let header = BackupHeader(id: sessionId, captureDate: existingEntry?.captureDate ?? Date(), deviceId: deviceId)
        try lineEncoder.encode(header).write(
            to: headerURL(for: sessionId),
            options: [.completeFileProtectionUntilFirstUserAuthentication]
        )
        // Start fresh points file (overwrite if corrupt leftover exists)
        try Data().write(to: pointsURL(for: sessionId), options: [.completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Encode points as JSONL — one line per point. Each line is the point's
    /// JSON sealed with `EncryptionManager` and base64-encoded, the same
    /// app-layer encryption one-shot backups and archived sessions get. When
    /// the key cannot be reached the batch is written as plain JSON lines,
    /// logged, and read back either way (`decodePointLine`).
    func encodedLines(_ points: ArraySlice<RRPoint>) throws -> Data {
        let manager = AppDependencies.current.storage.encryptionManager
        var sealLines = manager.isAvailable
        var appendData = Data()
        for point in points {
            let json = try lineEncoder.encode(point)
            if sealLines {
                appendData.append(sealedLine(json, with: manager, sealing: &sealLines))
            } else {
                appendData.append(json)
            }
            appendData.append(0x0A) // newline
        }
        if !sealLines, !points.isEmpty {
            debugLog("[RawRRBackup] \(points.count) streamed beats appended WITHOUT app-layer encryption (key unavailable)", level: .error)
        }
        return appendData
    }

    /// One sealed, base64-encoded line, or the plain JSON when sealing throws
    /// (and `sealing` is switched off for the rest of the batch).
    private func sealedLine(_ json: Data, with manager: EncryptionManager, sealing: inout Bool) -> Data {
        do {
            return try manager.encrypt(json).base64EncodedData()
        } catch {
            debugLog("[RawRRBackup] sealing a streamed beat failed: \(error)", level: .error)
            sealing = false
            return json
        }
    }

    /// A plain JSON line starts with `{`; anything else is a sealed line.
    func decodePointLine(_ line: Substring, decoder: JSONDecoder) throws -> RRPoint {
        let bytes = Data(line.utf8)
        guard line.first != "{" else { return try decoder.decode(RRPoint.self, from: bytes) }
        guard let sealed = Data(base64Encoded: bytes) else { throw BackupError.hashMismatch }
        let json = try AppDependencies.current.storage.encryptionManager.decrypt(sealed)
        return try decoder.decode(RRPoint.self, from: json)
    }

    /// Append to the points file, falling back to a fresh write when the file
    /// is missing or its handle can't be opened.
    ///
    /// The throwing `FileHandle` calls, not `seekToEndOfFile()` / `write(_:)`:
    /// those raise an Objective-C exception on a full disk or an I/O error,
    /// which Swift cannot catch, so the backup meant to save the night was the
    /// thing that crashed it. A failed append now throws to the caller, which
    /// logs it and retries on the next interval with the beats still buffered.
    func writeAppendData(
        _ appendData: Data, to pointsPath: URL, sessionId: UUID, count: Int
    ) throws {
        if let handle = try? FileHandle(forWritingTo: pointsPath) {
            try appendThroughHandle(handle, appendData, sessionId: sessionId)
            return
        }
        if fileManager.fileExists(atPath: pointsPath.path),
           try rewriteKeepingExisting(appendData, at: pointsPath, sessionId: sessionId) {
            return
        }
        do {
            // Explicit protection class so the file
            // is writable while the device is locked overnight.
            try appendData.write(to: pointsPath, options: [.completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            debugLog("[RawRRBackup] ERROR: Fallback write failed for \(sessionId.uuidString.prefix(8)): \(error). \(count) RR points may be lost.", level: .error)
            throw error
        }
    }

    /// Seek to the end and append through an open handle, closing it after.
    /// A write that throws is truncated back to the offset it started at and
    /// rethrown, so the batch the caller retries is not in the file twice.
    private func appendThroughHandle(_ handle: FileHandle, _ appendData: Data, sessionId: UUID) throws {
        defer { closeQuietly(handle, sessionId: sessionId) }
        let start = try handle.seekToEnd()
        do {
            try handle.write(contentsOf: appendData)
        } catch {
            truncateFailedAppend(handle, to: start, sessionId: sessionId)
            throw error
        }
    }

    /// The handle would not open but the bytes may still read: carry them into
    /// the rewrite so the night so far is not left behind in a file only
    /// recovery knows to look for. False when they don't read either; the file
    /// is then set aside for recovery and the caller writes a fresh one.
    private func rewriteKeepingExisting(_ appendData: Data, at pointsPath: URL, sessionId: UUID) throws -> Bool {
        guard let existing = attempt("RawRRBackup.readForRewrite", { try Data(contentsOf: pointsPath) }) else {
            preserveCorruptedPointsFile(at: pointsPath, sessionId: sessionId)
            return false
        }
        try (existing + appendData).write(to: pointsPath, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return true
    }

    /// A write that throws may have written part of the batch. The index is
    /// not advanced, so the next interval appends the whole batch again; cut
    /// the file back to where this append started so those lines are not in
    /// it twice.
    private func truncateFailedAppend(_ handle: FileHandle, to offset: UInt64, sessionId: UUID) {
        do {
            try handle.truncate(atOffset: offset)
        } catch {
            debugLog("[RawRRBackup] Truncating a failed append for \(sessionId.uuidString.prefix(8)) failed: \(error)", level: .warning)
        }
    }

    private func closeQuietly(_ handle: FileHandle, sessionId: UUID) {
        do {
            try handle.close()
        } catch {
            debugLog("[RawRRBackup] Closing the points file for \(sessionId.uuidString.prefix(8)) failed: \(error)", level: .warning)
        }
    }

    /// File exists, won't open and won't read. Preserved for recovery:
    /// `readAllPointLines` reads these alongside the live file.
    func preserveCorruptedPointsFile(at pointsPath: URL, sessionId: UUID) {
        let corruptedName = pointsPath.lastPathComponent + ".corrupted_\(Int(Date().timeIntervalSince1970))"
        let corruptedPath = pointsPath.deletingLastPathComponent().appendingPathComponent(corruptedName)
        debugLog("[RawRRBackup] WARNING: FileHandle failed on existing points file for \(sessionId.uuidString.prefix(8)); renaming to \(corruptedName) for recovery")
        do {
            try fileManager.moveItem(at: pointsPath, to: corruptedPath)
        } catch {
            debugLog("[RawRRBackup] WARNING: Failed to preserve corrupted points file for \(sessionId.uuidString.prefix(8)): \(error)", level: .warning)
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
        let header = try decoder.decode(BackupHeader.self, from: Data(contentsOf: headerURL(for: sessionId)))
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
            try fileManager.setAttributes(
                [FileAttributeKey.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: backupDirectory.path
            )
        } catch {
            debugLog("[RawRRBackup] WARN: Failed to set file protection on backup dir: \(error)", level: .warning)
        }
        migrateExistingFileProtection()
    }

    /// Migrate EXISTING files in the backup directory
    /// from the old `.complete` protection class to
    /// `.completeUntilFirstUserAuthentication`. The directory-level
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
    /// A one-shot backup still waiting for re-encryption keeps the stricter
    /// `.completeFileProtection` it was written with; that class is what
    /// stands in for the missing encryption until the rewrite.
    func migrateExistingFileProtection() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let unencrypted = PendingEncryptionLedger.pending(in: .rawBackup).map(\.uuidString)
        var failures = 0
        for fileURL in contents where !unencrypted.contains(where: { fileURL.lastPathComponent.hasPrefix($0) }) {
            do {
                try fileManager.setAttributes(
                    [FileAttributeKey.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: fileURL.path
                )
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            debugLog("[RawRRBackup] \(failures) backup file(s) kept their old protection class; retried next launch")
        }
    }

    /// Remove append-only header and points files for a session
    func cleanupAppendFiles(for sessionId: UUID) {
        let prefix = pointsURL(for: sessionId).lastPathComponent + ".corrupted_"
        let siblings = (attempt("RawRRBackup.listSiblings") {
            try fileManager.contentsOfDirectory(atPath: backupDirectory.path)
        } ?? []).filter { $0.hasPrefix(prefix) }.map { backupDirectory.appendingPathComponent($0) }
        for url in [headerURL(for: sessionId), pointsURL(for: sessionId)] + siblings {
            do {
                try fileManager.removeItem(at: url)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                // File already gone — expected during cleanup
            } catch {
                debugLog("[RawRRBackup] ⚠️ Failed to clean up \(url.lastPathComponent): \(error)")
            }
        }
    }

    /// A read error (the file locked by data protection, EPERM) is not
    /// corruption: the file is left in place, `indexReadFailed` is set, and
    /// `saveIndex` reads it again before writing. Only bytes that read but do
    /// not decode are rebuilt from the backup files.
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
        indexLock.withLock { index = loaded }
    }

    /// The index in `data`, or the one rebuilt from the backup files when it
    /// does not decode.
    private func decodedIndexOrRecovered(_ data: Data) -> [BackupIndex] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([BackupIndex].self, from: data)
        } catch {
            debugLog("[RawRRBackup] Failed to decode index: \(error)", level: .error)
            return recoverIndexFromFiles()
        }
    }

    /// Read the index that failed to load at launch and add the backups it
    /// lists to the in-memory index (its own rows win). Throws while the file
    /// still cannot be read, so a save never writes the partial in-memory list
    /// over the only list of the user's backups. Caller holds `indexLock`.
    private func mergeIndexThatFailedToLoad() throws {
        guard indexReadFailed else { return }
        guard fileManager.fileExists(atPath: indexFile.path) else {
            // Removed since (a purge): nothing left to merge or to protect.
            indexReadFailed = false
            return
        }
        let onDisk = decodedIndexOrRecovered(try Data(contentsOf: indexFile))
        indexReadFailed = false
        let known = Set(index.map(\.id))
        index += onDisk.filter { !known.contains($0.id) }
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

    func saveIndex() throws {
        indexLock.lock()
        defer { indexLock.unlock() }
        try mergeIndexThatFailedToLoad()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        // Protection class. The index needs to be writable
        // while the device is locked (the active recording's
        // `incrementalBackup` updates the index every few seconds).
        try data.write(to: indexFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - Errors

    enum BackupError: Error, LocalizedError {
        case noDataToBackup
        case hashMismatch
        case notFound
        case wouldReplaceLargerBackup(existing: Int, new: Int)

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
            }
        }
    }
}
