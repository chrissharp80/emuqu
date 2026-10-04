import Foundation

// MARK: - Data Recovery (Backup, Lost Sessions, Device Recovery)

extension SessionRecoveryCoordinator {
    // MARK: - Recovery Service

    /// Lazy-initialized recovery service with all dependencies injected from RRCollector.
    var recoveryService: SessionRecoveryService {
        if let existing = collector._recoveryService { return existing }
        let service = SessionRecoveryService(
            archive: collector.archive,
            rawBackup: collector.rawBackup,
            artifactDetector: collector.artifactDetector,
            windowSelector: collector.windowSelector,
            cloudSyncManager: collector.cloudSyncManager,
            baselineTracker: collector.baselineTracker
        )
        collector._recoveryService = service
        return service
    }

    // MARK: - Retry Fetch

    /// Manual retry of the strap's stored recording after a failed morning:
    /// stop-and-fetch, analyse, score, and present for acceptance.
    func retryFetchRecording() async throws -> HRVSession? {
        guard collector.polarManager.connectionState == .connected else {
            throw RRCollector.CollectorError.notConnected
        }
        let baseSession = collector.currentSession ?? HRVSession()
        let rrPoints = try await fetchRecordingForRetry(baseSession: baseSession)
        let series = RRSeries(points: rrPoints, sessionId: baseSession.id, startDate: baseSession.startDate)
        let analyzingSession = publishAnalyzingSession(on: collector, baseSession: baseSession, series: series)
        let flags = collector.artifactDetector.detectArtifacts(in: series)
        let bounds = await retrySleepBounds(baseSession: baseSession, rrPoints: rrPoints)
        let windowResult = collector.windowSelector.findBestWindowWithCapacity(
            in: series, flags: flags, sleepStartMs: bounds.startMs, wakeTimeMs: bounds.endMs
        )
        let finalSession = await buildRetrySession(
            analyzingSession: analyzingSession, baseSession: baseSession, series: series, flags: flags, bounds: bounds,
            analysisResult: await analyzeRetryWindow(analyzingSession, flags: flags, windowResult: windowResult)
        )
        await publishRetryResult(finalSession, verifyResult: collector.verification.verify(series, flags: flags), windowResult: windowResult)
        return finalSession
    }

    /// Stop the device recording and pull it, backing up whatever arrives before
    /// the 120-beat usefulness floor is enforced.
    private func fetchRecordingForRetry(baseSession: HRVSession) async throws -> [RRPoint] {
        let rrPoints: [RRPoint]
        do {
            rrPoints = try await collector.polarManager.stopAndFetchRecording()
        } catch {
            let capturedError = error
            await MainActor.run { collector.lastError = capturedError }
            throw capturedError
        }
        if !rrPoints.isEmpty {
            collector.backupRawData(rrPoints, sessionId: baseSession.id)
        }
        guard rrPoints.count >= 120 else {
            await MainActor.run { collector.lastError = RRCollector.CollectorError.insufficientData }
            throw RRCollector.CollectorError.insufficientData
        }
        return rrPoints
    }

    /// HealthKit sleep bounds as session-relative milliseconds. A HealthKit
    /// failure is non-fatal — the window selector just runs unanchored.
    private func retrySleepBounds(baseSession: HRVSession, rrPoints: [RRPoint]) async -> (startMs: Int64?, endMs: Int64?) {
        do {
            let sleepData = try await collector.healthKit.fetchSleepData(
                for: baseSession.startDate, recordingEnd: Date(), rrPoints: rrPoints
            )
            // `MillisecondOffset` rather than a bare `Int64(interval * 1000)`:
            // both dates come off disk and the conversion traps on a corrupt
            // one. A boundary that cannot be represented stays nil, which is
            // already how a missing boundary is expressed here.
            return (
                sleepData.sleepStart.flatMap { MillisecondOffset.between($0, and: baseSession.startDate) },
                sleepData.sleepEnd.flatMap { MillisecondOffset.between($0, and: baseSession.startDate) }
            )
        } catch {
            debugLog("[RRCollector] Could not fetch HealthKit data for retry: \(error)", level: .warning)
            return (nil, nil)
        }
    }

