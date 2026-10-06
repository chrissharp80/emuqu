import AudioToolbox
import Foundation
import UIKit

// MARK: - Streaming Mode (Quick Readings)

extension CollectorSessionControl {
    // MARK: - Sound Constants

    /// System sound ID for the "received message" chime (standard iOS notification sound)
    static let kCompletionSoundID: SystemSoundID = 1007

    /// Start a streaming session for quick HRV reading
    /// - Parameter durationSeconds: Target duration (180 for 3min, 300 for 5min)
    @MainActor
    func startStreamingSession(durationSeconds: Int = 180) throws {
        guard collector.polarManager.connectionState == .connected else {
            throw RRCollector.CollectorError.notConnected
        }
        guard !collector.polarManager.isStreaming, !collector.polarManager.isRecordingOnDevice else {
            throw RRCollector.CollectorError.alreadyRecording
        }
        // Capture device provenance for streaming mode
        let session = HRVSession(sessionType: .quick, deviceProvenance: DeviceProvenance.current(
            deviceId: collector.polarManager.connectedDeviceId ?? "unknown",
            deviceModel: collector.polarManager.connectedDeviceType?.displayName ?? "Polar device",
            firmwareVersion: nil,
            recordingMode: .streaming
        ))
        try collector.polarManager.startStreaming()
        resetStateForQuickStreaming(session, durationSeconds: durationSeconds)
        // Persist recording state so crash recovery can find this session
        collector.persistRecordingState(sessionId: session.id, startTime: Date(), sessionType: .quick)
        debugLog("[RRCollector] Started streaming session: target=\(durationSeconds)s (\(durationSeconds / 60)min)")
        // Start countdown timer - runs on main thread for UI updates
        startStreamingTimer()
    }

    @MainActor
    private func resetStateForQuickStreaming(_ session: HRVSession, durationSeconds: Int) {
        collector.currentSession = session
        collector.collectedPoints = []
        collector.sessionStartTime = Date()
        collector.isStreamingMode = true
        collector.recordingPhase = .streaming(targetSeconds: durationSeconds)
        collector.streamingTargetSeconds = durationSeconds
        collector.streamingElapsedSeconds = 0
        collector.isCollecting = true
        collector.pausedBeatCount = 0
    }

    /// Start the streaming countdown timer.
    ///
    /// 0.25s tolerance lets iOS coalesce this timer with other 1Hz work.
    /// The display only shows seconds, so ±0.25s is invisible to the user
    /// but meaningfully reduces CPU wakeups during overnight recording.
    func startStreamingTimer() {
        collector.streamingTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak collector] _ in
            Task { @MainActor in
                collector?.control.streamingCountdownTick()
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        collector.streamingTimer = timer
    }

    /// One 1 Hz tick of the quick-capture countdown. The guard is thread
    /// safety: streaming may have been stopped while the Task was pending.
    @MainActor
    private func streamingCountdownTick() {
        guard collector.isStreamingMode, collector.streamingTimer != nil else { return }
        collector.streamingElapsedSeconds += 1
        if let session = collector.currentSession {
            runQuickStreamingBackup(session: session)
        }
        guard collector.streamingElapsedSeconds >= collector.streamingTargetSeconds else { return }
        debugLog("[RRCollector] Streaming complete: elapsed=\(collector.streamingElapsedSeconds)s, target=\(collector.streamingTargetSeconds)s")
        collector.streamingTimer?.invalidate()
        collector.streamingTimer = nil
        // Play completion sound and vibrate (works even in silent mode)
        playCompletionAlert()
        // Notify that streaming is complete (UI should call stopStreamingSession)
        collector.onStreamingComplete?()
    }

