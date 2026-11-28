import Foundation

/// Stateless service that encapsulates session recovery logic.
///
/// Kept apart from `RRCollector` so the recovery algorithms can be tested in
/// isolation; `RRCollector` forwards to it and updates its own observable
/// state.
@MainActor
final class SessionRecoveryService {
    // MARK: - Types

    /// What a recovery import would do to an archived session, as decided by
    /// `patchAction`. An enum rather than string matching keeps the decision
    /// tree exhaustive and impossible to break with a typo.
    enum PatchAction {
        case addMissingData
        case reanalyzeNoResult
        case reanalyzeNoFlags
        case replaceWithNewData(existingCount: Int, newCount: Int)
    }

    // MARK: - Dependencies

    let archive: SessionArchive
    let rawBackup: RawRRBackup
    let artifactDetector: ArtifactDetector
    let windowSelector: WindowSelector
    let cloudSyncManager: CloudKitSyncManager
    let baselineTracker: BaselineTracker
    /// The settings whose sleep schedule ranks a recovered night's window.
    let settingsManager: SettingsManager
    /// The Get Me Back history a permanently deleted session's route leaves.
    let breadcrumbStore: BreadcrumbStore
    /// Mirrors a recovered night to Apple Health when the user's export is on,
    /// as acceptance does (`SessionAcceptanceService.exportToHealthIfEnabled`).
    let exportToHealth: @Sendable (HRVSession) -> Void

    /// Trash restores under way (`SessionRecoveryCoordinator.restoreFromTrash`):
    /// a restore drops the deletion mark first and writes the session back
    /// only after rebuilding it, so in between the Trash expiry would still
    /// read it as expired (`isExpiryStillDue`).
    private(set) var restoresInProgress: Set<UUID> = []

    // MARK: - Initialization

    init(
        archive: SessionArchive,
        rawBackup: RawRRBackup,
        artifactDetector: ArtifactDetector,
        windowSelector: WindowSelector,
        cloudSyncManager: CloudKitSyncManager,
        baselineTracker: BaselineTracker,
        settingsManager: SettingsManager,
        breadcrumbStore: BreadcrumbStore,
        exportToHealth: @escaping @Sendable (HRVSession) -> Void = { _ in }
    ) {
        self.archive = archive
        self.rawBackup = rawBackup
        self.artifactDetector = artifactDetector
        self.windowSelector = windowSelector
        self.cloudSyncManager = cloudSyncManager
        self.baselineTracker = baselineTracker
        self.settingsManager = settingsManager
        self.breadcrumbStore = breadcrumbStore
        self.exportToHealth = exportToHealth
    }

    /// The recovery window for a crash-recovered
    /// session must be ranked against the rolling baseline, exactly like the
    /// morning analyze and reanalyze paths. Same flag so all three
    /// stay in lockstep; `nil` falls back to raw-RMSSD ranking. The session's
    /// own night is left out, as the scorer leaves it out.
    private func windowBaselineStats(for session: HRVSession) -> BaselineTracker.RecoveryBaselineStats? {
        baselineTracker.recoveryBaselineStats(
            excludingNightOf: session,
            sleepSchedule: settingsManager.settings.sleepSchedule
        )
    }

    // MARK: - Patch Decision

    /// Decide what a recovery import of `incomingPoints` would do to an
    /// archived session.
    ///
    /// Pure and exhaustive — no string matching, no I/O — so every branch is
    /// reachable from a test.
    ///
    /// "Same data" means the same beat count with first and last timestamps
    /// within a second of each other. Re-importing identical data is only
    /// worth doing when something downstream is missing: no analysis result, or
    /// no artifact flags. If both are present the import is a genuine no-op and
    /// the caller is told so rather than silently redoing the work.
    static func patchAction(
        existingRR: RRSeries?,
        incomingPoints: [RRPoint],
        hasAnalysisResult: Bool,
        hasArtifactFlags: Bool
    ) throws -> PatchAction {
        guard let existingRR, !existingRR.points.isEmpty else {
            return .addMissingData
        }
        let existingCount = existingRR.points.count
        let newCount = incomingPoints.count

        guard isSameData(existingRR.points, incomingPoints) else {
            return .replaceWithNewData(existingCount: existingCount, newCount: newCount)
        }
        if !hasAnalysisResult { return .reanalyzeNoResult }
        if !hasArtifactFlags { return .reanalyzeNoFlags }
        throw RRCollector.CollectorError.dataAlreadyExists
    }

