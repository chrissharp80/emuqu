import Foundation

// MARK: - Morning Processing Pipeline

extension MorningSessionPipeline {
    /// Process overnight data (used for both initial streaming and background refinement).
    /// When `isBackgroundRefinement` is true, all global UI state mutations are skipped —
    /// the caller is responsible for deciding what to do with the returned session.
    /// `awaitsReview: false` (a pause) publishes the result without the
    /// acceptance state and without the pre-archive: the caller archives the
    /// night as paused itself, and a paused night is not reviewed.
    ///
    /// The heavy analysis runs in `MorningProcessingService`; this applies the
    /// results to the observable sub-objects, archives the session, and handles
    /// CloudKit sync.
    ///
    /// `scoring.createTrainingContextEnsuringFresh` falls back to a live
    /// HealthKit fetch when `fetchTrainingLoadIfEnabled` didn't populate the
    /// cache. This prevents a Tier 2 → 3 re-freeze race: if the cache is
    /// momentarily empty, the session would be frozen as Tier 2 (89-style score),
    /// and the user's first re-analyze later would produce Tier 3 (65-style) — same
    /// recording, different number. So we refuse to freeze without training
    /// data when the user expects it.
    func processOvernightData(
        points: [RRPoint],
        baseSession: HRVSession,
        dataSource: String,
        reconnectCount: Int,
        streamingBeats: Int = 0,
        deviceBeats: Int? = nil,
        isBackgroundRefinement: Bool = false, awaitsReview: Bool = true,
        prefetchedSleepData: SleepData? = nil
    ) async -> HRVSession {
        debugLog("[RRCollector] Processing \(dataSource) data for analysis...")
        // Fetch training load before delegating (updates cachedTrainingLoad on self)
        await fetchTrainingLoadIfEnabled()
        showAnalyzingSession(baseSession: baseSession, points: points, skip: isBackgroundRefinement)
        let freshContext = await scoring.createTrainingContextEnsuringFresh(relativeTo: Self.trainingAsOf(baseSession, now: Date()))
        let result = await morningProcessingService.processOvernightData(
            MorningProcessingService.OvernightRequest(
                points: points, baseSession: baseSession, dataSource: dataSource, reconnectCount: reconnectCount,
                streamingBeats: streamingBeats, deviceBeats: deviceBeats, deviceId: strapLink.connectedDeviceId,
                isBackgroundRefinement: isBackgroundRefinement, settings: settingsSnapshot(for: baseSession),
                trainingContext: freshContext, cachedTrainingLoad: scoring.cachedTrainingLoad,
                prefetchedSleepData: prefetchedSleepData,
                statusCallback: { [weak self] status in self?.morningCoordination.morningStatus = status }
            )
        )
        var finalSession = result.session
        freezeTrainingSnapshot(on: &finalSession, freshContext: freshContext)
        publishForeground(result, finalSession: finalSession, skip: isBackgroundRefinement, awaitsReview: awaitsReview)
        debugLog("[RRCollector] Overnight streaming analysis complete: \(points.count) RR points")
        return finalSession
    }

    /// Apply the result to observable state and pre-archive for crash safety.
    /// Both are skipped for background refinement — the caller owns that
    /// decision; a night that does not await review is published without
    /// the acceptance state and not pre-archived.
    private func publishForeground(
        _ result: MorningProcessingService.ProcessingResult, finalSession: HRVSession, skip: Bool, awaitsReview: Bool
    ) {
        guard !skip else { return }
        applyProcessingResult(result, finalSession: finalSession, awaitsReview: awaitsReview)
        if awaitsReview { archiveForReview(finalSession) }
    }

    /// Settings snapshot so the service never reads `SettingsManager.shared`.
    /// The ANS configuration is the one for this night, on the same
    /// prior-nights baseline as its recovery score.
    private func settingsSnapshot(for baseSession: HRVSession) -> MorningProcessingService.SettingsSnapshot {
        let settings = settingsManager.settings
        return MorningProcessingService.SettingsSnapshot(
            sleepSchedule: settings.sleepSchedule,
            enableTrainingLoadIntegration: settings.enableTrainingLoadIntegration,
            typicalSleepHours: settings.typicalSleepHours,
            scoringConfig: scoring.currentScoringConfig,
            ansConfig: scoring.ansConfig(for: baseSession),
            sessionMergeMode: settings.sessionMergeMode,
            mergeGapSeconds: settings.effectiveMergeGapSeconds
        )
    }

