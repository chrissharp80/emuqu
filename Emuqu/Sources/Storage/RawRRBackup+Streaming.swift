import CryptoKit
import Foundation

// The append-only streaming backup path, its helpers and error type. Members
// are internal rather than `private` because Swift's `private` does not reach
// across files.

extension RawRRBackup {
    // MARK: - Append-Only Backup (Streaming)

    /// Append only new points since the last backup. Constant cost per call.
    func appendBackup(points: [RRPoint], sessionId: UUID, deviceId: String? = nil) throws {
        indexLock.lock()
        let existingEntry = index.first { $0.id == sessionId }
        indexLock.unlock()
        let previousCount = existingEntry?.backedUpCount ?? 0
        // Nothing new to write
        guard points.count > previousCount else { return }
        let pointsPath = pointsURL(for: sessionId)
        // First backup for this session: write header and clean up any legacy file
        if existingEntry == nil || existingEntry?.backedUpCount == nil {
            try startAppendFormat(sessionId: sessionId, deviceId: deviceId, existingEntry: existingEntry)
        }
        let newPoints = points[previousCount...]
        try writeAppendData(try encodedLines(newPoints), to: pointsPath, sessionId: sessionId, count: newPoints.count)
        try updateAppendIndex(sessionId: sessionId, existingEntry: existingEntry, beatCount: points.count)
    }

    /// Write the session header and start a fresh points file, removing a
    /// legacy single-file backup if we're switching formats.
    ///
    /// Explicit `.completeFileProtectionUntilFirstUserAuthentication`
    /// on both writes. Without this option `Data.write(to:)` falls back to
    /// iOS's default `.complete` protection — which locks the file out when
    /// the device locks, breaking every overnight backup write (an
    /// iPhone 11 log: 29,067 RR points lost). Directory protection is set
    /// correctly in `createBackupDirectoryIfNeeded`, but new file creation
    /// doesn't inherit it on iOS — it must be passed explicitly.
    func startAppendFormat(
        sessionId: UUID, deviceId: String?, existingEntry: BackupIndex?
    ) throws {
        let header = BackupHeader(id: sessionId, captureDate: Date(), deviceId: deviceId)
        try lineEncoder.encode(header).write(
            to: headerURL(for: sessionId),
            options: [.completeFileProtectionUntilFirstUserAuthentication]
        )
        if let legacyName = existingEntry?.fileName {
            do {
                try fileManager.removeItem(at: backupDirectory.appendingPathComponent(legacyName))
            } catch {
                debugLog("[RawRRBackup] ⚠️ Failed to remove legacy file during format switch: \(error)")
            }
        }
        // Start fresh points file (overwrite if corrupt leftover exists)
        try Data().write(to: pointsURL(for: sessionId), options: [.completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Encode points as JSONL — one JSON object per line.
    func encodedLines(_ points: ArraySlice<RRPoint>) throws -> Data {
        var appendData = Data()
        for point in points {
            appendData.append(try lineEncoder.encode(point))
            appendData.append(0x0A) // newline
        }
        return appendData
    }

    /// Append to the points file, falling back to a fresh write when the file
    /// is missing or its handle can't be opened.
    func writeAppendData(
        _ appendData: Data, to pointsPath: URL, sessionId: UUID, count: Int
    ) throws {
        if let handle = try? FileHandle(forWritingTo: pointsPath) {
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(appendData)
            return
        }
        if fileManager.fileExists(atPath: pointsPath.path) {
            preserveCorruptedPointsFile(at: pointsPath, sessionId: sessionId)
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

    /// File exists but FileHandle failed — likely corrupted. Preserve for recovery.
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
        let points = try readPointLines(at: pointsURL(for: sessionId), sessionId: sessionId, decoder: decoder)
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
    func readPointLines(at pointsPath: URL, sessionId: UUID, decoder: JSONDecoder) throws -> [RRPoint] {
        let pointsString = try String(contentsOf: pointsPath, encoding: .utf8)
        let lines = pointsString.split(separator: "\n", omittingEmptySubsequences: true)
        var points: [RRPoint] = []
        points.reserveCapacity(lines.count)
        for line in lines {
            guard let lineData = line.data(using: .utf8) else { continue }
            do {
                points.append(try decoder.decode(RRPoint.self, from: lineData))
            } catch {
                debugLog("[RawRRBackup] Skipped corrupted line in \(sessionId.uuidString.prefix(8))")
            }
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
    /// Failures are swallowed rather than logged: if even one file is
    /// genuinely locked (device just booted, no first-unlock yet), warning
    /// about it would spam, and the next launch retries anyway.
    func migrateExistingFileProtection() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for fileURL in contents {
            _ = attempt("RawRRBackup+Streaming.setAttributes") {
                try fileManager.setAttributes(
                    [FileAttributeKey.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: fileURL.path
                )
            }
        }
    }

    /// Remove append-only header and points files for a session
    func cleanupAppendFiles(for sessionId: UUID) {
        for url in [headerURL(for: sessionId), pointsURL(for: sessionId)] {
            do {
                try fileManager.removeItem(at: url)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                // File already gone — expected during cleanup
            } catch {
                debugLog("[RawRRBackup] ⚠️ Failed to clean up \(url.lastPathComponent): \(error)")
            }
        }
    }

    func loadIndex() {
        guard fileManager.fileExists(atPath: indexFile.path) else { return }

        do {
            let data = try Data(contentsOf: indexFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([BackupIndex].self, from: data)
            indexLock.lock()
            index = decoded
            indexLock.unlock()
        } catch {
            debugLog("[RawRRBackup] Failed to load index: \(error)")
            indexLock.lock()
            index = []
            indexLock.unlock()
        }
    }

    func saveIndex() throws {
        indexLock.lock()
        defer { indexLock.unlock() }
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

        var errorDescription: String? {
            switch self {
            case .noDataToBackup:
                "No RR data to backup"
            case .hashMismatch:
                "Backup data integrity check failed"
            case .notFound:
                "Backup not found"
            }
        }
    }
}
