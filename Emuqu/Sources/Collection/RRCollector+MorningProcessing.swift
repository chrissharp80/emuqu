import Foundation

// MARK: - Morning Processing Pipeline

extension MorningSessionPipeline {
    /// Process overnight data (used for both initial streaming and background refinement).
    /// When `isBackgroundRefinement` is true, all global UI state mutations are skipped —
    /// the caller is responsible for deciding what to do with the returned session.
    ///
    /// This is now a thin wrapper around `MorningProcessingService`. It delegates
    /// the heavy analysis work to the service, then applies the results to the
    /// observable sub-objects, archives the session, and handles CloudKit sync.
    ///
    /// `collector.createTrainingContextEnsuringFresh` falls back to a live
    /// HealthKit fetch when `collector.fetchTrainingLoadIfEnabled` didn't populate the
    /// cache. This closes the Tier 2 → 3 re-freeze race: if the cache is
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
        isBackgroundRefinement: Bool = false,
        prefetchedSleepData: SleepData? = nil
    ) async -> HRVSession {
        debugLog("[RRCollector] Processing \(dataSource) data for analysis...")
        // Fetch training load before delegating (updates collector.cachedTrainingLoad on self)
        await collector.fetchTrainingLoadIfEnabled()
        showAnalyzingSession(baseSession: baseSession, points: points, skip: isBackgroundRefinement)
        let freshContext = await collector.createTrainingContextEnsuringFresh()
        let result = await collector.morningProcessingService.processOvernightData(
            MorningProcessingService.OvernightRequest(
                points: points, baseSession: baseSession, dataSource: dataSource, reconnectCount: reconnectCount,
                streamingBeats: streamingBeats, deviceBeats: deviceBeats, deviceId: collector.polarManager.connectedDeviceId,
                isBackgroundRefinement: isBackgroundRefinement, settings: settingsSnapshot(),
                trainingContext: freshContext, cachedTrainingLoad: collector.cachedTrainingLoad,
                prefetchedSleepData: prefetchedSleepData,
                statusCallback: { [weak collector] status in collector?.morningStatus = status }
            )
        )
        var finalSession = result.session
        freezeTrainingSnapshot(on: &finalSession, freshContext: freshContext)
        publishForeground(result, finalSession: finalSession, skip: isBackgroundRefinement)
        debugLog("[RRCollector] Overnight streaming analysis complete: \(points.count) RR points")
        return finalSession
    }

    /// Apply the result to observable state and pre-collector.archive for crash safety.
    /// Both are skipped for background refinement — the caller owns that
    /// decision.
    private func publishForeground(_ result: MorningProcessingService.ProcessingResult, finalSession: HRVSession, skip: Bool) {
        guard !skip else { return }
        applyProcessingResult(result, finalSession: finalSession)
        preArchiveForCrashSafety(finalSession)
    }

    /// Settings snapshot so the service never reads `SettingsManager.shared`.
    private func settingsSnapshot() -> MorningProcessingService.SettingsSnapshot {
        MorningProcessingService.SettingsSnapshot(
            sleepSchedule: collector.settingsManager.settings.sleepSchedule,
            enableTrainingLoadIntegration: collector.settingsManager.settings.enableTrainingLoadIntegration,
            typicalSleepHours: collector.settingsManager.settings.typicalSleepHours,
            scoringConfig: collector.currentScoringConfig,
            ansConfig: collector.currentANSConfig,
            sessionMergeMode: collector.settingsManager.settings.sessionMergeMode
        )
    }

    /// A temporary analyzing session so the UI has something to show while the
    /// service works. Skipped for background refinement.
    private func showAnalyzingSession(baseSession: HRVSession, points: [RRPoint], skip: Bool) {
        guard !skip else { return }
        collector.currentSession = HRVSession(
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
        if finalSession.trainingSnapshot == nil, let existing = collector.archive.retrieveOrLog(finalSession.id) {
            finalSession.trainingSnapshot = existing.trainingSnapshot
        }
        if finalSession.trainingSnapshot == nil {
            finalSession.trainingSnapshot = freshContext ?? collector.createTrainingContext()
        }
        if let frozen = finalSession.trainingSnapshot {
            finalSession.analysisResult?.trainingContext = frozen
        }
    }

    private func applyProcessingResult(_ result: MorningProcessingService.ProcessingResult, finalSession: HRVSession) {
        collector.currentSession = finalSession
        collector.verificationResult = result.verificationResult
        collector.recoveryWindow = result.recoveryWindow
        collector.needsAcceptance = finalSession.state == .complete
        if finalSession.state == .complete {
            collector.recordingPhase = .awaitingAcceptance
        }
        collector.baselineDeviation = result.baselineDeviation
        collector.sessionStartTime = nil
    }

    private func preArchiveForCrashSafety(_ finalSession: HRVSession) {
        guard finalSession.state == .complete else { return }
        do {
            debugLog("[RRCollector] Pre-archiving overnight session ID: \(finalSession.id.uuidString)")
            try collector.archive.archive(finalSession)
            collector.rawBackup.markAsArchived(finalSession.id)
            collector.archiveSignal.notifyChanged()
        } catch {
            debugLog("[RRCollector] Warning: Failed to pre-archive overnight streaming session: \(error)")
        }
    }

    /// Supersede same-night overnight sessions.
    ///
    /// Thin wrapper that delegates to `MorningProcessingService`.
    func supersedeSameNightSession(newSession: inout HRVSession) {
        let sleepSchedule = collector.settingsManager.settings.sleepSchedule
        collector.morningProcessingService.supersedeSameNightSession(newSession: &newSession, sleepSchedule: sleepSchedule)
    }
}
