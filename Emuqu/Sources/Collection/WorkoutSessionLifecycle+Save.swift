import Foundation

// Saving a finished workout: the archive write, the steps that follow a
// saved one, and the retry of a workout whose write failed.

/// How a finished workout's save came out.
enum WorkoutSaveOutcome: Equatable, Sendable {
    /// In the archive, with the post-save steps run.
    case saved
    /// An accidental start (`WorkoutAccidentalStart`): not archived unless
    /// the user saves it from the summary (`saveNotArchived`). Its backups
    /// stay until then, or until the user leaves the summary without saving
    /// (`discardNotArchived`).
    case notArchived
    /// The archive write failed (a full disk, or files the phone keeps locked
    /// until it is unlocked). The session is kept in memory, its raw backups
    /// stay on disk, and the save is retried.
    case notSavedYet
}

/// The archive write a finished workout goes through, and a hook called after
/// each saved workout's post-save steps. Both are nil in the app; a test sets
/// them to fail the write and to count the steps.
struct WorkoutSaveSeam {
    /// Replaces the write to `core.archive`.
    var write: (@MainActor (HRVSession) throws -> Void)?
    /// Called once each time a workout's post-save steps run.
    var didRunPostSaveSteps: (@MainActor (HRVSession) -> Void)?
}

extension WorkoutSessionLifecycle {
    /// Persist the finished workout, then run the post-save steps: the
    /// archive-changed signal, retiring the redundant backups, the iCloud
    /// upload and the Apple Health export.
    ///
    /// Both outcomes of the write are logged ("archived session …" and
    /// "Archive failed: …"), so the user's debug log shows whether the
    /// workout persisted.
    ///
    /// When the write fails the session is kept (`WorkoutLifecycle.unsavedSessions`)
    /// and the summary says it is not saved yet. The persisted recording state
    /// and the raw backup stay in place, so a relaunch before a retry succeeds
    /// still recovers it through SessionRecoveryService. The save is retried on
    /// unlock, on becoming active and from the summary (`retryUnsavedWorkouts`),
    /// and the post-save steps run only once one write succeeds.
    ///
    /// An accidental start (finalize classifies it `.failed` by
    /// `WorkoutAccidentalStart`) is not archived and its backups are kept:
    /// the summary says it was not saved and offers to save it. Nothing is
    /// retired for a session the archive does not hold.
    func archive(session: HRVSession) -> WorkoutSaveOutcome {
        guard session.state != .failed else {
            debugLog("[WorkoutRecorder] accidental start id=\(session.id.uuidString.prefix(8)) (under a minute, no heart rate, movement or samples): not archived, kept for the summary")
            return .notArchived
        }
        guard persist(session) else {
            holdUnsaved(session)
            return .notSavedYet
        }
        runPostSaveSteps(for: session)
        return .saved
    }

    /// The summary's Save on an accidental start: the user wants it, so it is
    /// saved as a complete workout and goes through the normal save, retry
    /// and post-save steps.
    func saveNotArchived() {
        guard lifecycle.saveOutcome == .notArchived, var session = lifecycle.finishedSession else { return }
        session.state = .complete
        lifecycle.finishedSession = session
        lifecycle.saveOutcome = archive(session: session)
        if lifecycle.saveOutcome != .notArchived { watchBridge.sendWorkoutSaveState(notSaved: false) }
    }

    /// The user left an accidental start's summary without saving it: its
    /// backups and recording marker go, as nothing more will be done with
    /// them.
    func discardNotArchived() {
        guard lifecycle.saveOutcome == .notArchived, let session = lifecycle.finishedSession else { return }
        retireRedundantBackups(for: session, archived: false)
        debugLog("[WorkoutRecorder] accidental start id=\(session.id.uuidString.prefix(8)) left unsaved by the user: backups retired")
    }

    /// Retries every workout whose save failed. Runs on the main actor with no
    /// suspension between a write and its bookkeeping, so triggers that land
    /// together (an unlock and the activation after it, a tap on Try Again)
    /// save each workout once and run its post-save steps once.
    /// The heart-rate-recovery samples a saved workout's archive write did
    /// not take are retried with them (`unsavedHRR`).
    func retryUnsavedWorkouts() {
        guard !lifecycle.unsavedSessions.isEmpty || !lifecycle.unsavedHRR.isEmpty else { return }
        for session in lifecycle.unsavedSessions {
            retrySave(session)
        }
        for (id, samples) in lifecycle.unsavedHRR {
            storeHRR(samples, for: id)
        }
        if lifecycle.unsavedSessions.isEmpty, lifecycle.unsavedHRR.isEmpty { stopObservingSaveRetryTriggers() }
    }

    /// HRR samples that arrive while the workout is not saved go into the
    /// kept copy, so the retry saves them with it. A workout the archive
    /// holds (saved by a retry, or whose first HRR write failed) gets them on
    /// its archived copy; when that write fails too they are kept and retried
    /// with the unsaved workouts (`unsavedHRR`), as the summary shows them.
    func keepHRRSamples(_ samples: [HRRSample], for id: UUID) {
        if let index = lifecycle.unsavedSessions.firstIndex(where: { $0.id == id }) {
            lifecycle.unsavedSessions[index].workoutMetadata?.hrrSamples = samples
            return
        }
        guard core.archive.store.exists(id) else { return }
        lifecycle.unsavedHRR[id] = samples
        storeHRR(samples, for: id)
        if lifecycle.unsavedHRR[id] != nil { observeSaveRetryTriggers() }
    }

