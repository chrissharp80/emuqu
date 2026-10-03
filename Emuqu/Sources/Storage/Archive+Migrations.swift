import Foundation

// MARK: - Migrations
//
// Kept off `SessionArchive` — the same coordinator split used for
// RRCollector, WorkoutRecorder, HealthKitManager and AssistantViewModel.
// The archive reads are `archive.` and countable rather than looking like
// this type's own state.

extension ArchiveMigrations {
    /// UserDefaults keys for "this backfill migration has nothing left to
    /// do on this install" flags. Without them every launch would re-filter
    /// the archive.index for nil fields even when 100% of entries are
    /// already backfilled — wasted lock acquisition + O(n) filter on every
    /// cold start. Flags are set after the first pass that reads every
    /// session in the work list (see `runIndexMigration`) and remain set
    /// because the writer contract (`_archive`) populates these fields on
    /// every new session.
    /// removeDuplicates and relinkSameNightSessions are NOT flagged because
    /// they handle state that can re-appear (CloudKit sync importing a
    /// duplicate, a same-night session arriving later).
    private enum MigrationFlag {
        static let recoveryScoresDone = "FlowRecovery.migration.recoveryScores.v1.done"
        static let endDatesDone = "FlowRecovery.migration.endDates.v1.done"
        static let metricsDone = "FlowRecovery.migration.metrics.v1.done"
        static let sleepIndexDone = "FlowRecovery.migration.sleepIndexFields.v1.done"
    }

    /// Run one-time data migrations in the background so they don't block
    /// app launch or dashboard rendering. Safe to call multiple times —
    /// each migration is a no-op if already complete.
    ///
    /// Each migration acquires/releases archive.archiveLock internally and yields
    /// the lock during disk I/O so the main thread is never blocked for
    /// more than a few milliseconds (eliminates "hang detected" warnings).
    func runDeferredMigrations() {
        reencryptPendingSessions(in: archive)
        migrateRecoveryScores()
        migrateEndDates()
        migrateMetrics()
        migrateSleepIndexFields()
        removeDuplicates()
        relinkSameNightSessions()
    }

    /// One-time migration: backfill `sleepEnd` + `sleepSegmentCount` on
    /// archive.index entries so the history list can show wake time (not
    /// recording-stopped time) and gate the split-night badge on real
    /// sleep gaps rather than recording linkage. Runs only for entries
    /// where both fields are nil; on sessions without a sleep snapshot the
    /// migration is a no-op. 3-phase locking.
    func migrateSleepIndexFields() {
        runIndexMigration(
            flag: MigrationFlag.sleepIndexDone, label: "sleep-index migration",
            needsWork: { $0.sleepEnd == nil && $0.sleepSegmentCount == nil },
            patch: { Self.sleepIndexPatch(entry: $0, session: $1) }
        )
    }

    /// Phases 1 and 2 of a backfill: gather the entries `needsWork` picks
    /// (locked), then read each session (unlocked) and build its patch; phase 3
    /// is `applyIndexPatches`. Returns how many entries were patched.
    ///
    /// The done flag is set once a pass has read every session, patched or
    /// not. Setting it only when the work list came back empty never
    /// happened: an entry with nothing to patch (a workout has no sleep
    /// fields) stays in the list for good, and every launch re-read and
    /// decrypted all of them. A session that fails to load keeps the flag off
    /// so the next launch tries it again.
    @discardableResult
    private func runIndexMigration(
        flag: String, label: String,
        needsWork: (SessionArchiveEntry) -> Bool,
        patch: (SessionArchiveEntry, HRVSession) -> SessionArchiveEntry?
    ) -> Int {
        if UserDefaults.standard.bool(forKey: flag) { return 0 }
        archive.archiveLock.lock()
        let workItems = archive.index.filter(needsWork).map { ($0, archive.resolveFileURL(for: $0)) }
        archive.archiveLock.unlock()
        var patches: [(UUID, SessionArchiveEntry)] = []
        var loadedAll = true
        for (entry, fileURL) in workItems {
            guard let session = Self.loadForMigration(at: fileURL, entry: entry, label: label) else { loadedAll = false; continue }
            if let patched = patch(entry, session) { patches.append((entry.sessionId, patched)) }
        }
        applyIndexPatches(patches, label: label)
        if loadedAll { UserDefaults.standard.set(true, forKey: flag) }
        return patches.count
    }

