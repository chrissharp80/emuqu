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

    /// Where a recording downloaded from the strap is filed: the session it
    /// becomes, the clock its beats are placed on, and an archived night it
    /// merges into (Recover of a night already scored from the stream).
    struct DownloadPlacement {
        let sessionId: UUID
        let sessionType: SessionType
        let startDate: Date
        let deviceProvenance: DeviceProvenance?
        let existing: HRVSession?
    }

    // MARK: - Recording API

    /// Start a new collection session (device internal recording)
    /// H10: exercise recording. Verity Sense: offline PPI recording.
    /// - Parameter sessionType: The type of session (overnight, nap, or quick)
    func startSession(sessionType: SessionType = .overnight) async throws {
        guard collector.polarManager.connectionState == .connected else {
            throw RRCollector.CollectorError.notConnected
        }
        // The strap's own answer, not a flag a stopped recording left behind.
        await collector.polarManager.recording.refreshRecordingState(
            until: Date().addingTimeInterval(StrapRecordingPolicy.featureReadyWindowSeconds)
        )
        guard !collector.polarManager.isRecordingOnDevice else {
            throw RRCollector.CollectorError.alreadyRecording
        }
        let session = HRVSession(sessionType: sessionType, deviceProvenance: deviceRecordingProvenance())
        let startTime = Date()
        guard !collector.reconciliation.sessionExists(session.id) else {
            throw RRCollector.CollectorError.sessionExists
        }
        try await collector.polarManager.startRecording()
        // Persisted at once: survives app crashes, phone reboots, etc.
        collector.persistRecordingState(sessionId: session.id, startTime: startTime, sessionType: sessionType)
        await publishDeviceRecordingStarted(session: session, startTime: startTime)
    }

    /// Captured before starting — tracks source device and collection method.
    func deviceRecordingProvenance() -> DeviceProvenance {
        DeviceProvenance.current(
            deviceId: collector.polarManager.connectedDeviceId ?? "unknown",
            deviceModel: collector.polarManager.connectedDeviceType?.displayName ?? "Polar device",
            firmwareVersion: nil,
            recordingMode: .deviceInternal
        )
    }

    /// Mark the session active in-app. Without `collector.isCollecting`, RecordView's
    /// isSessionActive check stays false (isOvernightStreaming and
    /// isCollecting both default false on this path), so the "Choose
    /// Session" picker keeps drawing on top of an already-running
    /// device recording — making it look like the start button did nothing.
    private func publishDeviceRecordingStarted(session: HRVSession, startTime: Date) async {
        collector.currentSession = session
        collector.collectedPoints = []
        collector.sessionStartTime = startTime
        collector.isCollecting = true
        collector.recordingPhase = .deviceRecording
    }

    /// Stop the device recording, download it and score it. The Retry card
    /// after a failed download is this same call: the session is resolved,
    /// dated and assembled exactly as a first Stop would.
    ///
    /// Only a recording that started since the session began is taken
    /// (`fetchRecording`'s date filter): the strap keeps the previous night
    /// until the next recording clears it, and that file is not this one.
    func stopSession() async throws -> HRVSession? {
        guard collector.polarManager.connectionState == .connected else {
            throw RRCollector.CollectorError.notConnected
        }
        let base = resolveBaseSession()
        collector.polarManager.beginTransfer()
        let recording: StrapRecording
        do {
            recording = try await collector.polarManager.fetchRecording(recordedSince: base?.startDate, budget: .attended)
        } catch {
            return await makeFailedSession(from: base ?? HRVSession(), error: error)
        }
        return await assembleDownloadedSession(recording, placement: await placement(for: recording, base: base))
    }

    /// The session on record keeps its id and clock. With none, the
    /// recording is filed as its own night, dated by its own start.
    private func placement(for recording: StrapRecording, base: HRVSession?) async -> DownloadPlacement {
        guard let base else {
            return DownloadPlacement(
                sessionId: UUID(), sessionType: .overnight,
                startDate: await recordingStart(recording),
                deviceProvenance: deviceRecordingProvenance(), existing: nil
            )
        }
        return DownloadPlacement(
            sessionId: base.id, sessionType: base.sessionType, startDate: base.startDate,
            deviceProvenance: base.deviceProvenance ?? deviceRecordingProvenance(), existing: nil
        )
    }

    // MARK: - The one assembly for downloaded beats

    /// Stop, Retry and Recover all end here: the downloaded beats are placed
    /// on the session's clock, backed up before anything else can fail,
    /// merged with an archived night when there is one, analysed with the
    /// night's own sleep (split nights included) and training load, saved for
    /// review, and presented for acceptance.
    func assembleDownloadedSession(_ recording: StrapRecording, placement: DownloadPlacement) async -> HRVSession {
        let devicePoints = recording.points(onClockOf: placement.startDate)
        backupRawData(devicePoints, sessionId: placement.sessionId, startDate: placement.startDate)
        guard devicePoints.count >= DataSourceSelector.minimumValidBeats else {
            debugLog("[RRCollector] Downloaded recording holds \(devicePoints.count) beats — too few to analyse")
            return await makeFailedSession(from: placement.failedBase, error: RRCollector.CollectorError.insufficientData)
        }
        let merged = mergedWithArchivedNight(devicePoints, placement: placement)
        let series = RRSeries(points: merged.points, sessionId: placement.sessionId, startDate: placement.startDate)
        let session = await analyzeAndAssemble(placement: placement, series: series, summary: merged.summary)
        // A night already in the archive is replaced only on Accept, so
        // Discard leaves it exactly as it was.
        if !collector.archive.exists(session.id) { collector.morning.archiveForReview(session) }
        return session
    }

    /// The device recording is the base; an archived night's beats only fill
    /// its gaps (`DataSourceSelector`).
    private func mergedWithArchivedNight(
        _ devicePoints: [RRPoint], placement: DownloadPlacement
    ) -> (points: [RRPoint], summary: HRVSession.DataSourceSummary) {
        // The archived night's beats count from its own start; the placement
        // clock may start earlier, when the recording began first.
        let archived = placement.existing.map {
            SessionMerger.rebased($0.rrSeries?.points ?? [], from: $0.startDate, onto: placement.startDate)
        } ?? []
        let selection = archived.isEmpty ? nil : DataSourceSelector.selectBestSource(
            streamingPoints: archived, internalPoints: devicePoints,
            sessionId: placement.sessionId, sessionStart: placement.startDate
        )
        let points = selection?.points ?? devicePoints
        debugLog("[RRCollector] Downloaded \(devicePoints.count) beats; archived night held \(archived.count) — using \(selection?.normalizedSource ?? "internal") (\(points.count) beats)")
        return (points, sourceSummary(
            source: selection?.normalizedSource ?? "internal", devicePoints: devicePoints,
            archivedCount: archived.count, totalCount: points.count, existing: placement.existing
        ))
    }

    private func sourceSummary(
        source: String, devicePoints: [RRPoint], archivedCount: Int, totalCount: Int, existing: HRVSession?
    ) -> HRVSession.DataSourceSummary {
        let deviceCount = devicePoints.count
        let differencePercent: Double? = archivedCount > 0
            ? Double(abs(deviceCount - archivedCount)) / Double(max(deviceCount, archivedCount)) * 100
            : nil
        return HRVSession.DataSourceSummary(
            selectedSource: source, streamingBeats: archivedCount, deviceBeats: deviceCount,
            totalBeats: totalCount, beatDifferencePercent: differencePercent,
            reconnectCount: existing?.dataSourceSummary?.reconnectCount ?? 0,
            deviceModel: existing?.deviceProvenance?.deviceModel ?? collector.polarManager.connectedDeviceType?.displayName
        )
    }

    /// Everything downstream of having a usable RR series: artifact detection,
    /// sleep + training context, window selection, analysis, and assembly.
    private func analyzeAndAssemble(
        placement: DownloadPlacement, series: RRSeries, summary: HRVSession.DataSourceSummary
    ) async -> HRVSession {
        let analyzingSession = await beginAnalyzingSession(placement: placement, series: series)
        let flags = collector.artifactDetector.detectArtifacts(in: series)
        let verifyResult = collector.verification.verify(series, flags: flags)
        let sleepContext = await fetchSleepContext(sessionStart: series.startDate, recordingEnd: analyzingSession.endDate ?? Date())
        await fetchTrainingLoadIfEnabled()
        let windowResult = collector.windowSelector.findBestWindowWithCapacity(
            in: series, flags: flags,
            sleepStartMs: sleepContext.sleepStartMs, wakeTimeMs: sleepContext.wakeTimeMs
        )
        let analysis = DeviceAnalysisOutcome(
            result: await runAnalysis(session: analyzingSession, windowResult: windowResult, flags: flags),
            flags: flags, verify: verifyResult, window: windowResult
        )
        return await assembleFinalSession(
            analyzingSession: analyzingSession, placement: placement, series: series,
            outcome: AssemblyOutcome(analysis: analysis, sleepContext: sleepContext, summary: summary)
        )
    }

    /// Publish the analyzing state and hand back the session the analysis runs against.
    /// It ends at the last beat, not at the download, and keeps the device
    /// that recorded it.
    private func beginAnalyzingSession(placement: DownloadPlacement, series: RRSeries) async -> HRVSession {
        let analyzingSession = HRVSession(
            id: placement.sessionId,
            startDate: series.startDate,
            endDate: Self.lastBeatDate(of: series),
            state: .analyzing,
            sessionType: placement.sessionType,
            rrSeries: series,
            analysisResult: nil,
            artifactFlags: nil,
            deviceProvenance: placement.deviceProvenance
        )
        collector.currentSession = analyzingSession
        return analyzingSession
    }

    /// When the recording's last beat ended, never later than now.
    static func lastBeatDate(of series: RRSeries) -> Date {
        guard let first = series.points.first, let last = series.points.last else { return Date() }
        let end = series.startDate.addingTimeInterval(Double(last.endMs - first.t_ms) / 1000)
        return min(end, Date())
    }

    // MARK: - Resolving the session and its start

    /// The session the device recording belongs to: the current session, the
    /// persisted recording state, or an archived placeholder. Nil when none
    /// is on record, and the recording is then filed by its own start.
    ///
    /// Archive recovery handles the "app was killed overnight" case: the
    /// persisted-state file didn't restore (either lost, corrupted, or never
    /// reached disk), but the archive still has a placeholder overnight
    /// session that was created when recording started. Without this step,
    /// the strap download would land in a fresh session while the placeholder
    /// stays in the archive with 0 RR points and a default score — causing the
    /// dashboard to pick the wrong one.
    func resolveBaseSession() -> HRVSession? {
        if let current = collector.currentSession { return current }
        if let persisted = collector.getPersistedRecordingState() {
            debugLog("[RRCollector] Using persisted recording state for session start time: \(persisted.startTime)")
            return Self.collectingSession(from: persisted)
        }
        if let recovered = findRecoverableArchivedSession() {
            debugLog("[RRCollector] Recovered session \(recovered.id.uuidString.prefix(8)) from archive (persisted state was missing — app likely killed overnight)")
            return recovered
        }
        debugLog("[RRCollector] No current session, persisted state, or archive candidate — filing the recording by its own start")
        return nil
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

    /// Search the archive for a recent overnight session that looks like a
    /// placeholder waiting for data. Returns nil if no good candidate found.
    ///
    /// A placeholder is identified by: overnight type, started within 24h,
    /// AND either (no meanRMSSD recorded) OR (recoveryScore is at/below the
    /// 1.0 floor that gets written before real analysis runs). The second
    /// predicate catches cases where some beats got streamed to the archive
    /// via the live-backup path but no real analysis ever completed.
    ///
    /// If there are multiple candidates, we can't tell which one the
    /// device was actually recording for. Returning the newest risks
    /// landing the strap's data in the wrong session and silently
    /// corrupting two nights at once. We bail so the recording is filed by
    /// its own start instead.
    private func findRecoverableArchivedSession() -> HRVSession? {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let candidates = collector.archive.entries
            .filter { Self.looksLikeUnresolvedOvernight($0, cutoff: cutoff) }
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

    /// When a recording the app cannot otherwise date began: aligned to
    /// HealthKit's sleep start when there is one, else counted back from now
    /// by the recording's own length.
    func recordingStart(_ recording: StrapRecording) async -> Date {
        if let start = recording.startedAt { return start }
        if let aligned = await healthKitAlignedStart(rrPoints: recording.points) { return aligned }
        debugLog("[RRCollector] Recording carries no start and HealthKit has no sleep — dating it back from now", level: .warning)
        return Date().addingTimeInterval(-StrapExerciseDecoder.durationSeconds(of: recording.points))
    }

    /// Align to HealthKit's sleep start, backing out the sleep onset measured
    /// in the beats themselves.
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

    // MARK: - Failure and backup

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
        collector.currentSession = failedSession
        collector.lastError = error
        return failedSession
    }

    /// Backup raw RR data immediately (non-fatal on failure)
    func backupRawData(_ points: [RRPoint], sessionId: UUID, startDate: Date? = nil) {
        guard !points.isEmpty else { return }
        do {
            try collector.rawBackup.backup(
                points: points,
                sessionId: sessionId,
                deviceId: collector.polarManager.connectedDeviceId,
                captureDate: startDate
            )
        } catch {
            debugLog("[RRCollector] Warning: Failed to backup raw RR data: \(error)", level: .warning)
        }
    }

    // MARK: - Sleep, training load and analysis

    /// Sleep boundaries from HealthKit for window selection, over the
    /// recording's own span.
    func fetchSleepContext(sessionStart: Date, recordingEnd: Date) async -> SleepBoundaryContext {
        var context = SleepBoundaryContext()
        guard let sleepData = try? await collector.healthKit.fetchSleepData(for: sessionStart, recordingEnd: recordingEnd) else {
            debugLog("[RRCollector] Could not fetch HealthKit sleep data for window selection", level: .warning)
            return context
        }
        context.sleepStartMs = sleepData.sleepStart.map { MillisecondOffset.between($0, and: sessionStart, fallback: 0) }
        context.wakeTimeMs = sleepData.sleepEnd.map { MillisecondOffset.between($0, and: sessionStart, fallback: 0) }
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

    // MARK: - Assembly

    /// What the analysis stage produced for one device-recorded session.
    struct DeviceAnalysisOutcome {
        let result: HRVAnalysisResult?
        let flags: [ArtifactFlags]
        let verify: Verification.Result
        let window: WindowSelector.WindowSelectionResult?
    }

    /// Everything the final session is built from besides the beats.
    private struct AssemblyOutcome {
        let analysis: DeviceAnalysisOutcome
        let sleepContext: SleepBoundaryContext
        let summary: HRVSession.DataSourceSummary
    }

    /// Assemble the final session, clamp boundaries, compute deviation, and update UI state
    private func assembleFinalSession(
        analyzingSession: HRVSession, placement: DownloadPlacement, series: RRSeries, outcome: AssemblyOutcome
    ) async -> HRVSession {
        let clamped = SleepBoundaryResolver.clamp(
            sleepStartMs: outcome.sleepContext.sleepStartMs, sleepEndMs: outcome.sleepContext.wakeTimeMs,
            recordingDurationMs: series.points.last?.endMs ?? 0
        )
        let result = outcome.analysis.result
        var finalSession = HRVSession(
            id: analyzingSession.id, startDate: analyzingSession.startDate, endDate: analyzingSession.endDate,
            state: result != nil ? .complete : .failed, sessionType: placement.sessionType,
            rrSeries: series, analysisResult: result, artifactFlags: outcome.analysis.flags,
            deviceProvenance: placement.deviceProvenance,
            sleepStartMs: clamped.sleepStartMs, sleepEndMs: clamped.sleepEndMs,
            sleepSegments: outcome.sleepContext.sleepSegments, dataSourceSummary: outcome.summary
        )
        carryForwardExistingMetadata(into: &finalSession, from: placement.existing)
        await applyRecoveryScore(to: &finalSession, analysisResult: result)
        await freezeTrainingSnapshot(on: &finalSession)
        await publishAcceptanceState(finalSession, verifyResult: outcome.analysis.verify, windowResult: outcome.analysis.window)
        return finalSession
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
        finalSession.trainingSnapshot = existing.trainingSnapshot
    }

    /// Freeze the training snapshot once, as of the night's own end: a
    /// recording recovered days later is not scored against today's load.
    private func freezeTrainingSnapshot(on finalSession: inout HRVSession) async {
        if finalSession.trainingSnapshot == nil {
            let asOf = finalSession.endDate ?? finalSession.startDate
            finalSession.trainingSnapshot = await collector.createTrainingContextEnsuringFresh(relativeTo: asOf)
        }
        if let frozen = finalSession.trainingSnapshot { finalSession.analysisResult?.trainingContext = frozen }
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
        collector.currentSession = finalSession
        collector.verificationResult = verifyResult
        collector.recoveryWindow = windowResult?.recoveryWindow
        collector.needsAcceptance = finalSession.state == .complete
        if finalSession.state == .complete {
            collector.recordingPhase = .awaitingAcceptance
        }
        collector.baselineDeviation = deviation
        collector.sessionStartTime = nil
        collector.archiveSignal.notifyChanged()
    }
}

extension DeviceRecordingSession.DownloadPlacement {
    /// The session a placement fails as when its beats are too few.
    var failedBase: HRVSession {
        HRVSession(
            id: sessionId, startDate: startDate, endDate: nil, state: .collecting,
            sessionType: sessionType, rrSeries: nil, analysisResult: nil, artifactFlags: nil,
            deviceProvenance: deviceProvenance
        )
    }
}

// MARK: - File-scope helpers
//
// Each names no member of RRCollector and calls nothing inside it, so
// none needs to be a member. `private` at file scope is fileprivate, so
// every call site in this file resolves.

@MainActor
private func logAmbiguousRecoveryCandidates(_ candidates: [SessionArchiveEntry]) {
    debugLog("[RRCollector] Archive recovery: found \(candidates.count) unresolved overnight candidates within 24h — refusing to guess, filing the recording by its own start", level: .warning)
    for c in candidates.prefix(5) {
        debugLog("[RRCollector]   candidate \(c.sessionId.uuidString.prefix(8)) date=\(c.date)")
    }
}