    private func analyzeRetryWindow(
        _ analyzingSession: HRVSession,
        flags: [ArtifactFlags],
        windowResult: WindowSelector.WindowSelectionResult?
    ) async -> HRVAnalysisResult? {
        guard let windowResult else { return await collector.analyze(analyzingSession) }
        guard let recoveryWindow = windowResult.recoveryWindow else {
            return await collector.analyze(analyzingSession, peakCapacity: windowResult.peakCapacity)
        }
        return await collector.analyze(
            analyzingSession, window: recoveryWindow, flags: flags, peakCapacity: windowResult.peakCapacity
        )
    }

    /// The sleep/vitals snapshots used to score are persisted here, and the
    /// strap that recorded the night is kept from the base session.
    private func buildRetrySession(
        analyzingSession: HRVSession,
        baseSession: HRVSession,
        series: RRSeries,
        flags: [ArtifactFlags],
        bounds: (startMs: Int64?, endMs: Int64?),
        analysisResult: HRVAnalysisResult?
    ) async -> HRVSession {
        let clamped = SleepBoundaryResolver.clamp(
            sleepStartMs: bounds.startMs,
            sleepEndMs: bounds.endMs,
            recordingDurationMs: series.points.last?.endMs ?? 0
        )
        var finalSession = HRVSession(
            id: analyzingSession.id, startDate: analyzingSession.startDate, endDate: analyzingSession.endDate,
            state: analysisResult != nil ? .complete : .failed, sessionType: baseSession.sessionType,
            rrSeries: series, analysisResult: analysisResult, artifactFlags: flags,
            sleepStartMs: clamped.sleepStartMs, sleepEndMs: clamped.sleepEndMs
        )
        finalSession.deviceProvenance = baseSession.deviceProvenance
        if let result = await collector.computeRecoveryScore(for: finalSession, from: analysisResult) {
            Self.applyScore(result, to: &finalSession)
        }
        return finalSession
    }

    /// Fold a score into the session. Sleep and vitals snapshots are frozen
    /// onto overnight sessions only: on a daytime capture they make it the
    /// newest snapshot-bearing session and take over the dashboard sleep chip
    /// (the device-recording path applies the same gate).
    static func applyScore(_ result: RecoveryScoreOutcome, to session: inout HRVSession) {
        session.recoveryScore = result.score
        session.scoreBreakdown = result.breakdown
        guard session.sessionType == .overnight else { return }
        if let snap = result.sleepSnapshot { session.sleepSnapshot = snap }
        if let vitals = result.vitalsSnapshot { session.vitalsSnapshot = vitals }
    }

    private func publishRetryResult(
        _ finalSession: HRVSession,
        verifyResult: Verification.Result,
        windowResult: WindowSelector.WindowSelectionResult?
    ) async {
        let deviation = collector.baselineTracker.deviation(for: finalSession)
        await MainActor.run {
            collector.currentSession = finalSession
            collector.verificationResult = verifyResult
            collector.recoveryWindow = windowResult?.recoveryWindow
            collector.needsAcceptance = finalSession.state == .complete
            if finalSession.state == .complete {
                collector.recordingPhase = .awaitingAcceptance
            }
            collector.baselineDeviation = deviation
            collector.sessionStartTime = nil
        }
    }

    // MARK: - Recover from Device (Helpers)

    /// Intermediate result from resolving session timing via persisted state and HealthKit.
    struct ResolvedRecoveryTiming {
        let sessionId: UUID
        let sessionType: SessionType
        let startDate: Date
        let endDate: Date
        let healthKitSleepStart: Date?
    }

    /// Intermediate result from merging device data with an existing streaming session.
    struct MergedRecoveryData {
        let effectiveSessionId: UUID
        let effectiveStartDate: Date
        let effectiveEndDate: Date
        let analysisSeries: RRSeries
        let streamingBeats: Int
        let deviceBeats: Int
        let dataSource: String
        let existingSession: HRVSession?
    }

