import Foundation

// MARK: - Pause/Resume Recording

extension CollectorSessionControl {
    // MARK: - Persisted Pause State

    static let pausedSessionIdKey = UserDefaultsKeys.pausedSessionId

    func persistPausedSessionState(sessionId: UUID) {
        UserDefaults.standard.set(sessionId.uuidString, forKey: Self.pausedSessionIdKey)
    }

    func clearPausedSessionState() {
        UserDefaults.standard.removeObject(forKey: Self.pausedSessionIdKey)
    }

    func getPersistedPausedSessionId() -> UUID? {
        guard let str = UserDefaults.standard.string(forKey: Self.pausedSessionIdKey) else { return nil }
        return UUID(uuidString: str)
    }

    // MARK: - Pause

    /// Pause overnight streaming: save + score immediately, but keep resumable.
    /// Always succeeds — even very short recordings (e.g. a bathroom break after
    /// just starting) are saved with their raw RR data so the user can resume.
    func pauseOvernightStreaming() async -> HRVSession? {
        guard collector.isOvernightStreaming else { return nil }

        debugLog("[RRCollector] ⏸ Pausing overnight streaming...")

        // Capture the original session before collector.gatherOvernightData() can overwrite
        // collector.currentSession with a failed placeholder (which drops deviceProvenance etc.)
        let originalSession = collector.currentSession ?? HRVSession()

        if let data = await collector.gatherOvernightData() {
            return await pauseWithFullAnalysis(data: data)
        }

        // Short-recording path: not enough data for analysis, but still save
        // whatever we have so the user can resume and accumulate more data.
        // collector.gatherOvernightData() already stopped streaming, backed up raw data,
        // and set collector.collectedPoints — we just need to build a paused session.
        return await pauseWithShortRecording(originalSession: originalSession)
    }

    // MARK: - pauseOvernightStreaming Helpers

    /// Full analysis pause path: merge parent data, analyze, collector.archive, update UI
    private func pauseWithFullAnalysis(data: OvernightStreamingCoordinator.OvernightDataResult) async -> HRVSession {
        let merged = collector.mergeParentSessionData(data: data)
        let totalBeats = merged.points.count
        await MainActor.run {
            collector.morningStatus = .analyzing(beats: totalBeats, streamedBeats: data.streamingBeats, deviceBeats: data.deviceBeats, source: data.dataSource)
        }
        var pausedSession = await collector.processOvernightData(
            points: merged.points,
            baseSession: merged.baseSession,
            dataSource: data.dataSource,
            reconnectCount: data.reconnectCount,
            streamingBeats: data.streamingBeats,
            deviceBeats: data.deviceBeats
        )
        pausedSession.state = .paused
        pausedSession.pausedDate = Date()
        await archivePausedSession(pausedSession, label: "Paused")
        persistPauseAndClearRecording(sessionId: pausedSession.id)
        await publishPausedState(pausedSession, totalBeats: totalBeats, clearLastError: false)
        debugLog("[RRCollector] ⏸ Recording paused. Data saved. Resumable.")
        return pausedSession
    }

    /// Short-recording pause path: save raw data without analysis for later resume
    private func pauseWithShortRecording(originalSession: HRVSession) async -> HRVSession {
        let points = await MainActor.run { collector.collectedPoints }
        debugLog("[RRCollector] ⏸ Short recording (\(points.count) beats) — saving for resume without analysis")
        let pausedSession = CollectorSessionControl.shortPausedSession(from: originalSession, points: points)
        await archivePausedSession(pausedSession, label: "Short paused")
        persistPauseAndClearRecording(sessionId: pausedSession.id)
        // `collector.lastError` is cleared too: the insufficientData error from
        // collector.gatherOvernightData isn't a failure on this path.
        await publishPausedState(pausedSession, totalBeats: points.count, clearLastError: true)
        debugLog("[RRCollector] ⏸ Recording paused (short). Resumable.")
        return pausedSession
    }

