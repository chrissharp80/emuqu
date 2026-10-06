import CryptoKit
import Foundation

/// Session archive manager for persistent storage
///
/// `@unchecked Sendable`. Every mutable field — `index`,
/// `sortedEntriesCache`, `sessionIdLookup`, `deletedSessionIds` and the read
/// counters — is guarded by `archiveLock`, and the guarantee is structural
/// rather than incidental:
///
///   • Every non-private member of this file that touches those fields takes
///     `archiveLock` first. Checked member by member, not sampled.
///   • Of the helpers in `Archive+Internal.swift`, those that touch the
///     fields without locking (`entryById`, `_retrieve`, `dropFromIndex`, …)
///     run under the caller's lock; the leading underscore and
///     `private`/internal scoping mark them as such. The rest take
///     `archiveLock` themselves.
///   • File I/O and decoding happen OUTSIDE the lock, holding it only across
///     index lookups — see `retrieveLightweight`. That is why the lock is not
///     a contention point on the read path.
///
/// The conformance exists because callers legitimately read the archive from
/// background tasks (`FitnessTabView+Sections` detaches its week-workout
/// lookup), and the compiler cannot see a lock-based invariant. If you add a
/// member here that touches the fields above, it takes the lock or it goes in
/// `Archive+Internal.swift` where the convention says the caller already did.
final class SessionArchive: @unchecked Sendable {
    // MARK: - Shared Instance

    /// Shared singleton — use this for all non-test code to prevent multiple
    /// instances operating on the same index.json concurrently.
    static let shared = SessionArchive()

    /// Shared archive policy tuning. These thresholds are used at multiple
    /// sites (the 0.85 containment ratio, the 1-hour import-duplicate
    /// window); one named home so the next change can't introduce drift
    /// between independently defined literals.
    enum Tuning {
        /// Fraction of one session's time range that must overlap
        /// another's before they are treated as the SAME recording
        /// (true duplicate) rather than distinct same-night segments.
        /// Used by split-night display normalization AND the dedupe
        /// quarantine gate.
        static let duplicateContainmentRatio: Double = 0.85
        /// Same-night entries younger than this are never deduped —
        /// CloudKit may still be reconciling them.
        static let dedupeSafetyWindow: TimeInterval = 24 * 3600
        /// Import-time window for `sessionExists(for:)`: an external reading
        /// (Elite HRV), which carries a start time but no span, starting
        /// within this of an archived entry counts as already imported.
        static let importDuplicateWindow: TimeInterval = 3600
    }

    // MARK: - Properties

    /// The persistence mechanics, built on each access; it holds no state of its own.
    var store: ArchiveStore {
        ArchiveStore(archive: self)
    }

    let archiveDirectory: URL
    let indexFile: URL
    let deletedIndexFile: URL
    /// Mutable archive index — every read AND write MUST hold `archiveLock`.
    /// A raw read while a locked writer mutates the CoW array buffer is
    /// undefined behavior (a real crash race; readers such as
    /// `SessionStorageDiagnostic` and `MorningNotificationScheduler` use the
    /// lock-safe `entries` snapshot).
    /// Setter cannot be tightened to `private(set)`: that ACL is
    /// file-scoped, and `Archive+Migrations`/`Archive+Repair` legitimately
    /// write `index` from other files while holding the lock.
    var index: [SessionArchiveEntry] = []
    /// Cached sorted entries — invalidated whenever `saveIndex()` is called.
    var sortedEntriesCache: [SessionArchiveEntry]?
    /// O(1) session lookup by ID — invalidated alongside sortedEntriesCache.
    var sessionIdLookup: [UUID: SessionArchiveEntry]?
    /// Tombstones for intentionally deleted sessions — same lock contract as
    /// `index`: every read AND write MUST hold `archiveLock`. External callers
    /// use the locked `deletedIds` accessor.
    var deletedSessionIds: Set<UUID> = []
    /// Set when `index.json` exists but could not be read at launch; the
    /// in-memory index is then incomplete. Same lock contract as `index`.
    var indexReadFailed = false
    let fileManager = FileManager.default
    let archiveLock = NSLock()