    /// A temporary analyzing session so the UI has something to show while the
    /// service works. Skipped for background refinement.
    private func showAnalyzingSession(baseSession: HRVSession, points: [RRPoint], skip: Bool) {
        guard !skip else { return }
        sessionState.currentSession = HRVSession(
            id: baseSession.id,
            startDate: baseSession.startDate,
            endDate: Date(),
            state: .analyzing,
            sessionType: baseSession.sessionType,
            rrSeries: RRSeries(points: points, sessionId: baseSession.id, startDate: baseSession.startDate),
            analysisResult: nil,
            artifactFlags: nil
        )
    }

    /// The moment a night's training load is read as of: its own end, as the
    /// strap-recovery path reads it (`DeviceRecordingSession`), never later
    /// than `now`. A night stopped this morning reads today's load;
    /// one rebuilt on a later day (the linked-night repair) is scored against
    /// the load of its own morning, not the processing day's.
    nonisolated static func trainingAsOf(_ session: HRVSession, now: Date) -> Date {
        min(session.endDate ?? now, now)
    }

    /// Freeze the training snapshot once — never overwrite an existing one.
    /// Background refinement rebuilds the session from scratch (via
    /// `buildFinalSession`), so `trainingSnapshot` is always nil on the new
    /// struct. Recover the frozen snapshot from the already-archived version
    /// first; only fall back to a fresh fetch when no prior snapshot exists
    /// (first-time processing) — preferring the just-resolved fresh context
    /// over a stale cache read, and dropping to the sync cache only if that
    /// returned nil.
    ///
    /// `analysisResult.trainingContext` is kept in sync so every read path
    /// (dashboard, history, export) sees the frozen ATL/CTL/TSB values
    /// regardless of which field it checks.
    private func freezeTrainingSnapshot(on finalSession: inout HRVSession, freshContext: TrainingContext?) {
        if finalSession.trainingSnapshot == nil, let existing = archive.retrieveOrLog(finalSession.id) {
            finalSession.trainingSnapshot = existing.trainingSnapshot
        }
        if finalSession.trainingSnapshot == nil {
            finalSession.trainingSnapshot = freshContext ?? scoring.createTrainingContext(relativeTo: Self.trainingAsOf(finalSession, now: Date()))
        }
        if let frozen = finalSession.trainingSnapshot {
            finalSession.analysisResult?.trainingContext = frozen
        }
    }

    /// A reviewed night that did not analyse (`.failed`) leaves the analysing
    /// phase for idle, as a failed session does, and is shown as it is; a
    /// pause sets its own phase once the paused night is saved.
    private func applyProcessingResult(
        _ result: MorningProcessingService.ProcessingResult, finalSession: HRVSession, awaitsReview: Bool
    ) {
        let awaitsAcceptance = awaitsReview && finalSession.state == .complete
        sessionState.currentSession = finalSession
        sessionState.verificationResult = result.verificationResult
        sessionState.recoveryWindow = result.recoveryWindow
        sessionState.needsAcceptance = awaitsAcceptance
        if awaitsAcceptance {
            sessionState.recordingPhase = .awaitingAcceptance
        } else if awaitsReview {
            sessionState.recordingPhase = .idle
        }
        sessionState.baselineDeviation = result.baselineDeviation
        streamingLifecycle.sessionStartTime = nil
    }

    /// The id the night on the review card is archived under: its own, or
    /// that of the night the archive folded it into (`reviewFoldedIntoSessionId`).
    nonisolated static func archivedId(of session: HRVSession, foldedInto foldedId: UUID?) -> UUID {
        foldedId ?? session.id
    }