    private static func shortPausedSession(from originalSession: HRVSession, points: [RRPoint]) -> HRVSession {
        HRVSession(
            id: originalSession.id,
            startDate: originalSession.startDate,
            endDate: Date(),
            state: .paused,
            sessionType: originalSession.sessionType,
            rrSeries: RRSeries(points: points, sessionId: originalSession.id, startDate: originalSession.startDate),
            analysisResult: nil,
            artifactFlags: nil,
            deviceProvenance: originalSession.deviceProvenance,
            linkedSessionIds: originalSession.linkedSessionIds,
            pausedDate: Date()
        )
    }

    private func publishPausedState(_ pausedSession: HRVSession, totalBeats: Int, clearLastError: Bool) async {
        await MainActor.run {
            collector.currentSession = pausedSession
            collector.pausedSession = pausedSession
            collector.pausedBeatCount = totalBeats
            collector.isPaused = true
            collector.recordingPhase = .paused(sessionId: pausedSession.id)
            collector.needsAcceptance = false
            collector.morningStatus = nil
            if clearLastError { collector.lastError = nil }
        }
    }

    /// Archive a paused session, logging any errors
    private func archivePausedSession(_ session: HRVSession, label: String) async {
        do {
            try collector.archive.archive(session)
            debugLog("[RRCollector] ✅ \(label) session archived: \(session.id.uuidString.prefix(8))")
        } catch {
            debugLog("[RRCollector] ⚠️ Failed to archive \(label.lowercased()) session: \(error)", level: .error)
            await MainActor.run { self.collector.lastError = error }
        }
    }

    /// Persist paused state BEFORE clearing recording state.
    /// If the app crashes between these two calls, we need at least one
    /// persisted marker to survive. Paused state is written first so
    /// restorePausedStateIfNeeded() can find it; recording state is cleared
    /// second. The reverse order (clear first, persist second) creates a
    /// window where neither marker exists and the session is orphaned.
    private func persistPauseAndClearRecording(sessionId: UUID) {
        persistPausedSessionState(sessionId: sessionId)
        collector.clearPersistedRecordingState()
    }

    // MARK: - Resume

    /// Resume recording after a pause. Creates a new session linked to the paused one.
    ///
    /// No overnight keep-alives (App Store 2.5.4);
    /// `bluetooth-central` carries resumed overnight segments too.
    /// See the note in `startOvernightStreaming`.
    func resumeOvernightStreaming(linkedSessionId: UUID) throws {
        guard collector.polarManager.connectionState == .connected else {
            throw RRCollector.CollectorError.notConnected
        }
        guard !collector.polarManager.isStreaming else {
            throw RRCollector.CollectorError.alreadyRecording
        }
        debugLog("[RRCollector] ▶ Resuming overnight streaming, linked to \(linkedSessionId.uuidString.prefix(8))")
        var session = HRVSession(
            sessionType: parentSessionType(of: linkedSessionId), deviceProvenance: .streaming(from: collector.polarManager)
        )
        session.linkedSessionIds = [linkedSessionId]
        linkChildToParent(childId: session.id, parentId: linkedSessionId)
        // Resume streaming; internal backup only when this session mode uses it.
        collector.overnightDeviceBackupActive = false
        if collector.useDeviceBackupForOvernight, collector.polarManager.connectedDeviceType != .veritySense {
            launchResumeDeviceBackupRecording()
        }
        try collector.polarManager.startStreaming()
        commitResumedSession(session)
    }

    /// Publish the resumed session's state, persist it for crash recovery, drop
    /// the paused-session marker, and restart the 1 Hz overnight timer.
    private func commitResumedSession(_ session: HRVSession) {
        resetStateForResumedSession(session)
        collector.persistRecordingState(sessionId: session.id, startTime: Date(), sessionType: .overnight)
        clearPausedSessionState()
        collector.startOvernightStreamingTimer()
        debugLog("[RRCollector] ▶ Resumed overnight streaming. New session: \(session.id.uuidString.prefix(8))")
    }

    /// Preserve the parent session's type so nap sessions stay as naps after resume.
    private func parentSessionType(of linkedSessionId: UUID) -> SessionType {
        collector.archive.retrieveOrLog(linkedSessionId)?.sessionType ?? .overnight
    }

