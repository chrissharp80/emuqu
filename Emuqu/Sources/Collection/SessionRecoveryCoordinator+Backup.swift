import CoreLocation
import Foundation
import os

// Backup and corrupted-session recovery: restoring from the app's own
// on-disk backups. These delegate to `SessionRecoveryService` rather than
// touching the device at all; pulling RR back off the strap's internal memory
// lives in `SessionRecoveryCoordinator+Device.swift`, and the merge data-loss repair in
// `SessionRecoveryCoordinator+MergeRepair.swift`.

extension SessionRecoveryCoordinator {
    // MARK: - Backup Recovery (delegates to SessionRecoveryService)

    /// Without the live recordings: a night still streaming has a backup and no
    /// archive entry yet, so it would look lost, and deleting it there would
    /// tombstone the night the morning archive is about to save. A night being ended
    /// (stopped, paused or discarded) stays live until it is saved or has
    /// failed, although it no longer collects. So is a finished workout whose
    /// save failed and is being retried in memory: recovering it from its
    /// backup as well would save it twice. A recording that died with the
    /// app is not live, and still shows.
    ///
    /// The scan also brings into their nights the fuller backups that stand
    /// beside an archived fragment of them (`mergeStrandedFullerBackups`):
    /// the scan's iCloud pull is what saves such a backup here.
    func checkForLostSessions() async -> [(id: UUID, date: Date, beatCount: Int)] {
        let lost = await recoveryService.checkForLostSessions(excludingLive: { liveRecordingIds() })
        await mergeStrandedFullerBackups()
        return lost
    }

    /// Each backup holding beats its archived night lacks
    /// (`SessionRecoveryService.strandedFullerBackupIds`) is merged into that
    /// night, analysed and scored as a recovery is.
    func mergeStrandedFullerBackups() async {
        var merged = 0
        for id in recoveryService.strandedFullerBackupIds(excluding: liveRecordingIds()) {
            let wrote = await recoveryService.mergeStrandedBackup(
                id,
                analyze: { [self] session, window, flags, capacity in await morning.analyze(session, window: window, flags: flags, peakCapacity: capacity) },
                analyzeWithCapacity: { [self] session, capacity in await morning.analyze(session, peakCapacity: capacity) },
                computeRecoveryScore: { [self] session, analysisResult in await enrichedRecoveryScore(session: session, analysisResult: analysisResult) }
            )
            if wrote { merged += 1 }
        }
        if merged > 0 { await MainActor.run { archiveSignal.notifyChanged() } }
    }

    /// The sessions recording right now, being ended, or finished and waiting
    /// for a save retry, whose backups are not lost.
    func liveRecordingIds() -> Set<UUID> {
        var ids = Set<UUID>()
        if sessionState.isCollecting || streamingLifecycle.isEndingOvernight,
           let id = sessionState.currentSession?.id { ids.insert(id) }
        if let id = streamingLifecycle.pausedSession?.id { ids.insert(id) }
        if let recorder = services.recorderBox.recorder,
           recorder.lifecycle.phase == .recording || recorder.lifecycle.phase == .finalizing,
           let id = recorder.lifecycle.currentSession?.id {
            ids.insert(id)
        }
        if let recorder = services.recorderBox.recorder {
            ids.formUnion(recorder.lifecycle.unsavedSessions.map(\.id))
        }
        return ids
    }

    /// A session the archive still holds as deleted cannot be put back (the
    /// archive refuses to write it), so the restore stops there and says so
    /// rather than rebuilding it only to have the write refused.
    func restoreFromTrash(_ sessionId: UUID) async -> HRVSession? {
        recoveryService.restoreFromTrash(sessionId)
        guard !archive.store.deletedIds.contains(sessionId) else {
            debugLog("[Recovery] Could not restore \(sessionId.uuidString.prefix(8)): it is still marked deleted", level: .error)
            recoveryService.restoreFromTrashFailed(sessionId)
            return nil
        }
        if let kept = restoreKeptSession(sessionId) { return kept }
        let restored = await recoverFromBackup(sessionId)
        if restored == nil { recoveryService.restoreFromTrashFailed(sessionId) }
        return restored
    }

    /// The deleted session's own file, put back as it was. Rebuilding from the
    /// raw backup is only for sessions deleted before the trash kept files.
    /// A night recorded or recovered again since the delete is linked to it,
    /// as the raw-backup restore does, so the night isn't counted twice.
    private func restoreKeptSession(_ sessionId: UUID) -> HRVSession? {
        let archive = self.archive
        guard var session = archive.store.trashedSession(sessionId) else { return nil }
        morning.supersedeSameNightSession(newSession: &session)
        do {
            try archive.archive(session, skipSameNightMerge: true)
        } catch {
            debugLog("[Recovery] Could not put back trashed session \(sessionId.uuidString.prefix(8)): \(error)", level: .error)
            return nil
        }
        archive.store.discardTrashed(sessionId)
        rawBackup.markAsArchived(sessionId)
        Task { await cloudSyncManager.forceReuploadSession(session) }
        Task { @MainActor in archiveSignal.notifyChanged() }
        return session
    }

    /// Deletes sessions from the Trash for good, and everything each
    /// exported to Apple Health: HRV, heart rate, resting heart rate, sleep
    /// and workouts (`HealthWriteAndObserve.removeExports`,
    /// `SessionRecoveryService.permanentlyDelete(_:removeHealthSamples:)`).
    @discardableResult
    func permanentlyDelete(_ ids: [UUID]) async -> TrashDeletionOutcome {
        await recoveryService.permanentlyDelete(ids) { id, span in
            await removeHealthExports(of: id, over: span)
        }
    }

    /// False (logged) when HealthKit could not delete all of them.
    private func removeHealthExports(of id: UUID, over span: ClosedRange<Date>) async -> Bool {
        do {
            try await healthWrites.removeExports(sessionId: id, from: span.lowerBound, to: span.upperBound)
            return true
        } catch {
            debugLog("[Recovery] Apple Health samples of \(id.uuidString.prefix(8)) could not all be deleted: \(error)", level: .error)
            return false
        }
    }

    /// The ids whose deletion mark was stored.
    @discardableResult

