import Foundation

/// Real diagnostic for "where did my RR data go?". Walks
/// every store the app uses for raw beat-by-beat data and reports
/// per-session: is the rrSeries on disk in the main archive, in the
/// RawRRBackup safety net, both, or neither.
///
/// This replaces the "I assumed your data is gone" speculation with an
/// actual inspection of the file system. Run from Settings → Archive
/// Diagnostics → "RR Storage Audit." Surfaces a per-session list with
/// status icons and a recovery summary so the user knows exactly which
/// sessions can be repaired.
///
/// Storage layers inspected:
///   1. SessionArchive — main per-session JSON files
///      ({appgroup}/HRVArchive/{uuid}.json). Encoded HRVSession with
///      optional rrSeries field. Lightweight loads skip the field; full
///      retrieve includes it.
///   2. RawRRBackup — independent append-only safety net written during
///      recording ({appgroup}/RRBackup/{uuid}_points.jsonl). Survives
///      even if the main archive write fails or the session JSON is
///      later overwritten without rrSeries.
///
/// The diagnostic is read-only. Backup beat counts come from the backup
/// index rather than a decode of each backup: decoding reconciles and
/// rewrites the index, and a backup that failed to decode fell out of the
/// orphan list, which is the case this report exists to show.
enum SessionStorageDiagnostic {
    // MARK: - Report types

    enum RRStatus: String, Codable, Sendable {
        /// Main archive JSON has `rrSeries` populated with at least one beat.
        case archivedFull
        /// Main archive JSON has no `rrSeries` (or empty), but the
        /// RawRRBackup safety net has the beats. This session is repairable.
        case backupOnly
        /// Main archive JSON has rrSeries AND the RawRRBackup is also
        /// present. (Both intact — happiest case.)
        case bothPresent
        /// Neither store has rrSeries. The session's analysis result
        /// (RMSSD, recovery score, etc.) may still be intact; only the
        /// per-beat stream used for Poincaré / waveform charts is gone.
        case neither
        /// File on disk wouldn't decode at all — corruption, encryption
        /// mismatch, or hash failure. Worth investigating separately.
        case unreadable
    }

    struct SessionReport: Sendable {
        let sessionId: UUID
        let date: Date
        let sessionType: SessionType
        let recoveryScore: Double?
        let archiveFileSize: Int64
        let archiveBeatCount: Int          // 0 if no rrSeries on archive file
        let backupBeatCount: Int            // 0 if no RawRRBackup entry
        let status: RRStatus
        /// Decoded analysisResult presence — e.g. "RMSSD 76.3, score 9.8".
        /// Confirms to the user that the analysis numbers ARE preserved
        /// even when rrSeries is gone.
        let analysisSummary: String?
    }

    struct Report: Sendable {
        let totalSessions: Int
        let archivedFullCount: Int
        let backupOnlyCount: Int
        let bothPresentCount: Int
        let neitherCount: Int
        let unreadableCount: Int
        let sessions: [SessionReport]
        /// Total bytes used by all session JSON files (archive directory).
        let archiveTotalBytes: Int64
        /// Total bytes used by all RawRRBackup files (backup directory).
        let backupTotalBytes: Int64
        /// IDs that exist in RawRRBackup but NOT in the archive index —
        /// orphaned backups. These usually mean a recording finished and
        /// was backed up but the archive write either crashed or was
        /// never called. Could indicate recoverable sessions that
        /// never made it to history.
        let orphanedBackupIds: [UUID]

        var repairableCount: Int { backupOnlyCount }
    }

    // MARK: - Run

    /// Walk both stores, return a per-session report.
    /// Synchronous and intentional — callers should hop to a background
    /// queue (Task.detached) for archives larger than ~200 sessions.
    ///
    /// Single lock-safe snapshot. Separate raw `archive.index` reads
    /// here would race concurrent locked mutations
    /// (CoW array read during in-place mutation is UB — a crash race).
    /// `entries` copies the cached index under `archiveLock`, already
    /// sorted date-descending,
    /// so the user sees their most recent sessions first, and one snapshot
    /// keeps ids / list / count mutually consistent.
    static func run(archive: SessionArchive, backup: RawRRBackup) -> Report {
        let archiveEntries = archive.entries
        let archivedIds = Set(archiveEntries.map(\.sessionId))
        let backupIds = Set(backup.unarchivedSessionIds)
            .union(backup.allBackupIds())
        let sessions = archiveEntries.map { inspectSession(entry: $0, archive: archive, backup: backup) }
        let counts = statusCounts(in: sessions)
        // Orphaned backups: in RawRRBackup index but not in archive index.
        let orphaned = backupIds.subtracting(archivedIds).sorted { $0.uuidString < $1.uuidString }
        return Report(
            totalSessions: archiveEntries.count,
            archivedFullCount: counts[.archivedFull] ?? 0,
            backupOnlyCount: counts[.backupOnly] ?? 0,
            bothPresentCount: counts[.bothPresent] ?? 0,
            neitherCount: counts[.neither] ?? 0,
            unreadableCount: counts[.unreadable] ?? 0,
            sessions: sessions,
            archiveTotalBytes: directorySize(at: archive.archiveDirectory),
            backupTotalBytes: backup.totalBackupSize,
            orphanedBackupIds: orphaned
        )
    }

