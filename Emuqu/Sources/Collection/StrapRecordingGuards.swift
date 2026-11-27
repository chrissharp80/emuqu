import Foundation

/// Whose recording the strap holds, and the checks a start, Stop or Discard
/// makes against it: a session of this app recording now, a workout the app
/// died during, or none. Read by the session controls, device recording and
/// recovery, so each asks the same question the same way.
@MainActor
struct StrapRecordingGuards {
    let sessionState: SessionState
    let streamingLifecycle: StreamingLifecycle
    /// The strap's link, for whether it is connected.
    let strapLink: StrapLinkState
    /// The strap's stream, for whether a session is buffering on it.
    let strapStream: StrapStreamSession
    /// What the strap's own memory holds, and the downloads on record.
    let strapRecording: StrapRecordingState
    let recordingStore: RecordingStateStore
    let archive: SessionArchive
    let rawBackup: RawRRBackup
    /// The workout slot, whose recorder may be recording on the strap.
    let recorderBox: RecorderBox

    /// A session of this app is recording right now, and the strap's
    /// recording is its own: an internal-mode or overnight night, or a
    /// workout's backup. Recovery flows leave that recording alone. A night
    /// being ended is still live: its ending stops and downloads the strap.
    var belongsToLiveSession: Bool {
        if sessionState.isCollecting || streamingLifecycle.isOvernightStreaming || streamingLifecycle.isEndingOvernight {
            return true
        }
        return belongsToLiveWorkout
    }

    /// A workout is recording or finishing, so the strap's recording is its
    /// backup. The Record screen's strap-only Stop and Discard leave it alone.
    var belongsToLiveWorkout: Bool {
        guard let recorder = recorderBox.recorder else { return false }
        return recorder.lifecycle.phase == .recording || recorder.lifecycle.phase == .finalizing
    }

    /// A workout the app died during, never archived, owns the strap's
    /// recording: its recording state is saved as a workout. Workout recovery
    /// (`recoverInterruptedWorkoutFromStrap`, the Record screen's "Recover
    /// workout from strap") rebuilds it with its route; Stop and Recover
    /// would file it through the overnight path without one.
    var heldByInterruptedWorkout: Bool {
        guard let state = recordingStore.load(), state.sessionType == .workout else { return false }
        return !archive.store.exists(state.sessionId)
    }

    /// A recording still running on the strap that no session owns: none is
    /// live and none is on record to stop it (a crashed night or workout has
    /// its own recovery). Left by a crash, or started on the strap itself.
    var holdsOrphanedRecording: Bool {
        strapRecording.isRecordingOnDevice
            && recordingStore.load() == nil
            && !belongsToLiveSession
    }

    /// A quick reading or a strap-only recording may start only with the
    /// strap connected, no night paused or being ended, and no session
    /// buffering on the strap: a paused night owns the current session and
    /// the recording phase until it is resumed, finished or saved, an ending
    /// is still taking its recording off the strap, and a workout on the
    /// strap streams from its start until its heart-rate recovery is
    /// captured. A strap-only recording started under a workout's stream was
    /// stopped and downloaded as that workout's backup at its finish, and on
    /// a Verity Sense it ended the workout's live heart rate. Throws
    /// `alreadyRecording` or `notConnected`; `what` names the start in the log.
    func requireConnectedWithNoNightHeld(starting what: String) throws {
        try sessionState.refuseStartWhileClaimed(starting: what)
        guard !streamingLifecycle.isPaused, !streamingLifecycle.isEndingOvernight else {
            debugLog("[RRCollector] Not starting \(what): a night is paused or being ended", level: .warning)
            throw RRCollector.CollectorError.alreadyRecording
        }
        guard !strapStream.isStreaming else {
            debugLog("[RRCollector] Not starting \(what): another session is buffering on the strap", level: .warning)
            throw RRCollector.CollectorError.alreadyRecording
        }
        guard strapLink.connectionState == .connected else { throw RRCollector.CollectorError.notConnected }
    }

    /// A session that owns what the strap records or holds, so no other
    /// flow may stop, download or clear it.
    enum StrapOwner: Equatable {
        /// A night being ended: its ending stops and downloads the strap.
        case endingNight
        /// A workout recording or finishing: the recording is its backup.
        case liveWorkout
        /// A night, nap or reading recording now.
        case liveSession
        /// A workout the app died during, never archived: workout recovery
        /// rebuilds it with its route.
        case interruptedWorkout
        /// A night paused, to be resumed, finished or discarded.
        case pausedNight
        /// A finished night waiting for the user to keep or discard it.
        case pendingAcceptance
    }