    /// Not a bare `decoder.decode(HRVSession.self, from: Data(contentsOf:))`:
    /// that fails on encrypted files ("Unexpected character 'F'" in the launch
    /// log). Route through the shared dual-format reader so
    /// encrypted + legacy plaintext both decode.
    private static func loadForMigration(
        at fileURL: URL, entry: SessionArchiveEntry, label: String
    ) -> HRVSession? {
        do {
            return try SessionArchive.loadAndDecodeSessionFile(at: fileURL, decoder: SessionArchive.lightweightSessionDecoder)
        } catch {
            debugLog("[Archive] \(label): failed to load session \(entry.sessionId.uuidString.prefix(8)): \(error)", level: .warning)
            return nil
        }
    }

    /// Phase 3 of every migration here: apply the patches under lock and
    /// persist. A no-op when nothing was patched.
    ///
    /// A patch was built from the entry as it stood in phase 1. If the session
    /// was re-archived since, its entry now carries a new file hash, and the
    /// patch would put the old one back — the next read then fails its
    /// integrity check. Such a patch is dropped; the re-archive already wrote a
    /// complete entry.
    private func applyIndexPatches(_ patches: [(UUID, SessionArchiveEntry)], label: String) {
        guard !patches.isEmpty else { return }
        archive.archiveLock.lock()
        for (id, patchedEntry) in patches {
            if let idx = archive.index.firstIndex(where: { $0.sessionId == id }),
               archive.index[idx].fileHash == patchedEntry.fileHash {
                archive.index[idx] = patchedEntry
            }
        }
        do { try archive.saveIndex() } catch { debugLog("[Archive] Failed to save index after \(label): \(error)") }
        archive.archiveLock.unlock()
    }

    /// If neither sleep field resolves, there's nothing to patch — leave the
    /// entry as-is so the fallback chain stays engaged.
    private static func sleepIndexPatch(
        entry: SessionArchiveEntry, session: HRVSession
    ) -> SessionArchiveEntry? {
        let fields = SessionArchive.deriveSleepIndexFields(from: session)
        guard fields.sleepEnd != nil || fields.sleepSegmentCount != nil else { return nil }
        return SessionArchiveEntry(
            sessionId: entry.sessionId,
            date: entry.date,
            endDate: entry.endDate,
            fileHash: entry.fileHash,
            filePath: entry.filePath,
            recoveryScore: entry.recoveryScore,
            meanRMSSD: entry.meanRMSSD,
            meanHR: entry.meanHR,
            stressIndex: entry.stressIndex,
            meanSDNN: entry.meanSDNN,
            tags: entry.tags,
            notes: entry.notes,
            sessionType: entry.sessionType,
            linkedSessionIds: entry.linkedSessionIds,
            sleepEnd: fields.sleepEnd,
            sleepSegmentCount: fields.sleepSegmentCount
        ).mirroringSleepFields(from: session)
    }

    /// One-time migration: patch archive.index entries that have nil recoveryScore
    /// by loading the session and extracting readinessScore from analysisResult.
    /// Uses 3-phase locking: gather work (locked) → disk I/O (unlocked) → apply (locked)
    /// so the main thread is never blocked during file reads.
    func migrateRecoveryScores() {
        runIndexMigration(
            flag: MigrationFlag.recoveryScoresDone, label: "recovery-score migration",
            needsWork: { $0.recoveryScore == nil && $0.meanRMSSD != nil },
            patch: { entry, session in
                session.readinessScore.map { Self.recoveryScorePatch(entry: entry, session: session, readiness: $0) }
            }
        )
    }