    static func statusCounts(in sessions: [SessionReport]) -> [RRStatus: Int] {
        sessions.reduce(into: [:]) { counts, report in
            counts[report.status, default: 0] += 1
        }
    }

    // MARK: - Per-session inspection

    /// (2) The FULL session (rrSeries included) is decoded from disk via
    /// `retrieveOrLog` on the archive directly — the same path HRVDetailV2View
    /// uses. A nil result means the file is unreadable or missing.
    ///
    /// (3) The RawRRBackup index is checked for the same session ID, and its
    /// recorded beat count used (either backup format).
    private static func inspectSession(
        entry: SessionArchiveEntry,
        archive: SessionArchive,
        backup: RawRRBackup
    ) -> SessionReport {
        // (1) Archive file size — useful regardless of decode outcome.
        let fileURL = archive.archiveDirectory.appendingPathComponent(entry.filePath)
        let fileSize: Int64 = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        guard let session = archive.retrieveOrLog(entry.sessionId, caller: "SessionStorageDiagnostic") else {
            return report(for: entry, fileSize: fileSize, archiveBeats: 0, backupBeats: 0,
                          status: .unreadable, analysisSummary: nil)
        }
        let archiveBeats = session.rrSeries?.points.count ?? 0
        let backupBeats = backup.backedUpBeatCount(entry.sessionId) ?? 0
        return report(
            for: entry, fileSize: fileSize, archiveBeats: archiveBeats, backupBeats: backupBeats,
            status: status(archiveBeats: archiveBeats, backupBeats: backupBeats),
            analysisSummary: analysisSummary(for: session)
        )
    }

    /// (4) Status decision tree.
    /// `internal` so the classification can be tested. This is what tells a
    /// user whether their raw RR data still exists — the question the whole
    /// diagnostics screen answers.
    static func status(archiveBeats: Int, backupBeats: Int) -> RRStatus {
        switch (archiveBeats > 0, backupBeats > 0) {
        case (true, true): return .bothPresent
        case (true, false): return .archivedFull
        case (false, true): return .backupOnly
        case (false, false): return .neither
        }
    }

    /// (5) Analysis summary so the user sees that the numbers are
    /// safe even when rrSeries isn't.
    private static func analysisSummary(for session: HRVSession) -> String? {
        guard let result = session.analysisResult else { return nil }
        var parts = [
            String(localized: "RMSSD \(oneDecimal(result.timeDomain.rmssd))", bundle: LanguageManager.appBundle),
            String(localized: "SDNN \(oneDecimal(result.timeDomain.sdnn))", bundle: LanguageManager.appBundle)
        ]
        if let score = session.recoveryScore {
            parts.append(String(localized: "Score \(oneDecimal(score))", bundle: LanguageManager.appBundle))
        }
        return parts.joined(separator: " · ")
    }

    /// One decimal place, in the app's language.
    private static func oneDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(LanguageManager.appLocale))
    }

    private static func report(
        for entry: SessionArchiveEntry,
        fileSize: Int64,
        archiveBeats: Int,
        backupBeats: Int,
        status: RRStatus,
        analysisSummary: String?
    ) -> SessionReport {
        SessionReport(
            sessionId: entry.sessionId,
            date: entry.date,
            sessionType: entry.sessionType,
            recoveryScore: entry.recoveryScore,
            archiveFileSize: fileSize,
            archiveBeatCount: archiveBeats,
            backupBeatCount: backupBeats,
            status: status,
            analysisSummary: analysisSummary
        )
    }

    // MARK: - Helpers

    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var size: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            size += Int64(values?.fileSize ?? 0)
        }
        return size
    }
}

// MARK: - RawRRBackup helper API

extension RawRRBackup {
    /// Diagnostic helper — every session ID currently in the backup
    /// index, regardless of archived flag. Used by `SessionStorageDiagnostic`
    /// to detect orphaned backups (in the backup but not in the
    /// archive index, e.g. because an archive write crashed).
    ///
    /// Read from the index itself: going through `allBackups` decoded and
    /// hashed every backup just to list ids, and dropped those that failed
    /// to decode.
    func allBackupIds() -> [UUID] {
        indexLock.lock()
        defer { indexLock.unlock() }
        return index.map(\.id)
    }
}