    /// Workout backups carry a WorkoutTrackBackup header and must
    /// rebuild via WorkoutRecoveryService (GPS / distance / TRIMP), NOT the HRV
    /// path. And the H10 records the full workout internally, so we pull that
    /// complete recording from the strap when it's connected — it survives the
    /// BLE drop + crash the streamed disk backup misses.
    ///
    /// `recordedType` is the type the recording was started as, when known
    /// (the launch alert's persisted state); see
    /// `SessionRecoveryService.recoveredSessionType`.
    func recoverFromBackup(_ sessionId: UUID, recordedType: SessionType? = nil) async -> HRVSession? {
        if services.workoutTrackBackup.retrieve(sessionId) != nil {
            return await recoverWorkoutFromBackup(sessionId)
        }
        let session = await recoverHRVFromBackup(sessionId, recordedType: recordedType)
        if session?.state == .complete {
            await MainActor.run { archiveSignal.notifyChanged() }
        }
        if let session, session.state == .paused { await holdKeptPausedNight(session) }
        return session
    }

    /// The archive kept a paused copy of the night holding more than its
    /// backup (`SessionRecoveryService.archivedCopyHoldingMore`): it is still
    /// paused, not saved. It goes on the Record tab, as a Resume puts it, so
    /// the night can be resumed or finished there, which is what the caller
    /// then says. Not while another recording holds the Record tab.
    private func holdKeptPausedNight(_ session: HRVSession) async {
        guard !sessionState.isCollecting, streamingLifecycle.pausedSession == nil else { return }
        await holdPaused(session)
    }

    private func recoverHRVFromBackup(_ sessionId: UUID, recordedType: SessionType?) async -> HRVSession? {
        await recoveryService.recoverFromBackup(
            sessionId,
            recordedType: recordedType,
            analyze: { [self] session, window, flags, capacity in
                await morning.analyze(session, window: window, flags: flags, peakCapacity: capacity)
            },
            analyzeWithCapacity: { [self] session, capacity in
                await morning.analyze(session, peakCapacity: capacity)
            },
            supersedeSameNight: { [self] session in
                morning.supersedeSameNightSession(newSession: &session)
            },
            computeRecoveryScore: { [self] session, analysisResult in
                await enrichedRecoveryScore(session: session, analysisResult: analysisResult)
            }
        )
    }

    /// Enriched scoring: ensure the analysisResult has a fresh training context (a crash
    /// before the original training fetch leaves it nil), then compute the
    /// composite. Without this, the backup recovery path archives the session
    /// with a nil `recoveryScore` and the dashboard recomputes the score live
    /// on every render until the user taps Reanalyze.
    private func enrichedRecoveryScore(session: HRVSession, analysisResult: HRVAnalysisResult?) async -> RecoveryScoreOutcome? {
        var enriched = analysisResult
        if enriched?.trainingContext == nil,
           let fresh = await scoring.createTrainingContextEnsuringFresh(relativeTo: session.endDate ?? session.startDate) {
            enriched?.trainingContext = fresh
        }
        return await morning.computeRecoveryScore(for: session, from: enriched)
    }

    /// Rebuild a crashed/interrupted WORKOUT from its on-disk backups,
    /// preferring the H10's complete on-device recording when the strap is
    /// connected. Routed here from `recoverFromBackup` for workout-type
    /// backups; the HRV path can't reconstruct GPS / distance / TRIMP.
    ///
    /// Returns the session only once it is in the archive. A rebuild whose
    /// archive write failed returns nil, as the HRV path does, with no review
    /// card and no archive-change signal: every caller reads a returned
    /// session as recovered and saved. Its backups are kept, so it can still
    /// be recovered from Lost Sessions.
    private func recoverWorkoutFromBackup(_ sessionId: UUID) async -> HRVSession? {
        let strap = await strapRecordingForWorkoutRecovery(sessionId: sessionId)
        let outcome = await WorkoutRecoveryService.recover(
            sessionId: sessionId, reason: .appCrashed,
            archive: archive, rawBackup: rawBackup, cloudSyncManager: cloudSyncManager,
            workoutTrackBackup: services.workoutTrackBackup, savedRouteStore: services.savedRouteStore, settingsManager: settingsManager,
            strapRRPoints: strap?.points
        )
        guard let outcome, outcome.wasArchived else {
            keepUnsavedDownload(strap?.recording)
            return nil
        }
        if let strap { strapRecorder.device.noteSaved(strap.recording) }
        await MainActor.run {
            archiveSignal.notifyChanged()
            // Surface for review/trim instead of silently keeping a
            // possibly-wrong-length session.
            morningCoordination.recoveredWorkoutReview = SessionRecoveryMath.makeRecoveredWorkoutReview(from: outcome.session)
        }
        return outcome.session
    }

    /// The H10 keeps recording internally through a crash. Its recording of
    /// this workout (one that started after the workout did, and no later
    /// than the workout's last known moment) is downloaded, stopping it if it
    /// still runs, and placed on the workout's clock by the recording's own
    /// start, as the live finish places it. A recording that began after the
    /// workout was last heard from belongs to a later session (an overnight
    /// armed that evening): it is kept aside as a rescue backup, as the
    /// overnight merge does. nil → the recovery service falls back to the
    /// streamed disk backup it reads on its own.
    private func strapRecordingForWorkoutRecovery(sessionId: UUID) async -> PulledStrapRecording? {
        guard let backup = services.workoutTrackBackup.retrieve(sessionId),
              !strapGuards.belongsToLiveSession else { return nil }
        let workoutStart = backup.header.startDate
        strapRecorder.beginTransfer()
        guard await strapRecorder.reconnectForTransfer(), strapRecorder.device.isRecordingOnDevice || strapRecorder.device.hasStoredExercise,
              let recording = await strapRecorder.fetchRecordingIfAvailable(recordedSince: workoutStart),
              !recording.points.isEmpty else {
            debugLog("[Recovery] Workout strap recovery: no usable H10 recording — using disk backup")
            return nil
        }
        guard Self.recording(startedAt: recording.startedAt, belongsToWorkoutLastHeardAt: Self.lastKnownMoment(of: backup)) else {
            let keptAside = strapRecorder.device.rescueToBackup(recording)
            debugLog("[Recovery] Workout strap recovery: the strap's recording began after the workout — \(keptAside ? "kept as a rescue backup" : "the rescue backup failed; the strap keeps it"); using disk backup")
            return nil
        }
        debugLog("[Recovery] Workout strap recovery: pulled \(recording.points.count) beats from H10")
        return PulledStrapRecording(recording: recording, points: recording.points(onClockOf: workoutStart))
    }