    /// Read-health counters surfaced to
    /// **Settings → Troubleshooting → Archive read health** so a user
    /// hitting the EPERM-storm pattern (1,557 failures in a 7-day debug
    /// log) can SEE the issue rather than discover it via missing
    /// trends and an AI with no context. Both counters are
    /// app-launch-scoped (in memory only); reset by
    /// `DataPurgeService.purgeAllUserData`.
    private(set) var totalReadAttempts: Int = 0
    private(set) var permissionDeniedReadFailures: Int = 0
    /// True when permission-denied failures exceed 10 over the
    /// app session AND the success rate is below 50%. The
    /// Troubleshooting card surfaces a banner only when this is true,
    /// so a one-off transient EPERM doesn't alarm the user.
    /// Reads both counters under `archiveLock` — the increments in
    /// `retrieveLightweightOrLog` run locked, so an unlocked two-field read
    /// here could see a torn pair.
    var hasReadHealthIssue: Bool {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        return permissionDeniedReadFailures >= 10
            && Double(permissionDeniedReadFailures) / Double(max(1, totalReadAttempts)) > 0.5
    }
    /// Locked snapshot of both read-health counters as one pair. The
    /// diagnostics page renders "X of Y reads failed" in a single
    /// sentence — reading the two stored properties individually could
    /// see a torn pair across the locked increments in
    /// `retrieveLightweightOrLog` (same race `hasReadHealthIssue`
    /// seals).
    var readHealthCounters: (attempts: Int, permissionDenied: Int) {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        return (totalReadAttempts, permissionDeniedReadFailures)
    }
    /// Forget every session held in memory, after "Delete All My Data" has
    /// removed the files. Without this the index stayed in memory until a
    /// restart, and the first save after the purge — a sleep refresh, a tag
    /// edit — wrote every deleted session's metadata back to `index.json`.
    func resetInMemoryStateAfterPurge() {
        archiveLock.lock()
        index = []
        deletedSessionIds = []
        sortedEntriesCache = nil
        sessionIdLookup = nil
        archiveLock.unlock()
        resetReadHealthCounters()
    }

    func resetReadHealthCounters() {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        totalReadAttempts = 0
        permissionDeniedReadFailures = 0
    }
    let sleepScheduleProvider: () -> SleepSchedule
    let sessionMergeModeProvider: () -> SessionMergeMode
    /// The user's merge gap in seconds: recordings of one night closer than
    /// this are one sleep. Read only when the merge mode is not `.off`.
    let mergeGapProvider: () -> TimeInterval

