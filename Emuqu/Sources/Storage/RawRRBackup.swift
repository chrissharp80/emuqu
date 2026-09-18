import CryptoKit
import Foundation

/// Raw RR data backup - writes immediately to prevent any data loss
/// This is a safety net: raw RR intervals with timestamps are stored
/// independently of the session archive, so even if the app crashes
/// or the user rejects/cancels, the raw data is never lost.
///
/// Streaming sessions use an append-only JSONL format: new RR points are
/// appended to disk without re-serializing previous data. This keeps backup
/// cost constant (~60 points per write) regardless of session length.
final class RawRRBackup: @unchecked Sendable {
    // @unchecked Sendable: mutable state is protected by `indexLock`; all
    // on-disk writes go through a single-threaded code path. This lets us
    // call backup methods from a background Task (e.g. off the workout
    // recorder's main-actor tick) without Swift 6 data-race warnings. See
    // WorkoutRecorder.incrementalBackupTick for the off-main-thread caller.
    // MARK: - Types

    /// Raw RR backup entry (public interface — consumers see this regardless of on-disk format)
    struct BackupEntry: Codable {
        let id: UUID
        let captureDate: Date
        let deviceId: String?
        let points: [RRPoint]
        let hash: String // SHA256 of the RR data for integrity verification

        /// Duration in seconds
        var duration: TimeInterval {
            guard let first = points.first, let last = points.last else { return 0 }
            return Double(last.t_ms - first.t_ms) / 1000.0
        }

        /// Beat count
        var beatCount: Int {
            points.count
        }
    }

    /// Lightweight header stored alongside the append-only points file
    struct BackupHeader: Codable {
        let id: UUID
        let captureDate: Date
        let deviceId: String?
    }

    // MARK: - Properties

    let backupDirectory: URL
    let indexFile: URL
    var index: [BackupIndex] = []
    let fileManager = FileManager.default
    let indexLock = NSLock()

    /// Serializes the whole read-modify-write of an incremental append.
    ///
    /// `indexLock` alone is not enough. If `appendBackup` took the
    /// lock, read `backedUpCount`, RELEASED it, did all the file I/O, then
    /// re-took the lock to store the new count, overlapping calls would
    /// corrupt the file: `WorkoutRecorder+Ticker` fires
    /// `incrementalBackup` from `Task.detached` on every 1 Hz tick, and
    /// detached tasks have no ordering guarantee relative to one another — so
    /// two overlapping calls both read the same `previousCount`, both encode
    /// `points[previousCount...]`, and both append it. The duplicate beats
    /// then fail the count-based integrity check on read, which rejects the
    /// ENTIRE backup file.
    ///
    /// That is the file that exists so a mid-night crash doesn't lose the
    /// recording (see the "29,067 RR points lost" note below), so a corrupting
    /// race here defeats the whole mechanism.
    ///
    /// Same shape as `SettingsManager.settingsWriteQueue`. `sync` rather than
    /// `async` because callers rely on the returned Bool, and the queue is
    /// private so there is no re-entrancy path back into it.
    private let appendQueue = DispatchQueue(label: "com.emuqu.rawrrbackup.append", qos: .utility)

    /// Shared encoder for JSONL line serialization (no pretty-print, no sorted keys — speed)
    let lineEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    /// Index entry (lightweight reference without full RR data)
    struct BackupIndex: Codable {
        static let currentSchemaVersion = 1

        let id: UUID
        let captureDate: Date
        /// Legacy single-file backup name (non-nil for old format)
        let fileName: String?
        let beatCount: Int
        let hash: String
        /// Has this backup been successfully incorporated into an archived session?
        var archived: Bool
        /// When was the last backup performed (for time-based incremental backups)
        var lastBackupTime: Date?
        /// How many points have been written to the append-only file (nil = legacy format)
        var backedUpCount: Int?

        // MARK: - Codable with defaults for new fields

        enum CodingKeys: String, CodingKey {
            case schemaVersion
            case id, captureDate, fileName, beatCount, hash, archived, lastBackupTime, backedUpCount
        }