    /// A strap recording downloaded for a session, on that session's clock.
    struct PulledStrapRecording {
        let recording: StrapRecording
        let points: [RRPoint]
    }

    /// A session that could not be saved with the strap's beats must not
    /// leave them only in memory: they are kept as a rescue backup, offered in
    /// Lost Sessions, and the strap is not cleared over them
    /// (`StrapRecordingPolicy.recordingIsSaved`). A session that was saved
    /// with them puts the recording on the saved record itself
    /// (`StrapRecordingState.noteSaved`).
    private func keepUnsavedDownload(_ recording: StrapRecording?) {
        guard let recording else { return }
        let keptAside = strapRecorder.device.rescueToBackup(recording)
        debugLog("[Recovery] The session could not be saved with the strap's \(recording.points.count) beats — \(keptAside ? "kept as a rescue backup" : "the rescue backup failed")", level: .warning)
    }

    /// The last moment the workout's own backup records: its newest GPS fix
    /// or sample, else its start.
    static func lastKnownMoment(of backup: WorkoutTrackBackup.Recovered) -> Date {
        let start = backup.header.startDate
        let lastSample = backup.samples.map(\.offsetSec).max().map { start.addingTimeInterval(TimeInterval($0)) }
        return [start, backup.track.last?.timestamp, lastSample].compactMap { $0 }.max() ?? start
    }

    /// Whether a recording that began at `start` can be the workout's: one
    /// with no start cannot be placed, and one that began more than
    /// `armingSlackSeconds` after the workout was last heard from is a later
    /// session's. The slack covers a workout that died before its first
    /// sample, while the strap was still being armed.
    static func recording(startedAt start: Date?, belongsToWorkoutLastHeardAt lastKnown: Date) -> Bool {
        guard let start else { return false }
        return start <= lastKnown.addingTimeInterval(armingSlackSeconds)
    }

    static let armingSlackSeconds: TimeInterval = 15 * 60

    /// Re-finalize a workout at a user-chosen end (seconds from start on the
    /// wall clock) — the review/trim card's Save. Its archived beats are
    /// clipped there, and WorkoutRecoveryService cuts its track, samples and
    /// pauses there too and recomputes every figure from what is kept, so a
    /// workout with no heart rate is trimmed like any other; no strap re-pull
    /// is needed (the merged data is in the archived session).
    ///
    /// A session no longer in the archive has nothing to trim: the card
    /// closes and it is marked reviewed, so it does not come back. An archived
    /// session that cannot be read, or a rebuild that fails, keeps nothing or
    /// is not archived, leaves the card up and the session unreviewed, so the
    /// trim can be saved again instead of being dropped.
    ///
    /// True when the card closed; false when it stays up because nothing was
    /// saved, so the card can say so.
    @discardableResult
    func retrimRecoveredWorkout(sessionId: UUID, endSec: Double) async -> Bool {
        guard let clipped = archivedBeats(of: sessionId, upTo: endSec) else { return false }
        guard archive.store.exists(sessionId) else {
            closeRecoveredWorkoutReview(sessionId)
            return true
        }
        let outcome = await WorkoutRecoveryService.recover(
            sessionId: sessionId, reason: .appCrashed,
            archive: archive, rawBackup: rawBackup, cloudSyncManager: cloudSyncManager,
            workoutTrackBackup: services.workoutTrackBackup, savedRouteStore: services.savedRouteStore, settingsManager: settingsManager,
            overrideRRPoints: clipped,
            discardBackupsOnAccept: true, // user confirmed — safe to clean up
            overrideEndSec: endSec
        )
        guard let outcome, outcome.wasArchived else {
            debugLog("[Recovery] Trim of recovered workout \(sessionId.uuidString.prefix(8)) failed — keeping the review card", level: .error)
            return false
        }
        archiveSignal.notifyChanged()
        closeRecoveredWorkoutReview(sessionId)
        return true
    }

    /// The archived workout's beats up to `endSec`: none when the session is
    /// no longer in the archive or has no beats, nil (logged) when the
    /// archive could not read it. `endSec` is on the wall clock, as the trim
    /// card shows the workout, so the beats are cut on it too
    /// (`WorkoutAnalyzer.rrPoints(_:endingAt:sessionStart:)`): their own
    /// clock stands still through a strap dropout.
    private func archivedBeats(of sessionId: UUID, upTo endSec: Double) -> [RRPoint]? {
        do {
            guard let session = try archive.retrieve(sessionId) else { return [] }
            return WorkoutAnalyzer.rrPoints(
                session.rrSeries?.points ?? [], endingAt: session.startDate.addingTimeInterval(endSec), sessionStart: session.startDate
            )
        } catch {
            debugLog("[Recovery] Could not read recovered workout \(sessionId.uuidString.prefix(8)) to trim it — keeping the review card: \(error)", level: .error)
            return nil
        }
    }

    /// The session is marked reviewed, so its card does not come back, and
    /// the card closes.
    private func closeRecoveredWorkoutReview(_ sessionId: UUID) {
        Self.markRecoveredWorkoutReviewed(sessionId)
        morningCoordination.recoveredWorkoutReview = nil
    }

    /// Discard a recovered workout the user rejected from the review card.
    /// Deletes the archived session; the on-disk RR backup survives (marked
    /// archived), so it can still be re-recovered from Lost Sessions if the
    /// user changes their mind. True when it was deleted and the card closed.
    @discardableResult
    func discardRecoveredWorkout(sessionId: UUID) -> Bool {
        // A failed delete keeps the card up and the session unreviewed, so
        // the rejected workout is not left in the archive looking accepted
        // and Discard can be tapped again. The RR backup is kept either way.
        guard attempt("recoveredWorkout.discard", { try archive.delete(sessionId) }) != nil else { return false }
        archiveSignal.notifyChanged()
        closeRecoveredWorkoutReview(sessionId)
        return true
    }

    enum WatchRouteRecoveryResult {
        case recovered(distanceMeters: Double) // full GPS route from a Watch workout
        case distanceOnly(distanceMeters: Double) // distance from HealthKit, no route
        case noRoute
        case failed
    }

