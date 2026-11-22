import Foundation

/// Stateless service that encapsulates session recovery logic.
///
/// Extracted from `RRCollector+Recovery.swift` so the recovery algorithms
/// can be tested in isolation. `RRCollector` keeps thin wrapper methods
/// that forward to this service and update its own observable state.
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

    // MARK: - Initialization

    init(
        archive: SessionArchive,
        rawBackup: RawRRBackup,
        artifactDetector: ArtifactDetector,
        windowSelector: WindowSelector,
        cloudSyncManager: CloudKitSyncManager,
        baselineTracker: BaselineTracker
    ) {
        self.archive = archive
        self.rawBackup = rawBackup
        self.artifactDetector = artifactDetector
        self.windowSelector = windowSelector
        self.cloudSyncManager = cloudSyncManager
        self.baselineTracker = baselineTracker
    }

    /// The recovery window for a crash-recovered
    /// session must be ranked against the rolling baseline, exactly like the
    /// morning analyze and reanalyze paths. Same flag so all three
    /// stay in lockstep; `nil` falls back to raw-RMSSD ranking. The session's
    /// own night is left out, as the scorer leaves it out.
    private func windowBaselineStats(for session: HRVSession) -> BaselineTracker.RecoveryBaselineStats? {
        baselineTracker.recoveryBaselineStats(
            excludingNightOf: session,
            sleepSchedule: AppDependencies.current.app.settingsManager.settings.sleepSchedule
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
    /// Split out of `patchAction`. Written inline as one
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
    /// below this can never become a recovered session — surfacing them
    /// would loop the user through "Recover All → fails → still shown".
    /// Keep in sync with `stopSession`'s `rrPoints.count >= 120` guard.
    private static let minRecoverableBeatCount = 120

    /// Rate-limit pullCloudBackupsToLocal — running it on every scan
    /// causes the "never ends" loop where the list re-populates from
    /// iCloud after each recovery pass.
    private static let cloudPullMinInterval: TimeInterval = 300
    private static let cloudPullKey = "sessionRecoveryLastCloudPull"

    /// Backups with no archive entry. `live` are the recordings still in
    /// progress: they have a backup and no entry yet, and are left out before
    /// anything is discarded, or a recording under two minutes old lost its
    /// crash-safety backup here.
    func checkForLostSessions(excluding live: Set<UUID> = []) async -> [(id: UUID, date: Date, beatCount: Int)] {
        await pullCloudBackupsToLocalIfDue(excluding: live)
        let archivedIds = Set(archive.entries.map(\.sessionId))
        let deletedIds = archive.deletedIds
        let orphans = rawBackup.allBackups().filter {
            !archivedIds.contains($0.id) && !deletedIds.contains($0.id) && !live.contains($0.id)
        }
        let counts = beatCounts(of: orphans)
        // Backups too short to analyze, counted after a fuller file of them
        // is adopted, are discarded permanently so they stop showing up on
        // every scan; the cloud copy goes too so another device doesn't
        // re-seed them. A pause/resume fragment an archived session links to
        // is kept: its beats belong to that night.
        let linkedIds = Set(archive.entries.flatMap { $0.linkedSessionIds ?? [] })
        discardUnrecoverable(orphans.map(\.id).filter { (counts[$0] ?? Int.max) < Self.minRecoverableBeatCount && !linkedIds.contains($0) })
        let lost = orphans.compactMap { orphan -> (id: UUID, date: Date, beatCount: Int)? in
            guard let count = counts[orphan.id], count >= Self.minRecoverableBeatCount else { return nil }
            return (id: orphan.id, date: orphan.captureDate, beatCount: count)
        }
        if !lost.isEmpty { debugLog("[SessionRecoveryService] Found \(lost.count) lost sessions with backups") }
        return lost
    }

    /// Each lost backup's beat count. One below `minRecoverableBeatCount` is
    /// counted after a fuller file of it is adopted
    /// (`beatCountAfterAdoptingFullerFile`), and is left out when that
    /// adoption failed, so it is neither discarded nor listed this scan.
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
    /// The discard removes every file of the session, so a night whose index
    /// row is short but whose file is full is kept this way. `indexed` when
    /// there is no row or no fuller file; nil (logged) when a fuller file
    /// could not be read or adopted.
    private func beatCountAfterAdoptingFullerFile(_ id: UUID, indexed: Int) -> Int? {
        let row = rawBackup.indexLock.withLock { rawBackup.index.first { $0.id == id } }
        guard let row else { return indexed }
        do {
            guard let fuller = try OneShotBackupName.fullerUnindexedBackup(than: row, in: rawBackup.backupDirectory) else { return indexed }
            try rawBackup.backup(points: fuller.points, sessionId: id, deviceId: fuller.deviceId, captureDate: fuller.captureDate)
            return fuller.points.count
        } catch {
            debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} A fuller backup of \(id.uuidString.prefix(8)) could not be adopted: \(error) — keeping it", level: .error)
            return nil
        }
    }

    private func discardUnrecoverable(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        debugLog("[SessionRecoveryService] Auto-discarding \(ids.count) backup(s) below \(Self.minRecoverableBeatCount)-beat recovery floor")
        for id in ids {
            do {
                try rawBackup.discardBackup(id)
            } catch {
                // Keep the iCloud copy while the local one stays, so the two
                // do not diverge; the next scan tries both again.
                debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} Failed to discard unrecoverable backup \(id.uuidString.prefix(8)): \(error)")
                continue
            }
            Task { await cloudSyncManager.deleteLiveBackup(sessionId: id) }
        }
    }

    /// Pull iCloud backups, but no more than once per `cloudPullMinInterval`.
    /// Prevents the Lost Sessions loop where every scan re-seeds from cloud.
    private func pullCloudBackupsToLocalIfDue(excluding live: Set<UUID>) async {
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: Self.cloudPullKey)
        let now = Date().timeIntervalSince1970
        if last > 0, now - last < Self.cloudPullMinInterval {
            return
        }
        await pullCloudBackupsToLocal(excluding: live)
        defaults.set(now, forKey: Self.cloudPullKey)
    }

    /// Pull iCloud backups that don't exist locally, with no recording known
    /// to be in progress. Prefer `pullCloudBackupsToLocal(excluding:)`.
    func pullCloudBackupsToLocal() async {
        await pullCloudBackupsToLocal(excluding: [])
    }

    /// Pull iCloud backups that don't exist locally. A recording still in
    /// progress (`live`) is left alone in iCloud — its live backup is the
    /// crash-safety copy. A backup of a session the user deleted, or deleted
    /// forever, is not brought back: its cloud copy is retired again (the
    /// first delete may have failed or run with iCloud sync off).
    func pullCloudBackupsToLocal(excluding live: Set<UUID>) async {
        let cloudBackups = await cloudSyncManager.fetchLiveBackups()
        guard !cloudBackups.isEmpty else { return }
        let retired = Set(archive.entries.map(\.sessionId))
            .union(rawBackup.allBackups().map(\.id))
            .union(archive.deletedIds)
            .union(ForgottenSessions.ids)
        for backup in cloudBackups where !live.contains(backup.sessionId) {
            if retired.contains(backup.sessionId) { retireCloudBackup(backup.sessionId) } else { savePulledBackup(backup) }
        }
    }

    /// Already have it locally — retire the cloud copy.
    private func retireCloudBackup(_ sessionId: UUID) {
        Task { await cloudSyncManager.deleteLiveBackup(sessionId: sessionId) }
    }

    private func savePulledBackup(_ backup: LiveBackupSummary) {
        do {
            try rawBackup.backup(points: backup.points, sessionId: backup.sessionId, deviceId: nil, captureDate: backup.captureDate)
            debugLog("[SessionRecoveryService] \u{2601}\u{fe0f} Pulled \(backup.beatCount) beats from iCloud (session \(backup.sessionId.uuidString.prefix(8)))")
        } catch {
            debugLog("[SessionRecoveryService] \u{274c} Failed to save iCloud backup locally: \(error)")
        }
    }

    /// Check for sessions that were intentionally deleted but still have backups.
    func checkForDeletedSessions() -> [(id: UUID, date: Date, beatCount: Int)] {
        let deletedIds = archive.deletedIds
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
        archive.trashedIds.intersection(deletedIds).subtracting(listed).compactMap { id in
            archive.trashedSession(id).map { (id: id, date: $0.startDate, beatCount: $0.rrSeries?.points.count ?? 0) }
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
            try archive.unmarkAsDeleted(sessionId)
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
            try archive.markAsDeleted(sessionId)
        } catch {
            debugLog("[SessionRecoveryService] Failed to re-mark session \(sessionId.uuidString.prefix(8)) as deleted after a failed restore: \(error)", level: .error)
        }
    }

    /// The span a deleted session's recording covers, which its Apple Health
    /// export lies in: its trashed file's start and end, or its raw backup's
    /// capture date and last beat. Nil for a session the archive holds, and
    /// for one with neither (nothing dates it).
    func deletedSessionSpan(_ sessionId: UUID) -> ClosedRange<Date>? {
        guard !archive.exists(sessionId) else { return nil }
        if let kept = archive.trashedSession(sessionId) {
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
        guard !archive.exists(sessionId) else { return archive.discardTrashed(sessionId) }
        guard removeLocalCopies(of: sessionId) else { return false }
        ForgottenSessions.remember(sessionId)
        Task { await cloudSyncManager.deleteLiveBackup(sessionId: sessionId) }
        forgetDeletionIfSettled(sessionId)
        return true
    }

    /// Deletes each session forever (`permanentlyDelete(_:)`), then hands
    /// the span its recording covered (`deletedSessionSpan`) to
    /// `removeHealthSamples`, which deletes what it exported to Apple Health
    /// and says whether that worked. That runs only after the local delete
    /// succeeded and never undoes it: a failure there is counted, and the
    /// session is gone from the Trash either way.
    func permanentlyDelete(
        _ ids: [UUID], removeHealthSamples: (UUID, ClosedRange<Date>) async -> Bool
    ) async -> TrashDeletionOutcome {
        var outcome = TrashDeletionOutcome()
        for id in ids {
            let span = deletedSessionSpan(id)
            guard permanentlyDelete(id) else {
                outcome.kept += 1
                continue
            }
            if let span, !(await removeHealthSamples(id, span)) { outcome.healthSamplesKept += 1 }
        }
        return outcome
    }

    /// The breadcrumb route, the trashed file and the raw backup, in that
    /// order; false at the first that could not be removed.
    private func removeLocalCopies(of sessionId: UUID) -> Bool {
        guard AppDependencies.current.location.breadcrumbStore.removeTrails(ofSession: sessionId) else {
            debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} The route of \(sessionId.uuidString.prefix(8)) could not be removed from the breadcrumb history — keeping it in the Trash", level: .error)
            return false
        }
        guard archive.discardTrashed(sessionId) else { return false }
        do {
            try rawBackup.discardBackup(sessionId)
            return true
        } catch {
            debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} Failed to discard the backup of \(sessionId.uuidString.prefix(8)): \(error) — keeping it in the Trash", level: .error)
            return false
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

    /// Mark sessions as intentionally deleted.
    func deleteLostSessions(_ sessionIds: [UUID]) {
        for id in sessionIds {
            do {
                try archive.markAsDeleted(id)
            } catch {
                debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} Failed to mark session \(id.uuidString.prefix(8)) as deleted: \(error)")
            }
        }
        debugLog("[SessionRecoveryService] Marked \(sessionIds.count) lost sessions as deleted")
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
        var allPoints = backup.points
        var sessionStart = backup.captureDate
        if let parent = parentSession(of: sessionId),
           let parentSeries = parent.rrSeries, !parentSeries.points.isEmpty {
            allPoints = Self.parentMergedPoints(
                parentSeries: parentSeries, parentStart: parent.startDate,
                childPoints: backup.points, childStart: backup.captureDate
            )
            sessionStart = parent.startDate
            debugLog("[SessionRecoveryService] Merged parent \(parent.id.uuidString.prefix(8)): \(parentSeries.points.count) + \(backup.beatCount) beats")
        }
        let series = RRSeries(points: allPoints, sessionId: sessionId, startDate: sessionStart)
        return BackupData(
            backup: backup,
            series: series,
            flags: await detectedArtifacts(in: series),
            sessionStart: sessionStart,
            endDate: Self.backupEndDate(backup)
        )
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
    /// instead of on top of it.
    nonisolated static func parentMergedPoints(
        parentSeries: RRSeries,
        parentStart: Date,
        childPoints: [RRPoint],
        childStart: Date
    ) -> [RRPoint] {
        let parentDurationMs = parentSeries.points.last?.endMs ?? 0
        let dateOffsetMs = MillisecondOffset.between(childStart, and: parentStart, fallback: 0)
        let offsetMs = max(parentDurationMs, dateOffsetMs)
        return parentSeries.points + childPoints.map { $0.shifted(by: offsetMs) }
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

    /// The session this one is a pause/resume child of, if any.
    func parentSession(of sessionId: UUID) -> HRVSession? {
        guard let entry = archive.entries.first(where: { $0.linkedSessionIds?.contains(sessionId) == true }) else {
            return nil
        }
        do {
            return try archive.retrieve(entry.sessionId)
        } catch {
            debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} Failed to retrieve parent session \(entry.sessionId): \(error)")
            return nil
        }
    }

    /// Where the backup's own beats run out, relative to its capture date.
    static func backupEndDate(_ backup: RawRRBackup.BackupEntry) -> Date? {
        backup.points.last.map { backup.captureDate.addingTimeInterval(Double($0.t_ms) / 1000.0) }
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
    /// Sessions removed from this device whose HRV samples could not be
    /// deleted from Apple Health.
    var healthSamplesKept = 0
}
