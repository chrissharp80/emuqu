import CryptoKit
import Foundation

// Index persistence, the archive error taxonomy, and the index-entry factory:
// the layer beneath the lock-free session methods in `Archive+Internal.swift`
// that reads and writes the index file itself.

extension SessionArchive {
    // MARK: - Private

    /// Resolve the on-disk file URL for an archive entry.
    /// Supports both legacy absolute paths and modern relative filenames.
    func resolveFileURL(for entry: SessionArchiveEntry) -> URL {
        entry.filePath.hasPrefix("/")
            ? URL(fileURLWithPath: entry.filePath)
            : archiveDirectory.appendingPathComponent(entry.filePath)
    }

    /// Protection class is `.completeUntilFirstUserAuthentication`,
    /// not `.completeUnlessOpen`: a user's debug log
    /// showed **3,325** "Operation
    /// not permitted" errors across 30+ session JSON files when
    /// the AI tried to walk the archive. `.completeUnlessOpen`
    /// keeps a file accessible across a screen-lock event ONLY
    /// while the file handle stays open — once closed, the next
    /// open requires the device to be unlocked. iOS reads in
    /// `Data(contentsOf:)` open + close in one go, so any read
    /// that happens while the screen is locked (CloudKit sync,
    /// background AI context build, AssistantContextSource
    /// re-walk) fails with errno=1.
    ///
    /// `.completeUntilFirstUserAuthentication` matches what
    /// RawRRBackup and DebugLog use (for the same errno-1
    /// reason in those subsystems). Trade-off:
    /// files become readable post-first-unlock-after-reboot
    /// instead of strict-while-unlocked. For HRV and workout
    /// data this is fine — the data isn't more sensitive than
    /// the rest of the app, and the strictness was breaking
    /// every background read path the app actually depends on.
    ///
    /// LAUNCH PERF. The per-file protection-class walk (recursive
    /// directory enumeration + per-file setAttributes, plus a read+rewrite on
    /// failure) scales with archive file count and must not run here in `init`,
    /// before first paint. It lives in `upgradeExistingFileProtection()`,
    /// which the launch housekeeping phase runs off-main once the dashboard
    /// has loaded. The directory create + directory-level setAttributes stay
    /// in `init` (cheap, and they govern the protection class NEW files
    /// inherit).
    func createArchiveDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: archiveDirectory.path) {
            _ = attempt("Archive+IndexIO.create") { try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true) }
        }
        do {
            try fileManager.setAttributes(Self.protectionAttributes, ofItemAtPath: archiveDirectory.path)
        } catch {
            debugLog("[Archive] WARN: directory-level protection-class downgrade failed at \(archiveDirectory.path): \(error.localizedDescription)", level: .warning)
        }
    }

    /// Computed, not stored: `[FileAttributeKey: Any]` is not `Sendable`, and a
    /// two-entry dictionary costs nothing to rebuild.
    static var protectionAttributes: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }

    /// Walk every existing archive file and upgrade its protection class to
    /// match the directory. Kept out of `createArchiveDirectoryIfNeeded`
    /// so the file walk doesn't block launch; called from the launch
    /// housekeeping phase, off the main thread and after the dashboard's
    /// first read. Idempotent — safe to re-run every launch.
    ///
    /// The directory-level setAttributes only affects NEW files; the 30+
    /// session files already on disk keep whatever class they had at write
    /// time.
    ///
    /// Not `try?`, which would silently
    /// swallow failures: a user's debug log
    /// showed 1,557 EPERM read failures across session JSON files; the
    /// migration was running but `setAttributes` was failing on individual
    /// files and we had no signal. So failures are logged (so future debug
    /// captures show what's stuck) and each one force-rewrites the file with
    /// the explicit protection-class option to break out of the stuck state.
    func upgradeExistingFileProtection() {
        var attrFailureCount = 0
        for case let filename as String in fileManager.enumerator(atPath: archiveDirectory.path) ?? .init() {
            let path = archiveDirectory.appendingPathComponent(filename).path
            if !applyProtectionAttributes(at: path, filename: filename, failureCount: attrFailureCount) {
                attrFailureCount += 1
            }
        }
        if attrFailureCount > 5 {
            debugLog("[Archive] WARN: \(attrFailureCount - 5) additional setAttributes failures (capped log)", level: .warning)
        }
    }

    /// False when the attribute write failed and the file was force-rewritten
    /// instead. Log noise is capped at 5 lines; bulk failures surface via the
    /// caller's count log.
    private func applyProtectionAttributes(at path: String, filename: String, failureCount: Int) -> Bool {
        do {
            try fileManager.setAttributes(Self.protectionAttributes, ofItemAtPath: path)
            return true
        } catch {
            if failureCount < 5 {
                debugLog("[Archive] WARN: setAttributes failed for \(filename): \(error.localizedDescription) — attempting rewrite", level: .warning)
            }
            rewriteWithProtection(at: path)
            return false
        }
    }

    func loadIndex() {
        guard fileManager.fileExists(atPath: indexFile.path) else { return }

        do {
            let data = try Data(contentsOf: indexFile)
            index = try Self.sessionDecoder.decode([SessionArchiveEntry].self, from: data)
            sessionIdLookup = nil
        } catch {
            debugLog("Failed to load archive index: \(error)", level: .error)
            index = []
            preserveUnreadableIndex()
        }
    }

    /// The first save after a failed load writes a near-empty index over the
    /// one that failed, and with it the only list of the user's sessions. The
    /// unreadable file is moved aside first — a rename works even when the
    /// bytes cannot be read — and the session files themselves stay put, so
    /// the orphan scan at the end of `boot()` adopts every one of them back.
    private func preserveUnreadableIndex() {
        let aside = indexFile.deletingLastPathComponent()
            .appendingPathComponent("\(indexFile.lastPathComponent).unreadable_\(Int(Date().timeIntervalSince1970))")
        if attempt("Archive.preserveIndex", { try fileManager.moveItem(at: indexFile, to: aside) }) != nil {
            debugLog("[Archive] unreadable index moved to \(aside.lastPathComponent); sessions will be re-adopted from their files", level: .warning)
        }
    }

    func loadDeletedIndex() {
        guard fileManager.fileExists(atPath: deletedIndexFile.path) else { return }

        do {
            let data = try Data(contentsOf: deletedIndexFile)
            let uuidStrings = try Self.sessionDecoder.decode([String].self, from: data)
            deletedSessionIds = Set(uuidStrings.compactMap { UUID(uuidString: $0) })
        } catch {
            // Not emptied and then saved over: the next deletion would write a
            // one-entry list over every tombstone the pull relies on, and
            // sessions the user deleted would download again. The file is set
            // aside and the list rebuilt from the deletion times kept beside it.
            debugLog("Failed to load deleted index: \(error) — rebuilding from recorded deletion times", level: .error)
            let aside = deletedIndexFile.deletingLastPathComponent()
                .appendingPathComponent("\(deletedIndexFile.lastPathComponent).unreadable_\(Int(Date().timeIntervalSince1970))")
            _ = attempt("Archive.preserveDeletedIndex") { try fileManager.moveItem(at: deletedIndexFile, to: aside) }
            deletedSessionIds = ArchiveStore.idsWithRecordedDeletionTime()
        }
    }

    func saveDeletedIndex() throws {
        let uuidStrings = deletedSessionIds.map(\.uuidString)
        let data = try Self.indexEncoder.encode(uuidStrings)
        try data.write(to: deletedIndexFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func saveIndex() throws {
        sortedEntriesCache = nil
        sessionIdLookup = nil
        let data = try Self.indexEncoder.encode(index)
        try data.write(to: indexFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - Errors

    enum ArchiveError: Error, LocalizedError {
        case hashMismatch
        case fileNotFound
        case sessionWasDeleted
        /// The session payload was decoded from a NEWER schema than this
        /// build writes (associated value = the payload's schema version).
        /// Re-encoding it here would silently drop the newer-schema fields,
        /// so `_archive` refuses the write.
        case newerSchemaVersion(Int)

        var errorDescription: String? {
            switch self {
            case .hashMismatch:
                "Session data integrity check failed — the file may be corrupted."
            case .fileNotFound:
                "Session file could not be found on disk."
            case .sessionWasDeleted:
                "This session was previously deleted."
            case let .newerSchemaVersion(version):
                "This session was saved by a newer app version (schema v\(version)) — update the app to modify it."
            }
        }

        /// True for failures that retrying can NEVER fix — a corrupt payload
        /// (`hashMismatch`) or an on-disk schema newer than this build can
        /// re-encode. The CloudKit push quarantines these instead of retrying
        /// them every sync forever (see `CloudKitSyncManager.pushPendingSessions`).
        var isPermanentUploadFailure: Bool {
            switch self {
            case .hashMismatch, .newerSchemaVersion: true
            case .fileNotFound, .sessionWasDeleted: false
            }
        }
    }
}

// MARK: - Index Entry Factory

extension SessionArchiveEntry {
    /// Single factory for building a lightweight index entry from a full
    /// session.
    ///
    /// Hand-rolled 16+-argument initializer calls at each site drift into
    /// INCONSISTENT field coverage: if `_archive` populates every field while
    /// `archiveBatch`, `repairArchive`, and `reconcileOrphanFiles` drop
    /// `meanSDNN` and/or the sleep-stage + nocturnal-dip mirror fields,
    /// sessions that enter the index via batch import, repair, or orphan
    /// adoption are invisible to 30-day sleep-stage trends and AI context
    /// queries (which read the lightweight index) until something re-archives
    /// them through `_archive`.
    ///
    /// Routing every construction site through this factory prevents that
    /// index drift. Field population matches `_archive`'s construction
    /// exactly, including `SessionArchive.deriveSleepIndexFields`.
    ///
    /// - Parameters:
    ///   - overridingSessionId: `repairArchive` keys rebuilt entries by the
    ///     UUID parsed from the FILENAME (the archive's naming contract),
    ///     not the id stored inside the payload. Pass it to preserve that
    ///     behavior exactly; every other site uses `session.id`.
    ///   - recoveryScoreFallback: `repairArchive` falls back to the raw
    ///     readiness score for legacy sessions that predate the composite
    ///     recovery score. Used only when `session.recoveryScore` is nil.
    static func make(
        from session: HRVSession,
        hash: String,
        filePath: String,
        overridingSessionId: UUID? = nil,
        recoveryScoreFallback: Double? = nil
    ) -> SessionArchiveEntry {
        let sleepFields = SessionArchive.deriveSleepIndexFields(from: session)
        // Mirror sleep stages + nocturnal dip into the lightweight index so
        // 30-day trend / AI queries don't need to load each session file.
        let mirror = SleepMirror(session: session)
        return SessionArchiveEntry(
            sessionId: overridingSessionId ?? session.id,
            date: session.startDate, endDate: session.endDate,
            fileHash: hash, filePath: filePath,
            recoveryScore: session.recoveryScore ?? recoveryScoreFallback,
            meanRMSSD: session.rmssd, meanHR: session.meanHR,
            stressIndex: session.stressIndex, meanSDNN: session.importedMetrics?.sdnn,
            tags: session.tags, notes: session.notes,
            sessionType: session.sessionType, linkedSessionIds: session.linkedSessionIds,
            sleepEnd: sleepFields.sleepEnd, sleepSegmentCount: sleepFields.sleepSegmentCount,
            deepSleepMinutes: mirror.deep, remSleepMinutes: mirror.rem,
            coreSleepMinutes: mirror.core, awakeMinutes: mirror.awake,
            nocturnalDipPercent: mirror.dip, hrvDataQuality: session.hrvDataQuality
        )
    }

    /// Sleep-stage + nocturnal-dip mirror fields derived from a full session.
    /// Single source of truth so `make(from:)` and `mirroringSleepFields(from:)`
    /// can never drift. Dip is computed by HRVAnalysisPipeline and stored on
    /// ANSMetrics.
    struct SleepMirror {
        let deep: Int?
        let rem: Int?
        let core: Int?
        let awake: Int?
        let dip: Double?

        init(session: HRVSession) {
            let snapshot = session.sleepSnapshot
            deep = snapshot?.deepSleepMinutes
            rem = snapshot?.remSleepMinutes
            core = Self.coreMinutes(in: snapshot)
            awake = snapshot?.awakeMinutes
            dip = session.analysisResult?.ansMetrics?.nocturnalHRDip
        }

        /// Core sleep isn't a top-level SleepData field — sum across segments
        /// when present, otherwise derive from total − deep − REM (only when
        /// we have both stage values, otherwise we can't tell what's "core").
        private static func coreMinutes(in snapshot: SleepData?) -> Int? {
            guard let snapshot else { return nil }
            let fromSegments = snapshot.effectiveSegments.compactMap(\.coreSleepMinutes).reduce(0, +)
            if fromSegments > 0 { return fromSegments }
            guard let deep = snapshot.deepSleepMinutes,
                  let rem = snapshot.remSleepMinutes else { return nil }
            return max(0, snapshot.nightSleepMinutes - deep - rem)
        }
    }

    /// Returns a copy of this entry with the sleep-stage + nocturnal-dip mirror
    /// fields repopulated from `session`, preserving every other field exactly.
    ///
    /// Migrations that rebuild an entry through the field-by-field initializer
    /// MUST call this, or they silently null the mirror fields that 30-day sleep
    /// trends + the AI fact catalog read straight off the lightweight index —
    /// the same drift `make(from:)` exists to prevent.
    /// The migrations keep their own per-field semantics (they patch a
    /// specific field like recoveryScore/endDate); this only overlays the five
    /// mirror fields from the session already loaded off disk.
    func mirroringSleepFields(from session: HRVSession) -> SessionArchiveEntry {
        let mirror = SleepMirror(session: session)
        return SessionArchiveEntry(
            sessionId: sessionId,
            date: date, endDate: endDate,
            fileHash: fileHash, filePath: filePath,
            recoveryScore: recoveryScore,
            meanRMSSD: meanRMSSD, meanHR: meanHR,
            stressIndex: stressIndex, meanSDNN: meanSDNN,
            tags: tags, notes: notes,
            sessionType: sessionType, linkedSessionIds: linkedSessionIds,
            sleepEnd: sleepEnd, sleepSegmentCount: sleepSegmentCount,
            deepSleepMinutes: mirror.deep, remSleepMinutes: mirror.rem,
            coreSleepMinutes: mirror.core, awakeMinutes: mirror.awake,
            nocturnalDipPercent: mirror.dip, hrvDataQuality: session.hrvDataQuality
        )
    }
}

// MARK: - File-scope helpers
//
// Moved out of SessionArchive. Each names no member of the
// type and calls nothing that stayed behind, so none needed to be inside
// it. `private` at file scope is fileprivate, so every call site in this
// file resolves exactly as before.

/// Rewrite the file with the explicit protection-class option.
/// `Data.write(to:options:)` honors
/// `completeFileProtectionUntilFirstUserAuthentication` even when
/// `setAttributes` cannot.
private func rewriteWithProtection(at path: String) {
    guard let bytes = attempt("archive.protectionUpgrade.read", {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }) else { return }
    attempt("archive.protectionUpgrade.write") {
        try bytes.write(to: URL(fileURLWithPath: path), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
