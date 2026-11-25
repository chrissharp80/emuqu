import AudioToolbox
import Foundation
import UIKit

// MARK: - Streaming Mode (Quick Readings)

extension CollectorSessionControl {
    // MARK: - Sound Constants

    /// System sound ID for the "received message" chime (standard iOS notification sound)
    static let kCompletionSoundID: SystemSoundID = 1007

    /// Fewest beats a quick reading is analysed on; the streaming
    /// verification checks the same number, and the insufficient-data
    /// message quotes it.
    nonisolated static let minimumQuickReadingBeats = 120

    /// How long a reading that reached its target may run on to collect
    /// that minimum: a 2-minute reading below 60 bpm holds fewer than 120
    /// beats, and a minute more covers a heart rate down to 40 bpm.
    private static let maxQuickReadingExtensionSeconds = 60

    /// Start a streaming session for quick HRV reading
    ///
    /// Refused while a night is paused or being ended: that night owns the
    /// current session and the recording phase until it is resumed, finished
    /// or saved.
    /// - Parameter durationSeconds: Target duration (180 for 3min, 300 for 5min)
    @MainActor
    func startStreamingSession(durationSeconds: Int = 180) throws {
        try collector.strapGuards.requireConnectedWithNoNightHeld(starting: "a quick reading")
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
        collector.recordingStore.persist(sessionId: session.id, startTime: Date(), sessionType: .quick)
        debugLog("[RRCollector] Started streaming session: target=\(durationSeconds)s (\(durationSeconds / 60)min)")
        // Start countdown timer - runs on main thread for UI updates
        startStreamingTimer()
    }

    @MainActor
    private func resetStateForQuickStreaming(_ session: HRVSession, durationSeconds: Int) {
        collector.sessionState.currentSession = session
        collector.sessionState.collectedPoints = []
        collector.streamingLifecycle.sessionStartTime = Date()
        collector.streamingLifecycle.isStreamingMode = true
        collector.sessionState.recordingPhase = .streaming(targetSeconds: durationSeconds)
        collector.streamingLifecycle.streamingTargetSeconds = durationSeconds
        collector.streamingLifecycle.streamingElapsedSeconds = 0
        collector.sessionState.isCollecting = true
        collector.streamingLifecycle.pausedBeatCount = 0
    }

    /// Start the streaming countdown timer.
    ///
    /// 0.25s tolerance lets iOS coalesce this timer with other 1Hz work.
    /// The display only shows seconds, so ±0.25s is invisible to the user
    /// but meaningfully reduces CPU wakeups during overnight recording.
    func startStreamingTimer() {
        collector.streamingLifecycle.streamingTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak collector] _ in
            Task { @MainActor in
                collector?.control.streamingCountdownTick()
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        collector.streamingLifecycle.streamingTimer = timer
    }

    /// One 1 Hz tick of the quick-capture countdown. The guard is thread
    /// safety: streaming may have been stopped while the Task was pending.
    /// The elapsed time is the wall clock's (`streamingElapsedNow`), so a
    /// reading the app was suspended through still ends at its target.
    @MainActor
    private func streamingCountdownTick() {
        guard collector.streamingLifecycle.isStreamingMode, collector.streamingLifecycle.streamingTimer != nil else { return }
        collector.streamingLifecycle.streamingElapsedSeconds = collector.streamingLifecycle.streamingElapsedNow
        if let session = collector.sessionState.currentSession {
            runQuickStreamingBackup(session: session)
        }
        guard quickReadingComplete() else { return }
        debugLog("[RRCollector] Streaming complete: elapsed=\(collector.streamingLifecycle.streamingElapsedSeconds)s, target=\(collector.streamingLifecycle.streamingTargetSeconds)s")
        collector.streamingLifecycle.streamingTimer?.invalidate()
        collector.streamingLifecycle.streamingTimer = nil
        // Play completion sound and vibrate (works even in silent mode)
        playCompletionAlert()
        // Notify that streaming is complete (UI should call stopStreamingSession)
        collector.streamingLifecycle.onStreamingComplete?()
    }

