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
        await pullCloudBackupsToLocalIfDue()
        let archivedIds = Set(archive.entries.map(\.sessionId))
        let deletedIds = archive.deletedIds
        let orphans = rawBackup.allBackups().filter {
            !archivedIds.contains($0.id) && !deletedIds.contains($0.id) && !live.contains($0.id)
        }
        // Backups too short to analyze are discarded permanently so they stop
        // showing up on every scan; the cloud copy goes too so another device
        // doesn't re-seed them.
        let unrecoverable = orphans.filter { $0.beatCount < Self.minRecoverableBeatCount }
        discardUnrecoverable(unrecoverable.map(\.id))
        let lost = orphans
            .filter { $0.beatCount >= Self.minRecoverableBeatCount }
            .map { (id: $0.id, date: $0.captureDate, beatCount: $0.beatCount) }
        if !lost.isEmpty {
            debugLog("[SessionRecoveryService] Found \(lost.count) lost sessions with backups")
        }
        return lost
    }

    private func discardUnrecoverable(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        debugLog("[SessionRecoveryService] Auto-discarding \(ids.count) backup(s) below \(Self.minRecoverableBeatCount)-beat recovery floor")
        for id in ids {
            do {
                try rawBackup.discardBackup(id)
            } catch {
                debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} Failed to discard unrecoverable backup \(id.uuidString.prefix(8)): \(error)")
            }
            Task { await cloudSyncManager.deleteLiveBackup(sessionId: id) }
        }
    }

    /// Pull iCloud backups, but no more than once per `cloudPullMinInterval`.
    /// Prevents the Lost Sessions loop where every scan re-seeds from cloud.
    private func pullCloudBackupsToLocalIfDue() async {
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: Self.cloudPullKey)
        let now = Date().timeIntervalSince1970
        if last > 0, now - last < Self.cloudPullMinInterval {
            return
        }
        await pullCloudBackupsToLocal()
        defaults.set(now, forKey: Self.cloudPullKey)
    }

    /// Pull iCloud backups that don't exist locally.
    func pullCloudBackupsToLocal() async {
        let cloudBackups = await cloudSyncManager.fetchLiveBackups()
        guard !cloudBackups.isEmpty else { return }
        let archivedIds = Set(archive.entries.map(\.sessionId))
        let localBackupIds = Set(rawBackup.allBackups().map(\.id))
        for backup in cloudBackups {
            let haveLocally = archivedIds.contains(backup.sessionId) || localBackupIds.contains(backup.sessionId)
            if haveLocally { retireCloudBackup(backup.sessionId) } else { savePulledBackup(backup) }
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

    /// The backup behind a Trash entry could not be read back.
    func restoreFromTrashFailed(_ sessionId: UUID) {
        cloudSyncManager.trashRestore.abandon(sessionId)
    }

    /// Permanently forget a deleted session.
    ///
    /// Its raw backup goes too, locally and in iCloud. The Trash lists deleted
    /// sessions that still have a backup; forgetting only the deletion left
    /// that backup behind, so the session reappeared under Lost Sessions and
    /// "Recover" brought back what the user had just deleted forever.
    func permanentlyDelete(_ sessionId: UUID) {
        archive.discardTrashed(sessionId)
        do {
            try rawBackup.discardBackup(sessionId)
        } catch {
            debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} Failed to discard the backup of \(sessionId.uuidString.prefix(8)): \(error)")
        }
        Task { await cloudSyncManager.deleteLiveBackup(sessionId: sessionId) }
        do {
            try archive.forgetDeletedSession(sessionId)
        } catch {
            debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} Failed to permanently delete session \(sessionId.uuidString.prefix(8)): \(error)")
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

    func retrieveBackupWithParentMerge(_ sessionId: UUID) -> BackupData? {
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
            flags: artifactDetector.detectArtifacts(in: series),
            sessionStart: sessionStart,
            endDate: Self.backupEndDate(backup)
        )
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
    func analyzeSession(
        _ session: inout HRVSession,
        series: RRSeries,
        flags: [ArtifactFlags],
        analyze: (_ session: HRVSession, _ window: WindowSelector.RecoveryWindow, _ flags: [ArtifactFlags], _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        analyzeWithCapacity: (_ session: HRVSession, _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?
    ) async {
        let baseline = windowBaselineStats(for: session)
        if let windowResult = windowSelector.findBestWindowWithCapacity(in: series, flags: flags, baselineStats: baseline) {
            if let recoveryWindow = windowResult.recoveryWindow {
                session.analysisResult = await analyze(session, recoveryWindow, flags, windowResult.peakCapacity)
            } else {
                session.analysisResult = await analyzeWithCapacity(session, windowResult.peakCapacity)
            }
        }
    }
}
