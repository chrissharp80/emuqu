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
    ///
    /// The discard claims the night's ending before its first suspension, so
    /// a discard while a Stop or a pause is ending the night, or a second
    /// discard, returns nil and leaves the night to that one. The claim is
    /// released just before the recorder is reset, once nothing of the night
    /// is left to remove.
    func discardOvernightRecording() async -> DiscardOutcome? {
        guard let claim = streamingLifecycle.claimOvernightEnding() else { return nil }
        let session = sessionState.currentSession
        debugLog("[RRCollector] 🗑 Discarding recording \(session?.id.uuidString.prefix(8) ?? "-")")
        await overnightStreaming.endDeviceRecordingArming()
        let strapArmed = overnightRun.deviceBackupActive
        stopStreamingWithoutKeeping()
        let strapCopyKept = strapArmed ? await clearStrapCopy() : false
        if let session { await removeKeptCopies(of: session.id) }
        recordingStore.clear()
        streamingLifecycle.releaseOvernightEnding(claim)
        returnToParentPauseOrIdle(parentId: session?.linkedSessionIds?.first)
        if strapCopyKept { sessionState.lastError = PolarManager.PolarError.fetchFailed(Self.strapCopyKeptReason) }
        archiveSignal.notifyChanged()
        return DiscardOutcome(strapCopyKept: strapCopyKept)
    }

    /// Discards a paused night: the paused session and the chain of paused
    /// segments it was resumed from, with their recovery and iCloud backups.
    /// The strap is not touched: a paused night's strap part was downloaded or
    /// rescued at pause, and the next start rescues anything left.
    ///
    /// A segment's backups go only once the archive has let it go. When a
    /// delete fails the discard stops there, that segment and the older ones
    /// keep their backups, and the error is shown: if nothing was deleted the
    /// pause stays as it was, otherwise the recorder returns to the pause of
    /// the segment that is left, so Discard can be tapped again.
    func discardPausedRecording() async {
        guard let paused = streamingLifecycle.pausedSession, paused.state == .paused else { return }
        debugLog("[RRCollector] 🗑 Discarding paused night \(paused.id.uuidString.prefix(8))")
        for id in pausedChain(from: paused) {
            do {
                try archive.delete(id)
            } catch {
                return keepPauseAfterFailedDelete(of: id, pausedId: paused.id, error: error)
            }
            await removeKeptCopies(of: id)
        }
        resetSession()
        archiveSignal.notifyChanged()
    }

    /// A paused segment the archive would not delete: the discard stops with
    /// it still archived and its backups kept. The paused session itself
    /// stays paused as it was; an older segment, whose newer ones are gone,
    /// becomes the pause. The error is shown either way.
    private func keepPauseAfterFailedDelete(of id: UUID, pausedId: UUID, error: Error) {
        debugLog("[RRCollector] ⚠️ Could not discard paused segment \(id.uuidString.prefix(8)): \(error)", level: .warning)
        if id != pausedId {
            returnToParentPauseOrIdle(parentId: id)
            archiveSignal.notifyChanged()
        }
        sessionState.lastError = error
    }

    /// Discards a strap-only recording: stops the strap and clears its copy,
    /// then forgets the session. When the strap cannot be stopped or cleared
    /// the recording is left exactly as it was (still recording, still
    /// recoverable) and the error is shown; returns false. While a night's
    /// ending is in progress the strap's recording is that night's, still to
    /// be downloaded or saved, and nothing is touched; also false. So is a
    /// live workout's backup recording, with `alreadyRecording` shown.
    func discardDeviceRecording() async -> Bool {
        guard !strapGuards.isHeldElsewhere("discarding") else { return false }
        let session = sessionState.currentSession
        debugLog("[RRCollector] 🗑 Discarding strap recording \(session?.id.uuidString.prefix(8) ?? "-")")
        do {
            try await strapRecorder.discardStoredExercises()
        } catch {
            debugLog("[RRCollector] ⚠️ Could not discard the strap recording: \(error)", level: .warning)
            sessionState.lastError = error
            return false
        }
        if let session { await removeKeptCopies(of: session.id) }
        recordingStore.clear()
        resetSession()
        return true
    }

    static let strapCopyKeptReason =
        "The strap's copy of the discarded recording could not be cleared. It will be saved to Lost Sessions when the next recording starts."

    // MARK: - Helpers

    /// The streaming half of `stopStreamingInfrastructure`, without keeping
    /// the beats: no gather, no "saving" status, no analysis.
    private func stopStreamingWithoutKeeping() {
        let elapsedHours = streamingLifecycle.streamingHoursForBattery
        streamingLifecycle.stopStreamingTimer()
        services.systemDiagnosticsManager.stopSamplingAfterRecording(for: .recordScreen)
        streamingLifecycle.isStreamingMode = false
        _ = strapStream.stopStreaming()
        strapBattery.recordRecordingHours(elapsedHours)
        streamingLifecycle.isOvernightStreaming = false
        overnightRun.deviceBackupActive = false
        deviceStatus.isStreaming = false
        sessionState.isCollecting = false
        sessionState.collectedPoints = []
        streamingLifecycle.streamingElapsedSeconds = 0
        morningCoordination.morningStatus = nil
    }

    /// Stops and clears the strap's internal recording. Returns true when the
    /// strap still holds it.
    private func clearStrapCopy() async -> Bool {
        do {
            try await strapRecorder.discardStoredExercises()
            return false
        } catch {
            debugLog("[RRCollector] ⚠️ Could not clear the strap's copy of the discarded recording: \(error)", level: .warning)
            return true
        }
    }

    /// Every copy of one session left after its archive entry: the Trash
    /// file a paused segment's delete leaves, the crash-recovery backup and
    /// the iCloud live backup. The id is remembered as deleted forever
    /// (`ForgottenSessions`), so a pull does not bring back a copy iCloud
    /// still holds, and a live-backup delete that fails is retried.
    private func removeKeptCopies(of id: UUID) async {
        ForgottenSessions.remember(id)
        archive.store.discardTrashed(id)
        _ = attempt("discard.rawBackup") { try rawBackup.discardBackup(id) }
        await cloudSyncManager.deleteLiveBackup(sessionId: id)
    }

    /// A discarded resumed segment returns the recorder to its paused parent;
    /// anything else returns it to idle.
    private func returnToParentPauseOrIdle(parentId: UUID?) {
        if let parentId, let parent = archive.retrieveOrLog(parentId), parent.state == .paused {
            resetSession()
            recordingStore.persistPaused(sessionId: parentId)
            streamingLifecycle.pausedSession = parent
            sessionState.currentSession = parent
            streamingLifecycle.isPaused = true
            streamingLifecycle.pausedBeatCount = parent.rrSeries?.points.count ?? 0
            sessionState.recordingPhase = .paused(sessionId: parentId)
            return
        }
        resetSession()
    }

    /// The paused session and every paused segment before it, newest first.
    /// Stops at the first ancestor that is not paused (a finished night is
    /// never discarded from here) and at a repeat, so a malformed link cannot
    /// loop.
    private func pausedChain(from paused: HRVSession) -> [UUID] {
        var chain = [paused.id]
        var next = paused.linkedSessionIds?.first
        while let id = next, !chain.contains(id),
              let parent = archive.retrieveOrLog(id), parent.state == .paused {
            chain.append(id)
            next = parent.linkedSessionIds?.first
        }
        return chain
    }
}