    /// Recover a crash-shortened workout's distance/route from Apple Health.
    /// Two paths, best-first:
    ///   1. If the Apple Watch recorded the walk as a workout, pull its full
    ///      GPS route → restores route AND distance.
    ///   2. Otherwise fall back to HealthKit's passive walking/running distance
    ///      over the workout window (the Watch/iPhone log distance continuously,
    ///      no GPS or workout needed) → restores the DISTANCE number even when
    ///      no route exists. This is the "the app knows my steps" path.
    /// Either rebuild that is not archived reports `.failed`; a found route
    /// that could not be saved does not fall back to the distance path.
    /// `training` reads the Watch's route and Health's passive distance.
    func recoverRouteFromAppleWatch(sessionId: UUID, training: TrainingHealthQueries) async -> WatchRouteRecoveryResult {
        guard let session = archive.retrieveOrLog(sessionId), let series = session.rrSeries else { return .failed }
        let start = session.startDate
        let end = session.endDate ?? start
        if let route = await training.fetchWorkoutRoute(from: start, to: end), route.fixes.count >= 2 {
            guard let rebuilt = await recoverWorkout(sessionId: sessionId, points: series.points, track: route) else { return .failed }
            await MainActor.run { archiveSignal.notifyChanged() }
            return .recovered(distanceMeters: rebuilt.workoutMetadata?.distanceMeters ?? 0)
        }
        let hkDistance = await training.fetchPassiveDistanceMeters(from: start, to: end)
        // Only worth rewriting when HealthKit meaningfully beats what we recorded.
        guard hkDistance > (session.workoutMetadata?.distanceMeters ?? 0) + 50 else { return .noRoute }
        guard let rebuilt = await recoverWorkout(sessionId: sessionId, points: series.points, distanceMeters: hkDistance)
        else { return .failed }
        await MainActor.run { archiveSignal.notifyChanged() }
        return .distanceOnly(distanceMeters: rebuilt.workoutMetadata?.distanceMeters ?? hkDistance)
    }

    /// Rebuild the workout with whichever override we recovered. `track` also
    /// discards the on-disk backups, since a full route supersedes them.
    /// Returns the rebuilt session only once it is archived; nil when nothing
    /// could be rebuilt or the archive write failed.
    private func recoverWorkout(
        sessionId: UUID,
        points: [RRPoint],
        track: SegmentedTrack? = nil,
        distanceMeters: Double? = nil
    ) async -> HRVSession? {
        let outcome = await WorkoutRecoveryService.recover(
            sessionId: sessionId,
            reason: .appCrashed,
            archive: archive,
            rawBackup: rawBackup,
            cloudSyncManager: cloudSyncManager,
            workoutTrackBackup: services.workoutTrackBackup, savedRouteStore: services.savedRouteStore, settingsManager: settingsManager,
            overrideRRPoints: points,
            discardBackupsOnAccept: track != nil,
            overrideTrack: track,
            overrideDistanceMeters: distanceMeters
        )
        guard let outcome, outcome.wasArchived else { return nil }
        return outcome.session
    }

    enum StrapAugmentResult {
        case merged(durationSec: Double, beats: Int)
        case notConnected
        case noStrapData
        case failed
    }

    /// "Recover session" — download the strap's complete recording and MERGE it
    /// into an already-archived workout, then auto-trim the end (HR drop). The
    /// strap holds the full heart-rate session even when the phone-side stream
    /// was partial, so this restores the true duration/HR. (The strap carries
    /// HR, not GPS — distance still comes from the recorded route.)
    func augmentWorkoutFromStrap(sessionId: UUID) async -> StrapAugmentResult {
        guard strapRecorder.linkState.connectionState == .connected else { return .notConnected }
        guard let session = archive.retrieveOrLog(sessionId) else { return .failed }
        strapRecorder.beginTransfer()
        guard let strap = await pullStrapRecording(for: session) else { return .noStrapData }
        let merged = SessionRecoveryMath.mergedWorkoutPoints(
            existing: session.rrSeries?.points ?? [], strapRR: strap.points,
            sessionId: sessionId, sessionStart: session.startDate
        )
        guard let outcome = await WorkoutRecoveryService.recover(
            sessionId: sessionId, reason: .appCrashed,
            archive: archive, rawBackup: rawBackup, cloudSyncManager: cloudSyncManager,
            workoutTrackBackup: services.workoutTrackBackup, savedRouteStore: services.savedRouteStore, settingsManager: settingsManager,
            overrideRRPoints: merged, autoTrimOverride: true
        ), outcome.wasArchived else {
            keepUnsavedDownload(strap.recording)
            return .failed
        }
        return await noteAugmented(outcome.session, from: strap, mergedCount: merged.count)
    }

    /// The augmented workout is in the archive with the strap's beats, so
    /// the strap's copy is on the saved record.
    private func noteAugmented(_ session: HRVSession, from strap: PulledStrapRecording, mergedCount: Int) async -> StrapAugmentResult {
        strapRecorder.device.noteSaved(strap.recording)
        await MainActor.run { archiveSignal.notifyChanged() }
        let dur = (session.endDate ?? session.startDate).timeIntervalSince(session.startDate)
        return .merged(durationSec: dur, beats: session.rrSeries?.points.count ?? mergedCount)
    }

    enum OvernightAugmentResult {
        case merged(source: String, beats: Int, score: Double?)
        case notReachable   // strap couldn't be reconnected in the window
        case noStrapData    // reconnected but no stored recording to pull
        case alreadyMerged  // session already carries device/composite data
        case failed
    }

    /// "Pull from strap & re-merge" for an OVERNIGHT session that scored
    /// streaming-only — e.g. Bluetooth dropped overnight so the morning device
    /// fetch was skipped and only the (possibly truncated) live stream was
    /// scored. The H10 keeps its full-night internal file until the next
    /// recording clears it, so this reconnects, downloads it, merges with the archived stream
    /// (device-preferred, stream fills gaps), and re-scores through the
    /// saved-session reanalysis the caller hands in
    /// (`SessionReanalysisCoordinator.reanalyzeSession`) so the HRV window +
    /// recovery score are recomputed from the fuller data. Overnight sibling
    /// of `augmentWorkoutFromStrap`.
    func augmentOvernightFromStrap(
        sessionId: UUID, rescoringWith reanalysis: SessionReanalysisCoordinator
    ) async -> OvernightAugmentResult {
        guard let session = archive.retrieveOrLog(sessionId) else { return .failed }
        // Nothing to add if the device recording is already in the mix.
        if let src = session.dataSourceSummary?.selectedSource, src == "internal" || src == "composite" {
            return .alreadyMerged
        }
        guard await reconnectStrapForAugment() else { return .notReachable }
        guard let strap = await pullStrapRecording(for: session) else { return .noStrapData }
        let (strapRR, existing) = (strap.points, session.rrSeries?.points ?? [])
        let selection = DataSourceSelector.selectBestSource(
            streamingPoints: existing, internalPoints: strapRR,
            sessionId: sessionId, sessionStart: session.startDate
        )
        guard let mergedPoints = overnightMergePoints(selection: selection, existing: existing, strapRR: strapRR),
              let updated = persistMergedOvernight(
                session: session, mergedPoints: mergedPoints, selection: selection, existingCount: existing.count, strap: strap
              ) else { return .failed }
        return await rescoreAugmentedOvernight(updated, merging: session, strap: strap, streamedCount: existing.count, with: reanalysis)
    }