    /// Writes kept HRR samples to the archived copy and lets them go once
    /// stored, or once the workout has left the archive; a failed write keeps
    /// them for the next retry.
    private func storeHRR(_ samples: [HRRSample], for id: UUID) {
        guard core.archive.store.exists(id) else {
            lifecycle.unsavedHRR[id] = nil
            return
        }
        do {
            try core.archive.update(id) { $0.workoutMetadata?.hrrSamples = samples }
            lifecycle.unsavedHRR[id] = nil
        } catch {
            debugLog("[WorkoutRecorder] HRR update failed, kept for a retry: \(error)", level: .warning)
        }
    }

    /// Writes the session, logging either way. False when the write threw.
    private func persist(_ session: HRVSession) -> Bool {
        do {
            if let write = saveSeam.write {
                try write(session)
            } else {
                _ = try core.archive.archive(session)
            }
            debugLog("[WorkoutRecorder] archived session id=\(session.id.uuidString.prefix(8)) sport=\(session.workoutMetadata?.sport.rawValue ?? "?") type=\(session.sessionType.rawValue)")
            return true
        } catch {
            debugLog("[WorkoutRecorder] Archive failed: \(error); kept for a retry, raw backup left for recovery", level: .warning)
            return false
        }
    }

    /// The steps a saved workout runs, once, and never before its write.
    private func runPostSaveSteps(for session: HRVSession) {
        core.notifyArchiveChanged()
        retireRedundantBackups(for: session, archived: true)
        let cloudSync = core.cloudSyncManager
        Task(priority: .utility) {
            await cloudSync.uploadSession(session)
        }
        exportToHealthKitIfAvailable(session)
        saveSeam.didRunPostSaveSteps?(session)
    }

    /// Keeps the session for a retry, replacing an older copy of it, and
    /// starts listening for the moments a retry may succeed.
    private func holdUnsaved(_ session: HRVSession) {
        lifecycle.unsavedSessions.removeAll { $0.id == session.id }
        lifecycle.unsavedSessions.append(session)
        observeSaveRetryTriggers()
    }

    /// One retry. A session the archive already holds was saved by another
    /// path, which ran its own follow-up steps, so it is only let go here.
    private func retrySave(_ session: HRVSession) {
        guard !core.archive.store.exists(session.id) else {
            debugLog("[WorkoutRecorder] unsaved session id=\(session.id.uuidString.prefix(8)) is already in the archive, retry dropped")
            settleRetried(session.id)
            return
        }
        guard persist(session) else { return }
        settleRetried(session.id)
        runPostSaveSteps(for: session)
    }

    private func settleRetried(_ id: UUID) {
        lifecycle.unsavedSessions.removeAll { $0.id == id }
        if lifecycle.finishedSession?.id == id { lifecycle.saveOutcome = .saved }
    }

    /// Unlock and activation (`NotificationTokens.protectedDataMayBeAvailable`):
    /// a file kept locked until the phone is unlocked can be written then, and
    /// coming back to the foreground is when space freed meanwhile shows.
    /// Installed once, while a workout is unsaved.
    private func observeSaveRetryTriggers() {
        guard !saveRetryObserving else { return }
        saveRetryObserving = true
        saveRetryObservers.observeProtectedDataMayBeAvailable { [weak self] in
            Task { @MainActor in self?.retryUnsavedWorkouts() }
        }
    }

    private func stopObservingSaveRetryTriggers() {
        saveRetryObservers.removeAll()
        saveRetryObserving = false
    }

    /// A successful archive makes the raw backup redundant, as does the user
    /// leaving an accidental start unsaved (`discardNotArchived`); nothing
    /// else retires them. Marking it stops
    /// SessionRecoveryService offering to "recover" a session that already
    /// lives in history, and clearing persisted state stops the next app
    /// launch prompting the user to recover.
    ///
    /// The workout-side track + samples + baro backups are redundant too once
    /// the session's `WorkoutMetadata` holds what they hold, so they're
    /// dropped rather than left to accumulate as stale per-session files in
    /// the App Group. For a saved workout that is checked first, off the main
    /// actor (`WorkoutTrackBackup.discard(_:ifCoveredBy:trackReplaced:)`): a
    /// backup with a row the archive lacks is the only copy of that row and
    /// stays. One the user left unsaved goes as it is.
    ///
    /// The persisted state is one key shared with RRCollector's overnight and
    /// quick recordings, so it is cleared only when it is this workout's; the
    /// check and clear run on `recordingStateQueue` after the start's save.
    private func retireRedundantBackups(for session: HRVSession, archived: Bool) {
        core.rawBackup.markAsArchived(session.id)
        let trackBackup = services.workoutTrackBackup
        if archived {
            Task.detached(priority: .utility) { trackBackup.discard(session.id, ifCoveredBy: session) }
        } else {
            trackBackup.discard(session.id)
        }
        let sessionId = session.id
        Self.recordingStateQueue.async {
            guard PersistedRecordingState.load()?.sessionId == sessionId else { return }
            PersistedRecordingState.clear()
        }
    }
}
