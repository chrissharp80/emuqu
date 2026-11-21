import CryptoKit
import Foundation
import os
import UIKit

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
    /// Set when the index file exists but could not be read at launch (data
    /// protection, EPERM); `index` then holds only what was written since.
    /// Guarded by `indexLock`, like `index`.
    var indexReadFailed = false
    /// Set while the in-memory index holds a change whose save threw, so the
    /// file is behind it (`saveIndex`). Guarded by `indexLock`.
    var indexSaveOwed = false
    let fileManager = FileManager.default
    let indexLock = NSLock()
    /// Writes one-shot files sealed or queued, and repairs queued backups.
    let sealer: RawBackupSealer
    /// The unlock and activation observers (`observeUnlock`).
    private let unlockObservers = NotificationTokens()
    /// Where `observeUnlock` listens: `.default` in the app.
    private let notificationCenter: NotificationCenter
    /// True while a `repairAfterUnlock` is queued and has not started, so
    /// unlock and activation arriving together queue one repair.
    private let repairQueued = OSAllocatedUnfairLock(initialState: false)

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
    /// recording, so a corrupting race here defeats the whole mechanism. The
    /// re-seal of plain files (`RawBackupSealer.reencrypt`), the index reconcile, and
    /// `discardBackup` / `purgeOldBackups` run here too, so none of them
    /// races an append.
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
    /// A bare SIGKILL report says nothing about when the crash actually
    /// happened or where the data went; this surfaces both.
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
        let backupDirectory = Self.resolveBackupDirectory()
        guard let entry = Self.storedIndexEntry(for: sessionId, in: backupDirectory) else { return nil }
        return TerminationForensicsSummary(
            lastBackupTime: entry.lastBackupTime,
            beatCount: entry.beatCount,
            backedUpCount: entry.backedUpCount,
            pointsFileSize: backupFileSize(of: entry, sessionId: sessionId, in: backupDirectory, fileManager: fm),
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

    // MARK: - Initialization

    /// The app's store, in the shared container (`resolveBackupDirectory`).
    convenience init() {
        self.init(directory: Self.resolveBackupDirectory())
    }

    /// A store in `directory`. The app uses the shared container; tests pass
    /// a folder of their own, so backups other tests left behind are never
    /// listed in theirs.
    convenience init(directory: URL) {
        self.init(directory: directory, notificationCenter: .default)
    }

    /// A store in `directory` that observes unlock and activation on
    /// `notificationCenter`.
    init(directory: URL, notificationCenter: NotificationCenter) {
        backupDirectory = directory
        self.notificationCenter = notificationCenter
        indexFile = backupDirectory.appendingPathComponent("backup_index.json")
        sealer = RawBackupSealer(directory: directory)

        createBackupDirectoryIfNeeded()
        loadIndex()
        logUnarchivedCount()
        reconcileIndexInBackground()
        reencryptPendingBackups()
        observeUnlock()
    }

    deinit {
        unlockObservers.removeAll(from: notificationCenter)
    }

    /// Runs `repairAfterUnlock` when protected data becomes available and
    /// when the app becomes active (a suspended app can miss the unlock), as
    /// `ConversationStore` retries a held save.
    private func observeUnlock() {
        for name in [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification] {
            unlockObservers.add(notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.repairAfterUnlock()
            })
        }
    }

    /// Queued on `appendQueue`, behind any append in flight, so neither step
    /// rewrites a points file while it is being appended to: the index save
    /// a failed write left owed (`saveIndexIfOwed`, logged when it throws
    /// again), then the re-seal of plain backups (`RawBackupSealer
    /// .reencryptPending`). A call while one is still queued adds nothing;
    /// one made while a repair runs queues the next.
    func repairAfterUnlock() {
        guard repairQueued.setIfClear() else { return }
        appendQueue.async { [self] in
            repairQueued.withLock { $0 = false }
            attempt("RawRRBackup.retryOwedIndexSave") { try saveIndexIfOwed() }
            sealer.reencryptPending(in: self)
        }
    }

    /// `RRBackup` in the shared container: the App Group (iOS deletes it with
    /// the last app in the group, so it does not survive a
    /// delete-and-reinstall), else Documents, else the temporary directory —
    /// `AppConfig.sharedContainerURL()`'s rule, which logs a fallback. The
    /// running store and the lockless termination forensics both use this, so
    /// they always look in the same place.
    private static func resolveBackupDirectory() -> URL {
        AppConfig.sharedContainerURL().appendingPathComponent(AppConfig.backupDirectoryName, isDirectory: true)
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

    /// Blocks until everything queued on `appendQueue` before the call has
    /// run: the reconcile and repair `init` queues, and any append. For tests
    /// that remove or inspect the folder.
    func waitForQueuedWork() {
        appendQueue.sync {}
    }

    /// Forget every backup held in memory, after "Delete All My Data" has
    /// removed the files, so the next save does not write their entries back.
    func resetInMemoryStateAfterPurge() {
        appendQueue.sync {
            indexLock.lock()
            index = []
            // The purge removed the index file too; nothing is left to re-read
            // or to write back.
            indexReadFailed = false
            indexSaveOwed = false
            indexLock.unlock()
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
    ///
    /// Never replaces a backup that holds more beats, judged against the
    /// on-disk index too when the launch could not read it. A strap fetch made after
    /// a crash is saved under the interrupted night's id, and the strap's copy
    /// can be shorter than what streamed (it started later, or the fetch was
    /// partial); replacing the streamed file deleted the rest of the night
    /// for good, since an interrupted night has no archived copy.
    ///
    /// `captureDate` is when the recording began. A caller that knows it wins;
    /// otherwise the backup keeps the date it already has rather than the
    /// moment of this write: recovery uses it as the session start, and a
    /// write-time date moved a recovered night onto the morning it was backed
    /// up.
    @discardableResult
    func backup(points: [RRPoint], sessionId: UUID, deviceId: String? = nil, captureDate: Date? = nil) throws -> BackupEntry {
        guard !points.isEmpty else {
            throw BackupError.noDataToBackup
        }
        let existing = try replaceableIndexEntry(sessionId, newCount: points.count)
        let entry = BackupEntry(
            id: sessionId, captureDate: captureDate ?? existing?.captureDate ?? Date(), deviceId: deviceId,
            points: points, hash: try Self.integrityHash(of: points)
        )
        let wasPending = RawBackupSealer.isPending(sessionId)
        // The old files go only once the new row is on disk.
        let fileName = try writeOneShot(entry, replacing: existing)
        cleanupAppendFiles(for: sessionId)
        sealer.removeReplacedFile(existing?.fileName, keeping: fileName, of: sessionId, wasPending: wasPending)
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

    /// Asks the sealer (`RawBackupSealer.reencryptPending`) to rewrite,
    /// encrypted, the backups written in plain JSON while the key was
    /// unreachable. Queued off the caller's thread behind the appends, so no
    /// append runs during a rewrite.
    func reencryptPendingBackups() {
        appendQueue.async { [self] in sealer.reencryptPending(in: self) }
    }

    /// Lists, off the caller's thread and behind the appends, the backups on
    /// disk the index does not name (`reconcileIndexWithFiles`).
    func reconcileIndexInBackground() {
        appendQueue.async { [self] in reconcileIndexWithFiles() }
    }

    /// Replace any existing backup index row for this session. When the save
    /// throws, the previous row goes back into memory and `indexSaveOwed`
    /// back to what it was, so memory keeps matching the index on disk,
    /// which still lists the old files, and nothing is owed for the row.
    private func reindex(
        sessionId: UUID, entry: BackupEntry, fileName: String, beatCount: Int, replacing previous: BackupIndex?
    ) throws {
        let owedBefore = indexLock.withLock { indexSaveOwed }
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
        replaceIndexRow(sessionId, with: indexEntry)
        do {
            try saveIndex()
        } catch {
            replaceIndexRow(sessionId, with: previous)
            indexLock.withLock { indexSaveOwed = owedBefore }
            throw error
        }
    }

    private func replaceIndexRow(_ sessionId: UUID, with row: BackupIndex?) {
        indexLock.lock()
        index.removeAll { $0.id == sessionId }
        if let row { index.append(row) }
        indexLock.unlock()
    }

    /// The current row for `sessionId` once a failed launch read of the index
    /// has been merged, or nil; throws when it holds more beats than
    /// `newCount`, or while the index file still cannot be read.
    private func replaceableIndexEntry(_ sessionId: UUID, newCount: Int) throws -> BackupIndex? {
        try mergeIndexIfLaunchReadFailed()
        guard let existing = existingIndexEntry(sessionId) else { return nil }
        if Self.beatCount(of: existing) > newCount {
            throw BackupError.wouldReplaceLargerBackup(existing: Self.beatCount(of: existing), new: newCount)
        }
        return existing
    }

    func existingIndexEntry(_ sessionId: UUID) -> BackupIndex? {
        indexLock.lock()
        defer { indexLock.unlock() }
        return index.first(where: { $0.id == sessionId })
    }

    /// Beats a backup holds: the appended count for the streaming format, the
    /// file's count for a one-shot backup.
    private static func beatCount(of entry: BackupIndex) -> Int {
        entry.backedUpCount ?? entry.beatCount
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
    /// - Returns: True when every point and the session's index row are on
    ///   disk, false if skipped (too soon, no data) or a write threw
    @discardableResult
    func incrementalBackup(points: [RRPoint], sessionId: UUID, deviceId: String? = nil, force: Bool = false, interval: TimeInterval = 60) -> Bool {
        guard !points.isEmpty else { return false }
        return appendQueue.sync {
            incrementalBackupLocked(points: points, sessionId: sessionId, deviceId: deviceId, force: force, interval: interval)
        }
    }

    /// Body of `incrementalBackup`, always run on `appendQueue`. True only
    /// once the points and the index row are both on disk. An index save
    /// that threw is retried by the next call that is due: the interval
    /// counts from the attempt (the row's `lastBackupTime` in memory), so a
    /// disk that keeps failing is tried once an interval, not on every tick.
    private func incrementalBackupLocked(points: [RRPoint], sessionId: UUID, deviceId: String?, force: Bool, interval: TimeInterval) -> Bool {
        let existingEntry = indexLock.withLock { index.first { $0.id == sessionId } }
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
    static func decodeLegacyBackup(at filePath: URL) throws -> BackupEntry {
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
    /// layout and the append-only header + points pair with any `.corrupted_*`
    /// siblings set aside from it.
    private func backupSize(of indexEntry: BackupIndex) -> Int64 {
        var urls: [URL] = []
        if let fileName = indexEntry.fileName {
            urls.append(backupDirectory.appendingPathComponent(fileName))
        }
        if indexEntry.backedUpCount != nil {
            let points = pointsURL(for: indexEntry.id)
            urls += [headerURL(for: indexEntry.id), points]
            urls += corruptedSiblingNames(of: points).map { backupDirectory.appendingPathComponent($0) }
        }
        return urls.reduce(0) { $0 + fileSize(at: $1) }
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    /// Discard a single backup permanently: the user's delete forever, a
    /// recording they discarded, or one too short to ever recover. Every
    /// file of the session goes (`removeEveryFile`), then its index row.
    /// Throws, keeping the row, when any file is still on disk, so no beats
    /// are left that nothing lists. On `appendQueue`, so neither an append
    /// nor a re-seal writes a file back in between.
    /// - Parameter sessionId: Session ID to discard.
    func discardBackup(_ sessionId: UUID) throws {
        try appendQueue.sync {
            let entry = existingIndexEntry(sessionId)
            try removeEveryFile(of: sessionId)
            guard let entry else { return }
            replaceIndexRow(sessionId, with: nil)
            try saveIndex()
            debugLog("[RawRRBackup] Discarded backup \(sessionId.uuidString.prefix(8)) (\(Self.beatCount(of: entry)) beats)")
        }
    }

    /// Purge old archived backups (keep last N days). A backup whose files
    /// will not all go keeps its row (`removeEveryFile`), so a purge never
    /// leaves beats that nothing lists. On `appendQueue`, like `discardBackup`.
    /// - Parameter keepDays: Number of days to keep archived backups
    func purgeOldBackups(keepDays: Int = 90) throws {
        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date()) else { return }
        try appendQueue.sync { try purgeArchivedBackups(before: cutoffDate) }
    }

    /// Body of `purgeOldBackups`, run on `appendQueue`: drops the rows of
    /// archived backups captured before `cutoff` whose files all went.
    private func purgeArchivedBackups(before cutoff: Date) throws {
        let old = indexLock.withLock { index.filter { $0.archived && $0.captureDate < cutoff } }
        let removed = Set(old.map(\.id).filter(removedEveryFile(of:)))
        guard !removed.isEmpty else { return }
        indexLock.withLock { index.removeAll { removed.contains($0.id) } }
        try saveIndex()
        debugLog("[RawRRBackup] Purged \(removed.count) of \(old.count) old archived backups")
    }

    /// Whether every file of the session went (`removeEveryFile`); a failure
    /// is logged.
    private func removedEveryFile(of sessionId: UUID) -> Bool {
        attempt("RawRRBackup.purgeBackup") { try removeEveryFile(of: sessionId) } != nil
    }

    /// Removes every file of the session: each one-shot file, indexed or
    /// not, and its append files (`appendFiles`), then takes it off the
    /// re-encryption queue, since no plaintext of it is left. Throws when the
    /// folder cannot be listed or any of them is still on disk, leaving it
    /// queued.
    private func removeEveryFile(of sessionId: UUID) throws {
        let files = try OneShotBackupName.files(of: sessionId, in: backupDirectory) + appendFiles(of: sessionId)
        let leftovers = BackupFiles.remove(files, using: fileManager)
        guard leftovers.isEmpty else { throw BackupError.couldNotRemove(leftovers.map(\.lastPathComponent)) }
        PendingEncryptionLedger.clear(sessionId, in: .rawBackup)
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

extension RawRRBackup: SealableBackupStore {
    /// Whether any backup's capture date lies within `window` of `date`.
    /// The strap's start sequence asks this before it clears a recording: a
    /// rescue backup is dated by the recording's own start.
    func holdsBackup(capturedWithin window: TimeInterval, of date: Date) -> Bool {
        indexLock.lock()
        defer { indexLock.unlock() }
        return index.contains { abs($0.captureDate.timeIntervalSince(date)) <= window }
    }

    /// Writes `entry` under a file name no earlier write used, then indexes it.
    ///
    /// Names were once whole-second timestamps, so two backups of a session in
    /// one second shared a file: when the second's index save threw, the
    /// rollback put back the old row (same name, old hash) over the new bytes,
    /// and the backup then failed its hash check and dropped out of every
    /// listing. A fresh name leaves the restored row and its file intact; the
    /// new file, which nothing indexes, is removed.
    private func writeOneShot(_ entry: BackupEntry, replacing existing: BackupIndex?) throws -> String {
        let fileName = OneShotBackupName.make(for: entry.id, at: Date()) { name in
            name == existing?.fileName || fileManager.fileExists(atPath: backupDirectory.appendingPathComponent(name).path)
        }
        let url = backupDirectory.appendingPathComponent(fileName)
        try RawBackupSealer.writeEntry(entry, to: url, sessionId: entry.id)
        do {
            try reindex(sessionId: entry.id, entry: entry, fileName: fileName, beatCount: entry.points.count, replacing: existing)
        } catch {
            _ = attempt("RawRRBackup.removeUnindexedBackup") { try fileManager.removeItem(at: url) }
            throw error
        }
        return fileName
    }
}

extension RawRRBackup {
    /// The size of whichever file holds the session's beats: the append-only
    /// points file while recording, or the whole-night file a stop writes
    /// (which replaces the append files, so reading only the points file
    /// would report a saved night as missing).
    fileprivate static func backupFileSize(
        of entry: BackupIndex, sessionId: UUID, in backupDirectory: URL, fileManager fm: FileManager
    ) -> Int64? {
        let candidates = [entry.fileName, "\(sessionId.uuidString)_points.jsonl"].compactMap { $0 }
        for name in candidates {
            let path = backupDirectory.appendingPathComponent(name).path
            guard let attributes = try? fm.attributesOfItem(atPath: path) else { continue }
            if let size = (attributes[.size] as? NSNumber)?.int64Value { return size }
        }
        return nil
    }
}