    /// Resolve session timing from persisted recording state and HealthKit sleep data.
    func resolveRecoveryTiming(
        rrPoints: [RRPoint],
        recordingEndDate: Date
    ) async -> ResolvedRecoveryTiming {
        let persistedState = collector.getPersistedRecordingState()
        if let ps = persistedState {
            debugLog("[Recovery] persistedState=exists(id=\(ps.sessionId.uuidString.prefix(8)), start=\(ps.startTime))")
        } else {
            debugLog("[Recovery] persistedState=nil")
        }
        if let persisted = persistedState {
            return await timingFromPersistedState(
                persisted, rrPoints: rrPoints, recordingEndDate: recordingEndDate
            )
        }
        return await timingEstimatedFromHistory(rrPoints: rrPoints)
    }

    /// Widen the HealthKit sleep query past the
    /// last RR point so a mid-night crash doesn't clip the
    /// night to "1.4h slept." `recordingEndDate` for an
    /// interrupted session = the crash timestamp; the actual
    /// sleep extends to the user's typical wake time. The actual
    /// HealthKit sleep end is preferred when known — that's the
    /// user's real wake time, not the crash time.
    private func timingFromPersistedState(
        _ persisted: (sessionId: UUID, startTime: Date, sessionType: SessionType),
        rrPoints: [RRPoint],
        recordingEndDate: Date
    ) async -> ResolvedRecoveryTiming {
        let scheduleEnd = collector.settingsManager.settings.sleepSchedule
            .overnightWindowEnd(relativeTo: persisted.startTime)
        let widenedQueryEnd = max(recordingEndDate, scheduleEnd)
        var endDate = recordingEndDate
        var healthKitSleepStart: Date?
        if let sleepData = try? await collector.healthKit.fetchSleepData(
            for: persisted.startTime, recordingEnd: widenedQueryEnd, rrPoints: rrPoints
        ) {
            healthKitSleepStart = sleepData.sleepStart
            endDate = sleepData.sleepEnd ?? widenedQueryEnd
        }
        return ResolvedRecoveryTiming(
            sessionId: persisted.sessionId, sessionType: persisted.sessionType,
            startDate: persisted.startTime, endDate: endDate,
            healthKitSleepStart: healthKitSleepStart
        )
    }

    /// No persisted state — estimate timing from HealthKit and recording duration.
    /// A HealthKit failure leaves the duration-based estimate in place.
    private func timingEstimatedFromHistory(rrPoints: [RRPoint]) async -> ResolvedRecoveryTiming {
        let durationSeconds = TimeInterval(rrPoints.last?.endMs ?? 0) / 1000.0
        let search = recoverySearchWindow(durationSeconds: durationSeconds)
        var dates = (start: search.end.addingTimeInterval(-durationSeconds), end: search.end)
        var healthKitSleepStart: Date?
        if let sleepData = try? await collector.healthKit.fetchSleepData(
            for: search.start, recordingEnd: search.end, rrPoints: rrPoints
        ) {
            healthKitSleepStart = sleepData.sleepStart
            dates = Self.anchorRecoveryDates(
                sleepData: sleepData, rrPoints: rrPoints,
                searchEnd: search.end, durationSeconds: durationSeconds
            )
        }
        return ResolvedRecoveryTiming(
            sessionId: UUID(), sessionType: .overnight,
            startDate: dates.start, endDate: dates.end,
            healthKitSleepStart: healthKitSleepStart
        )
    }

