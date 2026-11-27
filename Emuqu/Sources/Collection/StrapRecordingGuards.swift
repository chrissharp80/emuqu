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

    /// Whether the strap's recording belongs to a session the strap-only Stop
    /// and Discard must leave alone: a night being ended (its ending
    /// downloads the strap itself), a workout the app died during (workout
    /// recovery rebuilds it, `strapHeldByInterruptedWorkout`) or a
    /// live workout (the recording is its backup). `alreadyRecording` is shown
    /// for a workout's. `action` names the caller in the log.
    func isHeldElsewhere(_ action: String) -> Bool {
        if streamingLifecycle.isEndingOvernight {
            debugLog("[RRCollector] Not \(action) the strap recording: a night's ending is in progress")
            return true
        }
        if heldByInterruptedWorkout {
            debugLog("[RRCollector] Not \(action) the strap recording: it belongs to an interrupted workout, which workout recovery rebuilds", level: .warning)
            sessionState.lastError = RRCollector.CollectorError.alreadyRecording
            return true
        }
        guard belongsToLiveWorkout else { return false }
        debugLog("[RRCollector] Not \(action) the strap recording: it is a live workout's backup", level: .warning)
        sessionState.lastError = RRCollector.CollectorError.alreadyRecording
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
