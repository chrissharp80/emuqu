import CoreLocation
import Foundation
import os

// Backup, corrupted-session and merge-repair recovery: restoring from the
// app's own on-disk backups. These delegate to `SessionRecoveryService`
// rather than touching the device at all; pulling RR back off the strap's
// internal memory lives in `RRCollector+Recovery.swift`.

extension SessionRecoveryCoordinator {
    // MARK: - Backup Recovery (delegates to SessionRecoveryService)

    /// Without the live recordings: a night still streaming has a backup and no
    /// archive entry yet, so it looked lost, and deleting it there tombstoned
    /// the night the morning archive was about to save. A recording that died
    /// with the app is not live, and still shows.
    func checkForLostSessions() async -> [(id: UUID, date: Date, beatCount: Int)] {
        await recoveryService.checkForLostSessions(excluding: liveRecordingIds())
    }

    private func liveRecordingIds() -> Set<UUID> {
        var ids = Set<UUID>()
        if collector.isCollecting, let id = collector.currentSession?.id { ids.insert(id) }
        if let id = collector.pausedSession?.id { ids.insert(id) }
        if let recorder = AppDependencies.current.app.recorderBox.recorder,
           recorder.phase == .recording || recorder.phase == .finalizing,
           let id = recorder.currentSession?.id {
            ids.insert(id)
        }
        return ids
    }

    func pullCloudBackupsToLocal() async {
        await recoveryService.pullCloudBackupsToLocal()
    }

    func checkForDeletedSessions() -> [(id: UUID, date: Date, beatCount: Int)] {
        recoveryService.checkForDeletedSessions()
    }