    /// Anchor the HealthKit query to the most recent overnight session in the
    /// archive when there is one, else work backwards from now by the recording's
    /// own duration.
    private func recoverySearchWindow(durationSeconds: TimeInterval) -> (start: Date, end: Date) {
        let recentEntry = collector.archive.entries
            .filter { $0.sessionType == .overnight && $0.date.timeIntervalSinceNow > -24 * 60 * 60 }
            .max(by: { $0.date < $1.date })
        guard let recent = recentEntry else {
            let searchEnd = Date()
            let searchStart = searchEnd.addingTimeInterval(-durationSeconds)
            debugLog("[Recovery] No recent session — using duration-based estimate (\(searchStart) to \(searchEnd))")
            return (searchStart, searchEnd)
        }
        let searchEnd = recent.endDate ?? recent.date.addingTimeInterval(durationSeconds)
        debugLog("[Recovery] Anchoring HealthKit query to recent session \(recent.sessionId.uuidString.prefix(8)) (date: \(recent.date) to \(searchEnd))")
        return (recent.date, searchEnd)
    }

    /// Sleep onset is measured in the RR series itself, so a known HealthKit
    /// sleep START lets us back out the recording's true start. A known sleep END
    /// is the next-best anchor; failing both, the search window's end stands in.
    private static func anchorRecoveryDates(
        sleepData: SleepData,
        rrPoints: [RRPoint],
        searchEnd: Date,
        durationSeconds: TimeInterval
    ) -> (start: Date, end: Date) {
        if let hkSleepStart = sleepData.sleepStart {
            let sleepOnsetMs = SleepBoundaryResolver.detectSleepOnset(in: rrPoints) ?? 0
            let startDate = hkSleepStart.addingTimeInterval(-TimeInterval(sleepOnsetMs) / 1000.0)
            return (startDate, startDate.addingTimeInterval(durationSeconds))
        }
        let endDate = sleepData.sleepEnd ?? searchEnd
        return (endDate.addingTimeInterval(-durationSeconds), endDate)
    }

    /// Merge device-recovered RR data with any existing same-night streaming session.
    func mergeWithExistingSession(
        rrPoints: [RRPoint],
        timing: ResolvedRecoveryTiming
    ) -> MergedRecoveryData {
        let existingStreamingSession = findSameNightStreamingSession(startDate: timing.startDate)
        if let existing = existingStreamingSession {
            debugLog("[Recovery] findSameNightStreamingSession result: \(existing.id.uuidString.prefix(8)) source=\(existing.dataSourceSummary?.selectedSource ?? "nil")")
        } else {
            debugLog("[Recovery] findSameNightStreamingSession result: nil")
        }
        guard let existing = existingStreamingSession else {
            debugLog("[RRCollector] No existing same-night session found — creating new session")
            return MergedRecoveryData(
                effectiveSessionId: timing.sessionId, effectiveStartDate: timing.startDate,
                effectiveEndDate: timing.endDate,
                analysisSeries: RRSeries(points: rrPoints, sessionId: timing.sessionId, startDate: timing.startDate),
                streamingBeats: 0, deviceBeats: rrPoints.count, dataSource: "internal", existingSession: nil
            )
        }
        return mergeIntoExisting(existing, rrPoints: rrPoints, timing: timing)
    }

    // MARK: - Recover from Device

    /// Pull the strap's stored recording and reconcile it with the archive:
    /// fetch → resolve timing + merge → analyse → build, archive and publish.
    func recoverFromDevice() async throws -> HRVSession? {
        debugLog("[Recovery] ========== START recoverFromDevice ==========")
        guard collector.polarManager.connectionState == .connected else {
            debugLog("[Recovery] ABORT: not connected")
            throw RRCollector.CollectorError.notConnected
        }
        let (rrPoints, recovered) = try await fetchAndValidateDeviceData()
        let merged = await resolveTimingAndMerge(rrPoints: rrPoints, recordingEndDate: recovered.recordingDate)
        let analysis = await analyzeRecoveredData(merged: merged.data, timing: merged.timing)
        let finalSession = await scoreAndBuildRecoveredSession(merged: merged.data, timing: merged.timing, analysis: analysis)
        await archiveRecoveredSession(finalSession, effectiveSessionId: merged.data.effectiveSessionId)
        await updateUIAfterRecovery(
            session: finalSession, verifyResult: analysis.verifyResult, windowResult: analysis.windowResult
        )
        await collector.polarManager.checkForStoredExercises()
        debugLog("[Recovery] ========== END recoverFromDevice ==========")
        return finalSession
    }

