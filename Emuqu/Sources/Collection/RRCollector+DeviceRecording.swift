import Foundation

// MARK: - Device Internal Recording (H10 / Verity Sense)
//
// Kept off `RRCollector` to keep that type's size in check. Same
// coordinator split as the overnight-streaming and recovery
// extractions — the collector reads are `collector.` and countable.

extension DeviceRecordingSession {
    /// Context about sleep boundaries from HealthKit
    struct SleepBoundaryContext {
        var sleepStartMs: Int64?
        var wakeTimeMs: Int64?
        var sleepSegments: [HRVSession.SleepSegmentMs]?
    }

    // MARK: - Recording API

    /// Start a new collection session (device internal recording)
    /// H10: exercise recording. Verity Sense: offline PPI recording.
    /// - Parameter sessionType: The type of session (overnight, nap, or quick)
    func startSession(sessionType: SessionType = .overnight) async throws {
        guard collector.polarManager.connectionState == .connected else {
            throw RRCollector.CollectorError.notConnected
        }
        guard !collector.polarManager.isRecordingOnDevice else {
            throw RRCollector.CollectorError.alreadyRecording
        }
        let session = HRVSession(sessionType: sessionType, deviceProvenance: deviceRecordingProvenance())
        let startTime = Date()
        // Check if session already exists (collector.reconciliation block)
        guard !collector.reconciliation.sessionExists(session.id) else {
            throw RRCollector.CollectorError.sessionExists
        }
        // Start device internal recording (survives disconnect) — dispatches for H10 or Verity Sense
        try await collector.polarManager.startRecording()
        // Persist recording state IMMEDIATELY after successful start.
        // This survives app crashes, phone reboots, etc.
        collector.persistRecordingState(sessionId: session.id, startTime: startTime, sessionType: sessionType)
        await publishDeviceRecordingStarted(session: session, startTime: startTime)
    }

    /// Captured before starting — tracks source device and collection method.
    private func deviceRecordingProvenance() -> DeviceProvenance {
        DeviceProvenance.current(
            deviceId: collector.polarManager.connectedDeviceId ?? "unknown",
            deviceModel: collector.polarManager.connectedDeviceType?.displayName ?? "Polar device",
            firmwareVersion: nil,
            recordingMode: .deviceInternal
        )
    }

    /// Mark the session active in-app. Without `collector.isCollecting`, RecordView's
    /// isSessionActive check stays false (isOvernightStreaming and
    /// collector.isCollecting both default false on this path), so the "Choose
    /// Session" picker keeps drawing on top of an already-running
    /// device recording — making it look like the start button did nothing.
    private func publishDeviceRecordingStarted(session: HRVSession, startTime: Date) async {
        await MainActor.run {
            collector.currentSession = session
            collector.collectedPoints = []
            collector.sessionStartTime = startTime
            collector.isCollecting = true
            collector.recordingPhase = .deviceRecording
        }
    }

    /// Stop recording, fetch RR data from device, and collector.analyze
    func stopSession() async throws -> HRVSession? {
        guard collector.polarManager.connectionState == .connected else {
            throw RRCollector.CollectorError.notConnected
        }
        let baseSession = resolveBaseSession()
        // Stop streaming and get collected RR data
        let rrPoints: [RRPoint]
        do {
            rrPoints = try await collector.polarManager.stopAndFetchRecording()
        } catch {
            return await makeFailedSession(from: baseSession, error: error)
        }
        // IMMEDIATELY backup raw RR data before any processing
        backupRawData(rrPoints, sessionId: baseSession.id)
        guard rrPoints.count >= 120 else {
            return await makeFailedSession(from: baseSession, error: RRCollector.CollectorError.insufficientData)
        }
        return await analyzeAndAssembleDeviceSession(baseSession: baseSession, series: RRSeries(
            points: rrPoints, sessionId: baseSession.id,
            startDate: await calculateSessionStartDate(baseSession: baseSession, rrPoints: rrPoints)
        ))
    }