    /// The one ownership rule every strap stop, download and clear asks: who
    /// owns the strap's recording, other than `sessionId`, the session the
    /// flow acts for (its own recording, which it may take). Nil when no
    /// other session does. A night being ended and a live workout are never
    /// the asker's: their own flows do not come through here.
    func strapRecordingOwner(otherThan sessionId: UUID? = nil) -> StrapOwner? {
        if streamingLifecycle.isEndingOvernight { return .endingNight }
        if belongsToLiveWorkout { return .liveWorkout }
        let isCurrent = sessionId != nil && sessionState.currentSession?.id == sessionId
        if sessionState.isCollecting || streamingLifecycle.isOvernightStreaming, !isCurrent { return .liveSession }
        if heldByInterruptedWorkout, recordingStore.load()?.sessionId != sessionId { return .interruptedWorkout }
        if streamingLifecycle.isPaused, streamingLifecycle.pausedSession?.id != sessionId { return .pausedNight }
        let pendingIds = [sessionState.currentSession?.id, sessionState.reviewArchivedSessionId]
        if sessionState.needsAcceptance, sessionId == nil || !pendingIds.contains(sessionId) { return .pendingAcceptance }
        return nil
    }

    /// Whether the strap's recording belongs to a session the strap-only Stop
    /// and Discard must leave alone (`strapRecordingOwner`): any but the
    /// session on screen, whose recording they act on. A night being ended
    /// downloads the strap itself; for any other owner `alreadyRecording` is
    /// shown. `action` names the caller in the log.
    func isHeldElsewhere(_ action: String) -> Bool {
        guard let owner = strapRecordingOwner(otherThan: sessionState.currentSession?.id) else { return false }
        debugLog("[RRCollector] Not \(action) the strap recording: it belongs to another session (\(owner))", level: owner == .endingNight ? .debug : .warning)
        if owner != .endingNight { sessionState.lastError = RRCollector.CollectorError.alreadyRecording }
        return true
    }

    /// True when the strap holds a recording the app has never downloaded
    /// (`StrapRecordingPolicy.holdsUnrecoveredRecording`). The strap keeps
    /// every downloaded recording as a backup, so holding one is not enough.
    var hasUnrecoveredData: Bool {
        guard strapRecording.hasStoredExercise, let start = strapRecording.storedExerciseDate else { return false }
        return !isStrapRecordingSaved(startedAt: start)
    }

    /// Whether the app holds the strap recording that began at `start`
    /// (`StrapRecordingPolicy.recordingIsSaved`). The strap's start sequence
    /// asks the same question before it clears the strap. On disk: an
    /// archived night or nap that was running when the recording began
    /// (starting up to 30 minutes after it, and not ended before it), or a
    /// rescue backup within 30 minutes of its start. A strap armed late in a
    /// night is filed into that night, whose start can be hours before the
    /// recording's; a quick reading or workout that ended just before the
    /// recording does not hold it.
    func isStrapRecordingSaved(startedAt start: Date) -> Bool {
        let ledger = strapRecording.downloadLedger
        return StrapRecordingPolicy.recordingIsSaved(
            beatsSaved: ledger.wasSaved(recordingStartedAt: start),
            predatesDownloadRecord: ledger.predatesRecord(start),
            heldOnDisk: archiveHoldsSession(runningAt: start, slackMinutes: 30, in: archive)
                || rawBackup.holdsBackup(capturedWithin: 30 * 60, of: start)
        )
    }
}

/// Whether the archive holds a night or nap, the only sessions a strap
/// recording is saved into, that was running at `date`: one that started no
/// more than `slackMinutes` after it and had not ended before it. One with no
/// end, or ending sooner, counts as running for `slackMinutes` after its
/// start. A quick reading or a workout that ended just before is not one.
private func archiveHoldsSession(runningAt date: Date, slackMinutes: Int, in archive: SessionArchive) -> Bool {
    let slack = TimeInterval(slackMinutes * 60)
    return archive.store.entries.contains { entry in
        guard entry.sessionType == .overnight || entry.sessionType == .nap else { return false }
        let runsUntil = max(entry.endDate ?? entry.date, entry.date.addingTimeInterval(slack))
        return entry.date.addingTimeInterval(-slack) <= date && date <= runsUntil
    }
}