    /// Phase 2 — resolve session timing, back the raw beats up, and merge with
    /// any existing same-night session.
    private func resolveTimingAndMerge(
        rrPoints: [RRPoint],
        recordingEndDate: Date
    ) async -> (timing: ResolvedRecoveryTiming, data: MergedRecoveryData) {
        let timing = await resolveRecoveryTiming(rrPoints: rrPoints, recordingEndDate: recordingEndDate)
        collector.backupRawData(rrPoints, sessionId: timing.sessionId, startDate: timing.startDate)
        debugLog("[Recovery] Estimated startDate=\(timing.startDate), endDate=\(timing.endDate)")
        let overnightCount = collector.archive.entries.filter { $0.sessionType == .overnight }.count
        debugLog("[Recovery] Archive has \(collector.archive.entries.count) entries (\(overnightCount) overnight)")
        return (timing, mergeWithExistingSession(rrPoints: rrPoints, timing: timing))
    }

    /// Phase 4 — build the final session and fold the recovery score into it.
    private func scoreAndBuildRecoveredSession(
        merged: MergedRecoveryData,
        timing: ResolvedRecoveryTiming,
        analysis: RecoveryAnalysisResult
    ) async -> HRVSession {
        var finalSession = buildRecoveredSession(
            merged: merged, timing: timing,
            analysisResult: analysis.analysisResult, flags: analysis.flags,
            sleepStartMs: analysis.sleepStartMs, wakeTimeMs: analysis.wakeTimeMs
        )
        guard let result = await collector.computeRecoveryScore(for: finalSession, from: analysis.analysisResult) else {
            return finalSession
        }
        Self.applyScore(result, to: &finalSession)
        return finalSession
    }

    // MARK: - recoverFromDevice Helpers

    /// Intermediate result from analyzing recovered device data.
    private struct RecoveryAnalysisResult {
        let analysisResult: HRVAnalysisResult?
        let flags: [ArtifactFlags]
        let verifyResult: Verification.Result
        let windowResult: WindowSelector.WindowSelectionResult?
        let sleepStartMs: Int64?
        let wakeTimeMs: Int64
    }

    /// Fetch exercise data from the connected device and validate minimum beat count.
    private func fetchAndValidateDeviceData() async throws -> ([RRPoint], StrapRecordingCoordinator.RecoveredExercise) {
        let recovered: StrapRecordingCoordinator.RecoveredExercise
        do {
            recovered = try await collector.polarManager.recoverExerciseData()
        } catch {
            debugLog("[Recovery] ABORT: recoverExerciseData threw: \(error)")
            let capturedError = error
            await MainActor.run { collector.lastError = capturedError }
            throw capturedError
        }

        let rrPoints = recovered.rrPoints
        debugLog("[Recovery] Got \(rrPoints.count) beats from strap, recordingDate=\(recovered.recordingDate)")
        guard rrPoints.count >= 120 else {
            debugLog("[Recovery] ABORT: only \(rrPoints.count) beats, need 120")
            await MainActor.run { collector.lastError = RRCollector.CollectorError.insufficientData }
            throw RRCollector.CollectorError.insufficientData
        }

        return (rrPoints, recovered)
    }

    /// Run artifact detection, window selection, and HRV analysis on merged recovery data.
    private func analyzeRecoveredData(
        merged: MergedRecoveryData,
        timing: ResolvedRecoveryTiming
    ) async -> RecoveryAnalysisResult {
        let analyzingSession = HRVSession(
            id: merged.effectiveSessionId, startDate: merged.effectiveStartDate, endDate: merged.effectiveEndDate,
            state: .analyzing, sessionType: timing.sessionType,
            rrSeries: merged.analysisSeries, analysisResult: nil, artifactFlags: nil
        )
        await MainActor.run { collector.currentSession = analyzingSession }
        let flags = collector.artifactDetector.detectArtifacts(in: merged.analysisSeries)
        let verifyResult = collector.verification.verify(merged.analysisSeries, flags: flags)
        let sleepStartMs = timing.healthKitSleepStart.map { Int64($0.timeIntervalSince(merged.effectiveStartDate) * 1000) }
        let wakeTimeMs = MillisecondOffset.between(merged.effectiveEndDate, and: merged.effectiveStartDate, fallback: 0)
        let windowResult = collector.windowSelector.findBestWindowWithCapacity(
            in: merged.analysisSeries, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs
        )
        return RecoveryAnalysisResult(
            analysisResult: await analyzeRetryWindow(analyzingSession, flags: flags, windowResult: windowResult),
            flags: flags, verifyResult: verifyResult, windowResult: windowResult,
            sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs
        )
    }