    /// The selector's points, or the strap's when it chose nothing and the
    /// strap holds more. Nil when the archived stream would stay as it is:
    /// relabelling it as strap data would report a merge that never happened.
    private func overnightMergePoints(
        selection: DataSourceSelector.SelectionResult?, existing: [RRPoint], strapRR: [RRPoint]
    ) -> [RRPoint]? {
        if let selected = selection?.points { return selected.isEmpty ? nil : selected }
        return strapRR.count > existing.count ? strapRR : nil
    }

    /// The merged night is analysed again from its beats (`NightBeatsEdit`):
    /// a window the user picked stays and is scored, and any other is chosen
    /// again. When that fails the merge is undone (`undoOvernightMerge`), the
    /// strap's download kept as a rescue backup, and the result says it
    /// failed: a night holding the strap's beats under the stream's analysis
    /// and score is never left behind.
    ///
    /// Apple Health gets the night with the strap's beats, compared with the
    /// night as it was before the merge (`before`): the reanalysis compares
    /// with the merged copy it read, which already holds them.
    private func rescoreAugmentedOvernight(
        _ updated: HRVSession, merging before: HRVSession, strap: PulledStrapRecording, streamedCount: Int, with reanalysis: SessionReanalysisCoordinator
    ) async -> OvernightAugmentResult {
        guard let rescored = await Self.analysedAfterBeatsEdit(updated, with: reanalysis) else {
            undoOvernightMerge(before, mergedCount: updated.rrSeries?.points.count ?? 0, strap: strap)
            return .failed
        }
        await MainActor.run { archiveSignal.notifyChanged() }
        reanalysis.service.reexportIfReadingsChanged(from: before, to: rescored)
        let mergedBeatCount = rescored.rrSeries?.points.count ?? 0
        debugLog("[RRCollector] augmentOvernight: merged \(strap.points.count) strap + \(streamedCount) streamed → \(mergedBeatCount) beats, source=\(rescored.dataSourceSummary?.selectedSource ?? "?")")
        return .merged(source: rescored.dataSourceSummary?.selectedSource ?? "internal", beats: mergedBeatCount, score: rescored.recoveryScore)
    }

    /// A night whose beats an edit changed, analysed again: in full, or, for
    /// a window the user picked and still holds, scored over it. Nil when
    /// neither could be done.
    static func analysedAfterBeatsEdit(_ night: HRVSession, with reanalysis: SessionReanalysisCoordinator) async -> HRVSession? {
        if let reanalysed = await reanalysis.reanalyzeSession(night, preserveManualWindow: true) { return reanalysed }
        guard night.windowUserAdjusted == true else { return nil }
        return await reanalysis.service.recomputeScoreOnly(sessionId: night.id)
    }

    /// Puts the night back as it was before the strap's beats were merged,
    /// while it still holds the merged beats, and keeps the download aside.
    private func undoOvernightMerge(_ before: HRVSession, mergedCount: Int, strap: PulledStrapRecording) {
        let archive = archive
        let restored = attempt("augmentOvernight.undo") { try Self.undoMerge(before, mergedCount: mergedCount, in: archive) }
        keepUnsavedDownload(strap.recording)
        debugLog("[RRCollector] augmentOvernight: the merged night could not be analysed — \(restored == true ? "merge undone" : "could not undo the merge")", level: .error)
    }

    /// Writes `before`'s beats and derived fields back, while the stored copy
    /// still holds the `mergedCount` merged beats. Whether it wrote.
    nonisolated static func undoMerge(_ before: HRVSession, mergedCount: Int, in archive: SessionArchive) throws -> Bool {
        try archive.updateIfChanged(before.id) { stored in
            guard (stored.rrSeries?.points.count ?? 0) == mergedCount else { return false }
            restoreBeatsAndDerivedFields(of: before, in: &stored)
            return true
        }
    }

    /// The beats and every field computed from them, as `before` had them.
    nonisolated static func restoreBeatsAndDerivedFields(of before: HRVSession, in stored: inout HRVSession) {
        stored.rrSeries = before.rrSeries
        stored.dataSourceSummary = before.dataSourceSummary
        stored.artifactFlags = before.artifactFlags
        stored.analysisResult = before.analysisResult
        stored.autoWindowResult = before.autoWindowResult
        stored.windowUserAdjusted = before.windowUserAdjusted
        stored.endDate = before.endDate
        stored.sleepStartMs = before.sleepStartMs
        stored.sleepEndMs = before.sleepEndMs
    }

    /// Reconnect so the strap's stored recording is reachable (BLE likely
    /// dropped overnight).
    private func reconnectStrapForAugment() async -> Bool {
        strapRecorder.beginTransfer()
        return await strapRecorder.reconnectForTransfer()
    }