    /// Update the parent session so it knows about this child.
    private func linkChildToParent(childId: UUID, parentId: UUID) {
        do {
            guard var parentSession = try collector.archive.retrieve(parentId) else { return }
            var links = parentSession.linkedSessionIds ?? []
            links.append(childId)
            parentSession.linkedSessionIds = links
            _ = try collector.archive.archive(parentSession)
        } catch {
            debugLog("[RRCollector] ⚠️ Failed to link child \(childId.uuidString.prefix(8)) to parent \(parentId.uuidString.prefix(8)): \(error)", level: .error)
        }
    }

    /// The resumed segment arms the strap's recording the same way a fresh
    /// night does: on the strap's readiness, for as long as the night lasts.
    private func launchResumeDeviceBackupRecording() {
        collector.overnightStreaming.launchDeviceRecordingLoop()
    }

    /// The paused segment's beat count carries forward so the UI keeps counting
    /// the whole night rather than restarting from zero.
    private func resetStateForResumedSession(_ session: HRVSession) {
        let priorBeats = collector.pausedBeatCount
        debugLog("[RRCollector] Resume: carrying forward \(priorBeats) beats")
        collector.currentSession = session
        collector.collectedPoints = []
        collector.sessionStartTime = Date()
        collector.isStreamingMode = true
        collector.isOvernightStreaming = true
        collector.isPaused = false
        collector.recordingPhase = .overnightStreaming
        collector.pausedSession = nil
        collector.pausedBeatCount = priorBeats
        collector.streamingTargetSeconds = Int.max
        collector.streamingElapsedSeconds = 0
        collector.isCollecting = true
        collector.lastSeenReconnectCount = 0
        collector.verificationResult = nil
        collector.baselineDeviation = nil
    }

    // MARK: - Finalize

    /// Finalize a paused session — mark as complete and auto-save
    ///
    /// The acceptance flow only triggers when there are analysis results.
    /// Short-pause sessions (saved without analysis for resume purposes)
    /// have nothing to accept — those just clean up silently.
    func finalizeFromPause() {
        guard let session = collector.pausedSession, session.state == .paused else {
            debugLog("[RRCollector] Cannot finalize — no paused session")
            return
        }
        debugLog("[RRCollector] Finalizing paused session \(session.id.uuidString.prefix(8))")
        var finalSession = session
        finalSession.state = .complete
        do {
            try collector.archive.archive(finalSession)
        } catch {
            debugLog("[RRCollector] ⚠️ Failed to re-archive finalized session: \(error)", level: .error)
            collector.lastError = error
        }
        collector.baselineTracker.update(with: finalSession, sleepSchedule: collector.settingsManager.settings.sleepSchedule)
        collector.currentSession = finalSession
        collector.needsAcceptance = finalSession.analysisResult != nil
        collector.isPaused = false
        collector.recordingPhase = finalSession.state == .complete ? .awaitingAcceptance : .idle
        collector.pausedSession = nil
        clearPausedSessionState()
    }

    // MARK: - Find & Restore

    /// Restore paused state on app launch so the Record tab shows Resume / Done.
    /// Session deserialization runs off the main thread to avoid blocking app startup.
    func restorePausedStateIfNeeded() {
        guard let pausedId = getPersistedPausedSessionId() else { return }
        let archive = collector.archive
        Task.detached(priority: .userInitiated) {
            guard let session = archive.retrieveOrLog(pausedId), session.state == .paused else { return }
            await MainActor.run { [weak collector] in collector?.control.publishRestoredPausedSession(session, id: pausedId) }
        }
    }

    @MainActor
    private func publishRestoredPausedSession(_ session: HRVSession, id: UUID) {
        debugLog("[RRCollector] Restoring paused state for session \(id.uuidString.prefix(8))")
        collector.pausedSession = session
        collector.currentSession = session
        collector.isPaused = true
        collector.pausedBeatCount = session.rrSeries?.points.count ?? 0
        collector.recordingPhase = .paused(sessionId: id)
    }
}
