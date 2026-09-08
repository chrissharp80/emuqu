import Foundation

// The morning flow lives in `MorningSessionPipeline` — 623 lines
// off `RRCollector`.

extension RRCollector {
    /// Gather → process → analyse → accept.
    var morning: MorningSessionPipeline {
        MorningSessionPipeline(collector: self)
    }

    func gatherOvernightData() async -> OvernightStreamingCoordinator.OvernightDataResult? {
        await morning.gatherOvernightData()
    }

    func processOvernightData(
        points: [RRPoint],
        baseSession: HRVSession,
        dataSource: String,
        reconnectCount: Int,
        streamingBeats: Int = 0,
        deviceBeats: Int? = nil,
        isBackgroundRefinement: Bool = false,
        prefetchedSleepData: SleepData? = nil
    ) async -> HRVSession {
        await morning.processOvernightData(
            points: points, baseSession: baseSession, dataSource: dataSource,
            reconnectCount: reconnectCount, streamingBeats: streamingBeats,
            deviceBeats: deviceBeats, isBackgroundRefinement: isBackgroundRefinement,
            prefetchedSleepData: prefetchedSleepData
        )
    }

    func publishGatherSavingState(streamingPoints: [RRPoint], elapsedHours: Double) async {
        await morning.publishGatherSavingState(streamingPoints: streamingPoints, elapsedHours: elapsedHours)
    }

    func acceptSession() async throws { try await morning.acceptSession() }
    func rejectSession() async { await morning.rejectSession() }
    func clearAcceptanceState() { morning.clearAcceptanceState() }
    func supersedeSameNightSession(newSession: inout HRVSession) {
        morning.supersedeSameNightSession(newSession: &newSession)
    }

    func computeRecoveryScore(
        for session: HRVSession, from analysisResult: HRVAnalysisResult?
    ) async -> RecoveryScoreOutcome? {
        await morning.computeRecoveryScore(for: session, from: analysisResult)
    }

    func updateCompositeRecoveryScore(for session: HRVSession, exportMetrics: Bool = false) async {
        await morning.updateCompositeRecoveryScore(for: session, exportMetrics: exportMetrics)
    }

    func analyze(
        _ session: HRVSession, window: WindowSelector.RecoveryWindow,
        flags: [ArtifactFlags], peakCapacity: PeakCapacity? = nil
    ) async -> HRVAnalysisResult? {
        await morning.analyze(session, window: window, flags: flags, peakCapacity: peakCapacity)
    }

    func analyze(_ session: HRVSession, peakCapacity: PeakCapacity?) async -> HRVAnalysisResult? {
        await morning.analyze(session, peakCapacity: peakCapacity)
    }

    func analyze(_ session: HRVSession) async -> HRVAnalysisResult? {
        await morning.analyze(session)
    }
}