    private static func recoveryScorePatch(
        entry: SessionArchiveEntry, session: HRVSession, readiness: Double
    ) -> SessionArchiveEntry {
        SessionArchiveEntry(
            sessionId: entry.sessionId,
            date: entry.date,
            endDate: entry.endDate ?? session.endDate,
            fileHash: entry.fileHash,
            filePath: entry.filePath,
            recoveryScore: readiness,
            meanRMSSD: entry.meanRMSSD,
            meanHR: entry.meanHR ?? session.meanHR,
            stressIndex: entry.stressIndex ?? session.stressIndex,
            meanSDNN: entry.meanSDNN,
            tags: entry.tags,
            notes: entry.notes,
            sessionType: entry.sessionType,
            linkedSessionIds: session.linkedSessionIds
        ).mirroringSleepFields(from: session)
    }

    /// One-time migration: patch archive.index entries that have nil endDate
    /// by reading the actual session from disk. Uses 3-phase locking to
    /// avoid blocking the main thread during file reads.
    func migrateEndDates() {
        runIndexMigration(
            flag: MigrationFlag.endDatesDone, label: "endDate migration",
            needsWork: { $0.endDate == nil },
            patch: { entry, session in
                session.endDate.map { Self.endDatePatch(entry: entry, session: session, endDate: $0) }
            }
        )
    }

    private static func endDatePatch(
        entry: SessionArchiveEntry, session: HRVSession, endDate: Date
    ) -> SessionArchiveEntry {
        SessionArchiveEntry(
            sessionId: entry.sessionId,
            date: entry.date,
            endDate: endDate,
            fileHash: entry.fileHash,
            filePath: entry.filePath,
            recoveryScore: entry.recoveryScore,
            meanRMSSD: entry.meanRMSSD,
            meanHR: entry.meanHR ?? session.meanHR,
            stressIndex: entry.stressIndex ?? session.stressIndex,
            meanSDNN: entry.meanSDNN,
            tags: entry.tags,
            notes: entry.notes,
            sessionType: entry.sessionType,
            linkedSessionIds: entry.linkedSessionIds
        ).mirroringSleepFields(from: session)
    }

    /// One-time migration: backfill meanHR and stressIndex in archive.index entries.
    /// These fields were added so trend computation can use the in-memory archive.index
    /// instead of loading sessions from disk. Uses 3-phase locking.
    func migrateMetrics() {
        let patched = runIndexMigration(
            flag: MigrationFlag.metricsDone, label: "metrics migration",
            needsWork: { $0.meanHR == nil && $0.meanRMSSD != nil },
            patch: { Self.metricsPatch(entry: $0, session: $1) }
        )
        if patched > 0 { debugLog("[Archive] Migrated meanHR/stressIndex for \(patched) entries") }
    }

    private static func metricsPatch(
        entry: SessionArchiveEntry, session: HRVSession
    ) -> SessionArchiveEntry {
        SessionArchiveEntry(
            sessionId: entry.sessionId,
            date: entry.date,
            endDate: entry.endDate,
            fileHash: entry.fileHash,
            filePath: entry.filePath,
            recoveryScore: entry.recoveryScore,
            meanRMSSD: entry.meanRMSSD,
            meanHR: session.meanHR,
            stressIndex: session.stressIndex,
            meanSDNN: entry.meanSDNN,
            tags: entry.tags,
            notes: entry.notes,
            sessionType: entry.sessionType,
            linkedSessionIds: entry.linkedSessionIds
        ).mirroringSleepFields(from: session)
    }