    // MARK: - Shared JSON Coders
    //
    // Allocating a fresh `JSONDecoder()`/`JSONEncoder()` (and re-setting
    // `dateDecodingStrategy = .iso8601`) in every `retrieve`,
    // `retrieveLightweight`, `_archive`, `decodeSession`, `loadIndex`,
    // `saveIndex`, etc. is measurable: with dozens of calls per dashboard
    // load (every session in the visible slice retrieved once), the
    // allocator churn alone shows up in Instruments. `JSONDecoder` and
    // `JSONEncoder` are documented as safe to share across threads as long
    // as their configuration isn't mutated mid-flight, so we keep one of
    // each at module scope and configure them once at first use.
    //
    // The encoder used for session WRITES intentionally keeps
    // `sortedKeys` output formatting — file integrity hashes (SHA256 of the
    // bytes-as-written) depend on byte-deterministic encoding.
    // Do not add `prettyPrinted`, for the same reason.
    static let sessionDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    static let lightweightSessionDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.userInfo[.skipRRSeries] = true
        return d
    }()
    static let sessionEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    /// Encoder for the on-disk index file. Pretty-printed for human
    /// inspection during diagnostics — the index isn't hashed so the
    /// formatting choice is cosmetic.
    ///
    /// NOTE: `archiveBatch` also uses this encoder for SESSION files (a
    /// historical divergence from `_archive`'s compact `sessionEncoder`).
    /// That choice is deliberately preserved — see `SessionFileCodec`.
    static let indexEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    // MARK: - Initialization

    // spec:long-function A memberwise initializer is one assignment per stored
    // property and nothing else — no branches, no calls, no logic to extract.
    // Swift additionally forbids calling a helper on `self` before every stored
    // property is initialized, so the body cannot be split even mechanically.
    // Splitting the TYPE would be the real fix; that is tracked separately and
    // is not a formatting change.
    init(
        // Test seam — every default-constructed instance points
        // at the SAME on-disk App Group directory, so test suites that need
        // a genuinely empty archive ("empty archive must remain empty"
        // contracts) would read residue left by other suites' killed runs.
        // Passing an explicit directory gives a hermetic instance; `nil`
        // (production) keeps the App Group → Documents → tmp fallback chain
        // unchanged.
        directory: URL? = nil,
        sleepScheduleProvider: @escaping () -> SleepSchedule = { AppDependencies.current.app.settingsManager.settingsSnapshot.sleepSchedule },
        sessionMergeModeProvider: @escaping () -> SessionMergeMode = { AppDependencies.current.app.settingsManager.settingsSnapshot.sessionMergeMode },
        mergeGapProvider: @escaping () -> TimeInterval = { AppDependencies.current.app.settingsManager.settingsSnapshot.effectiveMergeGapSeconds }
    ) {
        self.sleepScheduleProvider = sleepScheduleProvider
        self.sessionMergeModeProvider = sessionMergeModeProvider
        self.mergeGapProvider = mergeGapProvider
        // App Group container first, Documents when it is unavailable. iOS
        // removes the container with the last app of the group, so neither
        // location survives deleting the app.
        if let directory {
            archiveDirectory = directory
        } else if let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) {
            archiveDirectory = containerURL.appendingPathComponent(AppConfig.archiveDirectoryName, isDirectory: true)
        } else if let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            archiveDirectory = documentsPath.appendingPathComponent(AppConfig.archiveDirectoryName, isDirectory: true)
        } else {
            // Fallback to temporary directory (should never happen on iOS)
            archiveDirectory = fileManager.temporaryDirectory.appendingPathComponent(AppConfig.archiveDirectoryName, isDirectory: true)
            debugLog("[Archive] WARNING: Using temporary directory as fallback")
        }
        indexFile = archiveDirectory.appendingPathComponent("index.json")
        deletedIndexFile = archiveDirectory.appendingPathComponent("deleted.json")

        createArchiveDirectoryIfNeeded()
        loadIndex()
        loadDeletedIndex()

        // LAUNCH PERF. `init` is the FIRST @State built,
        // and it runs synchronously before the first frame. `loadIndex` /
        // `loadDeletedIndex` are needed here so `entries`/`retrieve` work
        // immediately, but the orphan reconcile (a full-directory scan +
        // per-orphan decode+SHA256) and the tombstone mtime walk are NOT
        // needed for first paint and scale with file count — they would be
        // the biggest synchronous launch cost. Deferred to `boot()`,
        // which the app calls off the main thread after first paint.

        // Only log if count is unusual (helps debug archive corruption)
        if index.count == 0 || index.count > 1000 {
            debugLog("[Archive] Loaded \(index.count) sessions from archive")
        }
    }

    /// Deferred launch work: adopt crash-orphaned session files and emit the
    /// tombstone diagnostic. Kept out of `init` so neither the
    /// directory scan nor the per-tombstone `attributesOfItem` walk blocks
    /// the launch critical path. Idempotent — safe to call once after first
    /// paint, off the main thread. Orphan adoption still happens, just a
    /// beat later; the dashboard tolerates the brief pre-adoption window
    /// (orphans are rare crash-recovery artifacts).
    ///
    /// The per-file protection-class walk is not here. It rewrites the
    /// attributes of every session file on every launch, and running it at
    /// boot put that metadata write on the same files, at the same moment, as
    /// the dashboard's first read — a field log shows that read taking 3.8 s
    /// and finishing the instant this finished. It runs in the launch
    /// housekeeping phase instead, after the dashboard has its data
    /// (`AppLaunchTasks.scheduleMigrationJobs`).
    func boot() {
        retryFailedIndexLoad()
        reconcileOrphanFiles()
        logTombstoneSummary()
    }

    /// A launch read of `index.json` can fail while the file is locked; by
    /// boot it usually reads, and the sessions it lists come back for this
    /// launch rather than the next one.
    private func retryFailedIndexLoad() {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        attempt("Archive.retryIndexLoad") { try mergeIndexThatFailedToLoad() }
    }

    /// Deliberately quiet. A per-tombstone dump (53 entries in the
    /// field) calling `attributesOfItem` per ID on launch means 53
    /// sync filesystem hits + a massive log line every cold start.
    /// The recent-30d
    /// count is the only signal that matters; details on demand
    /// via Settings → Diagnostics → "Scan Archive Directory".
    private func logTombstoneSummary() {
        archiveLock.lock()
        let deletedSnapshot = deletedSessionIds
        archiveLock.unlock()
        guard !deletedSnapshot.isEmpty else { return }
        if hasTombstoneNewerThan(Date().addingTimeInterval(-30 * 86_400), in: deletedSnapshot) {
            debugLog("[Archive] deletedSessionIds: \(deletedSnapshot.count) total, at least one within last 30 days — investigate via Diagnostics", level: .warning)
        } else {
            debugLog("[Archive] deletedSessionIds: \(deletedSnapshot.count) total, 0 recent")
        }
    }

    /// Whether any tombstoned session was deleted after `cutoff`, by its
    /// recorded deletion time. A deleted session's file is no longer at
    /// `<id>.json` (it moves to the Trash), so its file date said nothing.
    private func hasTombstoneNewerThan(_ cutoff: Date, in deletedSnapshot: Set<UUID>) -> Bool {
        deletedSnapshot.contains { store.deletionTime(of: $0).map { $0 > cutoff } ?? false }
    }

    /// Pick up any session files on disk that aren't in the index. These are
    /// typically the result of a crash between the file write and index save
    /// in `archive(_:)`. If the file decodes successfully we re-add it to the
    /// index; otherwise we leave it alone (never auto-delete — the user may
    /// want to recover it manually).
    ///
    /// Runs off-main from `boot()`, so all `index`/
    /// `deletedSessionIds` access must hold `archiveLock`. Snapshot the
    /// current state under the lock, do the slow file decode WITHOUT the
    /// lock, then append under the lock (re-checking so a concurrent
    /// `archive()` write of the same file can't produce a duplicate entry).
    private func reconcileOrphanFiles() {
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: archiveDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            debugLog("[Archive] reconcileOrphanFiles: failed to enumerate \(archiveDirectory.path): \(error)")
            return
        }
        archiveLock.lock()
        let indexedFiles = Set(index.map(\.filePath))
        let deleted = deletedSessionIds
        archiveLock.unlock()
        let newEntries = files.compactMap {
            orphanEntry(for: $0, indexedFiles: indexedFiles, deleted: deleted)
        }
        guard !newEntries.isEmpty else { return }
        adoptOrphans(newEntries)
    }

    /// Includes the CloudKit sync state sidecars (`sync_state.json`,
    /// `pending_uploads.json`, `quarantined_uploads.json`). They live in the same archive directory
    /// but aren't session files; without this list the reconciler tries
    /// to decode them as HRVSession on every cold launch and logs
    /// "skipping undecodable orphan" warnings forever.
    private var reservedFileNames: Set<String> {
        [
            indexFile.lastPathComponent,
            deletedIndexFile.lastPathComponent,
            "sync_state.json",
            "pending_uploads.json",
            "quarantined_uploads.json"
        ]
    }

    /// An index entry for one on-disk file that nothing points at, or nil when
    /// the file isn't an adoptable orphan.
    ///
    /// The hash is over the bytes-as-stored — the orphan file is adopted
    /// untouched. The entry is built by the shared factory so adopted
    /// orphans keep the sleep-stage/dip mirror fields.
    ///
    /// Decoded through the archive's own loader, which decrypts. Session files
    /// are written encrypted, so a plain JSON decode skipped every real orphan
    /// as "undecodable" and a lost index could only be rebuilt by hand.
    private func orphanEntry(
        for file: URL, indexedFiles: Set<String>, deleted: Set<UUID>
    ) -> SessionArchiveEntry? {
        let name = file.lastPathComponent
        guard file.pathExtension == "json",
              !reservedFileNames.contains(name),
              !indexedFiles.contains(name)
        else { return nil }
        // Skip files that belong to sessions the user intentionally deleted.
        let bareId = (name as NSString).deletingPathExtension
        if let uuid = UUID(uuidString: bareId), deleted.contains(uuid) { return nil }
        guard let data = try? Data(contentsOf: file),
              let session = attempt("Archive.decodeOrphan", {
                  try Self.loadAndDecodeSessionFile(at: file, decoder: Self.sessionDecoder)
              })
        else {
            debugLog("[Archive] reconcileOrphanFiles: skipping undecodable orphan \(name)")
            return nil
        }
        return SessionArchiveEntry.make(
            from: session, hash: SessionFileCodec.sha256Hex(data), filePath: name
        )
    }

    /// Append the adoptable orphans under the lock, re-checking so a
    /// concurrent `archive()` write of the same file can't duplicate an entry.
    private func adoptOrphans(_ newEntries: [SessionArchiveEntry]) {
        archiveLock.lock()
        let currentFiles = Set(index.map(\.filePath))
        let toAdopt = newEntries.filter { !currentFiles.contains($0.filePath) }
        if !toAdopt.isEmpty {
            index.append(contentsOf: toAdopt)
            _ = attempt("Archive.save") { try saveIndex() }
        }
        archiveLock.unlock()
        if !toAdopt.isEmpty {
            debugLog("[Archive] reconcileOrphanFiles: adopted \(toAdopt.count) orphan session files into index")
        }
    }

    // MARK: - Public API

    /// Archive a completed session
    /// - Parameter session: The session to archive
    /// - Returns: Archive entry with file hash
    @discardableResult
    func archive(_ session: HRVSession) throws -> SessionArchiveEntry {
        try archive(session, skipSameNightMerge: false)
    }

    /// Internal archive variant with optional same-night merge skip.
    ///
    /// Seen in a user log: a CloudKit full-sync pull triggered 37
    /// `sameNightMerge` operations in 5 seconds at 05:30, each one
    /// re-archiving (full retrieve + merge + re-encode + re-encrypt +
    /// write + hash + index save) on the main thread. The app froze
    /// for the duration. CloudKit-pulled sessions are already the
    /// authoritative cross-device-merged version of that session-id;
    /// folding them into a same-night local entry is double-merging
    /// and wasted work. The pull path sets `skipSameNightMerge: true`
    /// and we just write the file as-is.
    /// The existing `removeDuplicates` migration handles genuine
    /// stale-night cleanup after the 24-hour safety window.
    ///
    /// Broadcasts on every successful archive so open
    /// surfaces (Dashboard, History, Recovery Report sheet) refresh
    /// automatically. A writer contract requiring each caller to fire
    /// `archiveSignal.notifyChanged()` after archiving is easy to miss:
    /// dashboard call sites (sleep refresh, vitals refresh,
    /// morning-feeling persist, etc.) silently archived
    /// without propagating, so an open Recovery Report sheet kept
    /// showing stale numbers until dismissed. Posting at the archive
    /// layer eliminates the contract burden and makes propagation
    /// automatic for any future writer.
    ///
    /// `ArchiveSignal` (an @MainActor `@Observable`) listens for
    /// this notification and bumps its `version`, which triggers the
    /// SwiftUI `.onChange(of: archiveSignal.version)` observers.
    ///
    /// `requestingReupload: true` is for a change the user made to a session
    /// already in the archive (a feeling, a trim, a sleep edit). CloudKit sync
    /// uploads each id once, so without it the edit never reached iCloud. A
    /// sleep edit's own values stay on the device (`CloudSessionPayload`).
    /// It also stamps `modifiedAt`, which is how another device that already
    /// holds the session knows this copy is newer and takes it on its next
    /// pull (last writer wins, `CloudKitSessionFreshness`).
    /// Routine rewrites (refreshes, stamps, migrations, re-encryption) leave
    /// it false: a second device rewriting its older copy must not replace
    /// the newer one in iCloud.
    @discardableResult
    func archive(_ session: HRVSession, skipSameNightMerge: Bool, requestingReupload: Bool = false) throws -> SessionArchiveEntry {
        var session = session
        if requestingReupload { session.modifiedAt = CloudKitSessionFreshness.stamp() }
        archiveLock.lock()
        let entry: SessionArchiveEntry
        let wasArchived = index.contains { $0.sessionId == session.id }
        do {
            entry = try _archive(session, skipSameNightMerge: skipSameNightMerge)
        } catch {
            archiveLock.unlock()
            throw error
        }
        archiveLock.unlock()
        NotificationCenter.default.post(name: .flowRecoveryArchiveChanged, object: session.id)
        if requestingReupload, wasArchived || entry.sessionId != session.id {
            postReuploadRequest(for: entry.sessionId)
        }
        return entry
    }

    /// Change fields of the archived copy in place: read, change and write
    /// under one lock, so the change lands on the newest version of the
    /// session. Writing back a copy a screen held changed only the edited
    /// fields in intent, but put back every other field as that screen last
    /// saw it, undoing a score or sleep update made since.
    ///
    /// `requestingReupload: false` is for a change iCloud payloads leave out
    /// (the HealthKit snapshots), or a routine stamp. `true` also stamps
    /// `modifiedAt`, as `archive(_:skipSameNightMerge:requestingReupload:)` does.
    func update(_ id: UUID, requestingReupload: Bool = true, _ change: (inout HRVSession) -> Void) throws {
        archiveLock.lock()
        do {
            guard var session = try _retrieve(id) else { throw ArchiveError.fileNotFound }
            change(&session)
            if requestingReupload { session.modifiedAt = CloudKitSessionFreshness.stamp() }
            _ = try _archive(session, skipSameNightMerge: true)
        } catch {
            archiveLock.unlock()
            throw error
        }
        archiveLock.unlock()
        NotificationCenter.default.post(name: .flowRecoveryArchiveChanged, object: id)
        guard requestingReupload else { return }
        postReuploadRequest(for: id)
    }

    /// Ask CloudKit sync to upload this session again.
    private func postReuploadRequest(for id: UUID) {
        NotificationCenter.default.post(
            name: .flowRecoveryArchiveSessionsNeedReupload, object: nil, userInfo: ["sessionIds": Set([id])]
        )
    }

    /// Retrieve an archived session
    /// - Parameter id: Session ID
    /// - Returns: The session, or nil if not found
    func retrieve(_ id: UUID) throws -> HRVSession? {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        return try _retrieve(id)
    }

    /// Retrieve a session, logging and returning nil on failure instead of throwing.
    /// Use when the caller cannot meaningfully handle the error (e.g., optional enrichment).
    func retrieveOrLog(_ id: UUID, caller: String = #function) -> HRVSession? {
        do {
            return try retrieve(id)
        } catch {
            debugLog("[SessionArchive] \(caller): failed to retrieve \(id.uuidString.prefix(8)): \(error)")
            return nil
        }
    }

    /// Lightweight retrieve, logging and returning nil on failure instead of throwing.
    func retrieveLightweightOrLog(_ id: UUID, caller: String = #function) -> HRVSession? {
        do {
            let result = try retrieveLightweight(id)
            archiveLock.lock()
            totalReadAttempts += 1
            archiveLock.unlock()
            return result
        } catch {
            recordReadFailure(error)
            debugLog("[SessionArchive] \(caller): failed to retrieve lightweight \(id.uuidString.prefix(8)): \(error)")
            return nil
        }
    }

    /// Count permission-denied failures so
    /// the Troubleshooting card can surface a recovery prompt
    /// when the EPERM-storm pattern recurs.
    private func recordReadFailure(_ error: Error) {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        totalReadAttempts += 1
        if let nsError = error as NSError?,
           nsError.domain == NSCocoaErrorDomain,
           nsError.code == 257 { // NSFileReadNoPermissionError
            permissionDeniedReadFailures += 1
        } else if let posix = (error as NSError?)?.userInfo[NSUnderlyingErrorKey] as? NSError,
                  posix.domain == NSPOSIXErrorDomain, posix.code == 1 {
            permissionDeniedReadFailures += 1
        }
    }

    /// Retrieve a session without deserializing the heavyweight `rrSeries` field.
    /// Use this for dashboard/list views that only need metadata and analysis results.
    /// Skips hash verification since this is a read-only performance path.
    ///
    /// Holds `archiveLock` ONLY for the index lookup, NOT across
    /// the file read + decrypt + decode. Those touch no shared mutable state
    /// (the file path is captured; decrypt/decode are pure), so keeping the
    /// lock across them would needlessly serialize every retrieve: the
    /// dashboard cold-load fan-out (`recentSessionsAsync`, ~35 sessions) would
    /// decrypt one-at-a-time under this lock, leaving the dashboard on empty
    /// placeholders. Releasing the lock before the file work lets those
    /// decrypts run in PARALLEL. A concurrent delete just makes the read below
    /// throw `fileNotFound`, which `retrieveLightweightOrLog` already handles.
    ///
    /// Same dual-format detection as `_retrieve`.
    /// The lightweight path doesn't verify the index hash (perf-only path,
    /// hence "lightweight"), but it still needs to handle both encrypted and
    /// legacy-plaintext files. Routed through the shared plaintext resolver
    /// so the legacy Format 2 / Format 3 fallback is picked up here too.
    func retrieveLightweight(_ id: UUID) throws -> HRVSession? {
        let fileURL: URL
        do {
            archiveLock.lock()
            defer { archiveLock.unlock() }
            guard let entry = entryById(id) else { return nil }
            fileURL = resolveFileURL(for: entry)
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ArchiveError.fileNotFound
        }
        let plaintext = try ArchiveStore.plaintextBytes(try Data(contentsOf: fileURL), id: id)
        return try Self.lightweightSessionDecoder.decode(HRVSession.self, from: plaintext)
    }
}
