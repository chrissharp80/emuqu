import Foundation

// MARK: - Pause/Resume Recording

extension CollectorSessionControl {
    // MARK: - Persisted Pause State

    static let pausedSessionIdKey = UserDefaultsKeys.pausedSessionId
    /// The paused night's capture choice. The recording marker that also
    /// holds it is cleared at pause, and Resume arms the strap by it.
    private static let pausedCaptureModeKey = "pausedSessionUsesDeviceBackup"

    func persistPausedSessionState(sessionId: UUID) {
        UserDefaults.standard.set(sessionId.uuidString, forKey: Self.pausedSessionIdKey)
        UserDefaults.standard.set(collector.overnightRun.usesDeviceBackup, forKey: Self.pausedCaptureModeKey)
    }

    func clearPausedSessionState() {
        UserDefaults.standard.removeObject(forKey: Self.pausedSessionIdKey)
        UserDefaults.standard.removeObject(forKey: Self.pausedCaptureModeKey)
    }

    /// Whether the paused night used the strap's internal recording; nil
    /// when no night is paused or it was paused before this was kept.
    func persistedPausedCaptureMode() -> Bool? {
        UserDefaults.standard.object(forKey: Self.pausedCaptureModeKey) as? Bool
    }

    func getPersistedPausedSessionId() -> UUID? {
        guard let str = UserDefaults.standard.string(forKey: Self.pausedSessionIdKey) else { return nil }
        return UUID(uuidString: str)
    }

    // MARK: - Pause

    /// Pause overnight streaming: save + score immediately, but keep resumable.
    /// Even very short recordings (e.g. a bathroom break after just starting)
    /// are saved with their raw RR data so the user can resume.
    ///
    /// The gather downloads from the strap before anything is saved, so the
    /// background assertion starts at once (see `stopOvernightStreaming`), and
    /// the arming loop is ended before anything stops so it cannot run during
    /// that download.
    ///
    /// The pause claims the night's ending before its first suspension and
    /// holds it until the night is paused, so a second pause (a tap while
    /// reconnect exhaustion auto-pauses), a Stop or a Discard returns without
    /// touching the night. Returns nil then, and when the paused night could
    /// not be archived.
    func pauseOvernightStreaming() async -> HRVSession? {
        guard let claim = collector.streamingLifecycle.claimOvernightEnding() else { return nil }
        defer { collector.streamingLifecycle.releaseOvernightEnding(claim) }
        let bgTask = BackgroundTaskAssertion.forRecordingStop(named: "OvernightPause")
        defer { bgTask.end() }
        await collector.overnightStreaming.endDeviceRecordingArming()
        debugLog("[RRCollector] ⏸ Pausing overnight streaming...")

        // Capture the original session before gatherOvernightData() can overwrite
        // currentSession with a failed placeholder (which drops deviceProvenance etc.)
        let originalSession = collector.sessionState.currentSession ?? HRVSession()

        if let data = await collector.morning.gatherOvernightData() {
            return await pauseWithFullAnalysis(data: data)
        }

        // Short-recording path: not enough data for analysis, but still save
        // whatever we have so the user can resume and accumulate more data.
        // gatherOvernightData() already stopped streaming, backed up raw data,
        // and set collectedPoints — we just need to build a paused session.
        return await pauseWithShortRecording(originalSession: originalSession)
    }

    // MARK: - pauseOvernightStreaming Helpers

    /// Full analysis pause path: merge parent data, analyze, archive, update UI.
    /// A night the archive would not take is not published as paused
    /// (`publishUnsavedPause`); the strap's beats the gather downloaded, which
    /// the stream's backup does not hold, get a backup of their own first.
    private func pauseWithFullAnalysis(data: OvernightStreamingCoordinator.OvernightDataResult) async -> HRVSession? {
        let merged = collector.overnightStreaming.mergeParentSessionData(data: data)
        let totalBeats = merged.points.count
        await MainActor.run {
            collector.morningCoordination.morningStatus = .analyzing(beats: totalBeats, streamedBeats: data.streamingBeats, deviceBeats: data.deviceBeats, source: data.dataSource)
        }
        var pausedSession = await collector.morning.processOvernightData(
            points: merged.points, baseSession: merged.baseSession, dataSource: data.dataSource,
            reconnectCount: data.reconnectCount, streamingBeats: data.streamingBeats,
            deviceBeats: data.deviceBeats, awaitsReview: false
        )
        pausedSession.state = .paused
        pausedSession.pausedDate = Date()
        guard await archiveAndPersistPause(pausedSession, label: "Paused") else {
            collector.morning.rescueDownloadedBeats(data.downloadedPoints, baseSession: data.baseSession)
            publishUnsavedPause(pausedSession)
            return nil
        }
        await publishPausedState(pausedSession, totalBeats: totalBeats, clearLastError: false)
        debugLog("[RRCollector] ⏸ Recording paused. Data saved. Resumable.")
        return pausedSession
    }