        init(id: UUID, captureDate: Date, fileName: String?, beatCount: Int, hash: String, archived: Bool, lastBackupTime: Date?, backedUpCount: Int? = nil) {
            self.id = id
            self.captureDate = captureDate
            self.fileName = fileName
            self.beatCount = beatCount
            self.hash = hash
            self.archived = archived
            self.lastBackupTime = lastBackupTime
            self.backedUpCount = backedUpCount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Schema version: absent in legacy data → defaults to 0
            _ = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            id = try container.decode(UUID.self, forKey: .id)
            captureDate = try container.decode(Date.self, forKey: .captureDate)
            // Legacy indices stored fileName as non-optional String
            fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
            beatCount = try container.decode(Int.self, forKey: .beatCount)
            hash = try container.decode(String.self, forKey: .hash)
            archived = try container.decode(Bool.self, forKey: .archived)
            lastBackupTime = try container.decodeIfPresent(Date.self, forKey: .lastBackupTime)
            backedUpCount = try container.decodeIfPresent(Int.self, forKey: .backedUpCount)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
            try container.encode(id, forKey: .id)
            try container.encode(captureDate, forKey: .captureDate)
            try container.encodeIfPresent(fileName, forKey: .fileName)
            try container.encode(beatCount, forKey: .beatCount)
            try container.encode(hash, forKey: .hash)
            try container.encode(archived, forKey: .archived)
            try container.encodeIfPresent(lastBackupTime, forKey: .lastBackupTime)
            try container.encodeIfPresent(backedUpCount, forKey: .backedUpCount)
        }
    }

    // MARK: - Termination forensics (static, lockless)

    /// Compact summary of what an in-flight backup looked
    /// like right before the app was killed, used by
    /// `CrashLogManager.recordTermination` to populate the termination
    /// report with actionable forensics (not just "iOS killed it").
    /// User reported a SIGKILL log that said nothing about when the
    /// crash actually happened or where their data went; this surfaces
    /// both.
    ///
    /// Lockless and static: the singleton may not be fully initialised
    /// at termination-report write time, and we don't want to take any
    /// lock that could deadlock the launch path. Reads the index file
    /// directly and parses it independently of the running manager.
    struct TerminationForensicsSummary {
        /// Wall-clock time of the LAST incremental backup write
        /// before the process was killed. The recording was alive at
        /// or just after this time — within the backup interval
        /// (typically a few seconds). Best available estimate of
        /// "when did the crash happen?"
        let lastBackupTime: Date?
        /// Beat count claimed in the index header. The recording
        /// thinks it captured this many points.
        let beatCount: Int
        /// Beats actually written to the append-only points file
        /// (nil for legacy single-file format).
        let backedUpCount: Int?
        /// Bytes on disk for the points file. Confirms the data
        /// physically exists even when no analysis ever ran.
        let pointsFileSize: Int64?
        /// Whether the backup has already been folded into a
        /// finalized `HRVSession` (`archived = true` in the index).
        /// When true the user already has a session for this
        /// recording; when false the data is recoverable but not
        /// yet a session.
        let isArchived: Bool
    }

    /// The backup directory is recomputed the same way `init()` does, and this
    /// stays lockless so it is safe to call from
    /// `CrashLogManager.recordTermination` at launch time.
    static func terminationForensicsSummary(for sessionId: UUID) -> TerminationForensicsSummary? {
        let fm = FileManager.default
        guard let backupDirectory = Self.resolveBackupDirectory(fm),
              let entry = Self.storedIndexEntry(for: sessionId, in: backupDirectory) else { return nil }
        let pointsURL = backupDirectory.appendingPathComponent("\(sessionId.uuidString)_points.jsonl")
        return TerminationForensicsSummary(
            lastBackupTime: entry.lastBackupTime,
            beatCount: entry.beatCount,
            backedUpCount: entry.backedUpCount,
            pointsFileSize: (try? fm.attributesOfItem(atPath: pointsURL.path)).flatMap { ($0[.size] as? NSNumber)?.int64Value },
            isArchived: entry.archived
        )
    }