    /// Whether two beat series are the same recording: the same beat count,
    /// with first and last timestamps within a second of each other.
    ///
    /// Written inline in `patchAction` as one
    /// three-term `&&` chain it costs ~2 s to type-check on a CI runner —
    /// `abs((a?.t_ms ?? 0) - (b?.t_ms ?? 0)) < 1000` gives the checker two
    /// optional-coalesces, a subtraction, an `abs` overload set and two untyped
    /// integer literals to solve at once, three times over. Annotating each
    /// value makes every line a separate, trivial problem.
    private static func isSameData(_ existing: [RRPoint], _ incoming: [RRPoint]) -> Bool {
        guard existing.count == incoming.count else { return false }
        let toleranceMs: Int64 = 1000
        let firstExisting: Int64 = existing.first?.t_ms ?? 0
        let firstIncoming: Int64 = incoming.first?.t_ms ?? 0
        let lastExisting: Int64 = existing.last?.t_ms ?? 0
        let lastIncoming: Int64 = incoming.last?.t_ms ?? 0
        return abs(firstExisting - firstIncoming) < toleranceMs
            && abs(lastExisting - lastIncoming) < toleranceMs
    }

    // MARK: - Lost Session Detection

    /// Minimum beat count required for HRV analysis to succeed. Backups
    /// below this can never become a recovered session — listing them
    /// would loop the user through "Recover All → fails → still shown" —
    /// so they are kept but not listed.
    /// Keep in sync with `stopSession`'s `rrPoints.count >= 120` guard.
    static let minRecoverableBeatCount = 120

    /// Rate-limit pullCloudBackupsToLocal — running it on every scan
    /// causes the "never ends" loop where the list re-populates from
    /// iCloud after each recovery pass.
    private static let cloudPullMinInterval: TimeInterval = 300
    private static let cloudPullKey = "sessionRecoveryLastCloudPull"

    /// Backups with no archive entry. `live` are the recordings still in
    /// progress: they have a backup and no entry yet, and are left out before
    /// anything is discarded, or a recording under two minutes old lost its
    /// crash-safety backup here. A recording the archive folded into another
    /// night (`SessionArchive.foldedRecordingIds`) has no entry of its own
    /// either, but its beats are in that night: it is not lost, and
    /// recovering it would merge the same beats in again.
    func checkForLostSessions(excluding live: Set<UUID> = []) async -> [(id: UUID, date: Date, beatCount: Int)] {
        await checkForLostSessions(excludingLive: { live })
    }

    /// `liveIds` is read after the iCloud pull, which can wait on the network
    /// for seconds: a recording started meanwhile writes its first backup at
    /// once, and with the set read before the wait that backup would be
    /// listed as lost while it records.
    func checkForLostSessions(excludingLive liveIds: () -> Set<UUID>) async -> [(id: UUID, date: Date, beatCount: Int)] {
        await pullCloudBackupsToLocalIfDue(excludingLive: liveIds)
        let orphans = unarchivedBackups(excluding: liveIds())
        let counts = beatCounts(of: orphans)
        // Backups too short to analyze, counted after a fuller file of them
        // is adopted, are not listed, as recovering one cannot succeed. They
        // are kept, with their iCloud copies: no size rule deletes recorded
        // beats the user did not choose to delete.
        let lost = orphans.compactMap { orphan -> (id: UUID, date: Date, beatCount: Int)? in
            guard let count = counts[orphan.id], count >= Self.minRecoverableBeatCount else { return nil }
            return (id: orphan.id, date: orphan.captureDate, beatCount: count)
        }
        if !lost.isEmpty { debugLog("[SessionRecoveryService] Found \(lost.count) lost sessions with backups") }
        return lost
    }

    /// Backups with no archived or deleted session, other than the live ones.
    private func unarchivedBackups(excluding live: Set<UUID>) -> [RawRRBackup.BackupEntry] {
        let archivedIds = Set(archive.store.entries.map(\.sessionId)).union(archive.foldedRecordingIds)
        let deletedIds = archive.store.deletedIds
        return rawBackup.allBackups().filter {
            !archivedIds.contains($0.id) && !deletedIds.contains($0.id) && !live.contains($0.id)
        }
    }