    /// Build the final recovered HRV session with source summary and existing session metadata.
    private func buildRecoveredSession(
        merged: MergedRecoveryData,
        timing: ResolvedRecoveryTiming,
        analysisResult: HRVAnalysisResult?,
        flags: [ArtifactFlags],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64
    ) -> HRVSession {
        let clamped = SleepBoundaryResolver.clamp(
            sleepStartMs: sleepStartMs, sleepEndMs: wakeTimeMs,
            recordingDurationMs: merged.analysisSeries.points.last?.endMs ?? 0
        )
        debugLog("[Recovery] Built session: id=\(merged.effectiveSessionId.uuidString.prefix(8)), dataSource=\(merged.dataSource), beats=\(merged.analysisSeries.points.count), analysisResult=\(analysisResult != nil ? "yes" : "NO")")
        var finalSession = HRVSession(
            id: merged.effectiveSessionId, startDate: merged.effectiveStartDate, endDate: merged.effectiveEndDate,
            state: analysisResult != nil ? .complete : .failed, sessionType: timing.sessionType,
            rrSeries: merged.analysisSeries, analysisResult: analysisResult, artifactFlags: flags,
            sleepStartMs: clamped.sleepStartMs, sleepEndMs: clamped.sleepEndMs,
            dataSourceSummary: recoveredSourceSummary(merged: merged)
        )
        carryForwardExistingMetadata(into: &finalSession, from: merged.existingSession)
        debugLog("[Recovery] finalSession: id=\(finalSession.id.uuidString.prefix(8)), state=\(finalSession.state), source=\(finalSession.dataSourceSummary?.selectedSource ?? "nil"), linkedIds=\(finalSession.linkedSessionIds ?? [])")
        return finalSession
    }

    private func recoveredSourceSummary(merged: MergedRecoveryData) -> HRVSession.DataSourceSummary {
        let beatDiffPercent: Double? = {
            guard merged.streamingBeats > 0 else { return nil }
            let diff = abs(merged.deviceBeats - merged.streamingBeats)
            return (Double(diff) / Double(max(merged.deviceBeats, merged.streamingBeats))) * 100.0
        }()
        return HRVSession.DataSourceSummary(
            selectedSource: merged.dataSource,
            streamingBeats: merged.streamingBeats,
            deviceBeats: merged.deviceBeats,
            totalBeats: merged.analysisSeries.points.count,
            beatDifferencePercent: beatDiffPercent,
            reconnectCount: merged.existingSession?.dataSourceSummary?.reconnectCount ?? 0,
            deviceModel: merged.existingSession?.deviceProvenance?.deviceModel ?? collector.polarManager.connectedDeviceType?.displayName
        )
    }

    /// The recovered session replaces the archived one under the same id, so the
    /// user's own annotations and the night's frozen sleep, vitals and training
    /// snapshots must survive the swap: the score is recomputed from them, and
    /// the training load stays the one frozen at waking.
    private func carryForwardExistingMetadata(into finalSession: inout HRVSession, from existing: HRVSession?) {
        guard let existing else { return }
        finalSession.tags = existing.tags
        finalSession.notes = existing.notes
        finalSession.deviceProvenance = existing.deviceProvenance
        finalSession.linkedSessionIds = existing.linkedSessionIds
        finalSession.sleepSnapshot = existing.sleepSnapshot
        finalSession.sleepUserAdjusted = existing.sleepUserAdjusted
        finalSession.vitalsSnapshot = existing.vitalsSnapshot
        guard let frozenTraining = existing.trainingSnapshot else { return }
        finalSession.trainingSnapshot = frozenTraining
        finalSession.analysisResult?.trainingContext = frozenTraining
    }

