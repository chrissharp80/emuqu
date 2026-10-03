import Foundation

/// Stateless service that encapsulates session recovery logic.
///
/// Extracted from `RRCollector+Recovery.swift` so the recovery algorithms
/// can be tested in isolation. `RRCollector` keeps thin wrapper methods
/// that forward to this service and update its own observable state.
@MainActor
final class SessionRecoveryService {
    // MARK: - Types

    /// Information about a potentially corrupted session
    struct CorruptedSessionInfo {
        let sessionId: UUID
        let archiveDate: Date
        let backupDate: Date
        let dateMismatchDays: Int
        let beatCount: Int
    }

    /// Result of the core recover-and-patch operation.
    struct PatchResult {
        let session: HRVSession
        let beatCount: Int
        let targetSessionId: UUID
    }

    /// What kind of update recoverAndPatchSession should perform.
    /// Using an enum instead of string matching makes the decision tree
    /// exhaustive and impossible to break with a typo.
    /// Internal rather than private so `patchAction` can be exercised directly.
    /// The decision it encodes — re-import, reanalyse, or add — is the part of
    /// recovery most worth having tests on, and a private type would have kept
    /// it locked inside a method that needs an archive and four closures.
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
    let healthKit: any HealthKitServiceProtocol
    let cloudSyncManager: CloudKitSyncManager
    let baselineTracker: BaselineTracker

    // MARK: - Initialization