    /// The strap's recording of `session`, on the session's clock: one that
    /// began during it. Nothing is taken while a live session owns the
    /// strap's recording. A recording that turns out to be another
    /// session's is not dropped: it goes to the rescue backup, and if that
    /// fails the strap's copy is not saved (`isStrapRecordingSaved`), so the
    /// next start rescues it again instead of clearing it.
    private func pullStrapRecording(for session: HRVSession) async -> PulledStrapRecording? {
        let end = session.endDate ?? session.startDate
        let storedIsThisSession = strapRecorder.device.storedExerciseDate.map {
            StrapRecordingPolicy.recording(startedAt: $0, belongsToSessionStartedAt: session.startDate) && $0 <= end
        } ?? false
        // A recording still running is only dated once it is downloaded; the
        // check after the download catches one that is not this session's.
        guard !strapGuards.belongsToLiveSession, strapRecorder.device.isRecordingOnDevice || storedIsThisSession else {
            debugLog("[RRCollector] Strap's recording is not from this session — not merging it")
            return nil
        }
        guard let recording = await strapRecorder.fetchRecordingIfAvailable(recordedSince: session.startDate),
              !recording.points.isEmpty else { return nil }
        guard let recordedStart = recording.startedAt, recordedStart <= end else {
            let keptAside = strapRecorder.device.rescueToBackup(recording)
            debugLog("[RRCollector] Downloaded recording is not from this session — \(keptAside ? "kept as a rescue backup" : "the rescue backup failed; the strap keeps it")")
            return nil
        }
        return PulledStrapRecording(recording: recording, points: recording.points(onClockOf: session.startDate))
    }

    /// Persist merged points + updated provenance. This must be written BEFORE
    /// re-analysis, because `SessionReanalysisCoordinator.reanalyzeSession` re-loads the archived session
    /// from disk (and re-archives the rescored result itself).
    ///
    /// Only the beats and their provenance are written, onto the stored copy
    /// under the archive's lock (`SessionArchive.updateIfChanged`): the strap
    /// download takes seconds to minutes, and a feeling, a sleep update or a
    /// note saved meanwhile is in the stored copy, not in `session`, which was
    /// read before it. Nothing is written when the stored beats are no longer
    /// the ones merged (another merge landed first) or the night was deleted.
    ///
    /// A night that cannot be written keeps the strap's download as a rescue
    /// backup (`keepUnsavedDownload`).
    private func persistMergedOvernight(
        session: HRVSession, mergedPoints: [RRPoint],
        selection: DataSourceSelector.SelectionResult?, existingCount: Int, strap: PulledStrapRecording
    ) -> HRVSession? {
        let summary = mergedSummary(session: session, mergedCount: mergedPoints.count, selection: selection,
                                    existingCount: existingCount, strapCount: strap.points.count)
        let written: HRVSession?
        do {
            written = try Self.writeMergedBeats(mergedPoints, summary: summary, into: session.id, replacing: existingCount, in: archive)
        } catch {
            debugLog("[RRCollector] augmentOvernight: archive failed: \(error)")
            written = nil
        }
        if written == nil { keepUnsavedDownload(strap.recording) } else { strapRecorder.device.noteSaved(strap.recording) }
        return written
    }

    /// Puts `points` and `summary` on the archived copy of `sessionId`, with
    /// what is indexed into the beats moved with them and the span following
    /// them (`NightBeatsEdit.replaceBeats`), and changes nothing else; nil,
    /// with nothing written, when that copy no longer holds `replacing`
    /// beats. Returns the copy as written.
    nonisolated static func writeMergedBeats(
        _ points: [RRPoint], summary: HRVSession.DataSourceSummary, into sessionId: UUID, replacing beatCount: Int, in archive: SessionArchive
    ) throws -> HRVSession? {
        var written: HRVSession?
        try archive.updateIfChanged(sessionId) { stored in
            guard (stored.rrSeries?.points.count ?? 0) == beatCount else { return false }
            NightBeatsEdit.replaceBeats(of: &stored, with: points)
            stored.dataSourceSummary = summary
            written = stored
            return true
        }
        return written
    }

    /// The provenance of a night after the strap's recording was merged in.
    private func mergedSummary(
        session: HRVSession, mergedCount: Int, selection: DataSourceSelector.SelectionResult?, existingCount: Int, strapCount: Int
    ) -> HRVSession.DataSourceSummary {
        HRVSession.DataSourceSummary(
            selectedSource: selection?.normalizedSource ?? "internal",
            streamingBeats: existingCount,
            deviceBeats: strapCount,
            totalBeats: mergedCount,
            beatDifferencePercent: nil,
            reconnectCount: session.dataSourceSummary?.reconnectCount ?? 0,
            deviceModel: session.dataSourceSummary?.deviceModel
        )
    }

    private static let reviewedRecoveredKey = "reviewedRecoveredWorkoutIds"

    static func markRecoveredWorkoutReviewed(_ sessionId: UUID) {
        var reviewed = UserDefaults.standard.stringArray(forKey: reviewedRecoveredKey) ?? []
        guard !reviewed.contains(sessionId.uuidString) else { return }
        reviewed.append(sessionId.uuidString)
        if reviewed.count > 50 { reviewed = Array(reviewed.suffix(50)) }
        UserDefaults.standard.set(reviewed, forKey: reviewedRecoveredKey)
    }

    /// Surface the review/trim card for an ALREADY-archived recovered workout
    /// the user hasn't confirmed yet (e.g. a session a prior recovery archived
    /// silently with a wrong, over-long duration). Targets recovered sessions
    /// (those carry `partialDataReason`) from the last 48h. Lets the user trim
    /// an existing bad session — they don't have to hunt for a control.
    func surfaceExistingRecoveredWorkoutForReview() {
        guard morningCoordination.recoveredWorkoutReview == nil else { return }
        let reviewed = Set(UserDefaults.standard.stringArray(forKey: Self.reviewedRecoveredKey) ?? [])
        let cutoff = Date().addingTimeInterval(-48 * 60 * 60)
        let candidates = archive.store.entries
            .filter { $0.sessionType == .workout && $0.date >= cutoff }
            .sorted { $0.date > $1.date }
        for entry in candidates {
            if reviewed.contains(entry.sessionId.uuidString) { continue }
            guard let session = archive.retrieveOrLog(entry.sessionId),
                  session.workoutMetadata?.partialDataReason != nil else { continue }
            morningCoordination.recoveredWorkoutReview = SessionRecoveryMath.makeRecoveredWorkoutReview(from: session)
            break
        }
    }