    /// Archive the recovered session and trigger cloud sync if complete.
    private func archiveRecoveredSession(_ session: HRVSession, effectiveSessionId: UUID) async {
        guard session.state == .complete else {
            debugLog("[Recovery] \u{26a0}\u{fe0f} NOT archiving — state is \(session.state)")
            debugLog("[Recovery] Archive after save: \(collector.archive.entries.count) entries")
            return
        }
        do {
            let archiveResult = try collector.archive.archive(session)
            retireRawBackupIfSafe(session: session, effectiveSessionId: effectiveSessionId)
            debugLog("[Recovery] \u{2705} archive returned entry: \(archiveResult.sessionId.uuidString.prefix(8))")
            // Uploaded only once saved here: iCloud must not hold a session
            // this device does not. The sync manager is read before the hop so
            // the Task never reaches back through the collector.
            let cloudSync = collector.cloudSyncManager
            Task { await cloudSync.uploadSession(session) }
        } catch {
            debugLog("[Recovery] \u{274c} archive THREW: \(error)", level: .error)
            await MainActor.run { collector.lastError = error }
        }
        debugLog("[Recovery] Archive after save: \(collector.archive.entries.count) entries")
    }

    /// Guard the raw-backup safety net: only retire the backup once
    /// we've archived a session that holds the data. A truncated
    /// device fetch (strap out of range, partial offline pull) can
    /// still analyse to `.complete` on a subset — if that archived
    /// subset is far smaller than the raw backup, keep the backup in
    /// the recovery list rather than marking it archived and losing
    /// the fuller capture forever. Normal artifact filtering trims
    /// only a modest fraction, so the 50% floor won't misfire on
    /// healthy sessions.
    private func retireRawBackupIfSafe(session: HRVSession, effectiveSessionId: UUID) {
        let archivedBeats = session.rrSeries?.points.count ?? 0
        if let backupBeats = collector.rawBackup.backedUpBeatCount(effectiveSessionId),
           backupBeats > 0, archivedBeats > 0, archivedBeats < backupBeats / 2 {
            debugLog("[Recovery] \u{26a0}\u{fe0f} Archived session holds \(archivedBeats) beats but raw backup holds \(backupBeats) — NOT marking backup archived so the fuller capture stays recoverable", level: .warning)
            return
        }
        collector.rawBackup.markAsArchived(effectiveSessionId)
    }

    /// Update UI state after device recovery completes.
    private func updateUIAfterRecovery(
        session: HRVSession,
        verifyResult: Verification.Result,
        windowResult: WindowSelector.WindowSelectionResult?
    ) async {
        let deviation = collector.baselineTracker.deviation(for: session)

        await MainActor.run {
            collector.currentSession = session
            collector.verificationResult = verifyResult
            collector.recoveryWindow = windowResult?.recoveryWindow
            collector.needsAcceptance = session.state == .complete
            if session.state == .complete {
                collector.recordingPhase = .awaitingAcceptance
            }
            collector.baselineDeviation = deviation
            collector.sessionStartTime = nil
            collector.archiveSignal.notifyChanged()
            debugLog("[Recovery] Set currentSession=\(session.id.uuidString.prefix(8)), needsAcceptance=\(session.state == .complete), archiveVersion incremented")
        }
    }

