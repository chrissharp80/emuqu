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
    func gatherOvernightData() async -> OvernightStreamingCoordinator.OvernightDataResult? {
        let baseSession = collector.currentSession ?? HRVSession()
        let reconnectCount = collector.polarManager.streamingReconnectCount
        let elapsedHoursForBattery = Double(collector.streamingElapsedSeconds) / 3600.0
        let streamingPoints = stopOvernightStreamForGather()
        await publishGatherSavingState(streamingPoints: streamingPoints, elapsedHours: elapsedHoursForBattery)
        await backupStreamingPointsBeforeFetch(streamingPoints, baseSession: baseSession)
        let internalPoints = await collector.overnightStreaming.fetchNightFromStrap(
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
    /// winning source. Either failure path fails the session and returns nil.
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
            _ = await collector.failSession(from: baseSession)
            return nil
        }
        let chosen = selectOvernightSource(
            streamingPoints: streamingPoints, internalPoints: internalPoints,
            baseSession: baseSession, isResumedChild: isResumedChild
        )
        if chosen == nil { _ = await collector.failSession(from: baseSession) }
        return chosen
    }

    /// Tear down the streaming infrastructure and hand back the captured beats.
    ///
    /// Do NOT stop background audio here. See the
    /// matching note in `stopStreamingInfrastructure` — the morning
    /// pipeline that runs after gather still needs the iOS
    /// background-task extension audio provides. Cleared in
    /// `analyzeAndFinalizeOvernight` after the score is final.
    ///
    /// No location stop here either: there is no overnight
    /// location keep-alive (App Store 2.5.4). Overnight never starts
    /// a location session, and stopping here could kill the
    /// keep-alive of a concurrently-recording workout.
    private func stopOvernightStreamForGather() -> [RRPoint] {
        collector.stopStreamingTimer()
        AppDependencies.current.app.systemDiagnosticsManager.stopSamplingAfterRecording()
        // Clear isStreamingMode BEFORE stopStreaming() to prevent
        // Combine sink race — see comment in stopOvernightStreaming().
        collector.isStreamingMode = false
        return collector.polarManager.stopStreaming()
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

    /// CRITICAL: Immediately backup streaming data to disk, off the main
    /// thread. The JSON serialize + SHA256 + atomic write can take ~100ms
    /// for a long overnight session; doing it inline stalls the UI.
    private func backupStreamingPointsBeforeFetch(_ streamingPoints: [RRPoint], baseSession: HRVSession) async {
        guard !streamingPoints.isEmpty else { return }
        debugLog("[RRCollector] 💾 Backing up \(streamingPoints.count) streaming points to disk before device fetch...")
        let backup = collector.rawBackup
        let sid = baseSession.id
        let did = collector.polarManager.connectedDeviceId
        let points = streamingPoints
        await Task.detached(priority: .utility) {
            do {
                try backup.backup(points: points, sessionId: sid, deviceId: did)
                debugLog("[RRCollector] ✅ Streaming data safely backed up to disk")
            } catch {
                debugLog("[RRCollector] ⚠️ Failed to backup streaming data: \(error)", level: .error)
            }
        }.value
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