    /// Resolve the sessionId of an interrupted WORKOUT to recover: the
    /// persisted crash flag, else the newest un-archived on-disk WORKOUT
    /// backup (one with a WorkoutTrackBackup header), since after a crash the
    /// off-main flag save may not have landed. A workout still recording or
    /// finalizing is live, not interrupted, and is excluded on both paths.
    /// The backup scan is disk I/O, runs detached, and narrows by the index
    /// before opening a file (decoding every backup held the first screen
    /// for about seven seconds).
    func findInterruptedWorkoutSessionId() async -> UUID? {
        let live = liveRecordingIds()
        if let flagged = flaggedInterruptedWorkoutId(live: live) { return flagged }
        let archive = self.archive
        let (rawBackup, tracks) = (rawBackup, services.workoutTrackBackup)
        return await Task.detached(priority: .userInitiated) {
            // Only the last 24h: a genuine crash recovery is for something
            // that just happened, not a stale or corrupt old backup.
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            let candidates = unrecoveredBackupIds(since: cutoff, archive: archive, rawBackup: rawBackup)
                .filter { !live.contains($0) }
            return newestWorkoutBackup(among: candidates, in: rawBackup, tracks: tracks, capturedSince: cutoff)
        }.value
    }

    /// The workout the persisted crash flag names, when it is neither live
    /// nor archived. Read synchronously, without touching the backups.
    private func flaggedInterruptedWorkoutId(live: Set<UUID>) -> UUID? {
        guard let state = recordingStore.load(),
              state.sessionType == .workout,
              !live.contains(state.sessionId),
              !archive.store.exists(state.sessionId) else { return nil }
        return state.sessionId
    }

    /// Direct, strap-first recovery for an interrupted WORKOUT — pulls the
    /// H10's complete on-device recording and rebuilds the workout WITHOUT
    /// the Lost Sessions disk-list (which lists on-disk partials, never the
    /// strap, and can't surface a strap-only session). Keyed off the
    /// persisted recording state so it targets EXACTLY the crashed workout,
    /// not a pile of old backups. Returns the recovered session once it is
    /// archived, or nil when there's nothing to recover (no interrupted
    /// workout, or neither the strap nor disk has usable data — e.g. strap
    /// not connected) or the archive write failed. Only an archived recovery
    /// clears the crash marker.
    func recoverInterruptedWorkoutFromStrap() async -> HRVSession? {
        guard let sessionId = await findInterruptedWorkoutSessionId() else { return nil }
        let session = await recoverWorkoutFromBackup(sessionId)
        if session != nil { clearPersistedRecordingState(ifItIs: sessionId) }
        return session
    }

    /// The persisted marker names ONE recording. The workout lookup can fall
    /// back to the newest unarchived workout backup when the marker is for an
    /// overnight session, and clearing the marker unconditionally then wiped an
    /// interrupted night's record along with it.
    private func clearPersistedRecordingState(ifItIs sessionId: UUID) {
        recordingStore.clear(ifItIs: sessionId)
    }

    /// Called once at app launch. If a WORKOUT was recording when the app
    /// died (the persisted recording flag is still set — it's written at
    /// workout start and cleared on a normal finish — and the session was
    /// never archived), auto-connect the last strap, pull its complete
    /// on-device recording, MERGE it with the already-streamed disk data, and
    /// archive it — so the user never has to manually recover.
    ///
    /// Best-effort and non-blocking: if the strap can't be reached within a
    /// short window the persisted flag is LEFT set, so the manual "Recover
    /// workout from strap" card still offers it (and the user can recover
    /// disk-only, or wait until the strap is next connected to get the merge).
    /// A recovery whose archive write fails leaves the flag set and the
    /// attempt counted, so the manual card still offers the workout.
    func autoRecoverInterruptedWorkoutOnLaunch() async {
        // The flagged workout is registered before the backup scan awaits:
        // the launch alert's Save waits on it and must find it running.
        let flagged = flaggedInterruptedWorkoutId(live: liveRecordingIds())
        guard claimFlaggedWorkout(flagged) else { return }
        defer { if let flagged { InterruptedWorkoutAutoRecovery.end(flagged) } }
        guard let sessionId = await findInterruptedWorkoutSessionId() else { return }
        InterruptedWorkoutAutoRecovery.begin(sessionId)
        defer { InterruptedWorkoutAutoRecovery.end(sessionId) }
        guard AutoRecoveryAttempts.remain(for: sessionId), await strapReachedForAutoRecovery(of: sessionId) else { return }
        // Counted only now, as the memory-heavy pull starts: a launch with the
        // strap out of range is not an attempt.
        AutoRecoveryAttempts.record(sessionId)
        guard await recoverWorkoutFromBackup(sessionId) != nil else { return }
        clearPersistedRecordingState(ifItIs: sessionId)
        AutoRecoveryAttempts.clear(sessionId)
        debugLog("[RRCollector] Auto-recovery: merged strap + streamed and archived interrupted workout")
    }

    /// Registers the flagged workout for this auto-recovery. False when the
    /// launch alert's Save or Resume registered it first: that recovery is
    /// under way, and this one stays out of it. No flagged workout: true.
    private func claimFlaggedWorkout(_ flagged: UUID?) -> Bool {
        guard let flagged else { return true }
        guard InterruptedWorkoutAutoRecovery.claim(flagged) else {
            debugLog("[RRCollector] Auto-recovery: the interrupted workout is already being recovered from the launch alert")
            return false
        }
        return true
    }

    /// The strap is reached, still records, and no new recording took it over
    /// while it was being reached. Otherwise recovery is left to the manual card.
    private func strapReachedForAutoRecovery(of sessionId: UUID) async -> Bool {
        guard await strapReadyForAutoRecovery() else {
            debugLog("[RRCollector] Auto-recovery: strap not reachable — deferring to manual card")
            return false
        }
        // A workout started while the strap was being reached: its recording
        // is the one on the strap now, and fetching it would stop it and
        // file its beats under the interrupted workout.
        if let current = recordingStore.load(), current.sessionId != sessionId {
            debugLog("[RRCollector] Auto-recovery: a new recording started — deferring to manual card")
            return false
        }
        return true
    }

    /// Get the strap connected so its on-device recording is reachable, and
    /// read whether it still records.
    private func strapReadyForAutoRecovery() async -> Bool {
        strapRecorder.beginTransfer()
        guard await strapRecorder.reconnectForTransfer() else { return false }
        await strapRecorder.refreshRecordingState(
            until: Date().addingTimeInterval(StrapRecordingPolicy.featureReadyWindowSeconds)
        )
        return strapRecorder.device.isRecordingOnDevice
    }

    /// What Resume made of an interrupted recording.
    enum PausedRecovery: Equatable {
        /// The night is paused, on the Record tab.
        case paused
        /// The archive held a finished copy of it with more beats than its
        /// backup (`SessionRecoveryService.archivedCopyHoldingMore`): that
        /// copy was kept as it is, and there is nothing to resume.
        case saved(SessionType)
        /// Nothing could be restored.
        case failed
    }

