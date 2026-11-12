import Foundation

// MARK: - Discard a recording in progress

extension CollectorSessionControl {
    /// What a discard removed, so the view can say so and decide whether to
    /// start the next recording.
    struct DiscardOutcome: Equatable {
        /// The strap's own copy of this recording could not be cleared. The
        /// next recording's start downloads it into Lost Sessions instead of
        /// losing it, so nothing is destroyed; the user is told.
        let strapCopyKept: Bool
    }

    /// Ends the recording in progress and keeps nothing from it: no score, no
    /// archived session, no crash-recovery backup, no iCloud live backup and,
    /// when this recording armed the strap's internal recording, no copy left
    /// on the strap.
    ///
    /// A resumed segment is discarded alone. Its paused parent stays in the
    /// archive and the recorder returns to that pause, so Resume and Done are
    /// offered again.
    ///
    /// The strap is cleared only when this night armed it
    /// (`overnightDeviceBackupActive`): arming clears the strap after rescuing
    /// anything older, so the only recording on it is this night's. A strap
    /// this night never armed may hold an older recording the app has not
    /// downloaded, and it is left alone.
    func discardOvernightRecording() async -> DiscardOutcome? {
        guard collector.isOvernightStreaming else { return nil }
        let session = collector.currentSession
        debugLog("[RRCollector] 🗑 Discarding recording \(session?.id.uuidString.prefix(8) ?? "-")")
        await collector.overnightStreaming.endDeviceRecordingArming()
        let strapArmed = collector.overnightDeviceBackupActive
        stopStreamingWithoutKeeping()
        let strapCopyKept = strapArmed ? await clearStrapCopy() : false
        if let session { await removeKeptCopies(of: session.id) }
        collector.clearPersistedRecordingState()
        returnToParentPauseOrIdle(parentId: session?.linkedSessionIds?.first)
        if strapCopyKept { collector.lastError = PolarManager.PolarError.fetchFailed(Self.strapCopyKeptReason) }
        collector.notifyArchiveChanged()
        return DiscardOutcome(strapCopyKept: strapCopyKept)
    }

    /// Discards a paused night: the paused session and the chain of paused
    /// segments it was resumed from, with their recovery and iCloud backups.
    /// The strap is not touched: a paused night's strap part was downloaded or
    /// rescued at pause, and the next start rescues anything left.
    func discardPausedRecording() async {
        guard let paused = collector.pausedSession, paused.state == .paused else { return }
        debugLog("[RRCollector] 🗑 Discarding paused night \(paused.id.uuidString.prefix(8))")
        for id in pausedChain(from: paused) {
            _ = attempt("discard.archiveDelete") { try collector.archive.delete(id) }
            await removeKeptCopies(of: id)
        }
        collector.resetSession()
        collector.notifyArchiveChanged()
    }

    /// Discards a strap-only recording: stops the strap and clears its copy,
    /// then forgets the session. When the strap cannot be stopped or cleared
    /// the recording is left exactly as it was (still recording, still
    /// recoverable) and the error is shown; returns false.
    func discardDeviceRecording() async -> Bool {
        let session = collector.currentSession
        debugLog("[RRCollector] 🗑 Discarding strap recording \(session?.id.uuidString.prefix(8) ?? "-")")
        do {
            try await collector.polarManager.discardStoredExercises()
        } catch {
            debugLog("[RRCollector] ⚠️ Could not discard the strap recording: \(error)", level: .warning)
            collector.lastError = error
            return false
        }
        if let session { await removeKeptCopies(of: session.id) }
        collector.clearPersistedRecordingState()
        collector.resetSession()
        return true
    }

    static let strapCopyKeptReason =
        "The strap's copy of the discarded recording could not be cleared. It will be saved to Lost Sessions when the next recording starts."

    // MARK: - Helpers

    /// The streaming half of `stopStreamingInfrastructure`, without keeping
    /// the beats: no gather, no "saving" status, no analysis.
    private func stopStreamingWithoutKeeping() {
        let elapsedHours = collector.streamingHoursForBattery
        collector.stopStreamingTimer()
        AppDependencies.current.app.systemDiagnosticsManager.stopSamplingAfterRecording()
        collector.isStreamingMode = false
        _ = collector.polarManager.stopStreaming()
        collector.polarManager.recordRecordingHours(elapsedHours)
        collector.isOvernightStreaming = false
        collector.overnightDeviceBackupActive = false
        collector.deviceStatus.isStreaming = false
        collector.isCollecting = false
        collector.collectedPoints = []
        collector.streamingElapsedSeconds = 0
        collector.morningStatus = nil
    }

    /// Stops and clears the strap's internal recording. Returns true when the
    /// strap still holds it.
    private func clearStrapCopy() async -> Bool {
        do {
            try await collector.polarManager.discardStoredExercises()
            return false
        } catch {
            debugLog("[RRCollector] ⚠️ Could not clear the strap's copy of the discarded recording: \(error)", level: .warning)
            return true
        }
    }

    /// The crash-recovery backup and the iCloud live backup of one session.
    private func removeKeptCopies(of id: UUID) async {
        _ = attempt("discard.rawBackup") { try collector.rawBackup.discardBackup(id) }
        await collector.cloudSyncManager.deleteLiveBackup(sessionId: id)
    }

    /// A discarded resumed segment returns the recorder to its paused parent;
    /// anything else returns it to idle.
    private func returnToParentPauseOrIdle(parentId: UUID?) {
        if let parentId, let parent = collector.archive.retrieveOrLog(parentId), parent.state == .paused {
            collector.resetSession()
            persistPausedSessionState(sessionId: parentId)
            collector.pausedSession = parent
            collector.currentSession = parent
            collector.isPaused = true
            collector.pausedBeatCount = parent.rrSeries?.points.count ?? 0
            collector.recordingPhase = .paused(sessionId: parentId)
            return
        }
        collector.resetSession()
    }

    /// The paused session and every paused segment before it, newest first.
    /// Stops at the first ancestor that is not paused (a finished night is
    /// never discarded from here) and at a repeat, so a malformed link cannot
    /// loop.
    private func pausedChain(from paused: HRVSession) -> [UUID] {
        var chain = [paused.id]
        var next = paused.linkedSessionIds?.first
        while let id = next, !chain.contains(id),
              let parent = collector.archive.retrieveOrLog(id), parent.state == .paused {
            chain.append(id)
            next = parent.linkedSessionIds?.first
        }
        return chain
    }
}