    /// One session's row read straight off the on-disk backup index.
    private static func storedIndexEntry(for sessionId: UUID, in backupDirectory: URL) -> BackupIndex? {
        guard let data = try? Data(contentsOf: backupDirectory.appendingPathComponent("backup_index.json")) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([BackupIndex].self, from: data))?.first { $0.id == sessionId }
    }

    /// App Group container first (survives reinstalls), falling back to Documents.
    private static func resolveBackupDirectory(_ fm: FileManager) -> URL? {
        if let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) {
            return containerURL.appendingPathComponent(AppConfig.backupDirectoryName, isDirectory: true)
        }
        return fm.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(AppConfig.backupDirectoryName, isDirectory: true)
    }

    // MARK: - Initialization

    init() {
        backupDirectory = Self.resolveBackupDirectory()
        indexFile = backupDirectory.appendingPathComponent("backup_index.json")

        createBackupDirectoryIfNeeded()
        loadIndex()
        logUnarchivedCount()
    }

    /// Try App Group container first (survives reinstalls), fall back to
    /// Documents, then the temporary directory (should never happen on iOS).
    private static func resolveBackupDirectory() -> URL {
        let fm = FileManager.default
        if let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) {
            debugLog("[RawRRBackup] Using App Group container")
            return containerURL.appendingPathComponent(AppConfig.backupDirectoryName, isDirectory: true)
        }
        if let documentsPath = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            debugLog("[RawRRBackup] Using Documents directory (App Group not configured)")
            return documentsPath.appendingPathComponent(AppConfig.backupDirectoryName, isDirectory: true)
        }
        debugLog("[RawRRBackup] WARNING: Using temporary directory as fallback")
        return fm.temporaryDirectory.appendingPathComponent(AppConfig.backupDirectoryName, isDirectory: true)
    }

    /// Only log on startup if there are unarchived backups (potential data loss).
    private func logUnarchivedCount() {
        indexLock.lock()
        let unarchivedCount = index.filter { !$0.archived }.count
        indexLock.unlock()
        if unarchivedCount > 0 {
            debugLog("[RawRRBackup] Found \(unarchivedCount) unarchived backups")
        }
    }

    // MARK: - File Paths (append-only format)

    func headerURL(for sessionId: UUID) -> URL {
        backupDirectory.appendingPathComponent("\(sessionId.uuidString)_header.json")
    }

    func pointsURL(for sessionId: UUID) -> URL {
        backupDirectory.appendingPathComponent("\(sessionId.uuidString)_points.jsonl")
    }

    // MARK: - Backup API

    /// One-shot backup of raw RR data (used for completed sessions, device fetches, cloud recovery).
    /// For streaming sessions, use `incrementalBackup()` which appends only new points.
    /// - Parameters:
    ///   - points: The raw RR intervals with timestamps
    ///   - sessionId: Session ID for cross-reference
    ///   - deviceId: Optional device identifier
    ///
    /// Writes the legacy single-file format, which is fine for one-shot
    /// backups, then cleans up any previous append-only files for this
    /// session (the formats are mutually exclusive).
    @discardableResult
    func backup(points: [RRPoint], sessionId: UUID, deviceId: String? = nil) throws -> BackupEntry {
        guard !points.isEmpty else {
            throw BackupError.noDataToBackup
        }
        let entry = BackupEntry(
            id: sessionId, captureDate: Date(), deviceId: deviceId,
            points: points, hash: try Self.integrityHash(of: points)
        )
        let fileName = "\(sessionId.uuidString)_\(Int(Date().timeIntervalSince1970)).json"
        try Self.writeEntry(entry, to: backupDirectory.appendingPathComponent(fileName), sessionId: sessionId)
        cleanupAppendFiles(for: sessionId)
        try reindex(sessionId: sessionId, entry: entry, fileName: fileName, beatCount: points.count)
        if points.count < 100 {
            debugLog("[RawRRBackup] Backed up \(points.count) beats for session \(sessionId.uuidString.prefix(8))")
        }
        return entry
    }

    /// Hash of the RR data for integrity. `.sortedKeys` pins the JSON key
    /// order so two encodings of the same data produce byte-for-byte identical
    /// output (and therefore identical hashes) regardless of process state,
    /// device, or runtime key-order heuristics. Without this the hash is
    /// non-portable and sometimes non-stable between sequential calls in the
    /// same process.
    ///
    /// Drained in an autoreleasepool. This encodes the full
    /// night's points purely to hash them (a multi-MB boxed JSONEncoder tree)
    /// and otherwise stacks with the other stop-time encodes into a SIGKILL
    /// memory spike. Same bytes, same hash — just freed immediately.
    static func integrityHash(of points: [RRPoint]) throws -> String {
        try autoreleasepool {
            let hashEncoder = JSONEncoder()
            hashEncoder.dateEncodingStrategy = .iso8601
            hashEncoder.outputFormatting = [.sortedKeys]
            let pointsData = try hashEncoder.encode(points)
            return SHA256.hash(data: pointsData).compactMap { String(format: "%02x", $0) }.joined()
        }
    }

    /// Encrypt one-shot backup blobs at write
    /// time. Read path detects format via magic prefix (same scheme as
    /// Archive.swift) and falls back to legacy plaintext for forward
    /// migration. The append-only points file path is left plaintext
    /// — encrypted at the directory level via
    /// NSFileProtectionComplete (set in createBackupDirectoryIfNeeded).
    ///
    /// Encode+encrypt drained in an autoreleasepool (the entry
    /// re-embeds the full night's points — the second big tree of this call).
    /// Write one entry, choosing the protection class from whether it encrypted.
    ///
    /// Unencrypted bytes get `.completeFileProtection`
    /// — unreadable whenever the device is locked, not merely before the first
    /// unlock — and the session is queued for re-encryption at next launch.
    private static func writeEntry(_ entry: BackupEntry, to url: URL, sessionId: UUID) throws {
        let encoded = try encodedEntry(entry)
        if !encoded.encrypted {
            PendingEncryptionLedger.record(sessionId)
        }
        let options: Data.WritingOptions = encoded.encrypted
            ? [.completeFileProtectionUntilFirstUserAuthentication]
            : [.completeFileProtection]
        try encoded.bytes.write(to: url, options: options)
    }

    /// Encode one backup entry, reporting whether encryption actually happened.
    ///
    /// Not a `try? encrypt(...)` falling through to
    /// `return plaintext` with no log and no signal of any kind. Raw RR points
    /// are the rawest physiological data the app holds, and this is the crash-
    /// recovery path, so the fallback fires exactly when something has already
    /// gone wrong. It reports the format so the caller can pick the
    /// strictest protection class and queue re-encryption.
    private static func encodedEntry(_ entry: BackupEntry) throws -> (bytes: Data, encrypted: Bool) {
        try autoreleasepool {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let plaintext = try encoder.encode(entry)
            let manager = AppDependencies.current.storage.encryptionManager
            guard manager.isAvailable else { return (plaintext, false) }
            do {
                return (try manager.encrypt(plaintext), true)
            } catch {
                debugLog("[RawRRBackup] encrypt failed for \(entry.id.uuidString.prefix(8)): \(error)", level: .error)
                return (plaintext, false)
            }
        }
    }

    /// Replace any existing backup index row for this session.
    private func reindex(
        sessionId: UUID, entry: BackupEntry, fileName: String, beatCount: Int
    ) throws {
        let indexEntry = BackupIndex(
            id: sessionId,
            captureDate: entry.captureDate,
            fileName: fileName,
            beatCount: beatCount,
            hash: entry.hash,
            archived: false,
            lastBackupTime: Date(),
            backedUpCount: nil // nil = legacy format
        )
        indexLock.lock()
        index.removeAll { $0.id == sessionId }
        index.append(indexEntry)
        indexLock.unlock()
        try saveIndex()
    }

    /// Mark a backup as successfully archived (still kept for safety)
    /// Beats recorded in the raw backup for `sessionId`, if a backup exists.
    /// The recovery archiver consults this before marking a backup archived so
    /// a truncated device fetch can't retire a backup that holds materially
    /// more data than what was archived.
    func backedUpBeatCount(_ sessionId: UUID) -> Int? {
        indexLock.lock()
        defer { indexLock.unlock() }
        return index.first(where: { $0.id == sessionId })?.beatCount
    }

    /// Lower a backup's stored beat counts to what actually survived on disk.
    /// Used to reconcile a torn/truncated append-only write, where the index
    /// claims more beats than the points file holds (index says 4380, disk has
    /// 147). Only ever LOWERS the count — we never fabricate beats we don't
    /// have. After reconciling, the backup stops mismatching on every read and
    /// the recovery archiver can retire it normally.
    func reconcileBeatCount(sessionId: UUID, to actualCount: Int, claimed: Int) {
        indexLock.lock()
        guard let idx = index.firstIndex(where: { $0.id == sessionId }) else {
            indexLock.unlock()
            return
        }
        let entry = index[idx]
        // Only act when it actually lowers something.
        guard (entry.backedUpCount ?? entry.beatCount) > actualCount else {
            indexLock.unlock()
            return
        }
        index[idx] = BackupIndex(
            id: entry.id, captureDate: entry.captureDate, fileName: entry.fileName,
            beatCount: actualCount, hash: entry.hash, archived: entry.archived,
            lastBackupTime: entry.lastBackupTime, backedUpCount: actualCount
        )
        indexLock.unlock()
        persistReconciledCount(sessionId: sessionId, to: actualCount, claimed: claimed)
    }

    private func persistReconciledCount(sessionId: UUID, to actualCount: Int, claimed: Int) {
        do {
            try saveIndex()
            debugLog("[RawRRBackup] Reconciled truncated backup \(sessionId.uuidString.prefix(8)): stored beat count lowered \(claimed) → \(actualCount) (torn write; missing beats are unrecoverable)")
        } catch {
            debugLog("[RawRRBackup] ⚠️ Failed to save index after reconcile: \(error)", level: .warning)
        }
    }

    /// Mark every backup whose session the archive already holds.
    ///
    /// `markAsArchived` is called on each successful archive path, so the flag
    /// is right for anything that completed in one go. It is wrong for anything
    /// that reached the archive by another route — a CloudKit pull, a launch
    /// recovery, a merge that reused a different session id — because no
    /// archive call ever passed through the backup's own id.
    ///
    /// Those entries then sit flagged forever. A field log shows the same
    /// fifteen at every launch across five days, and the Data settings page
    /// renders that as a red "Unarchived recordings — 15" for a user whose data
    /// is, in fact, safely archived. The count is meant to mean "beats that
    /// exist only in a backup"; without this reconciliation it means "beats
    /// that did not take the usual path", which is not a thing anyone can act
    /// on.
    ///
    /// Returns how many it corrected, so the caller can log a real number.
    @discardableResult
    func reconcileArchived(against archivedSessionIds: Set<UUID>) -> Int {
        indexLock.lock()
        let corrected = Self.indicesNeedingArchivedFlag(index, archivedSessionIds: archivedSessionIds)
        for idx in corrected { index[idx].archived = true }
        indexLock.unlock()
        guard !corrected.isEmpty else { return 0 }
        do {
            try saveIndex()
        } catch {
            debugLog("[RawRRBackup] ⚠️ Failed to save index after reconcile: \(error)", level: .warning)
        }
        return corrected.count
    }

    /// Which index positions are flagged unarchived while the archive holds
    /// their session. Pure, so the reconciliation rule is testable without a
    /// backup directory or an archive.
    nonisolated static func indicesNeedingArchivedFlag(
        _ index: [BackupIndex],
        archivedSessionIds: Set<UUID>
    ) -> [Int] {
        index.indices.filter { !index[$0].archived && archivedSessionIds.contains(index[$0].id) }
    }

    func markAsArchived(_ sessionId: UUID) {
        indexLock.lock()
        guard let idx = index.firstIndex(where: { $0.id == sessionId }) else {
            indexLock.unlock()
            return
        }
        index[idx].archived = true
        indexLock.unlock()
        do {
            try saveIndex()
        } catch {
            debugLog("[RawRRBackup] ⚠️ Failed to save index after marking archived: \(error)")
        }
        // No logging needed - archival is already logged in Archive.swift
    }

    /// Incremental backup during streaming — appends only new points since last backup.
    /// First call writes the header + all points. Subsequent calls append only the delta.
    /// Cost is O(new points) regardless of total session length.
    /// - Parameters:
    ///   - points: All RR points collected so far (not just new ones)
    ///   - sessionId: Session ID for cross-reference
    ///   - deviceId: Optional device identifier
    ///   - force: Force backup even if time threshold not met (for reconnection events, lifecycle events)
    ///   - interval: Seconds between disk flushes (default 60)
    /// - Returns: True if backup was updated, false if skipped (too soon, no data)
    @discardableResult
    func incrementalBackup(points: [RRPoint], sessionId: UUID, deviceId: String? = nil, force: Bool = false, interval: TimeInterval = 60) -> Bool {
        guard !points.isEmpty else { return false }
        return appendQueue.sync {
            incrementalBackupLocked(points: points, sessionId: sessionId, deviceId: deviceId, force: force, interval: interval)
        }
    }

    /// Body of `incrementalBackup`, always run on `appendQueue`.
    private func incrementalBackupLocked(points: [RRPoint], sessionId: UUID, deviceId: String?, force: Bool, interval: TimeInterval) -> Bool {
        indexLock.lock()
        let existingEntry = index.first { $0.id == sessionId }
        indexLock.unlock()
        guard force || Self.isDue(lastBackup: existingEntry?.lastBackupTime, interval: interval) else {
            return false
        }
        do {
            try appendBackup(points: points, sessionId: sessionId, deviceId: deviceId)
            return true
        } catch {
            debugLog("[RawRRBackup] ❌ Incremental backup failed: \(error)")
            return false
        }
    }

    /// No previous backup means write immediately on first data.
    private static func isDue(lastBackup: Date?, interval: TimeInterval) -> Bool {
        guard let lastBackup else { return true }
        return Date().timeIntervalSince(lastBackup) >= interval
    }

    /// Get count of unarchived backups (potential data recovery candidates)
    var unarchivedBackupCount: Int {
        indexLock.lock()
        let count = index.filter { !$0.archived }.count
        indexLock.unlock()
        return count
    }

    /// Get IDs of unarchived backups for potential recovery
    var unarchivedSessionIds: [UUID] {
        indexLock.lock()
        let ids = index.filter { !$0.archived }.sorted { $0.captureDate > $1.captureDate }.map(\.id)
        indexLock.unlock()
        return ids
    }

    /// Backups indexed at or after `cutoff`, read from the index alone — no
    /// backup file is opened.
    ///
    /// The index date is the header's capture date for a legacy backup and the
    /// moment of the first incremental save for an append-only one, which is
    /// never earlier than the header's. So this never drops a backup whose
    /// header is inside the window; it can admit one whose header is just
    /// outside it, which is why callers that care about the exact date still
    /// read the backup.
    func sessionIds(indexedSince cutoff: Date) -> [UUID] {
        indexLock.lock()
        let ids = index.filter { $0.captureDate >= cutoff }.map(\.id)
        indexLock.unlock()
        return ids
    }

    /// Retrieve a backup entry by session ID (supports both legacy and append-only formats)
    func retrieve(_ sessionId: UUID) throws -> BackupEntry? {
        indexLock.lock()
        let stored = index.first(where: { $0.id == sessionId })
        indexLock.unlock()
        guard let indexEntry = stored else { return nil }
        // Append-only format: header + JSONL points file
        if indexEntry.backedUpCount != nil {
            return try retrieveAppendFormat(sessionId: sessionId, indexEntry: indexEntry)
        }
        // Legacy single-file format
        guard let fileName = indexEntry.fileName else { return nil }
        let entry = try Self.decodeLegacyBackup(
            at: backupDirectory.appendingPathComponent(fileName)
        )
        guard entry.hash == indexEntry.hash else {
            throw BackupError.hashMismatch
        }
        return entry
    }

    /// Detect encrypted format via the same
    /// 0x46 0x52 magic prefix Archive.swift uses. Legacy plaintext
    /// backups still decode unchanged.
    private static func decodeLegacyBackup(at filePath: URL) throws -> BackupEntry {
        let rawBytes = try Data(contentsOf: filePath)
        let plaintext: Data
        if rawBytes.count >= 2, rawBytes[0] == 0x46, rawBytes[1] == 0x52 {
            plaintext = try AppDependencies.current.storage.encryptionManager.decrypt(rawBytes)
        } else {
            plaintext = rawBytes
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupEntry.self, from: plaintext)
    }

    /// Retrieve all backups (for export/recovery)
    func allBackups() -> [BackupEntry] {
        indexLock.lock()
        let currentIndex = index
        indexLock.unlock()
        return currentIndex.compactMap { readableBackup($0.id) }.sorted { $0.captureDate > $1.captureDate }
    }

    /// The backup, or nil when it is missing or does not decode — a decode
    /// failure is logged rather than thrown, for callers walking many backups.
    func readableBackup(_ sessionId: UUID) -> BackupEntry? {
        do {
            return try retrieve(sessionId)
        } catch {
            debugLog("[RawRRBackup] WARNING: Failed to retrieve backup \(sessionId.uuidString.prefix(8)): \(error)")
            return nil
        }
    }

    /// Get total backup size in bytes
    var totalBackupSize: Int64 {
        indexLock.lock()
        let currentIndex = index
        indexLock.unlock()
        return currentIndex.reduce(0) { $0 + backupSize(of: $1) }
    }

    /// On-disk bytes for one index entry, covering both the legacy single-file
    /// layout and the append-only header + points pair.
    private func backupSize(of indexEntry: BackupIndex) -> Int64 {
        var urls: [URL] = []
        if let fileName = indexEntry.fileName {
            urls.append(backupDirectory.appendingPathComponent(fileName))
        }
        if indexEntry.backedUpCount != nil {
            urls += [headerURL(for: indexEntry.id), pointsURL(for: indexEntry.id)]
        }
        return urls.reduce(0) { $0 + fileSize(at: $1) }
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    /// Discard a single backup permanently — removes the file(s) and the
    /// index entry. Use for backups that can provably never be recovered
    /// (e.g. beat count below the 120 analysis floor) so they stop showing
    /// up in the "Lost Sessions" list forever.
    /// - Parameter sessionId: Session ID to discard.
    func discardBackup(_ sessionId: UUID) throws {
        indexLock.lock()
        let entry = index.first { $0.id == sessionId }
        indexLock.unlock()
        guard let entry else { return }

        if let fileName = entry.fileName {
            let filePath = backupDirectory.appendingPathComponent(fileName)
            _ = attempt("RawRRBackup.remove") { try fileManager.removeItem(at: filePath) }
        }
        cleanupAppendFiles(for: entry.id)

        indexLock.lock()
        index.removeAll { $0.id == sessionId }
        indexLock.unlock()
        try saveIndex()
        debugLog("[RawRRBackup] Discarded backup \(sessionId.uuidString.prefix(8)) (\(entry.backedUpCount ?? 0) beats)")
    }

    /// Purge old archived backups (keep last N days)
    /// - Parameter keepDays: Number of days to keep archived backups
    func purgeOldBackups(keepDays: Int = 90) throws {
        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date()) else { return }
        indexLock.lock()
        let toRemove = index.filter { $0.archived && $0.captureDate < cutoffDate }
        indexLock.unlock()
        guard !toRemove.isEmpty else { return }
        for entry in toRemove {
            removeBackupFiles(for: entry)
        }
        indexLock.lock()
        let removedIds = Set(toRemove.map(\.id))
        index.removeAll { removedIds.contains($0.id) }
        indexLock.unlock()
        try saveIndex()
        debugLog("[RawRRBackup] Purged \(toRemove.count) old archived backups")
    }

    /// Remove both the legacy single file and the append-only pair.
    private func removeBackupFiles(for entry: BackupIndex) {
        if let fileName = entry.fileName {
            do {
                try fileManager.removeItem(at: backupDirectory.appendingPathComponent(fileName))
            } catch {
                debugLog("[RawRRBackup] ⚠️ Failed to remove legacy backup \(entry.id.uuidString.prefix(8)): \(error)")
            }
        }
        cleanupAppendFiles(for: entry.id)
    }

    /// Export a backup to CSV format
    func exportToCSV(_ sessionId: UUID) throws -> String {
        guard let entry = try retrieve(sessionId) else {
            throw BackupError.notFound
        }

        var csv = "timestamp_ms,rr_ms,hr_bpm\n"
        for point in entry.points {
            // Guard rr_ms > 0: a zero interval that survived persistence would
            // otherwise write "inf" into the hr cell (garbage, not a crash).
            let hr = point.rr_ms > 0 ? 60000.0 / Double(point.rr_ms) : 0
            csv += "\(point.t_ms),\(point.rr_ms),\(String(format: "%.1f", hr))\n"
        }
        return csv
    }
}
