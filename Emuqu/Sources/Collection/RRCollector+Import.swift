import Foundation

// MARK: - Import

extension RRCollector {
    func saveImportedSession(_ session: HRVSession) async throws {
        try await sessionImport.save(session)
    }

    func saveImportedSessionsBatch(_ sessions: [HRVSession]) async throws -> Int {
        try await sessionImport.saveBatch(sessions)
    }
}

extension RRCollector {
    /// Saving imported readings, over the parts it uses.
    var sessionImport: SessionImport {
        SessionImport(
            archive: archive, archiveSignal: archiveSignal, baselineTracker: baselineTracker,
            cloudSyncManager: cloudSyncManager, sessionState: sessionState, settingsManager: settingsManager
        )
    }
}

/// Saving imported readings into the archive, the baseline and iCloud.
///
/// A value over the parts it uses.
@MainActor
struct SessionImport {
    let archive: SessionArchive
    let archiveSignal: ArchiveSignal
    let baselineTracker: BaselineTracker
    let cloudSyncManager: CloudKitSyncManager
    let sessionState: SessionState
    let settingsManager: SettingsManager

    /// Save an imported session to the archive. Throws `duplicateImport` when
    /// the archive already holds a copy of the same recording (same type,
    /// overlapping time), the rule batch import applies too. A recording of
    /// the same sleep within the merge gap is merged by the archive onto one
    /// clock; the merged reading, under the id already there, is then what
    /// iCloud (through the archive's re-upload request) and the baseline get.
    /// A night is scored first, against the stored nights before it
    /// (`scoredForSave`).
    func save(_ session: HRVSession) async throws {
        guard session.state == .complete, session.analysisResult != nil else {
            throw RRCollector.CollectorError.importNotAnalyzed
        }
        guard !archive.store.holdsCopy(of: session) else { throw RRCollector.CollectorError.duplicateImport }
        let session = scoredForSave([session])[0]
        let entry = try archive.archive(session, skipSameNightMerge: false, requestingReupload: true)
        let merged = entry.sessionId != session.id
        let saved = merged ? archive.retrieveOrLog(entry.sessionId) ?? session : session
        if !merged {
            let cloudSync = cloudSyncManager
            Task { await cloudSync.uploadSession(saved) }
        }
        let sleepSchedule = settingsManager.settings.sleepSchedule
        baselineTracker.update(with: saved, sleepSchedule: sleepSchedule)
        // Against the nights before this one, not a baseline it just joined.
        let deviation = baselineTracker.deviation(for: saved, sleepSchedule: sleepSchedule)
        if let deviation { sessionState.baselineDeviation = deviation }
        archiveSignal.notifyChanged()
    }

    /// Batch save multiple imported sessions efficiently, each night scored
    /// first against the nights before it (`scoredForSave`). A batch that
    /// fails partway (a full disk) keeps what it wrote: those sessions still
    /// reach the baseline, the archive signal and iCloud before the error is
    /// thrown.
    func saveBatch(_ sessions: [HRVSession]) async throws -> Int {
        debugLog("[RRCollector] saveImportedSessionsBatch called with \(sessions.count) sessions")
        let validSessions = sessions.filter { $0.state == .complete && $0.analysisResult != nil }
        debugLog("[RRCollector] Valid sessions (complete + analyzed): \(validSessions.count)")
        guard !validSessions.isEmpty else {
            debugLog("[RRCollector] ERROR: No valid sessions to save!")
            return 0
        }
        let scored = scoredForSave(validSessions)
        let savedCount: Int
        do {
            savedCount = try archive.store.archiveBatch(scored)
        } catch {
            debugLog("[RRCollector] archiveBatch failed partway: \(error)", level: .warning)
            publishBatch(scored, wroteAny: nil)
            throw error
        }
        debugLog("[RRCollector] archiveBatch returned: \(savedCount) saved")
        publishBatch(scored, wroteAny: savedCount > 0)
        debugLog("[RRCollector] Archive now has \(archive.store.entries.count) entries")
        return savedCount
    }