    /// Everything downstream of having a usable RR series: artifact detection,
    /// sleep + training context, window selection, analysis, and assembly.
    private func analyzeAndAssembleDeviceSession(baseSession: HRVSession, series: RRSeries) async -> HRVSession {
        let analyzingSession = await beginAnalyzingSession(baseSession: baseSession, series: series)
        let flags = collector.artifactDetector.detectArtifacts(in: series)
        let verifyResult = collector.verification.verify(series, flags: flags)
        let sleepContext = await fetchSleepContext(sessionStart: series.startDate)
        await fetchTrainingLoadIfEnabled()
        let windowResult = collector.windowSelector.findBestWindowWithCapacity(
            in: series, flags: flags,
            sleepStartMs: sleepContext.sleepStartMs, wakeTimeMs: sleepContext.wakeTimeMs
        )
        return await assembleFinalSession(
            analyzingSession: analyzingSession, baseSession: baseSession, series: series,
            analysis: DeviceAnalysisOutcome(
                result: await runAnalysis(session: analyzingSession, windowResult: windowResult, flags: flags),
                flags: flags, verify: verifyResult, window: windowResult
            ),
            sleepContext: sleepContext
        )
    }

    /// Publish the analyzing state and hand back the session the analysis runs against.
    private func beginAnalyzingSession(baseSession: HRVSession, series: RRSeries) async -> HRVSession {
        let analyzingSession = HRVSession(
            id: baseSession.id,
            startDate: series.startDate,
            endDate: Date(),
            state: .analyzing,
            sessionType: baseSession.sessionType,
            rrSeries: series,
            analysisResult: nil,
            artifactFlags: nil
        )
        await MainActor.run { collector.currentSession = analyzingSession }
        return analyzingSession
    }

    // MARK: - stopSession Helpers

    /// Resolve base session from current session, persisted state, collector.archive
    /// recovery, or (last resort) a fresh session.
    ///
    /// Archive recovery handles the "app was killed overnight" case: the
    /// persisted-state file didn't restore (either lost, corrupted, or never
    /// reached disk), but the collector.archive still has a placeholder overnight
    /// session that was created when recording started. Without this step,
    /// stopSession would mint a brand-new session ID and the strap download
    /// would land in that fresh session while the placeholder stays in the
    /// collector.archive with 0 RR points and a default score — causing the dashboard
    /// to pick the wrong one. User-reported as "strap data missing after
    /// app restart overnight."
    func resolveBaseSession() -> HRVSession {
        if let current = collector.currentSession { return current }
        if let persisted = collector.getPersistedRecordingState() {
            debugLog("[RRCollector] Using persisted recording state for session start time: \(persisted.startTime)")
            return Self.collectingSession(from: persisted)
        }
        if let recovered = findRecoverableArchivedSession() {
            debugLog("[RRCollector] Recovered session \(recovered.id.uuidString.prefix(8)) from archive (persisted state was missing — app likely killed overnight)")
            return recovered
        }
        debugLog("[RRCollector] Warning: No current session, persisted state, or archive candidate — creating fresh session")
        return HRVSession()
    }

    private static func collectingSession(
        from persisted: (sessionId: UUID, startTime: Date, sessionType: SessionType)
    ) -> HRVSession {
        HRVSession(
            id: persisted.sessionId,
            startDate: persisted.startTime,
            endDate: nil,
            state: .collecting,
            sessionType: persisted.sessionType,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil
        )
    }

