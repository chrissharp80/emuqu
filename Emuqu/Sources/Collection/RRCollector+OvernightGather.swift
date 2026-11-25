import Foundation
import HealthKit

// The wake-time "gather" path. `gatherOvernightData` is the pause/resume and
// recovery entry point: stop the stream, back the beats up, pull the strap's
// internal recording through the same gate as the morning
// (`fetchNightFromStrap`), and pick the best source.
// `stopOvernightStreaming`, the normal morning, lives in
// `RRCollector+OvernightStreaming.swift` and shares `publishGatherSavingState`
// from here.

extension OvernightStreamingCoordinator {
    /// Wake-time gather: stop the stream, back the beats up, optionally pull the
    /// strap's internal recording, and pick the best source for the night.
    ///
    /// NOTE: Do NOT clear persisted recording state here. It must survive until
    /// the session is successfully archived so that `checkForInterruptedSession()`
    /// can offer recovery if the app crashes during processing. Callers clear it
    /// after archiving.
    ///
    /// The stream is stopped and backed up exactly as the morning stop does
    /// (`stopStreamingInfrastructure`, `backupStreamingData`).
    func gatherOvernightData() async -> OvernightStreamingCoordinator.OvernightDataResult? {
        let overnight = self
        let (baseSession, streamingPoints, reconnectCount) = await overnight.stopStreamingInfrastructure()
        await overnight.backupStreamingData(streamingPoints, sessionId: baseSession.id)
        let internalPoints = await overnight.fetchNightFromStrap(
            baseSession: baseSession, streamingPoints: streamingPoints,
            isVeritySense: morning.isVeritySenseDevice(baseSession)
        )
        guard let chosen = await resolveOvernightSource(
            streamingPoints: streamingPoints, internalPoints: internalPoints, baseSession: baseSession
        ) else { return nil }
        debugLog("[RRCollector] Final data source: \(chosen.source), \(chosen.points.count) beats")
        return OvernightStreamingCoordinator.OvernightDataResult(
            points: chosen.points, baseSession: baseSession, streamingBeats: streamingPoints.count,
            deviceBeats: internalPoints?.isEmpty == false ? internalPoints?.count : nil,
            dataSource: chosen.source, reconnectCount: reconnectCount,
            downloadedPoints: internalPoints
        )
    }

    /// Gate the night on having enough beats to be worth analysing, then pick the
    /// winning source. Either failure path fails the session and returns nil,
    /// after backing up any beats downloaded from the strap: the download
    /// stopped and took them, and the stream's backup does not hold them.
    private func resolveOvernightSource(
        streamingPoints: [RRPoint],
        internalPoints: [RRPoint]?,
        baseSession: HRVSession
    ) async -> (points: [RRPoint], source: String, usesDeviceBeats: Bool)? {
        let isResumedChild = baseSession.linkedSessionIds?.isEmpty == false
        guard OvernightStreamingCoordinator.hasSufficientOvernightData(
            streamingCount: streamingPoints.count,
            internalCount: internalPoints?.count ?? 0,
            isResumedChild: isResumedChild
        ) else {
            debugLog("[RRCollector] ❌ Overnight recording FAILED: insufficient data from both sources")
            debugLog("[RRCollector] Streaming: \(streamingPoints.count) beats, Internal: \(internalPoints?.count ?? 0) beats")
            await failRescuingDownload(internalPoints, baseSession: baseSession)
            return nil
        }
        let chosen = selectOvernightSource(
            streamingPoints: streamingPoints, internalPoints: internalPoints,
            baseSession: baseSession, isResumedChild: isResumedChild
        )
        return await keepingDownload(chosen, internalPoints: internalPoints, baseSession: baseSession)
    }

    /// The strap's beats are kept before the analysis runs, as the morning
    /// stop keeps them: the download is already on record, and the stream's
    /// backup alone would let the next arming clear the strap's copy. No
    /// source chosen fails the session, rescuing the download.
    private func keepingDownload(
        _ chosen: (points: [RRPoint], source: String, usesDeviceBeats: Bool)?, internalPoints: [RRPoint]?, baseSession: HRVSession
    ) async -> (points: [RRPoint], source: String, usesDeviceBeats: Bool)? {
        guard let chosen else {
            await failRescuingDownload(internalPoints, baseSession: baseSession)
            return nil
        }
        await morning.backUpDownloadedNight(
            internalPoints, chosen: chosen.points, usedDevice: chosen.usesDeviceBeats, baseSession: baseSession
        )
        return chosen
    }

    /// Fail the session, backing up first the strap beats no session will hold.
    private func failRescuingDownload(_ internalPoints: [RRPoint]?, baseSession: HRVSession) async {
        morning.rescueDownloadedBeats(internalPoints, baseSession: baseSession)
        _ = await morning.failSession(from: baseSession)
    }
}

// MARK: - File-scope helpers
//
// Each names no member of `RRCollector` and calls nothing on it, so none needs
// to be inside the type.

@MainActor
/// Select best data source — prefers device when it has more beats,
/// only creates composite when device has gaps that streaming can fill.
private func selectOvernightSource(
    streamingPoints: [RRPoint],
    internalPoints: [RRPoint]?,
    baseSession: HRVSession,
    isResumedChild: Bool
) -> (points: [RRPoint], source: String, usesDeviceBeats: Bool)? {
    if let selection = DataSourceSelector.selectBestSource(
        streamingPoints: streamingPoints,
        internalPoints: internalPoints,
        sessionId: baseSession.id,
        sessionStart: baseSession.startDate
    ) {
        return (selection.points, selection.normalizedSource, selection.usesDeviceBeats)
    }
    guard isResumedChild, !streamingPoints.isEmpty else { return nil }
    debugLog("[RRCollector] Resumed child: using \(streamingPoints.count) new beats (parent merge pending)")
    return (streamingPoints, "streaming", false)
}