    /// Save the night before the user reviews it, so a crash on the review
    /// card never loses it. A night that was not in the archive before is
    /// remembered so "Discard" can take it back out; one the archive folded
    /// into a night it already held is remembered as folded, since Discard
    /// cannot take it back out of that night. The morning, the
    /// device-recording Stop, Retry and Recover all save through here.
    /// A failed save is reported to the user, and the night is then not in
    /// the archive: the morning keeps its recording marker for it
    /// (`OvernightStreamingCoordinator.clearPersistedStateIfSaved`).
    /// A night processed again under an id the archive holds keeps what the
    /// user set on the stored copy (`SessionArchive.archiveRebuilt`).
    func archiveForReview(_ finalSession: HRVSession) {
        guard finalSession.state == .complete else { return }
        let isNewEntry = !archive.store.entries.contains { $0.sessionId == finalSession.id }
        do {
            debugLog("[RRCollector] Pre-archiving session for review: \(finalSession.id.uuidString)")
            let entry = try archive.archiveRebuilt(finalSession)
            retireRawBackupIfSafe(finalSession)
            retireNightRescue(of: finalSession)
            if entry.sessionId != finalSession.id {
                sessionState.reviewFoldedIntoSessionId = entry.sessionId
            } else if isNewEntry {
                sessionState.reviewArchivedSessionId = finalSession.id
                sessionState.reviewArchivedEntries = SessionState.ReviewEntries(of: finalSession)
            }
        } catch {
            debugLog("[RRCollector] Failed to pre-archive session for review: \(error)", level: .error)
            sessionState.lastError = error
        }
    }

    /// Retire the raw backup only once the archive holds the data. A
    /// truncated download can still analyse to `.complete` on a subset; if
    /// the archived series is far smaller than the backup, the backup stays
    /// in the recovery list rather than the fuller capture being lost.
    /// Artifact filtering trims only a modest fraction, so the 50 % floor
    /// does not misfire on a healthy session.
    private func retireRawBackupIfSafe(_ session: HRVSession) {
        let archivedBeats = session.rrSeries?.points.count ?? 0
        if let backupBeats = rawBackup.backedUpBeatCount(session.id),
           backupBeats > 0, archivedBeats > 0, archivedBeats < backupBeats / 2 {
            debugLog("[RRCollector] Archived session holds \(archivedBeats) beats but raw backup holds \(backupBeats) — keeping the backup recoverable", level: .warning)
            return
        }
        rawBackup.markAsArchived(session.id)
    }

    /// "Discard" on the review card: move the night saved for review to
    /// Trash (restorable from there), tell iCloud, and rebuild the baseline
    /// without it, since the morning flow already folded it in. Only the id
    /// saved for this review is touched (`SessionState.reviewArchivedSessionId`):
    /// a night newly pre-archived for it, or a paused night finalized for
    /// review with Done. Any other night already in the archive is not.
    ///
    /// False when the night could not be moved to Trash: it is still archived
    /// and still under review, the error is shown, and Discard can be tapped
    /// again. True otherwise, including when there was nothing to move.
    @discardableResult
    func discardReviewArchivedSession() -> Bool {
        let reviewId = sessionState.reviewArchivedSessionId
        sessionState.reviewArchivedSessionId = nil
        guard let reviewId, reviewId == sessionState.currentSession?.id else { return true }
        do {
            guard try archive.delete(reviewId) else { return true }
        } catch {
            debugLog("[RRCollector] Discard: could not move session \(reviewId.uuidString.prefix(8)) to Trash: \(error)", level: .error)
            sessionState.reviewArchivedSessionId = reviewId
            sessionState.lastError = error
            return false
        }
        baselineRebuild.rebuildFromArchive()
        let cloudSync = cloudSyncManager
        Task { await cloudSync.uploadDeletion(reviewId) }
        return true
    }

    /// Supersede same-night overnight sessions.
    func supersedeSameNightSession(newSession: inout HRVSession) {
        let settings = settingsManager.settings
        morningProcessingService.supersedeSameNightSession(
            newSession: &newSession, sleepSchedule: settings.sleepSchedule,
            sessionMergeMode: settings.sessionMergeMode, mergeGapSeconds: settings.effectiveMergeGapSeconds
        )
    }
}