    /// Search the collector.archive for a recent overnight session that looks like a
    /// placeholder waiting for data. Returns nil if no good candidate found.
    ///
    /// A placeholder is identified by: overnight type, started within 24h,
    /// AND either (no meanRMSSD recorded) OR (recoveryScore is at/below the
    /// 1.0 floor that gets written before real analysis runs). The second
    /// predicate catches cases where some beats got streamed to the collector.archive
    /// via the live-backup path but no real analysis ever completed.
    ///
    /// If there are multiple candidates, we can't tell which one the
    /// device was actually recording for. Returning the newest risks
    /// landing the strap's data in the wrong session and silently
    /// corrupting two nights at once. We bail so the caller creates a
    /// fresh session instead — at worst the user re-analyzes the
    /// original by hand, which is better than cross-contamination.
    private func findRecoverableArchivedSession() -> HRVSession? {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let candidates = collector.archive.entries
            .filter { Self.looksLikeUnresolvedOvernight($0, cutoff: cutoff) }
            // Newest first among candidates — most likely the one we just
            // lost state for.
            .sorted { $0.date > $1.date }
        guard let best = candidates.first else { return nil }
        if candidates.count > 1 {
            logAmbiguousRecoveryCandidates(candidates)
            return nil
        }
        do {
            return try collector.archive.retrieve(best.sessionId)
        } catch {
            debugLog("[RRCollector] Archive recovery: failed to retrieve session \(best.sessionId.uuidString.prefix(8)): \(error)")
            return nil
        }
    }

    private static func looksLikeUnresolvedOvernight(_ entry: SessionArchiveEntry, cutoff: Date) -> Bool {
        guard entry.sessionType == .overnight, entry.date >= cutoff else { return false }
        return entry.meanRMSSD == nil || (entry.recoveryScore ?? 0) <= 1.0
    }

    /// Create a failed session, update UI state, and return it
    func makeFailedSession(from base: HRVSession, error: Error) async -> HRVSession {
        let failedSession = HRVSession(
            id: base.id,
            startDate: base.startDate,
            endDate: Date(),
            state: .failed,
            sessionType: base.sessionType,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil
        )
        let capturedError = error
        await MainActor.run {
            collector.currentSession = failedSession
            collector.lastError = capturedError
        }
        return failedSession
    }

    /// Backup raw RR data immediately (non-fatal on failure)
    func backupRawData(_ points: [RRPoint], sessionId: UUID) {
        guard !points.isEmpty else { return }
        do {
            try collector.rawBackup.backup(
                points: points,
                sessionId: sessionId,
                deviceId: collector.polarManager.connectedDeviceId
            )
        } catch {
            debugLog("[RRCollector] Warning: Failed to backup raw RR data: \(error)", level: .warning)
        }
    }

    /// Calculate the correct session start date, aligning to HealthKit sleep if no persisted state
    ///
    /// Archive-recovery path (`findRecoverableArchivedSession`): the base
    /// session came from the collector.archive, so it already has a correct startDate
    /// from when recording actually started. Trust it — otherwise the
    /// HK-alignment / Date()-duration fallback anchors the download
    /// to "now minus duration", projecting overnight data into the future.
    func calculateSessionStartDate(
        baseSession: HRVSession,
        rrPoints: [RRPoint]
    ) async -> Date {
        if collector.currentSession != nil || collector.getPersistedRecordingState() != nil {
            debugLog("[RRCollector] Using persisted session start: \(baseSession.startDate)")
            return baseSession.startDate
        }
        if collector.archive.exists(baseSession.id) {
            debugLog("[RRCollector] Using archive-recovered session start: \(baseSession.startDate)")
            return baseSession.startDate
        }
        let durationSeconds = TimeInterval(rrPoints.last?.endMs ?? 0) / 1000.0
        if let alignedStart = await healthKitAlignedStart(rrPoints: rrPoints) {
            return alignedStart
        }
        return lastResortStart(baseSession: baseSession, durationSeconds: durationSeconds)
    }

    /// No persisted state — align to HealthKit sleep times.
    private func healthKitAlignedStart(rrPoints: [RRPoint]) async -> Date? {
        let searchEnd = Date()
        let sleepData = try? await collector.healthKit.fetchSleepData(
            for: searchEnd.addingTimeInterval(-24 * 60 * 60), recordingEnd: searchEnd, rrPoints: rrPoints
        )
        guard let hkSleepStart = sleepData?.sleepStart else { return nil }
        let sleepOnsetMs = SleepBoundaryResolver.detectSleepOnset(in: rrPoints) ?? 0
        debugLog("[RRCollector] Aligned to HealthKit sleep start")
        return hkSleepStart.addingTimeInterval(-TimeInterval(sleepOnsetMs) / 1000.0)
    }