    /// Cleanup: retire same-night overnight duplicate sessions.
    /// CloudKit sync or recovery can create a second session for the same night
    /// with a different UUID and no linkedSessionIds. This method groups overnight
    /// sessions by recovery night (using the user's sleep schedule) and retires
    /// all but the best entry per night. Sessions involved in link relationships
    /// (split-sleep segments) are protected.
    ///
    /// Guarantees (a split night once lost a segment here):
    /// 1. NOTHING is permanently deleted. Retired files are MOVED
    ///    to a clearly-labeled `QuarantinedDuplicates/` folder inside the
    ///    archive directory (with a README.txt explaining recovery), so a
    ///    wrong call here can never destroy a night of data.
    /// 2. Only TRUE duplicates are retired: the loser's time range must be
    ///    ≥ 85% contained in the keeper's range. Disjoint same-night
    ///    segments are split nights — `relinkSameNightSessions()` links
    ///    them; this method must never touch them. (Deleting them loses
    ///    data: a split night recorded Friday and first opened Sunday would
    ///    lose its second segment unrecoverably, because this runs BEFORE
    ///    relink and the raw RR backup is already marked archived.)
    /// 3. Entries without an `endDate` are skipped — containment can't be
    ///    proven, so nothing is retired on a guess.
    /// 4. Honors `sessionMergeMode == .off` — a user who explicitly
    ///    disabled same-night merging has opted out of same-night cleanup
    ///    too (`_archive` honors this too).
    /// 5. Retired ids get a `archive.deletedSessionIds` tombstone so CloudKit's
    ///    `reconcileLocalDeletions` soft-deletes the remote copy and the
    ///    pull path stops re-downloading it (otherwise each full sync
    ///    re-pulls the "duplicate" and the next launch deletes it again,
    ///    forever).
    func removeDuplicates() {
        guard archive.sessionMergeModeProvider() != .off else { return }
        let quarantineWork = duplicateQuarantineWork()
        guard !quarantineWork.isEmpty else { return }
        // Phase 2: move files to quarantine without holding the lock
        // (releasing the lock between phases lets the main thread sneak in)
        let quarantined = quarantineFiles(quarantineWork)
        guard !quarantined.isEmpty else { return }
        // Phase 3: update archive.index + tombstones under lock
        archive.archiveLock.lock()
        archive.index.removeAll { quarantined.contains($0.sessionId) }
        archive.deletedSessionIds.formUnion(quarantined)
        // Dated like any deletion: an undated tombstone loses to a restore
        // made on another device, and is missing from the rebuild of an
        // unreadable deleted list, either of which brought the duplicate back.
        quarantined.forEach(ArchiveStore.recordDeletionTime)
        do { try archive.saveIndex() } catch { debugLog("[Archive] ⚠️ Failed to save index after quarantining duplicates: \(error)") }
        do { try archive.saveDeletedIndex() } catch { debugLog("[Archive] ⚠️ Failed to save deleted index after quarantining duplicates: \(error)") }
        archive.archiveLock.unlock()
    }