    /// What follows a batch write, for the sessions of `sessions` the archive
    /// holds now: the baseline, the archive signal, and a full iCloud sync
    /// when the batch wrote anything. `wroteAny` is the batch's own count
    /// (merges into stored sessions included); nil after a failed batch,
    /// which returns no count, and then the sessions the archive holds decide.
    private func publishBatch(_ sessions: [HRVSession], wroteAny: Bool?) {
        let held = updateBaseline(withImported: sessions)
        archiveSignal.notifyChanged()
        guard wroteAny ?? (held > 0) else { return }
        let cloudSync = cloudSyncManager
        Task { await cloudSync.performFullSync() }
    }

    /// Only sessions the batch actually holds now feed the baseline: one it
    /// skipped (deleted by the user, a duplicate, or merged into an existing
    /// reading) must not come back through the baseline. Chronological so the
    /// rolling window sees them in the order they were recorded.
    /// Returns how many of `sessions` the archive holds.
    @discardableResult
    private func updateBaseline(withImported sessions: [HRVSession]) -> Int {
        let archivedIds = Set(archive.store.entries.map(\.sessionId))
        let written = sessions.filter { archivedIds.contains($0.id) }.sorted { $0.startDate < $1.startDate }
        for session in written {
            baselineTracker.update(with: session, sleepSchedule: settingsManager.settings.sleepSchedule)
        }
        return written.count
    }

    // MARK: - Scoring on save

    /// `sessions`, oldest first, with each night the app scores when it
    /// records one (`isScoredOnSave`) classified and scored against the
    /// nights before it: the stored ones and the earlier nights of
    /// `sessions`, merged by the baseline's own rules
    /// (`BaselineTracker.PendingNights`), so the nights of one import are
    /// scored as they would have been recorded one morning at a time.
    func scoredForSave(_ sessions: [HRVSession]) -> [HRVSession] {
        let settings = settingsManager.settings
        var nights = baselineTracker.pendingNights()
        var scored: [HRVSession] = []
        for session in sessions.sorted(by: { $0.startDate < $1.startDate }) {
            let context = RescoreContext(
                baselineStats: baselineTracker.recoveryBaselineStats(excludingNightOf: session, sleepSchedule: settings.sleepSchedule, in: nights),
                typicalSleepHours: settings.typicalSleepHours,
                scoringConfig: RecoveryScoreCalculator.ScoringConfiguration(from: settings)
            )
            let result = Self.scored(session, context: context)
            baselineTracker.admit(result, to: &nights, sleepSchedule: settings.sleepSchedule)
            scored.append(result)
        }
        return scored
    }

    /// Whether a saved import gets a recovery score: an overnight or a nap
    /// with beats, the types a recording scores (`MorningProcessingService`
    /// runs the score for both). A quick reading or a workout is saved
    /// unscored as its recording is, and so is a summary import with no beats
    /// (an Elite HRV row), whose score would be built from estimates. A
    /// session that carries a score already keeps it.
    nonisolated static func isScoredOnSave(_ session: HRVSession) -> Bool {
        (session.sessionType == .overnight || session.sessionType == .nap)
            && ReanalysisService.hasBeats(session) && session.recoveryScore == nil
    }

    /// `session` classified against the baseline in `context` and scored by
    /// the calculator every re-score runs (`ReanalysisService.rescoredBreakdown`):
    /// the session's own sleep and vitals snapshots (none, unless the import
    /// carried them), the user's scoring config, and the breakdown stamped with
    /// the current `ScoringVersion`. Returned as given when it is not scored
    /// on save, or when the composite is not finite.
    nonisolated static func scored(_ session: HRVSession, context: RescoreContext) -> HRVSession {
        guard isScoredOnSave(session), let result = session.analysisResult else { return session }
        var scored = session
        ReanalysisService.reclassifyHRVQuality(of: &scored, result: result, baselineStats: context.baselineStats)
        let training = scored.trainingSnapshot ?? result.trainingContext
        let breakdown = ReanalysisService.rescoredBreakdown(
            of: scored, result: result, training: training, referenceDate: scored.endDate ?? scored.startDate, context: context
        )
        guard breakdown.compositeScore.isFinite else { return session }
        scored.recoveryScore = RecoveryScoreCalculator.toTenScale(breakdown.compositeScore)
        scored.scoreBreakdown = breakdown
        scored.frozenReadiness = ReanalysisService.computeFrozenReadiness(compositeScore: breakdown.compositeScore, trainingContext: training)
        return scored
    }
}