    /// Short-recording pause path: save raw data without analysis for later
    /// resume. A resumed segment carries its parent's beats forward exactly
    /// as the full-analysis path does: the next resume merges only with its
    /// direct parent, so a short segment saved with its own beats alone (or
    /// none) would drop the start of the night. Its beats are the streamed
    /// ones, already in the stream's backup, so a night the archive would not
    /// take only goes unpublished.
    private func pauseWithShortRecording(originalSession: HRVSession) async -> HRVSession? {
        let points = await MainActor.run { collector.sessionState.collectedPoints }
        debugLog("[RRCollector] ⏸ Short recording (\(points.count) beats) — saving for resume without analysis")
        let merged = collector.overnightStreaming.mergeParentSessionData(data: OvernightStreamingCoordinator.OvernightDataResult(
            points: points, baseSession: originalSession, streamingBeats: points.count,
            deviceBeats: nil, dataSource: "streaming", reconnectCount: 0
        ))
        let pausedSession = CollectorSessionControl.shortPausedSession(from: merged.baseSession, points: merged.points)
        guard await archiveAndPersistPause(pausedSession, label: "Short paused") else {
            publishUnsavedPause(pausedSession)
            return nil
        }
        // gatherOvernightData's insufficientData error isn't a failure on
        // this path, so it is cleared; any other error stays.
        await publishPausedState(pausedSession, totalBeats: merged.points.count, clearLastError: true)
        debugLog("[RRCollector] ⏸ Recording paused (short). Resumable.")
        return pausedSession
    }