    /// A session the archive still holds as deleted cannot be put back (the
    /// archive refuses to write it), so the restore stops there and says so
    /// rather than rebuilding it only to have the write refused.
    func restoreFromTrash(_ sessionId: UUID) async -> HRVSession? {
        recoveryService.restoreFromTrash(sessionId)
        guard !collector.archive.deletedIds.contains(sessionId) else {
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
        let archive = collector.archive
        guard var session = archive.trashedSession(sessionId) else { return nil }
        collector.supersedeSameNightSession(newSession: &session)
        do {
            try archive.archive(session, skipSameNightMerge: true)
        } catch {
            debugLog("[Recovery] Could not put back trashed session \(sessionId.uuidString.prefix(8)): \(error)", level: .error)
            return nil
        }
        archive.discardTrashed(sessionId)
        collector.rawBackup.markAsArchived(sessionId)
        Task { await collector.cloudSyncManager.forceReuploadSession(session) }
        Task { @MainActor in collector.archiveSignal.notifyChanged() }
        return session
    }

    func permanentlyDelete(_ sessionId: UUID) {
        recoveryService.permanentlyDelete(sessionId)
    }

    func deleteLostSessions(_ sessionIds: [UUID]) {
        recoveryService.deleteLostSessions(sessionIds)
    }

    /// Workout backups carry a WorkoutTrackBackup header and must
    /// rebuild via WorkoutRecoveryService (GPS / distance / TRIMP), NOT the HRV
    /// path. And the H10 records the full workout internally, so we pull that
    /// complete recording from the strap when it's connected — it survives the
    /// BLE drop + crash the streamed disk backup misses.
    func recoverFromBackup(_ sessionId: UUID) async -> HRVSession? {
        if AppDependencies.current.storage.workoutTrackBackup.retrieve(sessionId) != nil {
            return await recoverWorkoutFromBackup(sessionId)
        }
        let session = await recoverHRVFromBackup(sessionId)
        if session?.state == .complete {
            await MainActor.run { collector.archiveSignal.notifyChanged() }
        }
        return session
    }

    private func recoverHRVFromBackup(_ sessionId: UUID) async -> HRVSession? {
        await recoveryService.recoverFromBackup(
            sessionId,
            analyze: { [self] session, window, flags, capacity in
                await collector.analyze(session, window: window, flags: flags, peakCapacity: capacity)
            },
            analyzeWithCapacity: { [self] session, capacity in
                await collector.analyze(session, peakCapacity: capacity)
            },
            supersedeSameNight: { [self] session in
                collector.supersedeSameNightSession(newSession: &session)
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
           let fresh = await collector.createTrainingContextEnsuringFresh(relativeTo: session.endDate ?? session.startDate) {
            enriched?.trainingContext = fresh
        }
        return await collector.computeRecoveryScore(for: session, from: enriched)
    }

    /// Rebuild a crashed/interrupted WORKOUT from its on-disk backups,
    /// preferring the H10's complete on-device recording when the strap is
    /// connected. Routed here from `recoverFromBackup` for workout-type
    /// backups; the HRV path can't reconstruct GPS / distance / TRIMP.
    private func recoverWorkoutFromBackup(_ sessionId: UUID) async -> HRVSession? {
        let outcome = await WorkoutRecoveryService.recover(
            sessionId: sessionId,
            reason: .appCrashed,
            archive: collector.archive,
            rawBackup: collector.rawBackup,
            cloudSyncManager: collector.cloudSyncManager,
            strapRRPoints: await strapRecordingForWorkoutRecovery(sessionId: sessionId)
        )
        guard let outcome else { return nil }
        await MainActor.run {
            collector.archiveSignal.notifyChanged()
            // Surface for review/trim instead of silently keeping a
            // possibly-wrong-length session.
            collector.morningCoordination.recoveredWorkoutReview = SessionRecoveryMath.makeRecoveredWorkoutReview(from: outcome.session)
        }
        return outcome.session
    }

    /// The H10 keeps recording internally through a crash. Its recording of
    /// this workout (one that started after the workout did) is downloaded,
    /// stopping it if it still runs, and placed on the workout's clock by the
    /// recording's own start, as the live finish places it. nil → the
    /// recovery service falls back to the streamed disk backup it reads on
    /// its own.
    private func strapRecordingForWorkoutRecovery(sessionId: UUID) async -> [RRPoint]? {
        guard let workoutStart = AppDependencies.current.storage.workoutTrackBackup.retrieve(sessionId)?.header.startDate,
              !strapRecordingBelongsToLiveSession else { return nil }
        let manager = collector.polarManager
        manager.beginTransfer()
        guard await manager.reconnectForTransfer(), manager.isRecordingOnDevice || manager.hasStoredExercise,
              let recording = await manager.fetchRecordingIfAvailable(recordedSince: workoutStart),
              !recording.points.isEmpty else {
            debugLog("[Recovery] Workout strap recovery: no usable H10 recording — using disk backup")
            return nil
        }
        debugLog("[Recovery] Workout strap recovery: pulled \(recording.points.count) beats from H10")
        return recording.points(onClockOf: workoutStart)
    }

    /// Re-finalize a recovered workout at a user-chosen end (seconds from
    /// start) by clipping its archived RR series — the review/trim card's
    /// Save. Reuses WorkoutRecoveryService so TRIMP/metrics stay consistent;
    /// no strap re-pull needed (the merged data is in the archived session).
    ///
    /// Refuses to trim into nothing — fewer than 30 beats isn't a workout. In
    /// that case the recovered workout is kept as it was, untrimmed, and marked
    /// reviewed like a save, so the card doesn't come back for the same session.
    /// A rebuild that fails leaves the card up and the session unreviewed, so
    /// the trim can be saved again instead of being dropped.
    func retrimRecoveredWorkout(sessionId: UUID, endSec: Double) async {
        let clipped = collector.archive.retrieveOrLog(sessionId)?.rrSeries?.points
            .filter { $0.t_ms <= Int64(endSec * 1000) } ?? []
        guard clipped.count >= 30 else { return closeRecoveredWorkoutReview(sessionId) }
        let outcome = await WorkoutRecoveryService.recover(
            sessionId: sessionId, reason: .appCrashed,
            archive: collector.archive, rawBackup: collector.rawBackup, cloudSyncManager: collector.cloudSyncManager,
            overrideRRPoints: clipped,
            discardBackupsOnAccept: true // user confirmed — safe to clean up
        )
        guard outcome != nil else {
            debugLog("[Recovery] Trim of recovered workout \(sessionId.uuidString.prefix(8)) failed — keeping the review card", level: .error)
            return
        }
        collector.archiveSignal.notifyChanged()
        closeRecoveredWorkoutReview(sessionId)
    }

    /// The session is marked reviewed, so its card does not come back, and
    /// the card closes.
    private func closeRecoveredWorkoutReview(_ sessionId: UUID) {
        Self.markRecoveredWorkoutReviewed(sessionId)
        collector.morningCoordination.recoveredWorkoutReview = nil
    }

    /// Discard a recovered workout the user rejected from the review card.
    /// Deletes the archived session; the on-disk RR backup survives (marked
    /// archived), so it can still be re-recovered from Lost Sessions if the
    /// user changes their mind.
    func discardRecoveredWorkout(sessionId: UUID) {
        // A failed delete keeps the card up and the session unreviewed, so
        // the rejected workout is not left in the archive looking accepted
        // and Discard can be tapped again. The RR backup is kept either way.
        guard attempt("recoveredWorkout.discard", { try collector.archive.delete(sessionId) }) != nil else { return }
        collector.archiveSignal.notifyChanged()
        closeRecoveredWorkoutReview(sessionId)
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
    func recoverRouteFromAppleWatch(sessionId: UUID) async -> WatchRouteRecoveryResult {
        guard let session = collector.archive.retrieveOrLog(sessionId), let series = session.rrSeries else { return .failed }
        let start = session.startDate
        let end = session.endDate ?? start
        if let route = await collector.healthKit.fetchWorkoutRoute(from: start, to: end), route.count >= 2,
           let outcome = await recoverWorkout(sessionId: sessionId, points: series.points, track: route) {
            await MainActor.run { collector.archiveSignal.notifyChanged() }
            return .recovered(distanceMeters: outcome.session.workoutMetadata?.distanceMeters ?? 0)
        }
        let hkDistance = await collector.healthKit.fetchPassiveDistanceMeters(from: start, to: end)
        // Only worth rewriting when HealthKit meaningfully beats what we recorded.
        guard hkDistance > (session.workoutMetadata?.distanceMeters ?? 0) + 50 else { return .noRoute }
        guard let outcome = await recoverWorkout(sessionId: sessionId, points: series.points, distanceMeters: hkDistance)
        else { return .failed }
        await MainActor.run { collector.archiveSignal.notifyChanged() }
        return .distanceOnly(distanceMeters: outcome.session.workoutMetadata?.distanceMeters ?? hkDistance)
    }

    /// Rebuild the workout with whichever override we recovered. `track` also
    /// discards the on-disk backups, since a full route supersedes them.
    private func recoverWorkout(
        sessionId: UUID,
        points: [RRPoint],
        track: [CLLocation]? = nil,
        distanceMeters: Double? = nil
    ) async -> WorkoutRecoveryService.Outcome? {
        await WorkoutRecoveryService.recover(
            sessionId: sessionId,
            reason: .appCrashed,
            archive: collector.archive,
            rawBackup: collector.rawBackup,
            cloudSyncManager: collector.cloudSyncManager,
            overrideRRPoints: points,
            discardBackupsOnAccept: track != nil,
            overrideTrack: track,
            overrideDistanceMeters: distanceMeters
        )
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
        guard collector.polarManager.connectionState == .connected else { return .notConnected }
        guard let session = collector.archive.retrieveOrLog(sessionId) else { return .failed }
        collector.polarManager.beginTransfer()
        let strapRR = await pullStrapRecording(for: session)
        guard !strapRR.isEmpty else { return .noStrapData }
        let merged = SessionRecoveryMath.mergedWorkoutPoints(
            existing: session.rrSeries?.points ?? [], strapRR: strapRR,
            sessionId: sessionId, sessionStart: session.startDate
        )
        guard let outcome = await WorkoutRecoveryService.recover(
            sessionId: sessionId, reason: .appCrashed,
            archive: collector.archive, rawBackup: collector.rawBackup, cloudSyncManager: collector.cloudSyncManager,
            overrideRRPoints: merged, autoTrimOverride: true
        ) else { return .failed }
        await MainActor.run { collector.archiveSignal.notifyChanged() }
        let dur = (outcome.session.endDate ?? outcome.session.startDate).timeIntervalSince(outcome.session.startDate)
        return .merged(durationSec: dur, beats: outcome.session.rrSeries?.points.count ?? merged.count)
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
    /// (device-preferred, stream fills gaps), and re-scores through the same
    /// overnight `collector.reanalyzeSession` path so the HRV window + recovery score are
    /// recomputed from the fuller data. Overnight sibling of
    /// `augmentWorkoutFromStrap`.
    func augmentOvernightFromStrap(sessionId: UUID) async -> OvernightAugmentResult {
        guard let session = collector.archive.retrieveOrLog(sessionId) else { return .failed }
        // Nothing to add if the device recording is already in the mix.
        if let src = session.dataSourceSummary?.selectedSource, src == "internal" || src == "composite" {
            return .alreadyMerged
        }
        guard await reconnectStrapForAugment() else { return .notReachable }
        let strapRR = await pullStrapRecording(for: session)
        guard !strapRR.isEmpty else { return .noStrapData }
        let existing = session.rrSeries?.points ?? []
        let selection = DataSourceSelector.selectBestSource(
            streamingPoints: existing, internalPoints: strapRR,
            sessionId: sessionId, sessionStart: session.startDate
        )
        guard let mergedPoints = overnightMergePoints(selection: selection, existing: existing, strapRR: strapRR),
              let updated = persistMergedOvernight(
                session: session, sessionId: sessionId, mergedPoints: mergedPoints,
                selection: selection, existingCount: existing.count, strapCount: strapRR.count
              ) else { return .failed }
        return await rescoreAugmentedOvernight(updated, strapCount: strapRR.count, streamedCount: existing.count)
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

    private func rescoreAugmentedOvernight(_ updated: HRVSession, strapCount: Int, streamedCount: Int) async -> OvernightAugmentResult {
        let rescored = await collector.reanalyzeSession(updated)
        await MainActor.run { collector.archiveSignal.notifyChanged() }
        let finalSession = rescored ?? updated
        let mergedBeatCount = finalSession.rrSeries?.points.count ?? 0
        debugLog("[RRCollector] augmentOvernight: merged \(strapCount) strap + \(streamedCount) streamed → \(mergedBeatCount) beats, source=\(finalSession.dataSourceSummary?.selectedSource ?? "?"), rescored=\(rescored != nil)")
        // A failed rescore reports no score: the archived one predates the merge.
        return .merged(
            source: finalSession.dataSourceSummary?.selectedSource ?? "internal",
            beats: mergedBeatCount,
            score: rescored?.recoveryScore
        )
    }

    /// Reconnect so the strap's stored recording is reachable (BLE likely
    /// dropped overnight).
    private func reconnectStrapForAugment() async -> Bool {
        collector.polarManager.beginTransfer()
        return await collector.polarManager.reconnectForTransfer()
    }

    /// The strap's recording of `session`, on the session's clock: one that
    /// began during it. Nothing is taken while a live session owns the
    /// strap's recording. A recording that turns out to be another
    /// session's is not dropped: it goes to the rescue backup, and if that
    /// fails the strap's copy is not saved (`isStrapRecordingSaved`), so the
    /// next start rescues it again instead of clearing it.
    private func pullStrapRecording(for session: HRVSession) async -> [RRPoint] {
        let manager = collector.polarManager
        let end = session.endDate ?? session.startDate
        let storedIsThisSession = manager.storedExerciseDate.map {
            StrapRecordingPolicy.recording(startedAt: $0, belongsToSessionStartedAt: session.startDate) && $0 <= end
        } ?? false
        // A recording still running is only dated once it is downloaded; the
        // check after the download catches one that is not this session's.
        guard !strapRecordingBelongsToLiveSession, manager.isRecordingOnDevice || storedIsThisSession else {
            debugLog("[RRCollector] Strap's recording is not from this session — not merging it")
            return []
        }
        guard let recording = await manager.fetchRecordingIfAvailable(recordedSince: session.startDate) else { return [] }
        guard let recordedStart = recording.startedAt, recordedStart <= end else {
            let keptAside = manager.rescueToBackup(recording)
            debugLog("[RRCollector] Downloaded recording is not from this session — \(keptAside ? "kept as a rescue backup" : "the rescue backup failed; the strap keeps it")")
            return []
        }
        return recording.points(onClockOf: session.startDate)
    }

    /// Persist merged points + updated provenance. This must be written BEFORE
    /// re-analysis, because `collector.reanalyzeSession` re-loads the archived session
    /// from disk (and re-archives the rescored result itself).
    private func persistMergedOvernight(
        session: HRVSession, sessionId: UUID, mergedPoints: [RRPoint],
        selection: DataSourceSelector.SelectionResult?, existingCount: Int, strapCount: Int
    ) -> HRVSession? {
        var updated = session
        updated.rrSeries = RRSeries(points: mergedPoints, sessionId: sessionId, startDate: session.startDate)
        updated.dataSourceSummary = HRVSession.DataSourceSummary(
            selectedSource: selection?.normalizedSource ?? "internal",
            streamingBeats: existingCount,
            deviceBeats: strapCount,
            totalBeats: mergedPoints.count,
            beatDifferencePercent: nil,
            reconnectCount: session.dataSourceSummary?.reconnectCount ?? 0,
            deviceModel: session.dataSourceSummary?.deviceModel
        )
        do {
            try collector.archive.archive(updated)
            return updated
        } catch {
            debugLog("[RRCollector] augmentOvernight: archive failed: \(error)")
            return nil
        }
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
        guard collector.morningCoordination.recoveredWorkoutReview == nil else { return }
        let reviewed = Set(UserDefaults.standard.stringArray(forKey: Self.reviewedRecoveredKey) ?? [])
        let cutoff = Date().addingTimeInterval(-48 * 60 * 60)
        let candidates = collector.archive.entries
            .filter { $0.sessionType == .workout && $0.date >= cutoff }
            .sorted { $0.date > $1.date }
        for entry in candidates {
            if reviewed.contains(entry.sessionId.uuidString) { continue }
            guard let session = collector.archive.retrieveOrLog(entry.sessionId),
                  session.workoutMetadata?.partialDataReason != nil else { continue }
            collector.morningCoordination.recoveredWorkoutReview = SessionRecoveryMath.makeRecoveredWorkoutReview(from: session)
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
        let archive = collector.archive
        let rawBackup = collector.rawBackup
        return await Task.detached(priority: .userInitiated) {
            // Only the last 24h: a genuine crash recovery is for something
            // that just happened, not a stale or corrupt old backup.
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            let candidates = unrecoveredBackupIds(since: cutoff, archive: archive, rawBackup: rawBackup)
                .filter { !live.contains($0) }
            return newestWorkoutBackup(among: candidates, in: rawBackup, capturedSince: cutoff)
        }.value
    }

    /// The workout the persisted crash flag names, when it is neither live
    /// nor archived. Read synchronously, without touching the backups.
    private func flaggedInterruptedWorkoutId(live: Set<UUID>) -> UUID? {
        guard let state = collector.getPersistedRecordingState(),
              state.sessionType == .workout,
              !live.contains(state.sessionId),
              !collector.archive.exists(state.sessionId) else { return nil }
        return state.sessionId
    }

    /// Direct, strap-first recovery for an interrupted WORKOUT — pulls the
    /// H10's complete on-device recording and rebuilds the workout WITHOUT
    /// the Lost Sessions disk-list (which lists on-disk partials, never the
    /// strap, and can't surface a strap-only session). Keyed off the
    /// persisted recording state so it targets EXACTLY the crashed workout,
    /// not a pile of old backups. Returns the recovered session, or nil when
    /// there's nothing to recover (no interrupted workout, or neither the
    /// strap nor disk has usable data — e.g. strap not connected).
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
        guard collector.getPersistedRecordingState()?.sessionId == sessionId else { return }
        collector.clearPersistedRecordingState()
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
    func autoRecoverInterruptedWorkoutOnLaunch() async {
        // The flagged workout is registered before the backup scan awaits:
        // the launch alert's Save waits on it and must find it running.
        let flagged = flaggedInterruptedWorkoutId(live: liveRecordingIds())
        if let flagged { InterruptedWorkoutAutoRecovery.begin(flagged) }
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
        if let current = collector.getPersistedRecordingState(), current.sessionId != sessionId {
            debugLog("[RRCollector] Auto-recovery: a new recording started — deferring to manual card")
            return false
        }
        return true
    }

    /// Get the strap connected so its on-device recording is reachable, and
    /// read whether it still records.
    private func strapReadyForAutoRecovery() async -> Bool {
        let manager = collector.polarManager
        manager.beginTransfer()
        guard await manager.reconnectForTransfer() else { return false }
        await manager.recording.refreshRecordingState(
            until: Date().addingTimeInterval(StrapRecordingPolicy.featureReadyWindowSeconds)
        )
        return manager.isRecordingOnDevice
    }

    func recoverToPausedState(_ sessionId: UUID, sessionType: SessionType) async -> Bool {
        guard let session = await recoveryService.recoverToPausedState(
            sessionId,
            sessionType: sessionType,
            analyze: { [self] session, window, flags, capacity in
                await collector.analyze(session, window: window, flags: flags, peakCapacity: capacity)
            },
            analyzeWithCapacity: { [self] session, capacity in
                await collector.analyze(session, peakCapacity: capacity)
            }
        ) else {
            return false
        }
        await MainActor.run { enterPausedState(session) }
        // Resume arms the strap by the night's own capture choice, not the default.
        if let usesDeviceBackup = collector.getPersistedCaptureMode() { collector.useDeviceBackupForOvernight = usesDeviceBackup }
        collector.persistPausedSessionState(sessionId: session.id)
        collector.clearPersistedRecordingState()
        return true
    }

    @MainActor
    private func enterPausedState(_ session: HRVSession) {
        collector.currentSession = session
        collector.pausedSession = session
        collector.pausedBeatCount = session.rrSeries?.points.count ?? 0
        collector.isPaused = true
        collector.recordingPhase = .paused(sessionId: session.id)
        collector.needsAcceptance = false
        collector.archiveSignal.notifyChanged()
    }

    // MARK: - Merge Data Loss Repair

    /// Rebuilds a child night's beat series by appending it to its parent's,
    /// time-shifted so the two are continuous.
    ///
    /// Repairs sessions affected by the merge data-loss bug where background
    /// device refinement bypassed `collector.mergeParentSessionData()`, leaving resumed
    /// sessions with only the child's data instead of parent + child merged.
    ///
    /// A v5-corrupted child already contains a copy of the parent's beats at
    /// its head, so only the tail past `parentBeatCount` is the child's own
    /// data. The offset takes the LARGER of the parent's recorded duration
    /// and the wall-clock gap between the two start dates, so a child that
    /// began after a long pause is not folded back on top of the parent.
    nonisolated static func mergedRepairPoints(
        childSeries: RRSeries,
        parentSeries: RRSeries,
        childStartDate: Date,
        parentStartDate: Date,
        parentBeatCount: Int,
        isV5Corrupted: Bool,
        idPrefix: String
    ) -> [RRPoint] {
        let childOriginalPoints: [RRPoint]
        if isV5Corrupted {
            childOriginalPoints = Array(childSeries.points.suffix(from: parentBeatCount))
            debugLog("[Recovery] Session \(idPrefix) is v5-corrupted (\(childSeries.points.count) beats) — extracting \(childOriginalPoints.count) child beats")
        } else {
            childOriginalPoints = childSeries.points
        }
        let parentDurationMs = parentSeries.points.last?.endMs ?? parentSeries.points.last?.t_ms ?? 0
        let dateOffsetMs = MillisecondOffset.between(childStartDate, and: parentStartDate, fallback: 0)
        let offsetMs = max(parentDurationMs, dateOffsetMs)
        let merged = parentSeries.points + childOriginalPoints.map { $0.shifted(by: offsetMs) }
        debugLog("[Recovery] Session \(idPrefix) merged: \(parentBeatCount) parent + \(childOriginalPoints.count) child (offset \(offsetMs / 60000)min) = \(merged.count) beats")
        return merged
    }

    /// Process each linked session inline — at most 2 full sessions (child +
    /// parent) in memory at a time. A previous implementation accumulated ALL
    /// candidates into a repairWork array, potentially holding hundreds of MB
    /// simultaneously.
    nonisolated func repairMergeDataLoss() async -> MergeRepairOutcome {
        debugLog("[Recovery] ========== START repairMergeDataLoss ==========")
        let linkedEntries = await linkedOvernightEntries()
        var outcome = MergeRepairOutcome()
        for entry in linkedEntries {
            switch await repairLinkedSession(entry) {
            case .repaired: outcome.repaired += 1
            case .failed: outcome.failed += 1
            case .unchanged: break
            }
        }
        if outcome.repaired > 0 { await MainActor.run { collector.archiveSignal.notifyChanged() } }
        debugLog("[Recovery] ========== END repairMergeDataLoss: \(outcome.repaired) repaired, \(outcome.failed) failed ==========")
        return outcome
    }

    /// How many linked nights were rewritten, and how many needed it but
    /// could not be written (those are worth another run).
    struct MergeRepairOutcome {
        var repaired = 0
        var failed = 0
    }

    /// One linked night: rewritten, left as it was (healthy, unreadable or
    /// implausible), or needing a repair whose write failed.
    enum LinkedRepairResult {
        case repaired
        case unchanged
        case failed
    }

    /// Gather candidates on the main actor (archive access). Pre-filters using
    /// the index's `linkedSessionIds` — avoids loading sessions from disk just
    /// to check whether they have links (saves ~700KB per session).
    nonisolated private func linkedOvernightEntries() async -> [SessionArchiveEntry] {
        let entries = await MainActor.run { collector.archive.entries }
        let linkedEntries = entries.filter { entry in
            entry.sessionType == .overnight &&
                entry.linkedSessionIds != nil &&
                !(entry.linkedSessionIds?.isEmpty ?? true)
        }
        guard !linkedEntries.isEmpty else { return [] }
        let skipped = entries.filter { $0.sessionType == .overnight }.count - linkedEntries.count
        debugLog("[Recovery] Checking \(linkedEntries.count) linked sessions (skipped \(skipped) non-linked)")
        return linkedEntries
    }

    /// Load the child + parent, decide whether anything is wrong, and if so
    /// rebuild and re-archive.
    nonisolated private func repairLinkedSession(_ entry: SessionArchiveEntry) async -> LinkedRepairResult {
        guard let parentId = entry.linkedSessionIds?.first else { return .unchanged }
        // Full load needed for the rrSeries merge.
        guard let session = await MainActor.run(resultType: HRVSession?.self, body: { collector.archive.retrieveOrLog(entry.sessionId) }),
              let parent = await MainActor.run(resultType: HRVSession?.self, body: { collector.archive.retrieveOrLog(parentId) }),
              let parentSeries = parent.rrSeries, !parentSeries.points.isEmpty,
              let childSeries = session.rrSeries, !childSeries.points.isEmpty
        else { return .unchanged }
        let damage = Self.mergeDamage(session: session, parent: parent, childSeries: childSeries, parentSeries: parentSeries)
        guard damage.needsRepair else { return .unchanged }
        guard let mergedPoints = Self.repairedPoints(
            entry: entry, session: session, parent: parent,
            childSeries: childSeries, parentSeries: parentSeries, damage: damage
        ) else { return .unchanged }
        let written = await rebuildAndArchive(session: session, parent: parent, mergedPoints: mergedPoints)
        return written ? .repaired : .failed
    }

    /// What (if anything) is wrong with a merged child session.
    struct MergeDamage {
        let needsMerge: Bool
        let isV5Corrupted: Bool
        let summaryStale: Bool
        let startDateWrong: Bool

        var needsRepair: Bool { needsMerge || isV5Corrupted || summaryStale || startDateWrong }
    }

    nonisolated private static func mergeDamage(
        session: HRVSession, parent: HRVSession,
        childSeries: RRSeries, parentSeries: RRSeries
    ) -> MergeDamage {
        let childBeatCount = childSeries.points.count
        let parentBeatCount = parentSeries.points.count
        return MergeDamage(
            needsMerge: childBeatCount <= parentBeatCount,
            isV5Corrupted: SessionRecoveryMath.hasV5TimestampDiscontinuity(childSeries: childSeries, parentBeatCount: parentBeatCount),
            summaryStale: session.dataSourceSummary.map { $0.totalBeats != childBeatCount } ?? false,
            startDateWrong: session.startDate.timeIntervalSince(parent.startDate) > 1800
        )
    }

    /// The beat series the repaired session should carry, or nil when the
    /// result fails the sanity ceiling.
    nonisolated private static func repairedPoints(
        entry: SessionArchiveEntry, session: HRVSession, parent: HRVSession,
        childSeries: RRSeries, parentSeries: RRSeries, damage: MergeDamage
    ) -> [RRPoint]? {
        let parentBeatCount = parentSeries.points.count
        let mergedPoints: [RRPoint]
        if damage.needsMerge || damage.isV5Corrupted {
            mergedPoints = mergedRepairPoints(
                childSeries: childSeries, parentSeries: parentSeries,
                childStartDate: session.startDate, parentStartDate: parent.startDate,
                parentBeatCount: parentBeatCount, isV5Corrupted: damage.isV5Corrupted,
                idPrefix: String(entry.sessionId.uuidString.prefix(8))
            )
        } else {
            mergedPoints = childSeries.points
            debugLog("[Recovery] Session \(entry.sessionId.uuidString.prefix(8)) already merged (\(mergedPoints.count) beats) but needs re-analysis (summaryStale=\(damage.summaryStale), startDateWrong=\(damage.startDateWrong))")
        }
        let maxReasonableBeats = (parentBeatCount + childSeries.points.count) * 2
        guard mergedPoints.count <= maxReasonableBeats, mergedPoints.count < 200_000 else {
            debugLog("[Recovery] ❌ Session \(entry.sessionId.uuidString.prefix(8)) has unreasonable beat count (\(mergedPoints.count)) — skipping")
            return nil
        }
        return mergedPoints
    }

    /// Re-run the morning pipeline over the repaired beats, carry the user's
    /// own edits across, then archive and upload. The repaired session is
    /// anchored to the PARENT's start; only the beat series differs. A child
    /// with no end ends at its last beat, not at the time the repair runs.
    nonisolated private func rebuildAndArchive(session: HRVSession, parent: HRVSession, mergedPoints: [RRPoint]) async -> Bool {
        let lastBeatEnd = mergedPoints.last.map { parent.startDate.addingTimeInterval(Double($0.endMs) / 1000) }
        let baseSession = HRVSession(
            id: session.id, startDate: parent.startDate, endDate: session.endDate ?? lastBeatEnd ?? parent.startDate,
            state: .analyzing, sessionType: .overnight,
            rrSeries: nil, analysisResult: nil, artifactFlags: nil,
            deviceProvenance: session.deviceProvenance,
            linkedSessionIds: session.linkedSessionIds, pausedDate: session.pausedDate
        )
        var repaired = await collector.processOvernightData(
            points: mergedPoints, baseSession: baseSession,
            dataSource: session.dataSourceSummary?.selectedSource ?? "streaming",
            reconnectCount: session.dataSourceSummary?.reconnectCount ?? 0,
            streamingBeats: session.dataSourceSummary?.streamingBeats ?? 0,
            deviceBeats: session.dataSourceSummary?.deviceBeats,
            isBackgroundRefinement: true
        )
        Self.carryUserEdits(from: session, to: &repaired)
        return await archiveRepaired(repaired, originalId: session.id, beatCount: mergedPoints.count)
    }

    /// Tags, notes, and the sleep-adjusted flag are the user's own work — the
    /// rebuilt session must not lose them. Vitals carry over only when the
    /// rebuild produced none.
    nonisolated private static func carryUserEdits(from session: HRVSession, to repaired: inout HRVSession) {
        repaired.tags = session.tags
        repaired.notes = session.notes
        repaired.sleepUserAdjusted = session.sleepUserAdjusted
        if repaired.vitalsSnapshot == nil, let oldVitals = session.vitalsSnapshot {
            repaired.vitalsSnapshot = oldVitals
        }
    }

    /// Upload immediately instead of accumulating — keeps peak memory low.
    nonisolated private func archiveRepaired(_ repairedSession: HRVSession, originalId: UUID, beatCount: Int) async -> Bool {
        do {
            let sessionToArchive = repairedSession
            _ = try await MainActor.run { try collector.archive.archive(sessionToArchive) }
            let syncSession = repairedSession
            // The sync manager is read on the main actor, so the upload Task
            // never reaches back through the collector.
            let cloudSync = await MainActor.run { collector.cloudSyncManager }
            Task { await cloudSync.forceReuploadSession(syncSession) }
            debugLog("[Recovery] Repaired session \(originalId.uuidString.prefix(8)): \(beatCount) beats, score \(repairedSession.recoveryScore.map { String(format: "%.1f", $0) } ?? "nil")")
            return true
        } catch {
            debugLog("[Recovery] Failed to archive repaired session: \(error)", level: .error)
            return false
        }
    }

}

// MARK: - File-scope helpers
//
// Kept out of RRCollector: each names no member of the type and calls
// nothing inside it, so none needs to be a member. `private` at file scope
// is fileprivate, so every call site in this file resolves the same way.

/// Backups indexed since `cutoff` that no session holds. A workout the user
/// deleted or rejected keeps its backup, and a backup already folded into a
/// session is marked archived; neither is an interrupted workout.
private func unrecoveredBackupIds(since cutoff: Date, archive: SessionArchive, rawBackup: RawRRBackup) -> [UUID] {
    let excluded = Set(archive.entries.map(\.sessionId)).union(archive.deletedIds)
    let unarchived = Set(rawBackup.unarchivedSessionIds)
    return rawBackup.sessionIds(indexedSince: cutoff).filter { !excluded.contains($0) && unarchived.contains($0) }
}

/// The newest of `candidates` that decodes, is dated inside the window by its
/// own header, and carries a workout track — the checks the index cannot
/// answer. Only the day's candidates reach here, so only their files are read.
private func newestWorkoutBackup(among candidates: [UUID], in rawBackup: RawRRBackup, capturedSince cutoff: Date) -> UUID? {
    let workoutTracks = AppDependencies.current.storage.workoutTrackBackup
    return candidates
        .compactMap { rawBackup.readableBackup($0) }
        .filter { $0.captureDate >= cutoff && workoutTracks.retrieve($0.id) != nil }
        .max { $0.captureDate < $1.captureDate }?
        .id
}

/// Bound auto-recovery attempts per session. Recovering a large strap
/// session is memory-heavy; if iOS kills the app mid-recovery BEFORE the
/// crash flag clears, the next launch retries — a relaunch loop (field log:
/// one session auto-recovered 5×). After a few tries, stop auto-recovering
/// and defer to the manual "Recover session" card so we quit fighting the
/// OS. Data stays safe in the backups either way.
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
