import Foundation

// Reanalysis lives in `SessionReanalysisCoordinator` — several hundred lines
// kept off `RRCollector`.

extension RRCollector {
    /// The reanalysis subsystem.
    var reanalysis: SessionReanalysisCoordinator {
        SessionReanalysisCoordinator(collector: self)
    }

    var reanalysisService: ReanalysisService { reanalysis.reanalysisService }

    func reanalyzeSession(
        _ session: HRVSession, method: WindowSelectionMethod = .consolidatedRecovery
    ) async -> HRVSession? {
        await reanalysis.reanalyzeSession(session, method: method)
    }

    func installRescoreListener() { reanalysis.installRescoreListener() }
    func installCloudKitSnapshotBackfillListener() { reanalysis.installCloudKitSnapshotBackfillListener() }
    func autoRefreshTodaysSleepIfImproved() async { await reanalysis.autoRefreshTodaysSleepIfImproved() }
    func updateCurrentSessionResult(_ result: HRVAnalysisResult) { reanalysis.updateCurrentSessionResult(result) }
    func unlinkSegment(segmentId: UUID, fromSession sessionId: UUID) {
        reanalysis.unlinkSegment(segmentId: segmentId, fromSession: sessionId)
    }

    func reanalyzeAllSessions(
        from: Date? = nil, to: Date? = nil,
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> (updated: Int, skipped: Int) {
        await reanalysis.reanalyzeAllSessions(from: from, to: to, progress: progress)
    }

    func retroApplySleepSettings(progress: @escaping (Int, Int) -> Void = { _, _ in }) async -> Int {
        await reanalysis.retroApplySleepSettings(progress: progress)
    }

    func reanalyzeAtPosition(_ session: HRVSession, targetMs: Int64) async -> HRVAnalysisResult? {
        await reanalysis.reanalyzeAtPosition(session, targetMs: targetMs)
    }

    func applyManualAnalysis(_ session: HRVSession, result: HRVAnalysisResult) async -> HRVSession? {
        await reanalysis.applyManualAnalysis(session, result: result)
    }

    @discardableResult
    func updateSessionSleepBoundaries(
        sessionId: UUID, sleepData: SleepData, isUserAdjustment: Bool = false
    ) -> Bool {
        reanalysis.updateSessionSleepBoundaries(
            sessionId: sessionId, sleepData: sleepData, isUserAdjustment: isUserAdjustment
        )
    }

    func repairTrainingSnapshots(
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> ReanalysisService.TrainingRepairResult {
        await reanalysis.repairTrainingSnapshots(progress: progress)
    }
}