// The strap-night helpers the morning pipeline and the overnight and device
// endings share: which device recorded the night, backing up what was
// downloaded, failing a night that cannot be scored, and the training load.
extension MorningSessionPipeline {
    /// Whether the session's device is a Verity Sense (streaming-only, no internal recording).
    /// Checks device provenance first (persisted), falls back to live connection state.
    func isVeritySenseDevice(_ session: HRVSession) -> Bool {
        if let model = session.deviceProvenance?.deviceModel.lowercased() {
            return model.contains("verity") || model.contains("sense")
        }
        return strapLink.connectedDeviceType == .veritySense
    }

    /// Create a failed session and publish it as the current one.
    ///
    /// When the strap gate has just reported that the strap still holds this
    /// night (`reportDeviceFetchMiss`), that stays the error: it is what the
    /// user has to act on before the next recording clears the strap, and
    /// "not enough beats" would hide it. `lastError` is cleared when a night
    /// or a resumed segment starts, so the error found here is this night's.
    func failSession(from baseSession: HRVSession) async -> HRVSession {
        let failed = HRVSession(
            id: baseSession.id, startDate: baseSession.startDate, endDate: Date(),
            state: .failed, sessionType: baseSession.sessionType,
            rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        await MainActor.run {
            sessionState.currentSession = failed
            // Nothing is being analysed any more; the failed session is shown.
            sessionState.recordingPhase = .idle
            if !Self.reportsStrapStillHoldsNight(sessionState.lastError) {
                sessionState.lastError = RRCollector.CollectorError.insufficientData
            }
            morningCoordination.morningStatus = nil
        }
        // Overnight holds no audio session (App Store 2.5.4); nothing to
        // release on the failure path.
        return failed
    }

    private static func reportsStrapStillHoldsNight(_ error: Error?) -> Bool {
        guard case .strapStillHoldsNight? = error as? RRCollector.CollectorError else { return false }
        return true
    }

    /// The strap's beats are on this device before anything else can fail.
    /// The night's backup is replaced by the merged beats it will be scored
    /// on. When the strap's beats were not used, or that backup cannot be
    /// written (it would replace a larger one), they get their own backup in
    /// Lost Sessions (`rescueDownloadedBeats`). A night scored on them is
    /// then remembered (`nightRescue`): once it is archived it holds those
    /// beats, and their own backup goes, or Lost Sessions would offer a
    /// second copy of a saved night.
    ///
    /// True only once a backup holding the strap's beats is on disk: the
    /// caller then puts the recording on the saved record
    /// (`StrapRecordingCoordinator.noteDownloadsSaved`), and until it does the
    /// next arming keeps the strap's copy. False with nothing downloaded.
    @discardableResult
    func backUpDownloadedNight(_ devicePoints: [RRPoint]?, chosen: [RRPoint], usedDevice: Bool, baseSession: HRVSession) async -> Bool {
        guard let devicePoints, !devicePoints.isEmpty else { return false }
        if usedDevice, await backUpMergedNight(chosen, sessionId: baseSession.id) { return true }
        guard let rescueId = writeRescueBackup(devicePoints, baseSession: baseSession) else { return false }
        if usedDevice { nightRescue = NightRescue(sessionId: baseSession.id, backupId: rescueId, beats: devicePoints.count) }
        return true
    }

    /// The strap beats a night was scored on, backed up under an id of their
    /// own because the night's backup held more beats.
    struct NightRescue {
        let sessionId: UUID
        let backupId: UUID
        let beats: Int
    }

    /// Once `session` is archived with at least the beats its rescue holds,
    /// the rescue backup is a copy of what the archive holds and is
    /// discarded. A night archived with fewer keeps it in Lost Sessions.
    private func retireNightRescue(of session: HRVSession) {
        guard let rescue = nightRescue, rescue.sessionId == session.id else { return }
        nightRescue = nil
        guard (session.rrSeries?.points.count ?? 0) >= rescue.beats else { return }
        do {
            try rawBackup.discardBackup(rescue.backupId)
        } catch {
            debugLog("[RRCollector] The strap beats' own backup of a saved night could not be removed: \(error)", level: .warning)
        }
    }

    /// Replaces the night's backup with `points`; false when it was not written.
    private func backUpMergedNight(_ points: [RRPoint], sessionId: UUID) async -> Bool {
        let backup = rawBackup
        let did = strapLink.connectedDeviceId
        return await Task.detached(priority: .utility) {
            do {
                try backup.backup(points: points, sessionId: sessionId, deviceId: did)
                return true
            } catch {
                debugLog("[RRCollector] Failed to back up the merged night (\(points.count) beats): \(error)", level: .error)
                return false
            }
        }.value
    }

    /// Fetch training load for readiness context (if enabled in settings)
    func fetchTrainingLoadIfEnabled() async {
        guard settingsManager.settings.enableTrainingLoadIntegration else { return }
        // Use forMorningReading: true so the frozen ATL/CTL/TSB snapshot represents
        // the training state at waking — EWMA through yesterday only, before any
        // activity today. The dashboard uses forMorningReading: false (live, includes
        // today) so ATL visibly updates throughout the day as workouts sync.
        // History keeps the frozen morning value permanently.
        scoring.cachedTrainingLoad = await trainingQueries.calculateTrainingLoad(forMorningReading: true)
        if let load = scoring.cachedTrainingLoad {
            debugLog("[RRCollector] Training load: weeklyScore=\(String(format: "%.1f", load.weeklyLoadScore)), daysSinceHard=\(load.daysSinceHardWorkout ?? -1)")
        }
    }

    /// Downloaded strap beats go to their own backup, dated by the night's
    /// start, so Lost Sessions can recover them. A pause the archive would not
    /// take rescues the strap's beats it holds the same way. True when the
    /// backup is on disk. A failed one is shown to the user, and the strap's
    /// copy, never put on the saved record, stays recoverable from the Record
    /// screen and is not cleared by the next arming.
    @discardableResult
    func rescueDownloadedBeats(_ internalPoints: [RRPoint]?, baseSession: HRVSession) -> Bool {
        guard let internalPoints, !internalPoints.isEmpty else { return false }
        return writeRescueBackup(internalPoints, baseSession: baseSession) != nil
    }

    /// The id of the backup `rescueDownloadedBeats` wrote, or nil when it failed.
    private func writeRescueBackup(_ internalPoints: [RRPoint], baseSession: HRVSession) -> UUID? {
        let rescueId = UUID()
        do {
            try rawBackup.backup(
                points: internalPoints, sessionId: rescueId,
                deviceId: strapLink.connectedDeviceId, captureDate: baseSession.startDate
            )
            debugLog("[RRCollector] Backed up \(internalPoints.count) downloaded strap beats apart from the night's backup (recoverable via Lost Sessions)")
            return rescueId
        } catch {
            debugLog("[RRCollector] Failed to back up \(internalPoints.count) downloaded strap beats: \(error)", level: .error)
            sessionState.lastError = error
            return nil
        }
    }

    /// Flip every published flag to the post-stream "saving" state in one hop.
    /// The night stays live through `StreamingLifecycle.isEndingOvernight`,
    /// which the caller's claim holds until the night is saved or failed.
    /// Whether the night armed the strap (`overnightDeviceBackupActive`) is
    /// kept for the strap gate, which every ending reaches next and which
    /// clears it.
    func publishGatherSavingState(streamingPoints: [RRPoint], elapsedHours: Double) async {
        await MainActor.run {
            morningCoordination.morningStatus = .saving(beats: streamingPoints.count)
            streamingLifecycle.isOvernightStreaming = false
            deviceStatus.isStreaming = false
            sessionState.recordingPhase = .analyzing
            sessionState.isCollecting = false
            sessionState.collectedPoints = streamingPoints
            streamingLifecycle.streamingElapsedSeconds = 0
            strapBattery.recordRecordingHours(elapsedHours)
        }
    }
}
