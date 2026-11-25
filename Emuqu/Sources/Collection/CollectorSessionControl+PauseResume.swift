import Foundation

// MARK: - Pause/Resume Recording

extension CollectorSessionControl {
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
        guard let claim = streamingLifecycle.claimOvernightEnding() else { return nil }
        defer { streamingLifecycle.releaseOvernightEnding(claim) }
        let bgTask = BackgroundTaskAssertion.forRecordingStop(named: "OvernightPause")
        defer { bgTask.end() }
        await overnightStreaming.endDeviceRecordingArming()
        debugLog("[RRCollector] ⏸ Pausing overnight streaming...")

        // Capture the original session before gatherOvernightData() can overwrite
        // currentSession with a failed placeholder (which drops deviceProvenance etc.)
        let originalSession = sessionState.currentSession ?? HRVSession()

        if let data = await overnightStreaming.gatherOvernightData() {
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
    /// (`publishUnsavedPause`); the strap's beats the gather downloaded were
    /// backed up by the gather, before the analysis.
    private func pauseWithFullAnalysis(data: OvernightStreamingCoordinator.OvernightDataResult) async -> HRVSession? {
        let merged = overnightStreaming.mergeParentSessionData(data: data)
        let totalBeats = merged.points.count
        await MainActor.run {
            morningCoordination.morningStatus = .analyzing(beats: totalBeats, streamedBeats: data.streamingBeats, deviceBeats: data.deviceBeats, source: data.dataSource)
        }
        var pausedSession = await morning.processOvernightData(
            points: merged.points, baseSession: merged.baseSession, dataSource: data.dataSource,
            reconnectCount: data.reconnectCount, streamingBeats: data.streamingBeats,
            deviceBeats: data.deviceBeats, awaitsReview: false
        )
        pausedSession.state = .paused
        pausedSession.pausedDate = Date()
        guard await archiveAndPersistPause(pausedSession, label: "Paused") else {
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
        let points = await MainActor.run { sessionState.collectedPoints }
        debugLog("[RRCollector] ⏸ Short recording (\(points.count) beats) — saving for resume without analysis")
        let merged = overnightStreaming.mergeParentSessionData(data: OvernightStreamingCoordinator.OvernightDataResult(
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
            sessionState.currentSession = pausedSession
            streamingLifecycle.pausedSession = pausedSession
            streamingLifecycle.pausedBeatCount = totalBeats
            streamingLifecycle.isPaused = true
            sessionState.recordingPhase = .paused(sessionId: pausedSession.id)
            sessionState.needsAcceptance = false
            morningCoordination.morningStatus = nil
            if clearLastError, Self.isInsufficientData(sessionState.lastError) { sessionState.lastError = nil }
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
        sessionState.currentSession = unsaved
        sessionState.needsAcceptance = false
        sessionState.recordingPhase = .idle
        morningCoordination.morningStatus = nil
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
            try archive.archive(session, skipSameNightMerge: false, requestingReupload: true)
            debugLog("[RRCollector] ✅ \(label) session archived: \(session.id.uuidString.prefix(8))")
            return true
        } catch {
            debugLog("[RRCollector] ⚠️ Failed to archive \(label.lowercased()) session: \(error)", level: .error)
            await MainActor.run { self.sessionState.lastError = error }
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
        recordingStore.persistPaused(sessionId: sessionId)
        recordingStore.clear()
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
        try overnightStreaming.refuseWhileEndingInProgress()
        guard strapLink.connectionState == .connected else {
            throw RRCollector.CollectorError.notConnected
        }
        guard !strapStream.isStreaming else {
            throw RRCollector.CollectorError.alreadyRecording
        }
        debugLog("[RRCollector] ▶ Resuming overnight streaming, linked to \(linkedSessionId.uuidString.prefix(8))")
        var session = HRVSession(
            sessionType: parentSessionType(of: linkedSessionId), deviceProvenance: .streaming(from: strapLink)
        )
        session.linkedSessionIds = [linkedSessionId]
        overnightRun.deviceBackupActive = false
        try strapStream.startStreaming()
        if overnightRun.usesDeviceBackup, strapLink.connectedDeviceType != .veritySense {
            launchResumeDeviceBackupRecording()
        }
        linkChildToParent(childId: session.id, parentId: linkedSessionId)
        commitResumedSession(session)
    }

    /// Publish the resumed session's state, persist it for crash recovery,
    /// drop the paused-session marker, and restart the 1 Hz overnight timer.
    private func commitResumedSession(_ session: HRVSession) {
        resetStateForResumedSession(session)
        recordingStore.persist(sessionId: session.id, startTime: Date(), sessionType: session.sessionType)
        recordingStore.clearPaused()
        overnightStreaming.startOvernightStreamingTimer()
        // The pause's gather stopped it; the resumed segment samples as a night does.
        services.systemDiagnosticsManager.startSamplingDuringRecording()
        debugLog("[RRCollector] ▶ Resumed overnight streaming. New session: \(session.id.uuidString.prefix(8))")
    }

    /// Preserve the parent session's type so nap sessions stay as naps after resume.
    private func parentSessionType(of linkedSessionId: UUID) -> SessionType {
        archive.retrieveOrLog(linkedSessionId)?.sessionType ?? .overnight
    }

    /// Update the parent session so it knows about this child. The link is
    /// added to the archive's copy as it is at the write, and the parent goes
    /// to iCloud again so other devices see it too.
    private func linkChildToParent(childId: UUID, parentId: UUID) {
        do {
            guard archive.store.exists(parentId) else { return }
            try archive.update(parentId, requestingReupload: true) { parent in
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
        overnightStreaming.launchDeviceRecordingLoop()
    }

    /// The paused segment's beat count carries forward so the UI keeps counting
    /// the whole night rather than restarting from zero. The pause's errors
    /// were about the paused part; the segment starts without them.
    private func resetStateForResumedSession(_ session: HRVSession) {
        let priorBeats = streamingLifecycle.pausedBeatCount
        debugLog("[RRCollector] Resume: carrying forward \(priorBeats) beats")
        sessionState.currentSession = session
        sessionState.collectedPoints = []
        streamingLifecycle.sessionStartTime = Date()
        streamingLifecycle.isStreamingMode = true
        streamingLifecycle.isOvernightStreaming = true
        overnightRun.isEnding = false
        streamingLifecycle.isPaused = false
        sessionState.recordingPhase = .overnightStreaming
        streamingLifecycle.pausedSession = nil
        streamingLifecycle.pausedBeatCount = priorBeats
        streamingLifecycle.streamingTargetSeconds = Int.max
        streamingLifecycle.streamingElapsedSeconds = 0
        sessionState.isCollecting = true
        streamingLifecycle.lastSeenReconnectCount = 0
        sessionState.verificationResult = nil
        sessionState.baselineDeviation = nil
        overnightRun.deviceFetchPolicy = .automatic
        sessionState.lastError = nil
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
        guard let session = streamingLifecycle.pausedSession, session.state == .paused else {
            debugLog("[RRCollector] Cannot finalize — no paused session")
            return
        }
        debugLog("[RRCollector] Finalizing paused session \(session.id.uuidString.prefix(8))")
        guard let finalSession = rearchiveFinalized(session) else { return }
        baselineTracker.update(with: finalSession, sleepSchedule: settingsManager.settings.sleepSchedule)
        sessionState.currentSession = finalSession
        sessionState.needsAcceptance = finalSession.analysisResult != nil
        sessionState.reviewArchivedSessionId = sessionState.needsAcceptance ? finalSession.id : nil
        sessionState.reviewArchivedEntries = SessionState.ReviewEntries(of: finalSession)
        streamingLifecycle.isPaused = false
        sessionState.recordingPhase = sessionState.needsAcceptance ? .awaitingAcceptance : .idle
        streamingLifecycle.pausedSession = nil
        recordingStore.clearPaused()
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
            guard archive.store.exists(paused.id) else {
                try archive.archive(finalSession, skipSameNightMerge: false, requestingReupload: true)
                return finalSession
            }
            try archive.update(paused.id, requestingReupload: true) { $0.state = .complete }
            return try archive.retrieve(paused.id) ?? finalSession
        } catch {
            debugLog("[RRCollector] ⚠️ Failed to re-archive finalized session: \(error)", level: .error)
            sessionState.lastError = error
            return nil
        }
    }

    // MARK: - Find & Restore

    /// Restore paused state on app launch so the Record tab shows Resume / Done.
    /// Session deserialization runs off the main thread to avoid blocking app startup.
    func restorePausedStateIfNeeded() {
        guard let pausedId = recordingStore.pausedSessionId() else { return }
        let archive = self.archive
        Task.detached(priority: .userInitiated) {
            guard let session = archive.retrieveOrLog(pausedId), session.state == .paused else { return }
            await MainActor.run { [weak self] in self?.publishRestoredPausedSession(session, id: pausedId) }
        }
    }

    @MainActor
    private func publishRestoredPausedSession(_ session: HRVSession, id: UUID) {
        debugLog("[RRCollector] Restoring paused state for session \(id.uuidString.prefix(8))")
        streamingLifecycle.pausedSession = session
        sessionState.currentSession = session
        streamingLifecycle.isPaused = true
        streamingLifecycle.pausedBeatCount = session.rrSeries?.points.count ?? 0
        sessionState.recordingPhase = .paused(sessionId: id)
        if let usesDeviceBackup = recordingStore.pausedCaptureMode() { overnightRun.usesDeviceBackup = usesDeviceBackup }
    }

    /// Refresh the cached recentPausedSession on a background thread.
    /// Archive I/O (index scan, file reads, SHA256, JSON decode) runs off-main.
    /// Only hops to main to publish the result.
    func refreshRecentPausedSession() {
        // Capture what we need before leaving the MainActor. `owner` is weak
        // so a background refresh never keeps these controls alive.
        let archive = self.archive
        let maxGap = settingsManager.settings.effectiveMergeGapSeconds

        Task.detached(priority: .utility) { [weak owner = self] in
            let result = CollectorSessionControl.findRecentPausedSessionOffMain(archive: archive, maxGap: maxGap)
            await MainActor.run { [weak owner] in
                owner?.sessionState.recentPausedSession = result
            }
        }
    }

    /// Pure function that searches the archive for a recent paused/complete overnight
    /// session. Runs entirely off the main thread — no actor isolation needed.
    /// Uses lightweight retrieval (skips rrSeries) since only state/dates are checked.
    ///
    /// The index scan + disk loads happen here, off the main thread.
    /// Lightweight loads skip rrSeries (~700KB per session) since we only
    /// need state, pausedDate, and endDate for the search.
    ///
    /// Paused sessions win over recently-completed ones — a pause is an
    /// explicit "I'm coming back to this." A paused session that was already
    /// resumed is not offered: it stays paused in the archive, but its night
    /// went on in the segment resumed from it, and continuing it again would
    /// leave that segment out.
    nonisolated static func findRecentPausedSessionOffMain(archive: SessionArchive, maxGap: TimeInterval) -> HRVSession? {
        guard maxGap > 0 else { return nil }
        let now = Date()
        let cutoff = now.addingTimeInterval(-maxGap)
        let entries = archive.store.entries
        // By when the night stopped, not when it started: a night paused or
        // finished minutes ago may have begun hours before the window.
        let loaded = entries
            .filter { $0.sessionType == .overnight && ($0.endDate ?? $0.date) >= cutoff }
            .compactMap { archive.retrieveLightweightOrLog($0.sessionId) }
        let paused = loaded.first {
            $0.state == .paused && now.timeIntervalSince($0.pausedDate ?? .distantPast) <= maxGap
                && !wasResumed($0, entries: entries)
        }
        if let paused { return paused }
        return loaded.first {
            $0.state == .complete && now.timeIntervalSince($0.endDate ?? .distantPast) <= maxGap
        }
    }

    /// Whether some archived segment was resumed from this paused session.
    nonisolated private static func wasResumed(_ paused: HRVSession, entries: [SessionArchiveEntry]) -> Bool {
        entries.contains { entry in
            SessionRecoveryMath.isResumedSegment(
                segmentId: entry.sessionId, segmentLinks: entry.linkedSessionIds,
                segmentEnd: entry.endDate ?? entry.date,
                parentId: paused.id, parentLinks: paused.linkedSessionIds, parentPausedAt: paused.pausedDate
            )
        }
    }
}