    /// Incremental backup every ~60 seconds (same as overnight streaming),
    /// pushed to iCloud on success (throttled internally to every 5 min).
    @MainActor
    private func runQuickStreamingBackup(session: HRVSession) {
        let buffer = collector.polarManager.streamedRRPoints
        let deviceId = collector.polarManager.connectedDeviceId
        let didBackup = collector.rawBackup.incrementalBackup(
            points: buffer, sessionId: session.id, deviceId: deviceId
        )
        guard didBackup else { return }
        let sessionId = session.id
        let cloudSyncManager = self.collector.cloudSyncManager
        Task(priority: .utility) {
            await cloudSyncManager.uploadLiveBackup(sessionId: sessionId, points: buffer, deviceId: deviceId)
        }
    }

    /// Play completion sound and haptic feedback
    func playCompletionAlert() {
        // Haptic feedback - works in silent mode
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        // Also trigger a heavier impact for more noticeable vibration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let impact = UIImpactFeedbackGenerator(style: .heavy)
            impact.impactOccurred()
        }

        // Play system sound (respects silent mode for sound, but we mainly want vibration)
        AudioServicesPlaySystemSound(Self.kCompletionSoundID)

        // Also play alert sound that works even in silent mode
        AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
    }

    /// Cancel streaming timer
    func stopStreamingTimer() {
        collector.streamingTimer?.invalidate()
        collector.streamingTimer = nil
    }

    /// Stop streaming session and analyze.
    ///
    /// Safety: if this is an overnight streaming session, route to the proper
    /// overnight flow instead.
    func stopStreamingSession() async -> HRVSession? {
        guard collector.isStreamingMode else { return nil }
        if collector.isOvernightStreaming {
            debugLog("[RRCollector] ⚠️ stopStreamingSession() called during overnight streaming - redirecting to stopOvernightStreaming()")
            return await collector.stopOvernightStreaming()
        }
        stopStreamingTimer()
        collector.isStreamingMode = false
        let baseSession = collector.currentSession ?? HRVSession()
        let elapsedHoursForBattery = Double(collector.streamingElapsedSeconds) / 3600.0
        let rrPoints = collector.polarManager.stopStreaming()
        await publishQuickStreamingStopped(rrPoints: rrPoints, elapsedHours: elapsedHoursForBattery)
        await collector.backupStreamingData(rrPoints, sessionId: baseSession.id)
        // For streaming, 120 beats is enough (~2 min at 60 bpm)
        guard rrPoints.count >= 120 else {
            let failed = await handleInsufficientStreamingData(baseSession: baseSession)
            disconnectVeritySenseAfterQuickSession()
            return failed
        }
        return await finalizeQuickStreamingSession(rrPoints: rrPoints, baseSession: baseSession)
    }

    private func finalizeQuickStreamingSession(rrPoints: [RRPoint], baseSession: HRVSession) async -> HRVSession {
        let finalSession = await analyzeStreamingData(rrPoints: rrPoints, baseSession: baseSession)
        await archiveAndFinalizeStreamingSession(finalSession)
        disconnectVeritySenseAfterQuickSession()
        return finalSession
    }

    /// Auto-disconnect Verity Sense to prevent battery drain.
    private func disconnectVeritySenseAfterQuickSession() {
        guard collector.polarManager.connectedDeviceType == .veritySense else { return }
        debugLog("[RRCollector] Auto-disconnecting Verity Sense after session end")
        collector.polarManager.disconnect()
    }

    private func publishQuickStreamingStopped(rrPoints: [RRPoint], elapsedHours: Double) async {
        await MainActor.run {
            collector.deviceStatus.isStreaming = false
            collector.recordingPhase = .analyzing
            collector.isCollecting = false
            collector.collectedPoints = rrPoints
            collector.streamingElapsedSeconds = 0
            collector.polarManager.recordRecordingHours(elapsedHours)
        }
    }

    // MARK: - Stop Streaming Helpers

    /// Returns a failed session when not enough beats were captured, and ends
    /// the recording the way every other stop does: the crash-recovery marker
    /// is cleared (a short or cancelled reading is not an interrupted session)
    /// and the recorder goes back to idle. The beats stay in the raw backup.
    private func handleInsufficientStreamingData(baseSession: HRVSession) async -> HRVSession {
        let failedSession = HRVSession(
            id: baseSession.id,
            startDate: baseSession.startDate,
            endDate: Date(),
            state: .failed,
            sessionType: baseSession.sessionType,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil
        )
        collector.clearPersistedRecordingState()
        await MainActor.run {
            collector.currentSession = failedSession
            collector.lastError = RRCollector.CollectorError.insufficientData
            collector.sessionStartTime = nil
            collector.recordingPhase = .idle
        }
        return failedSession
    }

    /// Runs artifact detection, HRV analysis and verification on quick-streaming
    /// data. Overnight streaming never reaches here (`stopStreamingSession`
    /// routes it to `stopOvernightStreaming`), and a quick reading carries no
    /// recovery score: a spot check mid-walk is not morning physiology. The
    /// analysis result is still kept so the user can see their HRV at the time.
    private func analyzeStreamingData(rrPoints: [RRPoint], baseSession: HRVSession) async -> HRVSession {
        let series = RRSeries(points: rrPoints, sessionId: baseSession.id, startDate: baseSession.startDate)
        let analyzingSession = publishAnalyzingSession(on: collector, baseSession: baseSession, series: series)
        let flags = collector.artifactDetector.detectArtifacts(in: series)
        if collector.settingsManager.settings.enableTrainingLoadIntegration {
            collector.cachedTrainingLoad = await collector.healthKit.calculateTrainingLoad()
        }
        let analysisResult = collector.analysisPipeline.analyzeFullSeries(
            series: series, flags: flags,
            trainingContext: collector.createTrainingContext(), ansConfig: collector.ansConfig(for: baseSession)
        )
        var finalSession = HRVSession(
            id: analyzingSession.id, startDate: analyzingSession.startDate, endDate: analyzingSession.endDate,
            state: analysisResult != nil ? .complete : .failed, sessionType: baseSession.sessionType,
            rrSeries: series, analysisResult: analysisResult, artifactFlags: flags
        )
        finalSession.deviceProvenance = baseSession.deviceProvenance
        await publishStreamingResult(finalSession, verifyResult: collector.streamingVerification.verify(series, flags: flags))
        return finalSession
    }

    private func publishStreamingResult(_ finalSession: HRVSession, verifyResult: Verification.Result) async {
        let deviation = collector.baselineTracker.deviation(for: finalSession)
        await MainActor.run {
            collector.currentSession = finalSession
            collector.verificationResult = verifyResult
            collector.recoveryWindow = nil
            collector.needsAcceptance = false
            collector.baselineDeviation = deviation
            collector.sessionStartTime = nil
            collector.recordingPhase = .idle
        }
    }

    /// Archives a completed streaming session and updates baselines.
    private func archiveAndFinalizeStreamingSession(_ session: HRVSession) async {
        guard session.state == .complete else {
            collector.clearPersistedRecordingState()
            return
        }
        do {
            try collector.archive.archive(session)
            collector.rawBackup.markAsArchived(session.id)
            collector.clearPersistedRecordingState()
            collector.baselineTracker.update(with: session, sleepSchedule: collector.settingsManager.settings.sleepSchedule)
            await MainActor.run { collector.archiveSignal.notifyChanged() }
            let cloudSync = collector.cloudSyncManager // read before the hop, not through the collector
            Task { await cloudSync.uploadSession(session) }
        } catch {
            debugLog("[RRCollector] Warning: Failed to archive streaming session: \(error)")
        }
    }
}

/// Show the analysing state while an analysis runs, and hand back the session
/// the analysis is anchored to. Used by the quick-streaming stop path;
/// file-scope because it names nothing of `RRCollector` beyond
/// `currentSession`.
@MainActor
func publishAnalyzingSession(on collector: RRCollector, baseSession: HRVSession, series: RRSeries) -> HRVSession {
    let analyzingSession = HRVSession(
        id: baseSession.id, startDate: baseSession.startDate, endDate: Date(),
        state: .analyzing, sessionType: baseSession.sessionType,
        rrSeries: series, analysisResult: nil, artifactFlags: nil
    )
    collector.currentSession = analyzingSession
    return analyzingSession
}
