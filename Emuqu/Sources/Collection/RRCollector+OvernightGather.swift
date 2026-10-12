import Foundation
import HealthKit

// The wake-time "gather" path. `gatherOvernightData` is the pause/resume and
// recovery entry point: stop the stream, back the beats up, pull the strap's
// internal recording through the same gate as the morning
// (`fetchNightFromStrap`), and pick the best source.
// `stopOvernightStreaming`, the normal morning, lives in
// `RRCollector+OvernightStreaming.swift` and shares `publishGatherSavingState`
// from here.

extension MorningSessionPipeline {
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
        let overnight = collector.overnightStreaming
        let (baseSession, streamingPoints, reconnectCount) = await overnight.stopStreamingInfrastructure()
        await overnight.backupStreamingData(streamingPoints, sessionId: baseSession.id)
        let internalPoints = await overnight.fetchNightFromStrap(
            baseSession: baseSession, streamingPoints: streamingPoints,
            isVeritySense: collector.isVeritySenseDevice(baseSession)
        )
        guard let chosen = await resolveOvernightSource(
            streamingPoints: streamingPoints, internalPoints: internalPoints, baseSession: baseSession
        ) else { return nil }
        debugLog("[RRCollector] Final data source: \(chosen.source), \(chosen.points.count) beats")
        return OvernightStreamingCoordinator.OvernightDataResult(
            points: chosen.points, baseSession: baseSession, streamingBeats: streamingPoints.count,
            deviceBeats: internalPoints?.isEmpty == false ? internalPoints?.count : nil,
            dataSource: chosen.source, reconnectCount: reconnectCount
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
    ) async -> (points: [RRPoint], source: String)? {
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
        if chosen == nil { await failRescuingDownload(internalPoints, baseSession: baseSession) }
        return chosen
    }

    /// Fail the session, backing up first the strap beats no session will hold.
    private func failRescuingDownload(_ internalPoints: [RRPoint]?, baseSession: HRVSession) async {
        rescueDownloadedBeats(internalPoints, baseSession: baseSession)
        _ = await collector.failSession(from: baseSession)
    }

    /// Downloaded strap beats go to their own backup, dated by the night's
    /// start, so Lost Sessions can recover them.
    private func rescueDownloadedBeats(_ internalPoints: [RRPoint]?, baseSession: HRVSession) {
        guard let internalPoints, !internalPoints.isEmpty else { return }
        do {
            try collector.rawBackup.backup(
                points: internalPoints, sessionId: UUID(),
                deviceId: collector.polarManager.connectedDeviceId, captureDate: baseSession.startDate
            )
            debugLog("[RRCollector] Backed up \(internalPoints.count) downloaded strap beats the night could not use (recoverable via Lost Sessions)")
        } catch {
            debugLog("[RRCollector] Failed to back up \(internalPoints.count) downloaded strap beats: \(error)", level: .error)
        }
    }

    /// Flip every published flag to the post-stream "saving" state in one hop.
    func publishGatherSavingState(streamingPoints: [RRPoint], elapsedHours: Double) async {
        await MainActor.run {
            collector.morningStatus = .saving(beats: streamingPoints.count)
            collector.isOvernightStreaming = false
            collector.overnightDeviceBackupActive = false
            collector.deviceStatus.isStreaming = false
            collector.recordingPhase = .analyzing
            collector.isCollecting = false
            collector.collectedPoints = streamingPoints
            collector.streamingElapsedSeconds = 0
            collector.polarManager.recordRecordingHours(elapsedHours)
        }
    }
}

// MARK: - File-scope helpers
//
// Kept outside RRCollector: each names no member of the
// type and calls nothing inside it, so none needs to be a member.
// `private` at file scope is fileprivate, so every call site in this
// file resolves the same way.

@MainActor
/// Select best data source — prefers device when it has more beats,
/// only creates composite when device has gaps that streaming can fill.
private func selectOvernightSource(
    streamingPoints: [RRPoint],
    internalPoints: [RRPoint]?,
    baseSession: HRVSession,
    isResumedChild: Bool
) -> (points: [RRPoint], source: String)? {
    if let selection = DataSourceSelector.selectBestSource(
        streamingPoints: streamingPoints,
        internalPoints: internalPoints,
        sessionId: baseSession.id,
        sessionStart: baseSession.startDate
    ) {
        return (selection.points, selection.normalizedSource)
    }
    guard isResumedChild, !streamingPoints.isEmpty else { return nil }
    debugLog("[RRCollector] Resumed child: using \(streamingPoints.count) new beats (parent merge pending)")
    return (streamingPoints, "streaming")
}