    init(
        archive: SessionArchive,
        rawBackup: RawRRBackup,
        artifactDetector: ArtifactDetector,
        windowSelector: WindowSelector,
        healthKit: any HealthKitServiceProtocol,
        cloudSyncManager: CloudKitSyncManager,
        baselineTracker: BaselineTracker
    ) {
        self.archive = archive
        self.rawBackup = rawBackup
        self.artifactDetector = artifactDetector
        self.windowSelector = windowSelector
        self.healthKit = healthKit
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

    // MARK: - Recover and Patch Session (Core Logic)

    /// Core logic for recovering RR data from the strap and patching an archived session.
    ///
    /// This performs everything except interacting with the Polar device
    /// (the caller supplies `rrPoints`) and updating `RRCollector`'s published state.
    ///
    /// - Parameters:
    ///   - rrPoints: RR points recovered from the device.
    ///   - sessionId: Optional explicit target session ID.
    ///   - backupRawData: Closure to back up raw points (called with points and session ID).
    ///   - analyze: Closure to run HRV analysis on a session with window + flags + capacity.
    ///   - analyzeWithCapacity: Closure to run HRV analysis on a session with just capacity.
    ///   - computeRecoveryScore: Closure to compute recovery score from session + analysis result.
    /// - Returns: The patched session and beat count.
    /// Branch count is driven by the number of fields/cases
    /// this function must handle, not by tangled control flow.
    /// Decide what this recovery is actually doing.
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

    private func resolveTargetSession(sessionId: UUID?) throws -> HRVSession? {
        if let id = sessionId {
            return try archive.retrieve(id)
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let todaySessions = archive.entries
            .filter { calendar.startOfDay(for: $0.date) == today }
            .sorted { $0.date > $1.date }
        // A today-session with no beats is the one that needs patching.
        for entry in todaySessions {
            guard let session = retrieveForRecovery(entry.sessionId),
                  session.rrSeries?.points.isEmpty ?? true else { continue }
            return session
        }
        guard let mostRecent = todaySessions.first else { return nil }
        return retrieveForRecovery(mostRecent.sessionId, label: "most recent session")
    }

    private func retrieveForRecovery(_ id: UUID, label: String = "session") -> HRVSession? {
        do {
            return try archive.retrieve(id)
        } catch {
            debugLog("[SessionRecoveryService] \u{26a0}\u{fe0f} Failed to retrieve \(label) \(id) during recovery search: \(error)")
            return nil
        }
    }

    /// Crash-recovery sleep window.
    /// `session.endDate` for a recovered session is the last RR point
    /// timestamp (i.e. the crash time). Bounding the sleep query at that point
    /// clips off everything from the crash to wake — the bug behind "I slept
    /// 5h 53m but the app shows 1.4h." Widening to the user's expected
    /// overnight-window end makes HealthKit return the FULL night, not just
    /// the pre-crash slice. The downstream SleepResolver still consumes the
    /// wider bounds correctly.
    private func resolveSleepWindow(
        for session: inout HRVSession,
        series: RRSeries
    ) async -> (sleepStartMs: Int64?, wakeTimeMs: Int64?) {
        guard let endDate = session.endDate else { return (nil, nil) }
        let scheduleEnd = AppDependencies.current.app.settingsManager.settings.sleepSchedule
            .overnightWindowEnd(relativeTo: session.startDate)
        let widenedEnd = max(endDate, scheduleEnd)
        let sleepData: SleepData
        do {
            sleepData = try await healthKit.fetchSleepData(
                for: session.startDate, recordingEnd: widenedEnd, rrPoints: series.points
            )
        } catch {
            debugLog("[SessionRecoveryService] Could not fetch HealthKit data for reanalysis: \(error)")
            return (nil, nil)
        }
        let start = session.startDate
        extendEndDate(of: &session, to: sleepData.sleepEnd, crashEnd: endDate, widenedEnd: widenedEnd)
        return (
            sleepData.sleepStart.map { Int64($0.timeIntervalSince(start) * 1000) },
            sleepData.sleepEnd.map { Int64($0.timeIntervalSince(start) * 1000) }
        )
    }

    /// Extend the session's endDate to the actual sleep end (or the schedule
    /// end when HealthKit doesn't resolve a sleep boundary). Without this the
    /// HR chart and downstream consumers stay bounded by the original
    /// crash-time endDate.
    private func extendEndDate(
        of session: inout HRVSession, to sleepEnd: Date?, crashEnd: Date, widenedEnd: Date
    ) {
        guard let sleepEnd else {
            // HealthKit found samples but no clear end — still widen to the
            // schedule end so downstream queries don't clip at the crash time.
            if widenedEnd > crashEnd { session.endDate = widenedEnd }
            return
        }
        guard sleepEnd > crashEnd else { return }
        session.endDate = sleepEnd
        debugLog("[SessionRecoveryService] extended recovered-session endDate from crash time to actual sleep end (\(sleepEnd))")
    }

    /// Which RR series a patch will analyse, and where it came from.
    ///
    /// A struct rather than a tuple because the three fields travel together
    /// through the rest of the patch and a bare `(RRSeries, Int, String)`
    /// reads as nothing at the call site.
    struct PatchSeriesSelection {
        let series: RRSeries
        let streamingBeats: Int
        let dataSource: String
    }

    private func selectPatchSeries(
        action: PatchAction,
        session: inout HRVSession,
        existingRR: RRSeries?,
        rrPoints: [RRPoint],
        targetSessionId: UUID
    ) throws -> PatchSeriesSelection {
        switch action {
        case .replaceWithNewData:
            guard let existing = existingRR else { throw RRCollector.CollectorError.noSessionToRecover }
            let selection = compositeSelection(
                existing: existing, rrPoints: rrPoints,
                targetSessionId: targetSessionId, sessionStart: session.startDate
            )
            session.rrSeries = selection.series
            return selection
        case .reanalyzeNoResult, .reanalyzeNoFlags:
            // Same data, just need to re-run analysis — keep existing series.
            guard let existing = existingRR else { throw RRCollector.CollectorError.noSessionToRecover }
            let source = session.dataSourceSummary?.selectedSource ?? "internal"
            return PatchSeriesSelection(series: existing, streamingBeats: 0, dataSource: source)
        case .addMissingData:
            // No existing data — use device points directly.
            let series = RRSeries(points: rrPoints, sessionId: targetSessionId, startDate: session.startDate)
            session.rrSeries = series
            return PatchSeriesSelection(series: series, streamingBeats: 0, dataSource: "internal")
        }
    }

    /// The existing session has streaming data and the device data differs —
    /// build a composite merge so the analysis uses the best available beats.
    /// Falls back to the device data alone when the selector can't reconcile
    /// the two.
    private func compositeSelection(
        existing: RRSeries, rrPoints: [RRPoint], targetSessionId: UUID, sessionStart: Date
    ) -> PatchSeriesSelection {
        let streamingBeats = existing.points.count
        guard let selection = DataSourceSelector.selectBestSource(
            streamingPoints: existing.points,
            internalPoints: rrPoints,
            sessionId: targetSessionId,
            sessionStart: sessionStart
        ) else {
            debugLog("[SessionRecoveryService] Re-import: source selection returned nil, using device data (\(rrPoints.count) beats)")
            return PatchSeriesSelection(
                series: RRSeries(points: rrPoints, sessionId: targetSessionId, startDate: sessionStart),
                streamingBeats: streamingBeats,
                dataSource: "internal"
            )
        }
        debugLog("[SessionRecoveryService] Re-import: selected \(selection.normalizedSource) (\(selection.points.count) beats from \(streamingBeats) streamed + \(rrPoints.count) device)")
        return PatchSeriesSelection(
            series: RRSeries(points: selection.points, sessionId: targetSessionId, startDate: sessionStart),
            streamingBeats: streamingBeats,
            dataSource: selection.normalizedSource
        )
    }

    /// `patchAction` decides what to do — an exhaustive enum, no string
    /// matching — and `selectPatchSeries` then picks the data for that action,
    /// one clear path per case. When no fresh analysis comes out of the new
    /// series, nothing is saved: the old result would be archived next to
    /// beats it was not computed from.
    func recoverAndPatchSession(
        rrPoints: [RRPoint],
        sessionId: UUID?,
        backupRawData: (_ points: [RRPoint], _ sessionId: UUID) -> Void,
        analyze: (_ session: HRVSession, _ window: WindowSelector.RecoveryWindow, _ flags: [ArtifactFlags], _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        analyzeWithCapacity: (_ session: HRVSession, _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        computeRecoveryScore: (_ session: HRVSession, _ analysisResult: HRVAnalysisResult?) async -> RecoveryScoreOutcome?
    ) async throws -> PatchResult {
        guard !rrPoints.isEmpty else { throw RRCollector.CollectorError.insufficientData }
        guard var session = try resolveTargetSession(sessionId: sessionId) else {
            throw RRCollector.CollectorError.noSessionToRecover
        }
        let existingRR = session.rrSeries
        let action = try Self.patchAction(
            existingRR: (existingRR?.points.isEmpty ?? true) ? nil : existingRR,
            incomingPoints: rrPoints, hasAnalysisResult: session.analysisResult != nil,
            hasArtifactFlags: session.artifactFlags != nil
        )
        backupRawData(rrPoints, session.id)
        let selection = try selectPatchSeries(action: action, session: &session, existingRR: existingRR, rrPoints: rrPoints, targetSessionId: session.id)
        guard await reanalyzePatched(
            &session, selection: selection, analyze: analyze,
            analyzeWithCapacity: analyzeWithCapacity, computeRecoveryScore: computeRecoveryScore
        ) else { throw RRCollector.CollectorError.insufficientData }
        session.dataSourceSummary = Self.patchedDataSourceSummary(session: session, selection: selection, rrPoints: rrPoints)
        try persistPatched(session, action: action)
        return PatchResult(session: session, beatCount: selection.series.points.count, targetSessionId: session.id)
    }

    private func persistPatched(_ session: HRVSession, action: PatchAction) throws {
        try archive.archive(session)
        rawBackup.markAsArchived(session.id)
        Task { await cloudSyncManager.forceReuploadSession(session) }
        debugLog("[SessionRecoveryService] Recovered and patched session \(session.id.uuidString.prefix(8)) - \(Self.updateReason(for: action))")
    }

    /// All actions require reanalysis — the enum cases that don't need it
    /// (dataAlreadyExists) throw before reaching here. False when no window
    /// or analysis came out of the new series; the session is then left
    /// unscored.
    private func reanalyzePatched(
        _ session: inout HRVSession,
        selection: PatchSeriesSelection,
        analyze: (_ session: HRVSession, _ window: WindowSelector.RecoveryWindow, _ flags: [ArtifactFlags], _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        analyzeWithCapacity: (_ session: HRVSession, _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        computeRecoveryScore: (_ session: HRVSession, _ analysisResult: HRVAnalysisResult?) async -> RecoveryScoreOutcome?
    ) async -> Bool {
        let series = selection.series
        let flags = artifactDetector.detectArtifacts(in: series)
        session.artifactFlags = flags
        let sleepWindow = await resolveSleepWindow(for: &session, series: series)
        guard let windowResult = windowSelector.findBestWindowWithCapacity(
            in: series, flags: flags, sleepStartMs: sleepWindow.sleepStartMs,
            wakeTimeMs: sleepWindow.wakeTimeMs, baselineStats: windowBaselineStats(for: session)
        ) else { return false }
        let analysisResult: HRVAnalysisResult? = if let recoveryWindow = windowResult.recoveryWindow {
            await analyze(session, recoveryWindow, flags, windowResult.peakCapacity)
        } else {
            await analyzeWithCapacity(session, windowResult.peakCapacity)
        }
        guard let analysisResult else { return false }
        session.analysisResult = analysisResult
        await applyPatchedScore(&session, computeRecoveryScore: computeRecoveryScore)
        return true
    }

    /// Persist the snapshots the scorer just used. Without this,
    /// downstream views that re-derive the breakdown from
    /// `session.sleepSnapshot` / `session.vitalsSnapshot`
    /// (RecoveryScoreDetailView, etc.) see nil and drop to tier 1.
    ///
    /// Overnight only: the scorer fetches last night's sleep for
    /// snapshot-less sessions, and freezing it onto a recovered `.quick`
    /// session hijacks the dashboard sleep chip (`latestWithSleep`) away from
    /// the real overnight session.
    private func applyPatchedScore(
        _ session: inout HRVSession,
        computeRecoveryScore: (_ session: HRVSession, _ analysisResult: HRVAnalysisResult?) async -> RecoveryScoreOutcome?
    ) async {
        guard let result = await computeRecoveryScore(session, session.analysisResult) else {
            return
        }
        session.recoveryScore = result.score
        session.scoreBreakdown = result.breakdown
        if session.sessionType == .overnight {
            if let snap = result.sleepSnapshot { session.sleepSnapshot = snap }
            if let vitals = result.vitalsSnapshot { session.vitalsSnapshot = vitals }
        }
        session.frozenReadiness = ReanalysisService.computeFrozenReadiness(
            compositeScore: result.breakdown.compositeScore,
            trainingContext: session.trainingSnapshot ?? session.analysisResult?.trainingContext
        )
    }

    private static func updateReason(for action: PatchAction) -> String {
        switch action {
        case .addMissingData: "adding missing RR data"
        case .reanalyzeNoResult: "re-analyzing (analysis was missing)"
        case .reanalyzeNoFlags: "re-analyzing (artifact flags were missing)"
        case let .replaceWithNewData(existing, new): "replacing \(existing) points with \(new) from strap"
        }
    }

    private static func patchedDataSourceSummary(
        session: HRVSession, selection: PatchSeriesSelection, rrPoints: [RRPoint]
    ) -> HRVSession.DataSourceSummary {
        let streamingBeats = selection.streamingBeats
        let beatDiffPercent: Double? = streamingBeats > 0
            ? (Double(abs(rrPoints.count - streamingBeats)) / Double(max(rrPoints.count, streamingBeats))) * 100.0
            : nil
        return HRVSession.DataSourceSummary(
            selectedSource: selection.dataSource,
            streamingBeats: streamingBeats,
            deviceBeats: rrPoints.count,
            totalBeats: selection.series.points.count,
            beatDifferencePercent: beatDiffPercent,
            reconnectCount: session.dataSourceSummary?.reconnectCount ?? 0,
            deviceModel: session.dataSourceSummary?.deviceModel ?? session.deviceProvenance?.deviceModel
        )
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
            allPoints = parentSeries.points + backup.points
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
