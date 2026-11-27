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
        static let legacyEliteIndexDone = "FlowRecovery.migration.legacyEliteIndex.v1.done"
    }

    /// Run the archive's data migrations in the background so they don't block
    /// app launch or dashboard rendering. Runs at launch and after every
    /// iCloud pull. Re-encrypts what was written while the key was
    /// unavailable (session files and the index) first. Safe to call multiple
    /// times: the four backfills are
    /// no-ops once their done flag is set, while `removeDuplicates` and
    /// `relinkSameNightSessions` run on every call because what they repair
    /// can come back.
    ///
    /// Each migration acquires/releases archive.archiveLock internally and yields
    /// the lock during disk I/O so the main thread is never blocked for
    /// more than a few milliseconds (eliminates "hang detected" warnings).
    func runDeferredMigrations() {
        reencryptPendingSessions(in: archive)
        archive.state.resealPlainIndexIfNeeded()
        migrateRecoveryScores()
        migrateEndDates()
        migrateMetrics()
        migrateSleepIndexFields()
        migrateLegacyEliteImportIndex()
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

    /// One-time migration: an Elite HRV import saved before
    /// `HRVAnalysisResult.estimatedMetrics` existed put its RMSSD-made stress
    /// index (and, in the first build, an RMSSD-made score) into its index
    /// entry. Its session now decodes without them (`HRVSession.init(from:)`),
    /// so the entry takes the session's values. An entry says nothing of its
    /// source, so every overnight or quick entry carrying a stress index or a
    /// score is read once; workouts and Breathe sessions were never Elite.
    func migrateLegacyEliteImportIndex() {
        runIndexMigration(
            flag: MigrationFlag.legacyEliteIndexDone, label: "legacy Elite index migration",
            needsWork: {
                ($0.sessionType == .overnight || $0.sessionType == .quick)
                    && ($0.stressIndex != nil || $0.recoveryScore != nil)
            },
            patch: { Self.legacyElitePatch(entry: $0, session: $1) }
        )
    }

    /// The entry with the session's stress index and score, for an Elite
    /// import whose entry still holds values the session no longer has; nil
    /// for every other session.
    private static func legacyElitePatch(
        entry: SessionArchiveEntry, session: HRVSession
    ) -> SessionArchiveEntry? {
        guard session.importedMetrics?.source == HRVSession.ImportedMetrics.eliteHRVSource,
              entry.stressIndex != session.stressIndex || entry.recoveryScore != session.recoveryScore
        else { return nil }
        return SessionArchiveEntry(
            sessionId: entry.sessionId, date: entry.date, endDate: entry.endDate,
            fileHash: entry.fileHash, filePath: entry.filePath,
            recoveryScore: session.recoveryScore,
            meanRMSSD: entry.meanRMSSD, meanHR: entry.meanHR,
            stressIndex: session.stressIndex, meanSDNN: entry.meanSDNN,
            tags: entry.tags, notes: entry.notes,
            sessionType: entry.sessionType, linkedSessionIds: entry.linkedSessionIds,
            sleepEnd: entry.sleepEnd, sleepSegmentCount: entry.sleepSegmentCount
        ).mirroringSleepFields(from: session)
    }

    /// Phases 1 and 2 of a backfill: gather the entries `needsWork` picks
    /// (locked), then read each session (unlocked) and build its patch; phase 3
    /// is `applyIndexPatches`. Returns how many entries were patched.
    ///
    /// The done flag is set once a pass has read every session, patched or
    /// not. Setting it only when the work list comes back empty would never
    /// happen: an entry with nothing to patch (a workout has no sleep
    /// fields) stays in the list for good, and every launch would re-read and
    /// decrypt all of them. A session that fails to load keeps the flag off
    /// so the next launch tries it again.
    @discardableResult
    private func runIndexMigration(
        flag: String, label: String,
        needsWork: (SessionArchiveEntry) -> Bool,
        patch: (SessionArchiveEntry, HRVSession) -> SessionArchiveEntry?
    ) -> Int {
        if UserDefaults.standard.bool(forKey: flag) { return 0 }
        archive.archiveLock.lock()
        let workItems = archive.state.index.filter(needsWork).map { ($0, archive.state.resolveFileURL(for: $0)) }
        archive.archiveLock.unlock()
        var patches: [(UUID, SessionArchiveEntry)] = []
        var loadedAll = true
        for (entry, fileURL) in workItems {
            guard let session = Self.loadForMigration(at: fileURL, entry: entry, label: label, encryption: archive.encryption) else { loadedAll = false; continue }
            if let patched = patch(entry, session) { patches.append((entry.sessionId, patched)) }
        }
        applyIndexPatches(patches, label: label)
        if loadedAll { UserDefaults.standard.set(true, forKey: flag) }
        return patches.count
    }

    /// Not a bare `decoder.decode(HRVSession.self, from: Data(contentsOf:))`:
    /// that fails on encrypted files ("Unexpected character 'F'"). Route
    /// through the shared dual-format reader so
    /// encrypted + legacy plaintext both decode.
    private static func loadForMigration(
        at fileURL: URL, entry: SessionArchiveEntry, label: String, encryption: EncryptionManager
    ) -> HRVSession? {
        do {
            return try ArchiveStore.loadAndDecodeSessionFile(at: fileURL, decoder: SessionArchive.lightweightSessionDecoder, encryption: encryption)
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
            if let idx = archive.state.index.firstIndex(where: { $0.sessionId == id }),
               archive.state.index[idx].fileHash == patchedEntry.fileHash {
                archive.state.index[idx] = patchedEntry
            }
        }
        do { try archive.state.saveIndex() } catch { debugLog("[Archive] Failed to save index after \(label): \(error)") }
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
            linkedSessionIds: entry.linkedSessionIds,
            sleepEnd: entry.sleepEnd,
            sleepSegmentCount: entry.sleepSegmentCount
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
            linkedSessionIds: entry.linkedSessionIds,
            sleepEnd: entry.sleepEnd,
            sleepSegmentCount: entry.sleepSegmentCount
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
            linkedSessionIds: entry.linkedSessionIds,
            sleepEnd: entry.sleepEnd,
            sleepSegmentCount: entry.sleepSegmentCount
        ).mirroringSleepFields(from: session)
    }

    /// Cleanup: retire same-night overnight duplicate sessions.
    /// CloudKit sync or recovery can create a second session for the same night
    /// with a different UUID and no linkedSessionIds. This method groups overnight
    /// sessions by recovery night (using the user's sleep schedule) and retires
    /// all but the best entry per night. Sessions involved in link relationships
    /// (split-sleep segments) are protected.
    ///
    /// Guarantees:
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
    /// 6. What the user added to a retired copy (tags, notes, the morning
    ///    feeling, perceived readiness) is carried into the keeper first
    ///    (`carryUserContent`); a copy that cannot be read for it is not
    ///    retired this pass. The tombstone deletes the copy on every device,
    ///    so content left on it is lost everywhere.
    func removeDuplicates() {
        guard archive.state.mergeSettings.mode() != .off else { return }
        let (quarantineWork, changedKeepers) = duplicateQuarantineWork()
        // Posted outside the lock phase 1 held, as every archive change is.
        if !changedKeepers.isEmpty {
            NotificationCenter.default.post(
                name: .flowRecoveryArchiveSessionsNeedReupload, object: nil, userInfo: ["sessionIds": changedKeepers]
            )
        }
        guard !quarantineWork.isEmpty else { return }
        // Phase 2: move files to quarantine without holding the lock
        // (releasing the lock between phases lets the main thread sneak in)
        let quarantined = quarantineFiles(quarantineWork.map { ($0.id, $0.url) })
        guard !quarantined.isEmpty else { return }
        let moves = quarantineWork.compactMap { work in
            quarantined[work.id].map { (QuarantineMove(id: work.id, quarantined: $0, original: work.url), work.hash) }
        }
        retireUnlessWritten(moves)
    }

    /// Phase 3: update archive.index + tombstones under lock, for the copies
    /// not written since phase 1 checked them.
    private func retireUnlessWritten(_ checkedMoves: [(QuarantineMove, String)]) {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        let moves = keepingCopiesWrittenSinceTheCheck(checkedMoves)
        guard !moves.isEmpty else { return }
        do {
            try retireQuarantined(Set(moves.map(\.id)))
        } catch {
            debugLog("[Archive] ⚠️ Failed to save the indexes after quarantining duplicates — moving the files back: \(error)", level: .warning)
            restoreFromQuarantine(moves)
        }
    }

    /// Phase 3, caller holds the lock: a copy written since phase 1 checked
    /// it (an edit in History, a newer copy from iCloud) is no longer the
    /// copy whose content went into its keeper, so it is not retired. Its
    /// quarantined file goes back unless that write already put a newer file
    /// in its place, which then stays and the older one stays in quarantine.
    /// Returns the moves still to retire.
    private func keepingCopiesWrittenSinceTheCheck(_ moves: [(QuarantineMove, String)]) -> [QuarantineMove] {
        let (unchanged, written) = moves.reduce(into: ([QuarantineMove](), [QuarantineMove]())) { split, checked in
            let (move, hash) = checked
            if archive.store.entryById(move.id)?.fileHash == hash { split.0.append(move) } else { split.1.append(move) }
        }
        for move in written {
            debugLog("[Archive] dedupe: \(move.id.uuidString.prefix(8)) was written while it was checked — kept", level: .info)
            guard !archive.fileManager.fileExists(atPath: move.original.path) else { continue }
            attempt("Archive.dedupe.returnWrittenCopy") { try archive.fileManager.moveItem(at: move.quarantined, to: move.original) }
        }
        return unchanged
    }

    /// One retired file: where quarantine put it and where the index expects it.
    private struct QuarantineMove {
        let id: UUID
        let quarantined: URL
        let original: URL
    }

    /// Phase 3, caller holds the lock: drop the quarantined ids from the
    /// index and tombstone them, tombstones saved first (an index saved
    /// without them would let the orphan scan adopt the files back). A failed
    /// save undoes both in-memory changes, rewrites the tombstone list
    /// without them, and throws; the stored index then still names the
    /// files, so the caller moves them back.
    private func retireQuarantined(_ ids: Set<UUID>) throws {
        let preIndex = archive.state.index
        let preDeleted = archive.state.deletedSessionIds
        archive.state.index.removeAll { ids.contains($0.sessionId) }
        archive.state.deletedSessionIds.formUnion(ids)
        do {
            try archive.state.saveDeletedIndex()
            try archive.state.saveIndex()
        } catch {
            archive.state.index = preIndex
            archive.state.deletedSessionIds = preDeleted
            archive.state.sortedEntriesCache = nil
            archive.state.sessionIdLookup = nil
            attempt("Archive.dedupe.rollbackTombstones") { try archive.state.saveDeletedIndex() }
            throw error
        }
        // Dated like any deletion: an undated tombstone loses to a restore
        // made on another device, and is missing from the rebuild of an
        // unreadable deleted list, either of which brought the duplicate back.
        ids.forEach(ArchiveStore.recordDeletionTime)
    }

    /// Move quarantined files back to where the (restored) index expects them.
    /// Caller holds the lock. A file that will not move back stays retired:
    /// its entry leaves the index again and it keeps its tombstone. The two
    /// saves are tried apart, the index regardless of the tombstones, since
    /// an index naming a file in quarantine fails every read of it. Without
    /// its tombstone a retired duplicate can come back from iCloud, which
    /// costs a duplicate, not a lost night. Whatever does not save stays in
    /// memory for the next save to write, and is logged as an error.
    private func restoreFromQuarantine(_ moves: [QuarantineMove]) {
        let stranded = Set(moves.filter { move in
            attempt("Archive.dedupe.restoreFromQuarantine") {
                try archive.fileManager.moveItem(at: move.quarantined, to: move.original)
            } == nil
        }.map(\.id))
        guard !stranded.isEmpty else { return }
        archive.state.index.removeAll { stranded.contains($0.sessionId) }
        archive.state.deletedSessionIds.formUnion(stranded)
        stranded.forEach(ArchiveStore.recordDeletionTime)
        attempt("Archive.dedupe.retireStrandedTombstones") { try archive.state.saveDeletedIndex() }
        if attempt("Archive.dedupe.retireStrandedIndex", { try archive.state.saveIndex() }) == nil {
            debugLog("[Archive] ⚠️ index still names \(stranded.count) quarantined file(s) on disk until the next save", level: .error)
        }
    }

    /// Phase 1: identify duplicates under lock. The
    /// keeper-ranking + containment selection is the pure
    /// `duplicateRetirements(...)`, called on a snapshot of the archive.index;
    /// the lock-held section gathers the snapshot, carries each retired
    /// copy's user content into its keeper (`carryUserContent(to:)`), and maps
    /// the ids that may go back to file URLs, with the file hash checked.
    private func duplicateQuarantineWork() -> (work: [(id: UUID, url: URL, hash: String)], changedKeepers: Set<UUID>) {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        let overnightEntries = archive.state.index.filter { $0.sessionType == .overnight }
        let retirements = Self.duplicateRetirements(
            overnightEntries: overnightEntries,
            linkedIds: Self.linkedSessionIdSet(in: overnightEntries),
            schedule: archive.state.mergeSettings.sleepSchedule(),
            now: Date(),
            mergeMode: archive.state.mergeSettings.mode()
        )
        let entriesById = Dictionary(
            overnightEntries.map { ($0.sessionId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let carried = carryUserContent(to: retirements)
        let work = carried.retirable.compactMap { id in
            entriesById[id].map { (id: id, url: archive.state.resolveFileURL(for: $0), hash: $0.fileHash) }
        }
        return (work, carried.changedKeepers)
    }

    /// Carry each retired copy's user content into its keeper, keeper by
    /// keeper, and return the retired ids whose content is in a keeper. A
    /// keeper or copy that cannot be read, or a keeper that cannot be
    /// written, keeps its copies out of this pass: retiring them would lose
    /// what only they hold. A keeper that changed is stamped, and returned so
    /// the caller queues it to upload again once the lock is released, as any
    /// edit made here is. Caller holds `archiveLock`.
    private func carryUserContent(to retirements: [DuplicateRetirement]) -> (retirable: [UUID], changedKeepers: Set<UUID>) {
        var retirable: [UUID] = []
        var changedKeepers: Set<UUID> = []
        for (keeperId, group) in Dictionary(grouping: retirements, by: \.keeper) {
            guard let changed = carryUserContent(of: group.map(\.loser), intoKeeper: keeperId) else { continue }
            if changed { changedKeepers.insert(keeperId) }
            retirable += group.map(\.loser)
        }
        return (retirable, changedKeepers)
    }

    /// Carry the content of the copies `loserIds` into the keeper and write it
    /// stamped when that changed it; true when it did. Nil, logged, when a
    /// session cannot be read or the keeper cannot be written. Caller holds
    /// `archiveLock`.
    private func carryUserContent(of loserIds: [UUID], intoKeeper keeperId: UUID) -> Bool? {
        do {
            guard var keeper = try archive.store._retrieve(keeperId) else { return false }
            var changed = false
            for loser in try loserIds.compactMap({ try archive.store._retrieve($0) }) {
                changed = SessionMerger.carryUserContent(from: loser, into: &keeper) || changed
            }
            guard changed else { return false }
            keeper.modifiedAt = CloudKitSessionFreshness.stamp()
            _ = try archive.store._archive(keeper, skipSameNightMerge: true)
            return true
        } catch {
            debugLog("[Archive] dedupe: could not carry the content of \(loserIds.count) duplicate(s) into \(keeperId.uuidString.prefix(8)) — kept this pass: \(error)", level: .warning)
            return nil
        }
    }

    /// Move each duplicate's file into QuarantinedDuplicates/, returning where
    /// each one that made it now is. A file that can't be moved keeps its
    /// archive.index entry — better a visible duplicate than an archive.index
    /// pointing at nothing.
    private func quarantineFiles(_ work: [(UUID, URL)]) -> [UUID: URL] {
        let quarantineDir = archive.store.quarantineDirectory
        prepareQuarantineDirectory(at: quarantineDir)
        var quarantined: [UUID: URL] = [:]
        for (id, fileURL) in work {
            quarantined[id] = moveToQuarantine(fileURL, id: id, dir: quarantineDir)
        }
        return quarantined
    }

    /// The quarantined file's new location, or nil when it was not moved. A
    /// file already at the destination (an earlier run quarantined the same
    /// session) is kept, and this one takes a name of its own, so nothing in
    /// quarantine is deleted. A missing source means another dedupe run
    /// (launch housekeeping and a CloudKit pull can overlap) already moved
    /// it: the copy in quarantine IS that file, so it is left alone.
    private func moveToQuarantine(_ fileURL: URL, id: UUID, dir: URL) -> URL? {
        guard archive.fileManager.fileExists(atPath: fileURL.path) else {
            debugLog("[Archive] dedupe: \(id.uuidString.prefix(8)) already moved by another run — skipped")
            return nil
        }
        let destination = Self.unusedQuarantineURL(for: fileURL, in: dir, fileManager: archive.fileManager)
        do {
            try archive.fileManager.moveItem(at: fileURL, to: destination)
            debugLog("[Archive] dedupe: quarantined duplicate \(id.uuidString.prefix(8)) → QuarantinedDuplicates/")
            return destination
        } catch {
            debugLog("[Archive] ⚠️ Failed to quarantine duplicate session file \(id.uuidString.prefix(8)): \(error)")
            return nil
        }
    }

    /// `<name>.json` in `dir`, or `<name>.<ms>.json`, raised past any name
    /// taken, when a file of that name is already there.
    static func unusedQuarantineURL(for fileURL: URL, in dir: URL, fileManager: FileManager) -> URL {
        let plain = dir.appendingPathComponent(fileURL.lastPathComponent)
        guard fileManager.fileExists(atPath: plain.path) else { return plain }
        let base = fileURL.deletingPathExtension().lastPathComponent
        var stamp = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
        while fileManager.fileExists(atPath: dir.appendingPathComponent("\(base).\(stamp).\(fileURL.pathExtension)").path) {
            stamp += 1
        }
        return dir.appendingPathComponent("\(base).\(stamp).\(fileURL.pathExtension)")
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
    /// - Keeper ranking: has recoveryScore > has meanRMSSD > newest date >
    ///   lowest session id, so every device keeps the same copy.
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
        duplicateRetirements(
            overnightEntries: overnightEntries, linkedIds: linkedIds, schedule: schedule, now: now, mergeMode: mergeMode
        ).map(\.loser)
    }

    /// One duplicate to retire, and the entry kept in its place.
    struct DuplicateRetirement: Equatable {
        let loser: UUID
        let keeper: UUID
    }

    /// `duplicatesToQuarantine`'s decision, with the keeper of each retired id.
    static func duplicateRetirements(
        overnightEntries: [SessionArchiveEntry],
        linkedIds: Set<UUID>,
        schedule: SleepSchedule,
        now: Date,
        mergeMode: SessionMergeMode
    ) -> [DuplicateRetirement] {
        guard mergeMode != .off else { return [] }
        let grouped = Dictionary(grouping: overnightEntries) { entry -> Date in
            schedule.overnightWindowStart(relativeTo: entry.date)
        }
        var retirements: [DuplicateRetirement] = []
        for (_, dayEntries) in grouped where dayEntries.count > 1 {
            let unlinked = SessionArchiveEntry.oneEntryPerSession(dayEntries.filter { !linkedIds.contains($0.sessionId) })
            guard unlinked.count > 1 else { continue }
            if hasRecentEntry(unlinked, now: now) { continue }
            retirements += containedDuplicates(in: unlinked)
        }
        return retirements
    }

    /// Rank one night's candidates and return those whose time range is
    /// mostly inside the keeper's. A scored entry beats an unscored one, an
    /// entry with RMSSD beats one without, the later start breaks remaining
    /// ties, and the session id breaks a tie on the start. The ranking must
    /// not depend on the order the entries come in: each device holds its
    /// index in its own order, and two devices keeping different copies of
    /// one night tombstoned both, which deleted the night everywhere.
    private static func containedDuplicates(in unlinked: [SessionArchiveEntry]) -> [DuplicateRetirement] {
        let sorted = unlinked.sorted { a, b in
            let aHasScore = a.recoveryScore != nil
            let bHasScore = b.recoveryScore != nil
            if aHasScore != bHasScore { return aHasScore }
            let aHasRMSSD = a.meanRMSSD != nil
            let bHasRMSSD = b.meanRMSSD != nil
            if aHasRMSSD != bHasRMSSD { return aHasRMSSD }
            if a.date != b.date { return a.date > b.date }
            return a.sessionId.uuidString < b.sessionId.uuidString
        }
        guard let keeper = sorted.first, let keeperEnd = keeper.endDate else { return [] }
        return sorted.dropFirst().filter { isContained($0, inKeeper: keeper, keeperEnd: keeperEnd) }
            .map { DuplicateRetirement(loser: $0.sessionId, keeper: keeper.sessionId) }
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
    2. Remove its UUID (the start of the filename) from deleted.json in
       the parent folder — the tombstone otherwise blocks re-adoption.
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

    /// Re-link unlinked same-night overnight sessions: segments of one
    /// split-sleep night that are stored without their links.
    ///
    /// Each night's read-modify-write runs under the lock. Done outside it, a
    /// concurrent archive of the same session (a sleep refresh, a rescore)
    /// could land between the read and the write and be overwritten, or its
    /// new file hash be replaced in the index with a stale one. It is rare work —
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

    /// Phase 1: identify groups needing re-link under lock. A night's
    /// recordings are split into sleeps by the user's merge gap
    /// (`SessionMerger.runsWithinGap`, the rule the morning merge uses); the
    /// latest recording of each sleep with more than one becomes the parent
    /// that links the rest. Recordings further apart than the gap are separate
    /// sleeps and are not linked.
    ///
    /// Nights with an entry younger than `dedupeSafetyWindow` wait, the same
    /// rule `removeDuplicates` follows. Linked here, a true duplicate that
    /// arrived the same morning (an iCloud pull) became a protected
    /// split-night segment and was never removed.
    private func relinkWorkItems() -> [RelinkWork] {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        let sleepSchedule = archive.state.mergeSettings.sleepSchedule()
        let overnightEntries = archive.state.index.filter { $0.sessionType == .overnight }
        let grouped = Dictionary(grouping: overnightEntries) { sleepSchedule.overnightWindowStart(relativeTo: $0.date) }
        let gap = archive.state.mergeSettings.mode() == .off ? 0 : archive.state.mergeSettings.gap()
        let now = Date()
        return grouped.values
            .filter { $0.count > 1 && !Self.hasRecentEntry($0, now: now) }
            .flatMap { night in SessionMerger.runsWithinGap(night, gap: gap) { SessionMerger.span(of: $0) } }
            .compactMap { relinkWork(for: $0) }
    }

    /// One sleep's work item: its latest recording links the others. Nil
    /// for a sleep of one recording.
    private func relinkWork(for sleep: [SessionArchiveEntry]) -> RelinkWork? {
        let sorted = sleep.sorted { $0.date < $1.date }
        guard sorted.count > 1, let latestEntry = sorted.last else { return nil }
        return RelinkWork(
            parentEntry: latestEntry,
            fileURL: archive.state.resolveFileURL(for: latestEntry),
            otherIds: sorted.dropLast().map(\.sessionId)
        )
    }

    private static func hasRecentEntry(_ entries: [SessionArchiveEntry], now: Date) -> Bool {
        entries.contains { now.timeIntervalSince($0.date) < SessionArchive.Tuning.dedupeSafetyWindow }
    }

    /// One night, locked: skipped when the parent changed since phase 1 (the
    /// next launch looks again), otherwise rewritten and its entry patched.
    /// The index is saved with each night, under the same lock as the file
    /// write: saved once at the end, the cached lookups would keep the old
    /// file hash until then (a read in between would fail its integrity
    /// check), and a crash in between would leave files the stored index
    /// does not match.
    ///
    /// A failed index save puts the parent's previous file and entry back
    /// (`ArchiveStore.rollBackWrite`): the stored index would otherwise keep
    /// the old hash for the rewritten file, and every read of the night would
    /// fail its integrity check after a relaunch. The next launch tries again.
    private func relinkUnderLock(_ work: RelinkWork) -> RelinkResult? {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        guard let idx = archive.state.index.firstIndex(where: { $0.sessionId == work.parentEntry.sessionId }),
              archive.state.index[idx].fileHash == work.parentEntry.fileHash,
              let prior = priorFile(for: work),
              let result = relink(work) else { return nil }
        let preIndex = archive.state.index
        archive.state.index[idx] = Self.relinked(archive.state.index[idx], result: result)
        do {
            try archive.state.saveIndex()
        } catch {
            debugLog("[Archive] ⚠️ Failed to save index after re-linking \(result.sessionId.uuidString.prefix(8)) — previous file restored: \(error)", level: .warning)
            archive.store.rollBackWrite(to: preIndex, filePath: work.fileURL, prior: prior, id: result.sessionId)
            return nil
        }
        return result
    }

    /// The parent's file as it is before the rewrite, for the rollback. Nil
    /// (night skipped) when it cannot be read.
    private func priorFile(for work: RelinkWork) -> ArchiveStore.PriorFile? {
        do {
            return try ArchiveStore.PriorFile(at: work.fileURL, id: work.parentEntry.sessionId, fileManager: archive.fileManager)
        } catch {
            debugLog("[Archive] relinkSameNightSessions: cannot read \(work.parentEntry.sessionId.uuidString.prefix(8)) before rewriting it: \(error)", level: .warning)
            return nil
        }
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
            return try ArchiveStore.loadAndDecodeSessionFile(
                at: work.fileURL, decoder: SessionArchive.sessionDecoder, encryption: archive.encryption
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
            // to plaintext; `writeArchiveBytes` picks protection per the
            // format actually written and keeps the ledger in step with disk.
            let result = try SessionArchive.SessionFileCodec.encodeForDisk(session, encoder: Self.relinkEncoder, encryption: archive.encryption)
            try writeArchiveBytes(result.bytes, to: fileURL, format: result.format, sessionID: session.id)
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
    /// that contract. Its plaintext fallback is the codec's: an `encrypt`
    /// that throws is logged there, and the file is queued for re-encryption
    /// (`writeArchiveBytes`). The write also carries an explicit
    /// protection class, matching every other archive write site: `.atomic`
    /// alone replaces the file and drops the directory-inherited protection
    /// class (which makes reads fail with EPERM, see the note in
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