    /// The target is reached and the reading holds the minimum beats, or has
    /// run on as long as it may for them.
    @MainActor
    private func quickReadingComplete() -> Bool {
        let elapsed = collector.streamingLifecycle.streamingElapsedSeconds
        let target = collector.streamingLifecycle.streamingTargetSeconds
        guard elapsed >= target else { return false }
        return collector.polarManager.streamedRRPoints.count >= Self.minimumQuickReadingBeats
            || elapsed >= target + Self.maxQuickReadingExtensionSeconds
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
        collector.streamingLifecycle.streamingTimer?.invalidate()
        collector.streamingLifecycle.streamingTimer = nil
    }

    /// Stop streaming session and analyze.
    ///
    /// Safety: if this is an overnight streaming session, route to the proper
    /// overnight flow instead.
    func stopStreamingSession() async -> HRVSession? {
        guard collector.streamingLifecycle.isStreamingMode else { return nil }
        if collector.streamingLifecycle.isOvernightStreaming {
            debugLog("[RRCollector] ⚠️ stopStreamingSession() called during overnight streaming - redirecting to stopOvernightStreaming()")
            return await collector.overnightStreaming.stopOvernightStreaming()
        }
        stopStreamingTimer()
        collector.streamingLifecycle.isStreamingMode = false
        let baseSession = collector.sessionState.currentSession ?? HRVSession()
        let elapsedHoursForBattery = collector.streamingLifecycle.streamingHoursForBattery
        let rrPoints = collector.polarManager.stopStreaming()
        await publishQuickStreamingStopped(rrPoints: rrPoints, elapsedHours: elapsedHoursForBattery)
        await collector.overnightStreaming.backupStreamingData(rrPoints, sessionId: baseSession.id)
        // A slow heart's 2-minute reading ran on until it had these (see
        // `quickReadingComplete`); one stopped early can still fall short.
        guard rrPoints.count >= Self.minimumQuickReadingBeats else {
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
        collector.polarManager.discovery.disconnect()
    }

    private func publishQuickStreamingStopped(rrPoints: [RRPoint], elapsedHours: Double) async {
        await MainActor.run {
            collector.deviceStatus.isStreaming = false
            collector.sessionState.recordingPhase = .analyzing
            collector.sessionState.isCollecting = false
            collector.sessionState.collectedPoints = rrPoints
            collector.streamingLifecycle.streamingElapsedSeconds = 0
            collector.polarManager.battery.recordRecordingHours(elapsedHours)
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
        collector.recordingStore.clear()
        await MainActor.run {
            collector.sessionState.currentSession = failedSession
            collector.sessionState.lastError = RRCollector.CollectorError.insufficientData
            collector.streamingLifecycle.sessionStartTime = nil
            collector.sessionState.recordingPhase = .idle
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
            collector.scoring.cachedTrainingLoad = await collector.healthKit.calculateTrainingLoad()
        }
        let analysisResult = collector.analysisPipeline.analyzeFullSeries(
            series: series, flags: flags,
            trainingContext: collector.scoring.createTrainingContext(), ansConfig: collector.scoring.ansConfig(for: baseSession)
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
            collector.sessionState.currentSession = finalSession
            collector.sessionState.verificationResult = verifyResult
            collector.sessionState.recoveryWindow = nil
            collector.sessionState.needsAcceptance = false
            collector.sessionState.baselineDeviation = deviation
            collector.streamingLifecycle.sessionStartTime = nil
            collector.sessionState.recordingPhase = .idle
        }
    }

    /// Archives a completed streaming session and updates baselines.
    private func archiveAndFinalizeStreamingSession(_ session: HRVSession) async {
        guard session.state == .complete else {
            collector.recordingStore.clear()
            return
        }
        do {
            try collector.archive.archive(session)
            collector.rawBackup.markAsArchived(session.id)
            collector.recordingStore.clear()
            collector.baselineTracker.update(with: session, sleepSchedule: collector.settingsManager.settings.sleepSchedule)
            await MainActor.run { collector.archiveSignal.notifyChanged() }
            let cloudSync = collector.cloudSyncManager // read before the hop, not through the collector
            Task { await cloudSync.uploadSession(session) }
        } catch {
            // The reading on screen is not saved: say so. Its recording marker
            // stays, so the next launch offers it from the raw backup.
            debugLog("[RRCollector] Failed to archive streaming session: \(error)", level: .error)
            await MainActor.run { collector.sessionState.lastError = error }
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
    collector.sessionState.currentSession = analyzingSession
    return analyzingSession
}