    /// Find an existing archived same-night session that has streaming data.
    /// Used by recoverFromDevice to merge device data into the existing session
    /// rather than creating a duplicate.
    private func findSameNightStreamingSession(startDate: Date) -> HRVSession? {
        let sleepSchedule = collector.settingsManager.settings.sleepSchedule
        let nightStart = sleepSchedule.overnightWindowStart(relativeTo: startDate)
        debugLog("[RRCollector] findSameNightStreamingSession: looking for night anchor \(nightStart) (from startDate \(startDate))")
        for entry in collector.archive.entries where entry.sessionType == .overnight {
            let entryNight = sleepSchedule.overnightWindowStart(relativeTo: entry.date)
            guard entryNight == nightStart else { continue }
            debugLog("[RRCollector] findSameNightStreamingSession: matched entry \(entry.sessionId.uuidString.prefix(8)) (date: \(entry.date), anchor: \(entryNight))")
            guard let session = collector.archive.retrieveOrLog(entry.sessionId) else {
                debugLog("[RRCollector] findSameNightStreamingSession: failed to retrieve session \(entry.sessionId.uuidString.prefix(8))")
                continue
            }
            let hasRR = session.rrSeries != nil && !(session.rrSeries?.points.isEmpty ?? true)
            debugLog("[RRCollector] findSameNightStreamingSession: session state=\(session.state), hasRR=\(hasRR), beats=\(session.rrSeries?.points.count ?? 0), source=\(session.dataSourceSummary?.selectedSource ?? "nil")")
            return session
        }
        return nil
    }
}

// MARK: - File-scope helpers
//
// Moved out of RRCollector. Each names no member of the
// type and calls nothing that stayed behind, so none needed to be inside
// it. `private` at file scope is fileprivate, so every call site in this
// file resolves exactly as before.

@MainActor
/// The recovered device file always wins as the base; the selector only
/// decides whether the archived streaming beats can fill its gaps.
private func mergeIntoExisting(
    _ existing: HRVSession,
    rrPoints: [RRPoint],
    timing: SessionRecoveryCoordinator.ResolvedRecoveryTiming
) -> SessionRecoveryCoordinator.MergedRecoveryData {
    let existingPoints = existing.rrSeries?.points ?? []
    let effectiveId = existing.id
    let effectiveStart = existing.startDate
    let chosen = recoveryMergeSelection(
        existingPoints: existingPoints, rrPoints: rrPoints,
        sessionId: effectiveId, sessionStart: effectiveStart, existing: existing
    )
    debugLog("[RRCollector] Replacing existing session \(existing.id.uuidString.prefix(8)) (source was: \(existing.dataSourceSummary?.selectedSource ?? "unknown"))")
    return SessionRecoveryCoordinator.MergedRecoveryData(
        effectiveSessionId: effectiveId, effectiveStartDate: effectiveStart,
        effectiveEndDate: existing.endDate ?? timing.endDate,
        analysisSeries: chosen.series, streamingBeats: existingPoints.count, deviceBeats: rrPoints.count,
        dataSource: chosen.source, existingSession: existing
    )
}

@MainActor
private func recoveryMergeSelection(
    existingPoints: [RRPoint],
    rrPoints: [RRPoint],
    sessionId: UUID,
    sessionStart: Date,
    existing: HRVSession
) -> (series: RRSeries, source: String) {
    let deviceOnly = RRSeries(points: rrPoints, sessionId: sessionId, startDate: sessionStart)
    guard !existingPoints.isEmpty else {
        debugLog("[RRCollector] Re-import: existing session \(existing.id.uuidString.prefix(8)) had no RR data, using device data (\(rrPoints.count) beats)")
        return (deviceOnly, "internal")
    }
    guard let selection = DataSourceSelector.selectBestSource(
        streamingPoints: existingPoints, internalPoints: rrPoints,
        sessionId: sessionId, sessionStart: sessionStart
    ) else {
        debugLog("[RRCollector] Re-import: source selection returned nil, using device data (\(rrPoints.count) beats)")
        return (deviceOnly, "internal")
    }
    debugLog("[RRCollector] Re-import: selected \(selection.normalizedSource) (\(selection.points.count) beats from \(existingPoints.count) streamed + \(rrPoints.count) device)")
    return (RRSeries(points: selection.points, sessionId: sessionId, startDate: sessionStart), selection.normalizedSource)
}