    /// Phase 1: identify duplicates under lock. The
    /// keeper-ranking + containment selection is the pure
    /// `duplicatesToQuarantine(...)`, called on a snapshot of the archive.index;
    /// the lock-held section only gathers the snapshot and maps the
    /// selected ids back to file URLs.
    private func duplicateQuarantineWork() -> [(UUID, URL)] {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        let overnightEntries = archive.index.filter { $0.sessionType == .overnight }
        let quarantineIds = Self.duplicatesToQuarantine(
            overnightEntries: overnightEntries,
            linkedIds: Self.linkedSessionIdSet(in: overnightEntries),
            schedule: archive.sleepScheduleProvider(),
            now: Date(),
            mergeMode: archive.sessionMergeModeProvider()
        )
        let entriesById = Dictionary(
            overnightEntries.map { ($0.sessionId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return quarantineIds.compactMap { id in
            entriesById[id].map { (id, archive.resolveFileURL(for: $0)) }
        }
    }

    /// Move each duplicate's file into QuarantinedDuplicates/, returning the
    /// ids that made it. A file that can't be moved keeps its archive.index entry —
    /// better a visible duplicate than an archive.index pointing at nothing.
    private func quarantineFiles(_ work: [(UUID, URL)]) -> Set<UUID> {
        let quarantineDir = archive.archiveDirectory.appendingPathComponent("QuarantinedDuplicates", isDirectory: true)
        prepareQuarantineDirectory(at: quarantineDir)
        var quarantined: Set<UUID> = []
        for (id, fileURL) in work where moveToQuarantine(fileURL, id: id, dir: quarantineDir) {
            quarantined.insert(id)
        }
        return quarantined
    }

    /// An existing file at the destination is replaced — it's a duplicate of a
    /// duplicate, and keeping it would block the move.
    private func moveToQuarantine(_ fileURL: URL, id: UUID, dir: URL) -> Bool {
        let destination = dir.appendingPathComponent(fileURL.lastPathComponent)
        do {
            if archive.fileManager.fileExists(atPath: destination.path) {
                try archive.fileManager.removeItem(at: destination)
            }
            try archive.fileManager.moveItem(at: fileURL, to: destination)
            debugLog("[Archive] dedupe: quarantined duplicate \(id.uuidString.prefix(8)) → QuarantinedDuplicates/")
            return true
        } catch {
            debugLog("[Archive] ⚠️ Failed to quarantine duplicate session file \(id.uuidString.prefix(8)): \(error)")
            return false
        }
    }

    /// Ids participating in any link relationship among the given entries —
    /// both the linking session and every session it links to. Linked
    /// sessions are explicit split-sleep segments and must never be deduped.
    static func linkedSessionIdSet(in overnightEntries: [SessionArchiveEntry]) -> Set<UUID> {
        var linkedIds: Set<UUID> = []
        for entry in overnightEntries {
            guard let linked = entry.linkedSessionIds, !linked.isEmpty else { continue }
            linkedIds.insert(entry.sessionId)
            linkedIds.formUnion(linked)
        }
        return linkedIds
    }

    /// Pure dedupe policy: which overnight sessions should be quarantined
    /// as true same-night duplicates.
    ///
    /// Separate from `removeDuplicates()` so the
    /// keeper-ranking + containment selection is testable without disk,
    /// locks, or settings singletons. Decision rules:
    /// - `mergeMode == .off` → nothing (user opted out of same-night cleanup).
    /// - Linked sessions (either side of a link) are protected.
    /// - Nights with any entry younger than `Tuning.dedupeSafetyWindow`
    ///   (24 h) are skipped — CloudKit may still be reconciling.
    /// - Keeper ranking: has recoveryScore > has meanRMSSD > newest date.
    /// - A loser is quarantined only when its time range is ≥
    ///   `Tuning.duplicateContainmentRatio` (85%) contained in the
    ///   keeper's; disjoint same-night segments are split nights and are
    ///   left for `relinkSameNightSessions()`.
    /// - Entries without an `endDate` (keeper or loser) are skipped —
    ///   containment can't be proven, so nothing is retired on a guess.
    ///
    /// Pure modulo diagnostic logging: output depends only on the inputs.
    static func duplicatesToQuarantine(
        overnightEntries: [SessionArchiveEntry],
        linkedIds: Set<UUID>,
        schedule: SleepSchedule,
        now: Date,
        mergeMode: SessionMergeMode
    ) -> [UUID] {
        guard mergeMode != .off else { return [] }
        let grouped = Dictionary(grouping: overnightEntries) { entry -> Date in
            schedule.overnightWindowStart(relativeTo: entry.date)
        }
        var quarantineIds: [UUID] = []
        for (_, dayEntries) in grouped where dayEntries.count > 1 {
            let unlinked = dayEntries.filter { !linkedIds.contains($0.sessionId) }
            guard unlinked.count > 1 else { continue }
            let hasRecentEntry = unlinked.contains { now.timeIntervalSince($0.date) < SessionArchive.Tuning.dedupeSafetyWindow }
            if hasRecentEntry { continue }
            quarantineIds += containedDuplicates(in: unlinked)
        }
        return quarantineIds
    }

    /// Rank one night's candidates and return the ids of those whose time
    /// range is mostly inside the keeper's. A scored entry beats an unscored
    /// one, an entry with RMSSD beats one without, and the later start breaks
    /// remaining ties.
    private static func containedDuplicates(in unlinked: [SessionArchiveEntry]) -> [UUID] {
        let sorted = unlinked.sorted { a, b in
            let aHasScore = a.recoveryScore != nil
            let bHasScore = b.recoveryScore != nil
            if aHasScore != bHasScore { return aHasScore }
            let aHasRMSSD = a.meanRMSSD != nil
            let bHasRMSSD = b.meanRMSSD != nil
            if aHasRMSSD != bHasRMSSD { return aHasRMSSD }
            return a.date > b.date
        }
        guard let keeper = sorted.first, let keeperEnd = keeper.endDate else { return [] }
        return sorted.dropFirst().filter { isContained($0, inKeeper: keeper, keeperEnd: keeperEnd) }
            .map(\.sessionId)
    }

    /// Whether a losing entry's range is ≥85% covered by the keeper's. A
    /// zero-length entry counts as junk when it sits inside the keeper's
    /// range. Anything less overlapped is a genuine split-night segment and is
    /// left alone for the relink migration.
    private static func isContained(
        _ entry: SessionArchiveEntry, inKeeper keeper: SessionArchiveEntry, keeperEnd: Date
    ) -> Bool {
        guard let loserEnd = entry.endDate else { return false }
        let loserDuration = loserEnd.timeIntervalSince(entry.date)
        // Overlap of [entry.date, loserEnd] with [keeper.date, keeperEnd].
        let overlap = min(loserEnd, keeperEnd).timeIntervalSince(max(entry.date, keeper.date))
        let contained: Bool = if loserDuration > 0 {
            overlap / loserDuration >= SessionArchive.Tuning.duplicateContainmentRatio
        } else {
            entry.date >= keeper.date && entry.date <= keeperEnd
        }
        guard !contained else { return true }
        debugLog("[Archive] dedupe: \(entry.sessionId.uuidString.prefix(8)) overlaps keeper \(keeper.sessionId.uuidString.prefix(8)) by \(Int((max(0, overlap) / max(loserDuration, 1)) * 100))% — treating as split-night segment, leaving for relink")
        return false
    }

    /// Create the duplicate-quarantine folder and its explanatory README
    /// on first use. The README is the "well-labeled" contract: anyone
    /// (including a future debugging session) opening the folder on disk
    /// can tell exactly what these files are and how to restore one.
    private func prepareQuarantineDirectory(at dir: URL) {
        if !archive.fileManager.fileExists(atPath: dir.path) {
            do {
                try archive.fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                debugLog("[Archive] ⚠️ Failed to create QuarantinedDuplicates directory: \(error)")
                return
            }
        }
        let readme = dir.appendingPathComponent("README.txt")
        guard !archive.fileManager.fileExists(atPath: readme.path) else { return }
        do {
            try Self.quarantineReadme.data(using: .utf8)?
                .write(to: readme, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            debugLog("[Archive] ⚠️ Failed to write quarantine README: \(error)")
        }
    }

    private static let quarantineReadme = """
    QUARANTINED DUPLICATE SESSIONS — nothing in this folder is lost.

    Each .json file here is a complete archived HRV session (same
    encrypted format as the parent folder) that the duplicate-cleanup
    migration retired because its time range was ≥85% contained in a
    better-ranked session from the same night. The data was moved
    here instead of deleted so a wrong call can always be undone.

    To restore a session:
    1. Move its .json file back into the parent archive folder.
    2. Remove its UUID (the filename) from deleted.json in the parent
       folder — the tombstone otherwise blocks re-adoption.
    3. Relaunch the app; the orphan-file reconciler re-indexes it.

    Files here are never read by the app and may be deleted manually
    once you are confident the kept sessions are correct.
    """

    /// One night's parent session and the ids it should be linked to.
    private struct RelinkWork {
        let parentEntry: SessionArchiveEntry
        let fileURL: URL
        let otherIds: [UUID]
    }

    /// One successfully re-linked session: its new file hash and link chain.
    private struct RelinkResult {
        let sessionId: UUID
        let hashString: String
        let links: [UUID]
    }

    /// Re-link unlinked same-night overnight sessions. Fixes sessions that were
    /// recorded as split-sleep but not linked because the resume button was hidden
    /// or the old 6-hour night anchor failed to group them.
    ///
    /// Each night's read-modify-write runs under the lock. Done outside it, a
    /// concurrent archive of the same session (a sleep refresh, a rescore)
    /// landed between the read and the write and was overwritten, or its new
    /// file hash was replaced in the index with a stale one. It is rare work —
    /// only nights with unlinked segments — so the short hold is the right trade.
    func relinkSameNightSessions() {
        let workItems = relinkWorkItems()
        guard !workItems.isEmpty else { return }
        let results = workItems.compactMap { relinkUnderLock($0) }
        guard !results.isEmpty else { return }
        // We rewrote the session files in place. The CloudKit copy is now
        // stale. Signal the sync manager to clear its "uploaded" set for
        // these IDs so the next sync pushes the corrected versions.
        NotificationCenter.default.post(
            name: .flowRecoveryArchiveSessionsNeedReupload,
            object: nil,
            userInfo: ["sessionIds": Set(results.map(\.sessionId))]
        )
    }

    /// Phase 1: identify groups needing re-link under lock. The latest session
    /// of each multi-session night becomes the parent that links the rest.
    ///
    /// Nights with an entry younger than `dedupeSafetyWindow` wait, the same
    /// rule `removeDuplicates` follows. Linked here, a true duplicate that
    /// arrived the same morning (an iCloud pull) became a protected
    /// split-night segment and was never removed.
    private func relinkWorkItems() -> [RelinkWork] {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        let sleepSchedule = archive.sleepScheduleProvider()
        let overnightEntries = archive.index
            .filter { $0.sessionType == .overnight }
            .sorted { $0.date < $1.date }
        let grouped = Dictionary(grouping: overnightEntries) { sleepSchedule.overnightWindowStart(relativeTo: $0.date) }
        let now = Date()
        var workItems: [RelinkWork] = []
        for (_, nightEntries) in grouped where nightEntries.count > 1 && !Self.hasRecentEntry(nightEntries, now: now) {
            let sorted = nightEntries.sorted { $0.date < $1.date }
            guard let latestEntry = sorted.last else { continue }
            workItems.append(RelinkWork(
                parentEntry: latestEntry,
                fileURL: archive.resolveFileURL(for: latestEntry),
                otherIds: sorted.dropLast().map(\.sessionId)
            ))
        }
        return workItems
    }

    private static func hasRecentEntry(_ entries: [SessionArchiveEntry], now: Date) -> Bool {
        entries.contains { now.timeIntervalSince($0.date) < SessionArchive.Tuning.dedupeSafetyWindow }
    }

    /// One night, locked: skipped when the parent changed since phase 1 (the
    /// next launch looks again), otherwise rewritten and its entry patched.
    /// The index is saved with each night, under the same lock as the file
    /// write: saved once at the end, the cached lookups kept the old file
    /// hash until then (a read in between failed its integrity check), and a
    /// crash in between left files the stored index no longer matched.
    private func relinkUnderLock(_ work: RelinkWork) -> RelinkResult? {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        guard let idx = archive.index.firstIndex(where: { $0.sessionId == work.parentEntry.sessionId }),
              archive.index[idx].fileHash == work.parentEntry.fileHash,
              let result = relink(work) else { return nil }
        archive.index[idx] = Self.relinked(archive.index[idx], result: result)
        do { try archive.saveIndex() } catch { debugLog("[Archive] ⚠️ Failed to save index after re-linking: \(error)") }
        return result
    }

    /// Phase 2 for one night: read, modify, and write the parent's file.
    /// Nil when nothing needed adding or the write failed. Caller holds the
    /// lock.
    ///
    /// Uses the shared full-session decoder — we MUST preserve rrSeries
    /// through the round-trip; the lightweight decoder would erase the strap's
    /// beat-by-beat data on write.
    private func relink(_ work: RelinkWork) -> RelinkResult? {
        guard var session = loadForRelink(work) else { return nil }
        var links = session.linkedSessionIds ?? []
        let missingLinks = work.otherIds.filter { !Set(links).contains($0) }
        guard !missingLinks.isEmpty else { return nil }
        links.append(contentsOf: missingLinks)
        session.linkedSessionIds = links
        guard let hashString = writeRelinked(session, to: work.fileURL, id: work.parentEntry.sessionId) else {
            return nil
        }
        return RelinkResult(sessionId: work.parentEntry.sessionId, hashString: hashString, links: links)
    }

    private func loadForRelink(_ work: RelinkWork) -> HRVSession? {
        do {
            // Encrypted-file dual-format reader.
            return try SessionArchive.loadAndDecodeSessionFile(
                at: work.fileURL, decoder: SessionArchive.sessionDecoder
            )
        } catch {
            debugLog("[Archive] relinkSameNightSessions: failed to load session \(work.parentEntry.sessionId.uuidString.prefix(8)): \(error)", level: .warning)
            return nil
        }
    }

    /// Write the re-linked session back over its file, returning the hash of
    /// the bytes as written. Nil when the write failed.
    private func writeRelinked(_ session: HRVSession, to fileURL: URL, id: UUID) -> String? {
        do {
            // Shared codec path. A relink under a locked Keychain falls back
            // to plaintext; `archiveWriteOptions` picks protection per the
            // format actually written.
            let result = try SessionArchive.SessionFileCodec.encodeForDisk(session, encoder: Self.relinkEncoder)
            let options = archiveWriteOptions(for: result.format, sessionID: session.id)
            try result.bytes.write(to: fileURL, options: options)
            return result.hash
        } catch {
            debugLog("[Archive] ⚠️ Failed to write re-linked session \(id.uuidString.prefix(8)): \(error)")
            return nil
        }
    }

    /// Keeps the historical `.prettyPrinted + .sortedKeys` format for
    /// relink-written files (NOT unified with `_archive`'s compact
    /// `sessionEncoder` — see SessionFileCodec). The hash is computed from the
    /// bytes we write and the archive.index entry is updated in phase 3, so the
    /// encoder formatting choice is self-consistent on read.
    ///
    /// Encoding plaintext and writing raw would silently drop
    /// encryption-at-rest for any session that had been encrypted on disk.
    /// So this matches the `_archive` write path: encode →
    /// encrypt (when EncryptionManager is available) → write → hash the
    /// bytes-as-written. The archive.index `fileHash` must match disk bytes for
    /// `_retrieve`'s integrity check, and hashing plaintext while writing
    /// ciphertext breaks that contract.
    ///
    /// Routed through `SessionFileCodec` (the shared encode →
    /// encrypt-if-available → hash codec) so this site can never drift from
    /// that contract. No plaintext-fallback warn log here, preserving
    /// this site's historical silent fallback (`_archive`/`archiveBatch` each
    /// keep their own log lines). The write also carries an explicit
    /// protection class, matching every other archive write site: `.atomic`
    /// alone replaces the file and drops the directory-inherited protection
    /// class (the EPERM-storm root cause, see the note in
    /// `_archive`), and a relinked file written without it can become
    /// unreadable while the device is locked.
    private static let relinkEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Relink only rewrites the file hash + link chain — every other field,
    /// including the sleep-stage / dip mirrors and the quality flag the
    /// AI/voice aggregation gate reads, is carried across unchanged rather
    /// than nulled through the field-by-field initializer.
    private static func relinked(
        _ old: SessionArchiveEntry, result: RelinkResult
    ) -> SessionArchiveEntry {
        SessionArchiveEntry(
            sessionId: old.sessionId, date: old.date, endDate: old.endDate,
            fileHash: result.hashString, filePath: old.filePath,
            recoveryScore: old.recoveryScore, meanRMSSD: old.meanRMSSD,
            meanHR: old.meanHR, stressIndex: old.stressIndex,
            meanSDNN: old.meanSDNN, tags: old.tags, notes: old.notes,
            sessionType: old.sessionType, linkedSessionIds: result.links,
            sleepEnd: old.sleepEnd, sleepSegmentCount: old.sleepSegmentCount,
            deepSleepMinutes: old.deepSleepMinutes, remSleepMinutes: old.remSleepMinutes,
            coreSleepMinutes: old.coreSleepMinutes, awakeMinutes: old.awakeMinutes,
            nocturnalDipPercent: old.nocturnalDipPercent,
            hrvDataQuality: old.hrvDataQuality, modifiedAt: old.modifiedAt
        )
    }
}

extension Notification.Name {
    /// Posted when a local migration has mutated archived session files in
    /// place, making the CloudKit copies stale. `userInfo["sessionIds"]`
    /// carries a `Set<UUID>` that `CloudKitSyncManager` clears from its
    /// uploaded-set so the next sync pass re-uploads them.
    static let flowRecoveryArchiveSessionsNeedReupload = Notification.Name("flowRecoveryArchiveSessionsNeedReupload")
}