    /// Resume after a crash. Only a paused night is put on the Record tab: a
    /// kept finished copy put there offered Resume and Done for a night
    /// already saved, and Done saved it again.
    func recoverToPausedState(_ sessionId: UUID, sessionType: SessionType) async -> PausedRecovery {
        guard let session = await pausedRecovery(sessionId, sessionType: sessionType) else { return .failed }
        guard session.state == .paused else {
            recordingStore.clear(ifItIs: sessionId)
            return .saved(session.sessionType)
        }
        await holdPaused(session)
        recordingStore.clear(ifItIs: sessionId)
        return .paused
    }

    /// The paused night the service rebuilds, or the fuller copy it keeps.
    private func pausedRecovery(_ sessionId: UUID, sessionType: SessionType) async -> HRVSession? {
        await recoveryService.recoverToPausedState(
            sessionId,
            sessionType: sessionType,
            analyze: { [self] session, window, flags, capacity in
                await morning.analyze(session, window: window, flags: flags, peakCapacity: capacity)
            },
            analyzeWithCapacity: { [self] session, capacity in
                await morning.analyze(session, peakCapacity: capacity)
            }
        )
    }

    /// Puts a paused night on the Record tab, with Resume and Done, as it
    /// stands after a relaunch.
    private func holdPaused(_ session: HRVSession) async {
        await MainActor.run { enterPausedState(session) }
        // Resume arms the strap by the night's own capture choice, not the default.
        if let usesDeviceBackup = recordingStore.captureMode() { overnightRun.usesDeviceBackup = usesDeviceBackup }
        recordingStore.persistPaused(sessionId: session.id)
    }

    @MainActor
    private func enterPausedState(_ session: HRVSession) {
        sessionState.currentSession = session
        streamingLifecycle.pausedSession = session
        streamingLifecycle.pausedBeatCount = session.rrSeries?.points.count ?? 0
        streamingLifecycle.isPaused = true
        sessionState.recordingPhase = .paused(sessionId: session.id)
        sessionState.needsAcceptance = false
        archiveSignal.notifyChanged()
    }
}

// MARK: - File-scope helpers
//
// Each names no member of `RRCollector` and calls nothing on it, so none needs
// to be inside the type.

/// Backups indexed since `cutoff` that no session holds. A workout the user
/// deleted or rejected keeps its backup, and a backup already folded into a
/// session is marked archived; neither is an interrupted workout.
private func unrecoveredBackupIds(since cutoff: Date, archive: SessionArchive, rawBackup: RawRRBackup) -> [UUID] {
    let excluded = Set(archive.store.entries.map(\.sessionId)).union(archive.store.deletedIds)
    let unarchived = Set(rawBackup.unarchivedSessionIds)
    return rawBackup.sessionIds(indexedSince: cutoff).filter { !excluded.contains($0) && unarchived.contains($0) }
}

/// The newest of `candidates` that decodes, is dated inside the window by its
/// own header, and carries a workout track — the checks the index cannot
/// answer. Only the day's candidates reach here, so only their files are read.
private func newestWorkoutBackup(
    among candidates: [UUID], in rawBackup: RawRRBackup, tracks workoutTracks: WorkoutTrackBackup, capturedSince cutoff: Date
) -> UUID? {
    return candidates
        .compactMap { rawBackup.readableBackup($0) }
        .filter { $0.captureDate >= cutoff && workoutTracks.retrieve($0.id) != nil }
        .max { $0.captureDate < $1.captureDate }?
        .id
}

/// Bound auto-recovery attempts per session. Recovering a large strap
/// session is memory-heavy; if iOS kills the app mid-recovery BEFORE the
/// crash flag clears, the next launch retries, a relaunch loop. After a few
/// tries, stop auto-recovering and defer to the manual "Recover session" card
/// so we quit fighting the OS. Data stays safe in the backups either way.
///
/// One dictionary holds the count of the workout being recovered only:
/// recording an attempt drops any other workout's count and a recovery
/// clears its own, so counts for workouts that never recover do not pile up.
@MainActor
private enum AutoRecoveryAttempts {
    private static let key = "autoRecoverAttempts"
    private static let limit = 3

    static func remain(for sessionId: UUID) -> Bool {
        let attempts = count(for: sessionId)
        guard attempts < limit else {
            debugLog("[RRCollector] Auto-recovery: \(sessionId.uuidString.prefix(8)) hit \(attempts) attempts — deferring to manual card to break the relaunch loop")
            return false
        }
        return true
    }

    static func record(_ sessionId: UUID) {
        let attempts = count(for: sessionId) + 1
        UserDefaults.standard.set([sessionId.uuidString: attempts], forKey: key)
        debugLog("[RRCollector] Auto-recovery: interrupted workout \(sessionId.uuidString.prefix(8)) — attempt \(attempts)")
    }

    static func clear(_ sessionId: UUID) {
        guard count(for: sessionId) > 0 else { return }
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func count(for sessionId: UUID) -> Int {
        UserDefaults.standard.dictionary(forKey: key)?[sessionId.uuidString] as? Int ?? 0
    }
}

/// The interrupted workout launch auto-recovery is working on. The launch
/// alert's Save and Resume wait for it rather than rebuild the same workout
/// alongside it from the phone's copy alone.
enum InterruptedWorkoutAutoRecovery {
    private static let running = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    static func begin(_ id: UUID) { running.withLock { _ = $0.insert(id) } }
    /// Registers `id` unless a recovery of it is registered already; true
    /// when this call registered it. The launch alert and launch
    /// auto-recovery each claim the workout, so only one rebuilds it.
    static func claim(_ id: UUID) -> Bool { running.withLock { $0.insert(id).inserted } }
    static func end(_ id: UUID) { running.withLock { _ = $0.remove(id) } }
    static func isRunning(_ id: UUID) -> Bool { running.withLock { $0.contains(id) } }

    /// Returns once auto-recovery of `id` has finished, or after `limit`.
    static func waitUntilDone(_ id: UUID, limit: TimeInterval = 150) async {
        let deadline = Date().addingTimeInterval(limit)
        while isRunning(id), Date() < deadline {
            await sleepQuietly(500_000_000, context: "InterruptedWorkoutAutoRecovery.wait")
        }
    }
}