    /// Each lost backup's beat count. One below `minRecoverableBeatCount` is
    /// counted after a fuller file of it is adopted
    /// (`beatCountAfterAdoptingFullerFile`), and is left out when that
    /// adoption failed, so it is not listed this scan.
    private func beatCounts(of orphans: [RawRRBackup.BackupEntry]) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for orphan in orphans {
            counts[orphan.id] = orphan.beatCount >= Self.minRecoverableBeatCount
                ? orphan.beatCount
                : beatCountAfterAdoptingFullerFile(orphan.id, indexed: orphan.beatCount)
        }
        return counts
    }

    /// The beats a short backup holds once the fullest one-shot file of the
    /// session the index does not name, when it holds more, becomes its
    /// backup (`OneShotBackupName.fullerUnindexedBackup`, `RawRRBackup.backup`).
    /// A night whose index row is short but whose file is full is listed
    /// this way. `indexed` when
    /// there is no row or no fuller file; nil (logged) when a fuller file
    /// could not be read or adopted.
    private func beatCountAfterAdoptingFullerFile(_ id: UUID, indexed: Int) -> Int? {
        let row = rawBackup.indexLock.withLock { rawBackup.index.first { $0.id == id } }
        guard let row else { return indexed }
        do {
            guard let fuller = try OneShotBackupName.fullerUnindexedBackup(than: row, in: rawBackup.backupDirectory, encryption: rawBackup.encryption) else { return indexed }
            try rawBackup.backup(points: fuller.points, sessionId: id, deviceId: fuller.deviceId, captureDate: fuller.captureDate)
            return fuller.points.count
        } catch {
            debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} A fuller backup of \(id.uuidString.prefix(8)) could not be adopted: \(error) — keeping it", level: .error)
            return nil
        }
    }

    /// Pull iCloud backups, but no more than once per `cloudPullMinInterval`.
    /// Prevents the Lost Sessions loop where every scan re-seeds from cloud.
    /// Only a pull that read iCloud starts the wait: one that failed (offline,
    /// iCloud busy) or was not made (sync off) is tried again at the next
    /// scan, not five minutes later with the user's backups unseen.
    private func pullCloudBackupsToLocalIfDue(excludingLive liveIds: () -> Set<UUID>) async {
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: Self.cloudPullKey)
        let now = Date().timeIntervalSince1970
        if last > 0, now - last < Self.cloudPullMinInterval {
            return
        }
        if await pullCloudBackupsToLocal(excludingLive: liveIds) {
            defaults.set(now, forKey: Self.cloudPullKey)
        }
    }

    /// Pull iCloud backups that don't exist locally, with no recording known
    /// to be in progress. Prefer `pullCloudBackupsToLocal(excluding:)`.
    @discardableResult
    func pullCloudBackupsToLocal() async -> Bool {
        await pullCloudBackupsToLocal(excluding: [])
    }

    /// Pull iCloud backups that don't exist locally. A recording still in
    /// progress (`live`) is left alone in iCloud — its live backup is the
    /// crash-safety copy. A backup of a session the user deleted, or deleted
    /// forever, is not brought back: its cloud copy is retired again (the
    /// first delete may have failed or run with iCloud sync off).
    ///
    /// Returns whether iCloud was read; false when sync is off or the read
    /// failed (logged), which is not the same as iCloud holding no backups.
    @discardableResult
    func pullCloudBackupsToLocal(excluding live: Set<UUID>) async -> Bool {
        await pullCloudBackupsToLocal(excludingLive: { live })
    }

    /// `liveIds` is read once iCloud has answered, so a recording started
    /// during the read is left alone too.
    @discardableResult
    func pullCloudBackupsToLocal(excludingLive liveIds: () -> Set<UUID>) async -> Bool {
        let cloudBackups: [LiveBackupSummary]
        do {
            guard let fetched = try await cloudSyncManager.fetchLiveBackups() else { return false }
            cloudBackups = fetched
        } catch {
            debugLog("[SessionRecoveryService] iCloud backups could not be read: \(error.localizedDescription) — tried again at the next scan", level: .warning)
            return false
        }
        seed(cloudBackups, excluding: liveIds())
        return true
    }

    /// Saves each pulled backup that holds beats no copy here has, and
    /// retires the cloud copy of each whose beats a copy here covers
    /// (`cloudBackupDisposition`).
    private func seed(_ cloudBackups: [LiveBackupSummary], excluding live: Set<UUID>) {
        let pulled = cloudBackups.filter { !live.contains($0.sessionId) }
        guard !pulled.isEmpty else { return }
        let holdings = cloudBackupHoldings(for: pulled.map(\.sessionId))
        for backup in pulled {
            switch Self.cloudBackupDisposition(of: backup.sessionId, beats: backup.beatCount, holdings: holdings) {
            case .retire: retireCloudBackup(backup.sessionId)
            case .save: savePulledBackup(backup)
            case .keep: continue
            }
        }
    }

    /// What this device holds of the sessions `ids` name. A recording folded
    /// into a night the user deleted counts as removed with that night.
    private func cloudBackupHoldings(for ids: [UUID]) -> CloudBackupHoldings {
        let deleted = archive.store.deletedIds.union(ForgottenSessions.ids)
        let removed = Set(ids.filter { deleted.contains($0) || deleted.contains(archive.archivedId(of: $0)) })
        let local = rawBackup.allBackups().map { ($0.id, $0.beatCount) }
        return CloudBackupHoldings(
            removed: removed,
            archivedNightBeats: archivedNightBeats(of: ids.filter { !removed.contains($0) }),
            localBeats: Dictionary(local, uniquingKeysWith: max),
            uploadedHere: cloudSyncManager.liveBackupsUploadedHere
        )
    }

    /// The beats of the archived night each recording is kept in, under its
    /// own id or the night it was folded into (`SessionArchive.archivedId`),
    /// for the recordings the archive holds; nil for a night that could not
    /// be read, which then covers nothing.
    private func archivedNightBeats(of ids: [UUID]) -> [UUID: Int?] {
        var beats: [UUID: Int?] = [:]
        for id in ids where archive.holdsNight(id) {
            let night = archive.retrieveOrLog(archive.archivedId(of: id), caller: "SessionRecoveryService.archivedNightBeats")
            beats[id] = night.map { $0.rrSeries?.points.count ?? 0 }
        }
        return beats
    }

    /// What this device knows of the sessions behind iCloud's live backups.
    struct CloudBackupHoldings {
        /// Deleted, or deleted forever, here, directly or with the night the
        /// recording was folded into.
        let removed: Set<UUID>
        /// The beats of the archived night holding each recording the archive
        /// holds; nil when that night could not be read.
        let archivedNightBeats: [UUID: Int?]
        /// The beats of each local raw backup, this device's own or pulled.
        let localBeats: [UUID: Int]
        /// Sessions whose iCloud backup this device uploaded.
        let uploadedHere: Set<UUID>
    }

    /// What a scan does with one iCloud live backup.
    enum CloudBackupDisposition: Equatable {
        /// Delete the iCloud copy.
        case retire
        /// Save it as a local raw backup, over a smaller one, and keep the
        /// iCloud copy.
        case save
        /// Leave both copies as they are.
        case keep
    }

    /// Decided by what each copy holds (`FullerCopy`), never by which copy
    /// exists. A night the user removed has its backup retired. An archived
    /// night retires it only when the night holds as many beats: a night
    /// recovered from an early pull of another device's backup is a fragment,
    /// and the later, fuller backup is saved here and kept in iCloud until the
    /// night holds its beats. A local backup with fewer beats than iCloud's is
    /// replaced by it. One that covers it retires it only when this device
    /// uploaded it; another device's backup is that recording's crash-safety
    /// copy and stays until its night is archived. A backup no copy here
    /// holds is saved for recovery, unless it is another device's below the
    /// recovery floor, which the scan would only discard again.
    static func cloudBackupDisposition(of id: UUID, beats: Int, holdings: CloudBackupHoldings) -> CloudBackupDisposition {
        if holdings.removed.contains(id) { return .retire }
        if let night = holdings.archivedNightBeats[id] {
            if FullerCopy.covers(night, beats) { return .retire }
            return FullerCopy.covers(holdings.localBeats[id], beats) ? .keep : .save
        }
        guard let local = holdings.localBeats[id] else {
            if beats >= minRecoverableBeatCount { return .save }
            if holdings.uploadedHere.contains(id) { return .retire }
            return .keep
        }
        guard FullerCopy.covers(local, beats) else { return .save }
        return holdings.uploadedHere.contains(id) ? .retire : .keep
    }

    /// A copy here covers it, or its night was removed: the iCloud copy goes.
    private func retireCloudBackup(_ sessionId: UUID) {
        Task { await cloudSyncManager.deleteLiveBackup(sessionId: sessionId) }
    }

    /// Dated by the recording's start (`LiveBackupSummary.sessionStart`):
    /// recovery takes the local backup's capture date as the session start.
    private func savePulledBackup(_ backup: LiveBackupSummary) {
        do {
            try rawBackup.backup(points: backup.points, sessionId: backup.sessionId, deviceId: nil, captureDate: backup.sessionStart)
            debugLog("[SessionRecoveryService] \u{2601}\u{fe0f} Pulled \(backup.beatCount) beats from iCloud (session \(backup.sessionId.uuidString.prefix(8)))")
        } catch {
            debugLog("[SessionRecoveryService] \u{274c} Failed to save iCloud backup locally: \(error)")
        }
    }

    /// Check for sessions that were intentionally deleted but still have backups.
    func checkForDeletedSessions() -> [(id: UUID, date: Date, beatCount: Int)] {
        let deletedIds = archive.store.deletedIds
        let allBackups = rawBackup.allBackups()

        var deleted: [(id: UUID, date: Date, beatCount: Int)] = []
        for backup in allBackups where deletedIds.contains(backup.id) {
            deleted.append((id: backup.id, date: backup.captureDate, beatCount: backup.beatCount))
        }
        return deleted + keptWithoutBackup(deletedIds: deletedIds, listed: Set(deleted.map(\.id)))
    }

    /// Deleted sessions the trash holds a file for but no raw backup covers,
    /// such as imported workouts, which never had one and so never appeared
    /// in the trash at all.
    private func keptWithoutBackup(deletedIds: Set<UUID>, listed: Set<UUID>) -> [(id: UUID, date: Date, beatCount: Int)] {
        archive.store.trashedIds.intersection(deletedIds).subtracting(listed).compactMap { id in
            archive.store.trashedSession(id).map { (id: id, date: $0.startDate, beatCount: $0.rrSeries?.points.count ?? 0) }
        }
    }

    /// Unmark a session as deleted so it can be recovered.
    ///
    /// iCloud is told as well: its record is a tombstone, and the upload that
    /// follows has to replace it rather than yield to it — otherwise the next
    /// sync deleted the session again.
    func restoreFromTrash(_ sessionId: UUID) {
        cloudSyncManager.trashRestore.noteRestored(sessionId)
        do {
            try archive.store.unmarkAsDeleted(sessionId)
        } catch {
            debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} Failed to unmark session \(sessionId.uuidString.prefix(8)) as deleted: \(error)")
        }
    }

    /// The backup behind a Trash entry could not be read back. Puts the
    /// deletion mark back that `restoreFromTrash` removed, so the entry stays
    /// in the Trash exactly as before instead of leaving it with nothing
    /// archived.
    func restoreFromTrashFailed(_ sessionId: UUID) {
        cloudSyncManager.trashRestore.abandon(sessionId)
        do {
            try archive.store.markAsDeleted(sessionId)
        } catch {
            debugLog("[SessionRecoveryService] Failed to re-mark session \(sessionId.uuidString.prefix(8)) as deleted after a failed restore: \(error)", level: .error)
        }
    }

    /// The span a deleted session's recording covers, which its Apple Health
    /// export lies in: its trashed file's start and end, or its raw backup's
    /// capture date and last beat. Nil for a session the archive holds, and
    /// for one with neither (nothing dates it).
    func deletedSessionSpan(_ sessionId: UUID) -> ClosedRange<Date>? {
        guard !archive.store.exists(sessionId) else { return nil }
        if let kept = archive.store.trashedSession(sessionId) {
            return kept.startDate ... max(kept.startDate, kept.endDate ?? kept.startDate)
        }
        guard let backup = storedBackup(sessionId) else { return nil }
        return backup.captureDate ... max(backup.captureDate, Self.backupEndDate(backup) ?? backup.captureDate)
    }

    /// Permanently delete a session from the Trash. True when nothing of it
    /// is left on this device; false (logged) when something could not be
    /// removed, and it then stays in the Trash to be deleted again.
    ///
    /// Removed in order, stopping at the first failure: the route its
    /// workout filed in the breadcrumb history, its trashed file (and any
    /// `<id>.json` a failed delete left), and its raw backup. The Trash lists
    /// a deleted session while it has a trashed file or a backup, so a
    /// failure leaves it listed. Then the id is remembered as deleted forever
    /// (`ForgottenSessions`), so neither pull brings back a copy iCloud still
    /// holds, and the iCloud live backup is deleted. The deletion mark is
    /// dropped only once iCloud has confirmed the deletion or this device has
    /// never synced (`CloudDeletionCoordinator.tombstoneIsSettled`); until
    /// then the full sync keeps sending it, and confirming it drops the mark.
    ///
    /// A session the archive holds (restored, or brought back by a pull) is
    /// not deleted: only a stray Trash file of it is removed.
    @discardableResult
    func permanentlyDelete(_ sessionId: UUID) -> Bool {
        guard !archive.store.exists(sessionId) else { return archive.store.discardTrashed(sessionId) }
        guard removeLocalCopies(of: sessionId) else { return false }
        ForgottenSessions.remember(sessionId)
        Task { await cloudSyncManager.deleteLiveBackup(sessionId: sessionId) }
        forgetDeletionIfSettled(sessionId)
        return true
    }

    func beginRestore(_ sessionId: UUID) { restoresInProgress.insert(sessionId) }
    func endRestore(_ sessionId: UUID) { restoresInProgress.remove(sessionId) }

    /// Whether the Trash expiry may still delete `sessionId` for good now:
    /// no restore of it is under way, and the archive, asked under its lock,
    /// still holds it as an expired deletion.
    func isExpiryStillDue(_ sessionId: UUID) -> Bool {
        !restoresInProgress.contains(sessionId) && archive.store.isStillExpiredDeletion(sessionId)
    }

    /// Deletes each session forever (`permanentlyDelete(_:)`), then hands
    /// the span its recording covered (`deletedSessionSpan`) to
    /// `removeHealthSamples`, which deletes what it exported to Apple Health
    /// and says whether that worked. That runs only after the local delete
    /// succeeded and never undoes it: a failure there is counted, and the
    /// session is gone from the Trash either way.
    ///
    /// `stillDue` is asked for each id at its turn, on the main actor with
    /// the delete that follows, so nothing starts in between; an id it
    /// refuses is left as it is (the Trash expiry passes `isExpiryStillDue`).
    func permanentlyDelete(
        _ ids: [UUID], stillDue: (UUID) -> Bool = { _ in true }, removeHealthSamples: (UUID, ClosedRange<Date>) async -> Bool
    ) async -> TrashDeletionOutcome {
        var outcome = TrashDeletionOutcome()
        for id in ids {
            guard stillDue(id) else { continue }
            let span = deletedSessionSpan(id)
            guard permanentlyDelete(id) else {
                outcome.kept += 1
                continue
            }
            if let span, !(await removeExports(of: id, over: span, with: removeHealthSamples)) { outcome.healthSamplesKept += 1 }
        }
        return outcome
    }

    /// What the session exported to Apple Health, and what each recording
    /// kept under it (`SessionArchive.idsKept(under:)`) exported under its
    /// own id before it was folded in. True when all of it went.
    private func removeExports(
        of id: UUID, over span: ClosedRange<Date>, with remove: (UUID, ClosedRange<Date>) async -> Bool
    ) async -> Bool {
        var removed = await remove(id, span)
        for kept in archive.idsKept(under: id) {
            let keptRemoved = await remove(kept, span)
            removed = removed && keptRemoved
        }
        return removed
    }

    /// The breadcrumb route, the trashed file and the raw backup, in that
    /// order; false at the first that could not be removed.
    private func removeLocalCopies(of sessionId: UUID) -> Bool {
        guard breadcrumbStore.removeTrails(ofSession: sessionId) else {
            debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} The route of \(sessionId.uuidString.prefix(8)) could not be removed from the breadcrumb history — keeping it in the Trash", level: .error)
            return false
        }
        guard archive.store.discardTrashed(sessionId) else { return false }
        do {
            try rawBackup.discardBackup(sessionId)
            try discardBackupsKept(under: sessionId)
            return true
        } catch {
            debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} Failed to discard the backup of \(sessionId.uuidString.prefix(8)): \(error) — keeping it in the Trash", level: .error)
            return false
        }
    }

    /// The backups of the recordings folded into the session, and of the
    /// copies retired into it (`SessionArchive.idsKept(under:)`): their beats
    /// are the session's, so deleting it forever deletes them too, and none
    /// is left on the device under its old id.
    private func discardBackupsKept(under sessionId: UUID) throws {
        for id in archive.idsKept(under: sessionId) {
            try rawBackup.discardBackup(id)
        }
    }

    private func forgetDeletionIfSettled(_ sessionId: UUID) {
        guard cloudSyncManager.deletion.tombstoneIsSettled(sessionId) else { return }
        do {
            try archive.forgetDeletedSession(sessionId)
        } catch {
            debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} Failed to drop the deletion mark of \(sessionId.uuidString.prefix(8)): \(error)", level: .warning)
        }
    }

    /// Mark sessions as intentionally deleted. Returns the ids whose mark was
    /// stored; an id whose mark could not be saved is left out (and stays a
    /// lost session), so the caller removes only what was really dismissed.
    @discardableResult
    func deleteLostSessions(_ sessionIds: [UUID]) -> Set<UUID> {
        var marked: Set<UUID> = []
        for id in sessionIds {
            do {
                try archive.store.markAsDeleted(id)
                marked.insert(id)
            } catch {
                debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} Failed to mark session \(id.uuidString.prefix(8)) as deleted: \(error)")
            }
        }
        debugLog("[SessionRecoveryService] Marked \(marked.count) of \(sessionIds.count) lost sessions as deleted")
        return marked
    }

    // MARK: - Shared Backup Helpers

    /// Result of retrieving a backup and optionally merging parent data.
    struct BackupData {
        let backup: RawRRBackup.BackupEntry
        let series: RRSeries
        let flags: [ArtifactFlags]
        let sessionStart: Date
        let endDate: Date?
    }

    /// Artifact detection runs off the main actor: it walks every beat of
    /// the night (28,000 and more), and recovery runs it from the launch
    /// alert and for each backup "Recover All" goes through.
    func retrieveBackupWithParentMerge(_ sessionId: UUID) async -> BackupData? {
        guard let backup = storedBackup(sessionId) else { return nil }
        let (allPoints, sessionStart) = pointsOnParentClock(backup, sessionId: sessionId)
        let series = RRSeries(points: allPoints, sessionId: sessionId, startDate: sessionStart)
        return BackupData(
            backup: backup,
            series: series,
            flags: await detectedArtifacts(in: series),
            sessionStart: sessionStart,
            endDate: Self.backupEndDate(backup)
        )
    }

    /// A resumed segment's backup with its parent's beats in front, on the
    /// parent's clock; the backup as it is for a session with no parent.
    /// A backup that already holds the parent (`backupHoldsParent`) is not
    /// merged again.
    func pointsOnParentClock(_ backup: RawRRBackup.BackupEntry, sessionId: UUID) -> (points: [RRPoint], start: Date) {
        guard let parent = parentSession(of: sessionId, endingAt: Self.backupEndDate(backup) ?? backup.captureDate),
              let parentSeries = parent.rrSeries, !parentSeries.points.isEmpty else { return (backup.points, backup.captureDate) }
        let points = Self.parentMergedPoints(
            parentSeries: parentSeries, parentStart: parent.startDate,
            childPoints: backup.points, childStart: backup.captureDate
        )
        debugLog("[SessionRecoveryService] Parent \(parent.id.uuidString.prefix(8)) on the clock of \(sessionId.uuidString.prefix(8)): \(points.count) beats from a backup of \(backup.beatCount)")
        return (points, parent.startDate)
    }

    /// The series' artifact flags, detected off the main actor.
    private func detectedArtifacts(in series: RRSeries) async -> [ArtifactFlags] {
        let detector = artifactDetector
        return await Task.detached(priority: .userInitiated) {
            detector.detectArtifacts(in: series)
        }.value
    }

    /// The parent's beats followed by the child's, re-based onto the
    /// parent's clock. The child's offsets count from its own capture date,
    /// so they are shifted by the larger of the parent's recorded duration
    /// and the gap between the two start dates — the same rule the other
    /// pause/resume merges use — so the resumed half lands after the first
    /// instead of on top of it. Points that already hold the parent
    /// (`backupHoldsParent`) are returned as they are.
    nonisolated static func parentMergedPoints(
        parentSeries: RRSeries,
        parentStart: Date,
        childPoints: [RRPoint],
        childStart: Date
    ) -> [RRPoint] {
        guard !backupHoldsParent(childPoints: childPoints, childStart: childStart, parentSeries: parentSeries, parentStart: parentStart) else {
            return childPoints
        }
        let parentDurationMs = parentSeries.points.last?.endMs ?? 0
        let dateOffsetMs = MillisecondOffset.between(childStart, and: parentStart, fallback: 0)
        let offsetMs = max(parentDurationMs, dateOffsetMs)
        return parentSeries.points + childPoints.map { $0.shifted(by: offsetMs) }
    }

    /// Whether a resumed segment's backup already holds its parent's beats,
    /// so merging the parent in again would put them in twice. A pause, a
    /// stop or a merge repair writes the merged night over the segment's
    /// backup (`MorningProcessingService.backupRawDataAsync`), and an app
    /// killed before that night is archived leaves the merged backup for
    /// recovery. Such a backup is marked twice: it counts from the parent's
    /// start, while a segment's own beats count from its resume, always after
    /// the parent began (`childStart` up to `parentClockTolerance` past it,
    /// the second a stored date may lose); and its points begin with the
    /// parent's.
    nonisolated static func backupHoldsParent(
        childPoints: [RRPoint], childStart: Date, parentSeries: RRSeries, parentStart: Date
    ) -> Bool {
        if childStart <= parentStart.addingTimeInterval(parentClockTolerance) { return true }
        return beginsWithParent(childPoints, parentPoints: parentSeries.points)
    }

    /// A stored capture date keeps whole seconds; a resume is never within a
    /// second of its parent's start.
    nonisolated static let parentClockTolerance: TimeInterval = 1

    /// Whether `points` begin with every one of the parent's beats, at the
    /// same offsets: the parent's beats are already in them.
    nonisolated static func beginsWithParent(_ points: [RRPoint], parentPoints: [RRPoint]) -> Bool {
        guard !parentPoints.isEmpty, points.count >= parentPoints.count else { return false }
        return zip(points, parentPoints).allSatisfy { $0.t_ms == $1.t_ms && $0.rr_ms == $1.rr_ms }
    }

    /// The raw-RR backup for a session, or nil when there isn't one or it
    /// can't be read.
    func storedBackup(_ sessionId: UUID) -> RawRRBackup.BackupEntry? {
        do {
            guard let retrieved = try rawBackup.retrieve(sessionId) else {
                debugLog("[SessionRecoveryService] No backup found for session \(sessionId)")
                return nil
            }
            return retrieved
        } catch {
            debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} Failed to retrieve backup for session \(sessionId): \(error)")
            return nil
        }
    }

    /// The session this one is a pause/resume child of, if any
    /// (`SessionLinks.isResumeParent`). Other sessions list it too: the
    /// segment resumed from it, and a night that holds its beats. Neither is
    /// its parent, and putting either's beats in front of its own would
    /// place them twice. `childEnd` dates a child with no archive entry.
    func parentSession(of sessionId: UUID, endingAt childEnd: Date) -> HRVSession? {
        let entries = archive.store.entries
        let child = entries.first { $0.sessionId == sessionId }.map(SessionLinks.Node.init)
        guard let entry = entries.first(where: { Self.isResumeParent($0, of: sessionId, child: child, childEnd: childEnd) }) else {
            return nil
        }
        do {
            return try archive.retrieve(entry.sessionId)
        } catch {
            debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} Failed to retrieve parent session \(entry.sessionId): \(error)")
            return nil
        }
    }

    /// Whether `entry` is the resume parent of `sessionId`: read against the
    /// child's own entry when it has one, else against its backup's end.
    nonisolated static func isResumeParent(
        _ entry: SessionArchiveEntry, of sessionId: UUID, child: SessionLinks.Node?, childEnd: Date
    ) -> Bool {
        let parent = SessionLinks.Node(entry)
        guard let child else { return SessionLinks.isResumeParent(parent, ofUnarchived: sessionId, childEnd: childEnd) }
        return SessionLinks.isResumeParent(parent, of: child)
    }

    /// Where the backup's own beats run out, relative to its capture date,
    /// on the real clock (`[RRPoint].lastBeatEnd(after:)`): a streamed
    /// backup's `t_ms` stops at every dropout, and the span a deleted
    /// session's Apple Health export is searched in ended that early.
    static func backupEndDate(_ backup: RawRRBackup.BackupEntry) -> Date? {
        backup.points.lastBeatEnd(after: backup.captureDate)
    }

    /// Run windowed analysis on a session, updating its analysisResult in place.
    ///
    /// Window selection, the heaviest pass over the night, runs off the main
    /// actor, as the morning and reanalysis paths run it. When no window
    /// qualifies (a short, noisy or pre-sleep backup), the whole series is
    /// analysed, as those paths fall back; without it such a backup could
    /// never be recovered and stayed listed in Lost Sessions for good.
    func analyzeSession(
        _ session: inout HRVSession,
        series: RRSeries,
        flags: [ArtifactFlags],
        analyze: (_ session: HRVSession, _ window: WindowSelector.RecoveryWindow, _ flags: [ArtifactFlags], _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        analyzeWithCapacity: (_ session: HRVSession, _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?
    ) async {
        let baseline = windowBaselineStats(for: session)
        let selector = windowSelector
        let selection = await Task.detached(priority: .userInitiated) {
            selector.findBestWindowWithCapacity(in: series, flags: flags, baselineStats: baseline)
        }.value
        guard let windowResult = selection else {
            debugLog("[SessionRecoveryService] No qualifying window in the backup — falling back to full-session analysis")
            session.analysisResult = await analyzeWithCapacity(session, nil)
            return
        }
        if let recoveryWindow = windowResult.recoveryWindow {
            session.analysisResult = await analyze(session, recoveryWindow, flags, windowResult.peakCapacity)
        } else {
            session.analysisResult = await analyzeWithCapacity(session, windowResult.peakCapacity)
        }
    }
}

/// What deleting sessions from the Trash for good achieved
/// (`SessionRecoveryService.permanentlyDelete(_:removeHealthSamples:)`), for
/// the Trash to report.
struct TrashDeletionOutcome: Equatable, Sendable {
    /// Sessions something of which could not be removed from this device;
    /// they stay in the Trash.
    var kept = 0
    /// Sessions removed from this device whose Apple Health exports (heart
    /// rate, HRV, sleep or workouts) could not all be deleted.
    var healthSamplesKept = 0
}