    /// Fetch sleep boundaries from HealthKit for window selection
    func fetchSleepContext(sessionStart: Date) async -> SleepBoundaryContext {
        var context = SleepBoundaryContext()
        guard let sleepData = try? await collector.healthKit.fetchSleepData(for: sessionStart, recordingEnd: Date()) else {
            debugLog("[RRCollector] Could not fetch HealthKit sleep data for window selection", level: .warning)
            return context
        }
        if let sleepStart = sleepData.sleepStart {
            context.sleepStartMs = MillisecondOffset.between(sleepStart, and: sessionStart, fallback: 0)
            debugLog("[RRCollector] Using HealthKit sleep start for window selection")
        }
        if let sleepEnd = sleepData.sleepEnd {
            context.wakeTimeMs = MillisecondOffset.between(sleepEnd, and: sessionStart, fallback: 0)
            debugLog("[RRCollector] Using HealthKit wake time for window selection")
        }
        if sleepData.segments.count > 1 {
            context.sleepSegments = Self.segmentsRelative(to: sessionStart, sleepData: sleepData)
            debugLog("[RRCollector] Split night: \(sleepData.segments.count) segments detected")
        }
        return context
    }

    /// A split night's segments, re-expressed as session-relative milliseconds.
    private static func segmentsRelative(
        to sessionStart: Date,
        sleepData: SleepData
    ) -> [HRVSession.SleepSegmentMs] {
        sleepData.segments.map { seg in
            HRVSession.SleepSegmentMs(
                startMs: MillisecondOffset.between(seg.sleepStart, and: sessionStart, fallback: 0),
                endMs: MillisecondOffset.between(seg.sleepEnd, and: sessionStart, fallback: 0)
            )
        }
    }

    /// Fetch training load for readiness context (if enabled in settings)
    func fetchTrainingLoadIfEnabled() async {
        guard collector.settingsManager.settings.enableTrainingLoadIntegration else { return }
        // Use forMorningReading: true so the frozen ATL/CTL/TSB snapshot represents
        // the training state at waking — EWMA through yesterday only, before any
        // activity today. The dashboard uses forMorningReading: false (live, includes
        // today) so ATL visibly updates throughout the day as workouts sync.
        // History keeps the frozen morning value permanently.
        collector.cachedTrainingLoad = await collector.healthKit.calculateTrainingLoad(forMorningReading: true)
        if let load = collector.cachedTrainingLoad {
            debugLog("[RRCollector] Training load: weeklyScore=\(String(format: "%.1f", load.weeklyLoadScore)), daysSinceHard=\(load.daysSinceHardWorkout ?? -1)")
        }
    }

    /// Run HRV analysis using the best available window
    func runAnalysis(
        session: HRVSession,
        windowResult: WindowSelector.WindowSelectionResult?,
        flags: [ArtifactFlags]
    ) async -> HRVAnalysisResult? {
        if let windowResult, let recoveryWindow = windowResult.recoveryWindow {
            return await collector.analyze(session, window: recoveryWindow, flags: flags, peakCapacity: windowResult.peakCapacity)
        } else if let windowResult {
            debugLog("[RRCollector] No recovery window (even after fallback) - analyzing full session with peak capacity")
            return await collector.analyze(session, peakCapacity: windowResult.peakCapacity)
        } else {
            debugLog("[RRCollector] No valid windows at all - analyzing full session")
            return await collector.analyze(session)
        }
    }

