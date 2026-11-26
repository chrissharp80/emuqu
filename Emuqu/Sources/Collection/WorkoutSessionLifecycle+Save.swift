import Foundation

// Saving a finished workout: the archive write, the steps that follow a
// saved one, and the retry of a workout whose write failed.

/// How a finished workout's save came out.
enum WorkoutSaveOutcome: Equatable, Sendable {
    /// In the archive, with the post-save steps run.
    case saved
    /// An accidental start (no heart rate, no movement, under 30 samples):
    /// deliberately not archived.
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
    /// An accidental start (finalize classifies a session with no heart
    /// rate, no movement and under 30 samples as `.failed`) is not archived:
    /// its backups are retired as for an archived one, and it never reaches
    /// history, iCloud or Apple Health.
    func archive(session: HRVSession) -> WorkoutSaveOutcome {
        guard session.state != .failed else {
            retireRedundantBackups(for: session)
            debugLog("[WorkoutRecorder] accidental start id=\(session.id.uuidString.prefix(8)) (no heart rate, movement or samples): not archived")
            return .notArchived
        }
        guard persist(session) else {
            holdUnsaved(session)
            return .notSavedYet
        }
        runPostSaveSteps(for: session)
        return .saved
    }

    /// Retries every workout whose save failed. Runs on the main actor with no
    /// suspension between a write and its bookkeeping, so triggers that land
    /// together (an unlock and the activation after it, a tap on Try Again)
    /// save each workout once and run its post-save steps once.
    func retryUnsavedWorkouts() {
        guard !lifecycle.unsavedSessions.isEmpty else { return }
        for session in lifecycle.unsavedSessions {
            retrySave(session)
        }
        if lifecycle.unsavedSessions.isEmpty { stopObservingSaveRetryTriggers() }
    }

    /// HRR samples that arrive while the workout is not saved go into the
    /// kept copy, so the retry saves them with it. When a retry saved the
    /// workout after the HRR write-back found it missing from the archive,
    /// they are written to the archived copy instead.
    func keepHRRSamples(_ samples: [HRRSample], for id: UUID) {
        if let index = lifecycle.unsavedSessions.firstIndex(where: { $0.id == id }) {
            lifecycle.unsavedSessions[index].workoutMetadata?.hrrSamples = samples
            return
        }
        guard core.archive.store.exists(id) else { return }
        do {
            try core.archive.update(id) { $0.workoutMetadata?.hrrSamples = samples }
        } catch {
            debugLog("[WorkoutRecorder] HRR update after a retried save failed: \(error)", level: .warning)
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
        retireRedundantBackups(for: session)
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

    /// A successful archive makes the raw backup redundant. Marking it stops
    /// SessionRecoveryService offering to "recover" a session that already
    /// lives in history, and clearing persisted state stops the next app
    /// launch prompting the user to recover.
    ///
    /// The workout-side track + samples + baro backups are redundant too (the
    /// same data lives inside the session's `WorkoutMetadata`), so they're
    /// dropped rather than left to accumulate as stale per-session files in
    /// the App Group.
    ///
    /// The persisted state is one key shared with RRCollector's overnight and
    /// quick recordings, so it is cleared only when it is this workout's; the
    /// check and clear run on `recordingStateQueue` after the start's save.
    private func retireRedundantBackups(for session: HRVSession) {
        core.rawBackup.markAsArchived(session.id)
        services.workoutTrackBackup.discard(session.id)
        let sessionId = session.id
        Self.recordingStateQueue.async {
            guard PersistedRecordingState.load()?.sessionId == sessionId else { return }
            PersistedRecordingState.clear()
        }
    }
}