    /// `originalSession` is the segment itself, or the segment re-anchored to
    /// its parent's start when the parent's beats were merged in.
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
            collector.sessionState.currentSession = pausedSession
            collector.streamingLifecycle.pausedSession = pausedSession
            collector.streamingLifecycle.pausedBeatCount = totalBeats
            collector.streamingLifecycle.isPaused = true
            collector.sessionState.recordingPhase = .paused(sessionId: pausedSession.id)
            collector.sessionState.needsAcceptance = false
            collector.morningCoordination.morningStatus = nil
            if clearLastError, Self.isInsufficientData(collector.sessionState.lastError) { collector.sessionState.lastError = nil }
        }
    }

    /// A pause the archive would not take: Resume could link to nothing, so no
    /// paused state is published. The recorder returns to idle with the
    /// archive's error shown and the night shown as failed, as a failed
    /// morning is. The night's beats stay in its raw backup and its recording
    /// marker stays, so Lost Sessions and the launch recovery still offer it.
    private func publishUnsavedPause(_ session: HRVSession) {
        var unsaved = session
        unsaved.state = .failed
        collector.sessionState.currentSession = unsaved
        collector.sessionState.needsAcceptance = false
        collector.sessionState.recordingPhase = .idle
        collector.morningCoordination.morningStatus = nil
        debugLog("[RRCollector] ⏸ Pause not saved — night \(session.id.uuidString.prefix(8)) left in its raw backup", level: .error)
    }

    /// The short pause path has no use for gather's "not enough data" error;
    /// a strap that still holds the paused part is news the user keeps.
    private static func isInsufficientData(_ error: Error?) -> Bool {
        (error as? RRCollector.CollectorError) == .insufficientData
    }

    /// Archive the paused session, then swap the recording marker for the
    /// paused one. When the archive write fails the recording marker stays:
    /// the paused marker would name a session the archive does not hold, and
    /// the launch then offers the night for recovery from its backup instead.
    /// Returns whether the session was archived.
    private func archiveAndPersistPause(_ session: HRVSession, label: String) async -> Bool {
        guard await archivePausedSession(session, label: label) else { return false }
        persistPauseAndClearRecording(sessionId: session.id)
        return true
    }

    /// Archive a paused session; a failure is logged and shown to the user.
    /// Asked to go to iCloud again: a segment paused again after a resume is
    /// an id iCloud already holds, which sync would otherwise never re-send.
    private func archivePausedSession(_ session: HRVSession, label: String) async -> Bool {
        do {
            try collector.archive.archive(session, skipSameNightMerge: false, requestingReupload: true)
            debugLog("[RRCollector] ✅ \(label) session archived: \(session.id.uuidString.prefix(8))")
            return true
        } catch {
            debugLog("[RRCollector] ⚠️ Failed to archive \(label.lowercased()) session: \(error)", level: .error)
            await MainActor.run { self.collector.sessionState.lastError = error }
            return false
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
    /// See the note in `startOvernightStreaming`. Refused, like a new night,
    /// while an earlier ending is still in progress. Streaming starts first,
    /// as for a fresh night, so a failed resume leaves no arming loop, and the
    /// child is linked to its parent only once streaming started, so a failed
    /// resume leaves no link.
    func resumeOvernightStreaming(linkedSessionId: UUID) throws {
        try collector.overnightStreaming.refuseWhileEndingInProgress()
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
        collector.overnightRun.deviceBackupActive = false
        try collector.polarManager.startStreaming()
        if collector.overnightRun.usesDeviceBackup, collector.polarManager.connectedDeviceType != .veritySense {
            launchResumeDeviceBackupRecording()
        }
        linkChildToParent(childId: session.id, parentId: linkedSessionId)
        commitResumedSession(session)
    }

    /// Publish the resumed session's state, persist it for crash recovery,
    /// drop the paused-session marker, and restart the 1 Hz overnight timer.
    private func commitResumedSession(_ session: HRVSession) {
        resetStateForResumedSession(session)
        collector.persistRecordingState(sessionId: session.id, startTime: Date(), sessionType: session.sessionType)
        clearPausedSessionState()
        collector.overnightStreaming.startOvernightStreamingTimer()
        // The pause's gather stopped it; the resumed segment samples as a night does.
        collector.services.systemDiagnosticsManager.startSamplingDuringRecording()
        debugLog("[RRCollector] ▶ Resumed overnight streaming. New session: \(session.id.uuidString.prefix(8))")
    }

    /// Preserve the parent session's type so nap sessions stay as naps after resume.
    private func parentSessionType(of linkedSessionId: UUID) -> SessionType {
        collector.archive.retrieveOrLog(linkedSessionId)?.sessionType ?? .overnight
    }

    /// Update the parent session so it knows about this child. The link is
    /// added to the archive's copy as it is at the write, and the parent goes
    /// to iCloud again so other devices see it too.
    private func linkChildToParent(childId: UUID, parentId: UUID) {
        do {
            guard collector.archive.store.exists(parentId) else { return }
            try collector.archive.update(parentId, requestingReupload: true) { parent in
                var links = parent.linkedSessionIds ?? []
                links.append(childId)
                parent.linkedSessionIds = links
            }
        } catch {
            debugLog("[RRCollector] ⚠️ Failed to link child \(childId.uuidString.prefix(8)) to parent \(parentId.uuidString.prefix(8)): \(error)", level: .error)
        }
    }

    /// The resumed segment arms the strap's recording the same way a fresh
    /// night does: on the strap's readiness, for as long as the night lasts.
    /// Arming clears the H10, so a paused part the app never downloaded is
    /// downloaded to the rescue backup first, and a part that cannot be
    /// keeps the strap from being armed (`StrapStartSequence`).
    private func launchResumeDeviceBackupRecording() {
        collector.overnightStreaming.launchDeviceRecordingLoop()
    }

    /// The paused segment's beat count carries forward so the UI keeps counting
    /// the whole night rather than restarting from zero. The pause's errors
    /// were about the paused part; the segment starts without them.
    private func resetStateForResumedSession(_ session: HRVSession) {
        let priorBeats = collector.streamingLifecycle.pausedBeatCount
        debugLog("[RRCollector] Resume: carrying forward \(priorBeats) beats")
        collector.sessionState.currentSession = session
        collector.sessionState.collectedPoints = []
        collector.sessionStartTime = Date()
        collector.streamingLifecycle.isStreamingMode = true
        collector.streamingLifecycle.isOvernightStreaming = true
        collector.overnightRun.isEnding = false
        collector.streamingLifecycle.isPaused = false
        collector.sessionState.recordingPhase = .overnightStreaming
        collector.streamingLifecycle.pausedSession = nil
        collector.streamingLifecycle.pausedBeatCount = priorBeats
        collector.streamingLifecycle.streamingTargetSeconds = Int.max
        collector.streamingLifecycle.streamingElapsedSeconds = 0
        collector.sessionState.isCollecting = true
        collector.lastSeenReconnectCount = 0
        collector.sessionState.verificationResult = nil
        collector.sessionState.baselineDeviation = nil
        collector.deviceFetchPolicy = .automatic
        collector.sessionState.lastError = nil
    }

    // MARK: - Finalize

    /// Finalize a paused session — mark as complete and auto-save
    ///
    /// The acceptance flow only triggers when there are analysis results.
    /// Short-pause sessions (saved without analysis for resume purposes)
    /// have nothing to accept: they are saved and the recorder returns to idle.
    /// When the save fails the night stays paused, as the archive still holds
    /// it, so Resume and Done remain.
    ///
    /// The night is finalized from the archive's copy, which a sleep refresh
    /// or a rescore may have rewritten since the pause; the copy held at the
    /// pause would put the older sleep and score back.
    func finalizeFromPause() {
        guard let session = collector.streamingLifecycle.pausedSession, session.state == .paused else {
            debugLog("[RRCollector] Cannot finalize — no paused session")
            return
        }
        debugLog("[RRCollector] Finalizing paused session \(session.id.uuidString.prefix(8))")
        guard let finalSession = rearchiveFinalized(session) else { return }
        collector.baselineTracker.update(with: finalSession, sleepSchedule: collector.settingsManager.settings.sleepSchedule)
        collector.sessionState.currentSession = finalSession
        collector.sessionState.needsAcceptance = finalSession.analysisResult != nil
        collector.sessionState.reviewArchivedSessionId = collector.sessionState.needsAcceptance ? finalSession.id : nil
        collector.sessionState.reviewArchivedEntries = SessionState.ReviewEntries(of: finalSession)
        collector.streamingLifecycle.isPaused = false
        collector.sessionState.recordingPhase = collector.sessionState.needsAcceptance ? .awaitingAcceptance : .idle
        collector.streamingLifecycle.pausedSession = nil
        clearPausedSessionState()
    }

    /// Marks the archive's copy of the paused night complete, in place, and
    /// returns it as written. A night the archive no longer holds is saved
    /// from the held copy. Either write asks iCloud for the night again, as
    /// the finished night replaces the paused one there. Nil when the write
    /// failed; the error is shown.
    private func rearchiveFinalized(_ paused: HRVSession) -> HRVSession? {
        var finalSession = paused
        finalSession.state = .complete
        do {
            guard collector.archive.store.exists(paused.id) else {
                try collector.archive.archive(finalSession, skipSameNightMerge: false, requestingReupload: true)
                return finalSession
            }
            try collector.archive.update(paused.id, requestingReupload: true) { $0.state = .complete }
            return try collector.archive.retrieve(paused.id) ?? finalSession
        } catch {
            debugLog("[RRCollector] ⚠️ Failed to re-archive finalized session: \(error)", level: .error)
            collector.sessionState.lastError = error
            return nil
        }
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
        collector.streamingLifecycle.pausedSession = session
        collector.sessionState.currentSession = session
        collector.streamingLifecycle.isPaused = true
        collector.streamingLifecycle.pausedBeatCount = session.rrSeries?.points.count ?? 0
        collector.sessionState.recordingPhase = .paused(sessionId: id)
        if let usesDeviceBackup = persistedPausedCaptureMode() { collector.overnightRun.usesDeviceBackup = usesDeviceBackup }
    }
}