    /// Assemble the final session, clamp boundaries, compute deviation, and update UI state
    func assembleFinalSession(
        analyzingSession: HRVSession,
        baseSession: HRVSession,
        series: RRSeries,
        analysis: DeviceAnalysisOutcome,
        sleepContext: SleepBoundaryContext
    ) async -> HRVSession {
        let clamped = SleepBoundaryResolver.clamp(
            sleepStartMs: sleepContext.sleepStartMs, sleepEndMs: sleepContext.wakeTimeMs,
            recordingDurationMs: series.points.last?.endMs ?? 0
        )
        var finalSession = HRVSession(
            id: analyzingSession.id, startDate: analyzingSession.startDate, endDate: analyzingSession.endDate,
            state: analysis.result != nil ? .complete : .failed, sessionType: baseSession.sessionType,
            rrSeries: series, analysisResult: analysis.result, artifactFlags: analysis.flags,
            sleepStartMs: clamped.sleepStartMs, sleepEndMs: clamped.sleepEndMs,
            sleepSegments: sleepContext.sleepSegments
        )
        await applyRecoveryScore(to: &finalSession, analysisResult: analysis.result)
        // Freeze training snapshot once at capture time
        finalSession.trainingSnapshot = collector.createTrainingContext()
        await publishAcceptanceState(finalSession, verifyResult: analysis.verify, windowResult: analysis.window)
        return finalSession
    }

    /// What the analysis stage produced for one device-recorded session.
    struct DeviceAnalysisOutcome {
        let result: HRVAnalysisResult?
        let flags: [ArtifactFlags]
        let verify: Verification.Result
        let window: WindowSelector.WindowSelectionResult?
    }

    /// Persist the snapshots used to score so the
    /// dashboard doesn't re-derive a tier-1 breakdown from nil.
    ///
    /// Overnight sessions only. The scorer fetches
    /// LAST NIGHT's sleep for any session lacking a snapshot, so
    /// freezing it onto a daytime device capture makes that capture
    /// the newest snapshot-bearing session and hijacks the
    /// dashboard sleep chip (`latestWithSleep`) away from the real
    /// overnight session. Same gate the streaming path has
    /// (RRCollector+Streaming.swift).
    private func applyRecoveryScore(to finalSession: inout HRVSession, analysisResult: HRVAnalysisResult?) async {
        guard let result = await collector.computeRecoveryScore(for: finalSession, from: analysisResult) else { return }
        finalSession.recoveryScore = result.score
        finalSession.scoreBreakdown = result.breakdown
        guard finalSession.sessionType == .overnight else { return }
        if let snap = result.sleepSnapshot { finalSession.sleepSnapshot = snap }
        if let v = result.vitalsSnapshot { finalSession.vitalsSnapshot = v }
    }

    private func publishAcceptanceState(
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
}

// MARK: - File-scope helpers
//
// Each names no member of RRCollector and calls nothing inside it, so
// none needs to be a member. `private` at file scope is fileprivate, so
// every call site in this file resolves.

@MainActor
private func logAmbiguousRecoveryCandidates(_ candidates: [SessionArchiveEntry]) {
    debugLog("[RRCollector] Archive recovery: found \(candidates.count) unresolved overnight candidates within 24h — refusing to guess, falling through to fresh session", level: .warning)
    for c in candidates.prefix(5) {
        debugLog("[RRCollector]   candidate \(c.sessionId.uuidString.prefix(8)) date=\(c.date)")
    }
}

@MainActor
/// Last-resort fallback. `Date() - duration` assumes the strap just
/// finished recording; for an app killed overnight and relaunched
/// hours later this anchors the data wrongly into the present.
/// If `baseSession.endDate` is known (device recording sets it from
/// the strap's last beat), prefer that as the anchor — it reflects
/// when the recording actually stopped. Otherwise we have to fall
/// back to `Date()` and log a warning so the anomaly is visible.
private func lastResortStart(baseSession: HRVSession, durationSeconds: TimeInterval) -> Date {
    guard let endDate = baseSession.endDate else {
        debugLog("[RRCollector] No HealthKit data and no endDate — using fetch-time fallback; start date may be wrong if app was killed overnight", level: .warning)
        return Date().addingTimeInterval(-durationSeconds)
    }
    debugLog("[RRCollector] Anchoring session start to baseSession.endDate - duration (\(endDate) - \(Int(durationSeconds))s)")
    return endDate.addingTimeInterval(-durationSeconds)
}
