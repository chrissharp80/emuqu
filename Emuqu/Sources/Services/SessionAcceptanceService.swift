import Foundation

/// Extracted acceptance logic from RRCollector+Acceptance.
///
/// Owns the heavy work of session acceptance (score recomputation, sleep fetch,
/// archive, baseline update, CloudKit upload, HealthKit export) without directly
/// mutating any observable UI state. The caller (RRCollector) performs the final
/// UI state updates after the service returns.
@MainActor
final class SessionAcceptanceService {
    // MARK: - Dependencies

    private let archive: SessionArchive
    private let healthKit: any HealthKitServiceProtocol
    private let baselineTracker: BaselineTracker
    private let rawBackup: RawRRBackup
    /// Discards pending exercise data on the Polar device (used during rejection).
    private let onDiscardExercise: () -> Void

    /// Called to sync an accepted session to iCloud.
    private let onCloudSync: (HRVSession) async -> Void

    /// Called to delete a live backup from iCloud after acceptance or rejection.
    private let onCloudDelete: (UUID) async -> Void

    // MARK: - Initialization

    init(
        archive: SessionArchive,
        healthKit: any HealthKitServiceProtocol,
        baselineTracker: BaselineTracker,
        rawBackup: RawRRBackup,
        onDiscardExercise: @escaping () -> Void,
        onCloudSync: @escaping (HRVSession) async -> Void,
        onCloudDelete: @escaping (UUID) async -> Void
    ) {
        self.archive = archive
        self.healthKit = healthKit
        self.baselineTracker = baselineTracker
        self.rawBackup = rawBackup
        self.onDiscardExercise = onDiscardExercise
        self.onCloudSync = onCloudSync
        self.onCloudDelete = onCloudDelete
    }

    // MARK: - Accept Session

    /// Performs the heavy work of accepting a session:
    /// recomputes the recovery score with fresh HealthKit data, archives the session,
    /// updates baseline, marks raw backup, exports to HealthKit if enabled, and syncs
    /// to CloudKit.
    ///
    /// - Returns: The accepted (and possibly score-updated) session.
    /// - Throws: If archiving fails.
    /// How far to trust this recording's HRV, and whether to fall back to the
    /// user's baseline instead.
    ///
    /// Decision tree:
    ///   1. No sleep overlap → baseline fallback (`.preSleep`)
    ///   2. Overlaps sleep + RMSSD ≥ baseline → trust it (`.good`)
    ///   3. Overlaps sleep + RMSSD < baseline + session < 30 min → ambiguous (`.insufficient`)
    ///   4. Overlaps sleep + RMSSD < baseline + session ≥ 30 min → legitimate bad night (`.good`)
    ///
    /// Two independent sufficiency checks feed rule 1, either of which forces
    /// the fallback: an analysis window under 5 minutes (the strap died
    /// mid-window), or no organised recovery in a session under 3 hours while
    /// below baseline.
    struct HRVQualityDecision {
        let dataQuality: HRVDataQuality
        let useBaselineHRV: Bool
    }

    static func classifyHRVQuality(
        result: HRVAnalysisResult,
        sleepData: SleepData?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        recordingStart: Date,
        recordingEnd: Date
    ) -> HRVQualityDecision {
        let sessionDuration = recordingEnd.timeIntervalSince(recordingStart)
        let rmssd = result.timeDomain.rmssd
        let baselineRmssd = baselineStats.map { exp($0.lnRmssdMean) } ?? 0
        if let insufficient = insufficientDataDecision(result: result, rmssd: rmssd, baselineRmssd: baselineRmssd, sessionDuration: sessionDuration) {
            return insufficient
        }
        guard overlapsSleep(sleepData, recordingStart: recordingStart, recordingEnd: recordingEnd) else {
            debugLog("[SessionAcceptanceService] HRV recording doesn't overlap sleep — using baseline HRV")
            return HRVQualityDecision(dataQuality: .preSleep, useBaselineHRV: true)
        }
        let longEnough = sessionDuration >= HRVConstants.MinimumDuration.forOvernightSessionSeconds
        guard rmssd >= baselineRmssd || longEnough else {
            debugLog("[SessionAcceptanceService] Short session (\(Int(sessionDuration))s) with RMSSD \(String(format: "%.0f", rmssd))ms < baseline \(String(format: "%.0f", baselineRmssd))ms — using baseline HRV")
            return HRVQualityDecision(dataQuality: .insufficient, useBaselineHRV: true)
        }
        if !longEnough {
            debugLog("[SessionAcceptanceService] Short session (\(Int(sessionDuration))s) but RMSSD \(String(format: "%.0f", rmssd))ms ≥ baseline \(String(format: "%.0f", baselineRmssd))ms — trusting it")
        }
        return HRVQualityDecision(dataQuality: .good, useBaselineHRV: false)
    }

    /// No sleep data means we cannot determine overlap — trust the HRV as-is.
    private static func overlapsSleep(
        _ sleepData: SleepData?, recordingStart: Date, recordingEnd: Date
    ) -> Bool {
        guard let sleepStart = sleepData?.sleepStart, let sleepEnd = sleepData?.sleepEnd else {
            return true
        }
        return recordingEnd > sleepStart && recordingStart < sleepEnd
    }

    /// A window too short to trust, or a session that never reached its
    /// recovery zone, both count as insufficient when the RMSSD also came in
    /// under baseline. Nil means the data is good enough to judge normally.
    private static func insufficientDataDecision(
        result: HRVAnalysisResult, rmssd: Double, baselineRmssd: Double, sessionDuration: TimeInterval
    ) -> HRVQualityDecision? {
        let analysisWindowDurationMs: Int64 = if let wsMs = result.windowStartMs,
                                                 let weMs = result.windowEndMs {
            weMs - wsMs
        } else {
            Int64(sessionDuration * 1000)
        }
        let windowTooShort = analysisWindowDurationMs < HRVConstants.MinimumDuration.forReliableWindowMs
        let noRecoveryZoneData = result.isOrganizedRecovery != true
            && sessionDuration < HRVConstants.MinimumDuration.forOvernightSessionSeconds
        guard windowTooShort || noRecoveryZoneData, rmssd < baselineRmssd else { return nil }
        if windowTooShort {
            debugLog("[SessionAcceptanceService] Analysis window only \(analysisWindowDurationMs / 1000)s with RMSSD \(String(format: "%.0f", rmssd))ms < baseline \(String(format: "%.0f", baselineRmssd))ms — too short to trust, using baseline HRV")
        } else {
            debugLog("[SessionAcceptanceService] No organized recovery in \(Int(sessionDuration / 60))min session with RMSSD \(String(format: "%.0f", rmssd))ms < baseline \(String(format: "%.0f", baselineRmssd))ms — didn't reach recovery zone, using baseline HRV")
        }
        return HRVQualityDecision(dataQuality: .insufficient, useBaselineHRV: true)
    }

    /// The training context to freeze the score against.
    ///
    /// Guarantees Tier 3 freezing when training-load integration is
    /// on. Real tester report (H10 + overnight): the dashboard showed
    /// 89 immediately after wake-up, and re-analysing the SAME recording later
    /// produced 65, because the finalize path passed `trainingContext: nil` —
    /// the upstream `cachedTrainingLoad` had not populated yet, or HealthKit was
    /// busy on the cold-launch race — so the score froze at Tier 2 instead of
    /// Tier 3. The user then saw a 24-point drop after the first re-analyse
    /// recomputed with training data and re-froze.
    ///
    /// The contract: when the session ends, the training load is known; grab it
    /// and freeze it. If the caller hands us no context and the user has
    /// training-load integration enabled, fetch one inline before scoring. The
    /// cost is one bounded HealthKit call on the rare cold path; the benefit is
    /// that the frozen score is never retroactively rewritten.
    private func resolveTrainingContext(
        given trainingContext: TrainingContext?,
        scoringConfig: RecoveryScoreCalculator.ScoringConfiguration,
        sessionEnd: Date
    ) async -> TrainingContext? {
        if let ctx = trainingContext { return ctx }
        guard scoringConfig.enableTrainingLoadIntegration,
              !scoringConfig.isOnTrainingBreak
        else { return nil }
        let load = await healthKit.calculateTrainingLoad(relativeTo: sessionEnd)
        return TrainingContext(from: load, relativeTo: sessionEnd)
    }

    /// Sleep and vitals, frozen from this point forward — raced against a
    /// 10-second timeout.
    ///
    /// The HealthKit queries go through `withCheckedContinuation`, which hangs
    /// forever if the callback never fires. Racing a sleeping task against the
    /// fetch means a wedged query costs ten seconds and a score without
    /// sleep/vitals, rather than an acceptance that never completes.
    /// A failed sleep fetch is not fatal to acceptance — the score is computed
    /// without it — but it must leave a trace.
    nonisolated private static func sleepOrNil(
        _ hk: any HealthKitServiceProtocol, from fetchStart: Date, to fetchEnd: Date, rrPoints: [RRPoint]?
    ) async -> SleepData? {
        do {
            return try await hk.fetchSleepData(
                for: fetchStart, recordingEnd: fetchEnd, rrPoints: rrPoints
            )
        } catch {
            debugLog("[SessionAcceptanceService] Sleep fetch failed during acceptance: \(error)")
            return nil
        }
    }

    private func fetchSleepAndVitals(
        rrPoints: [RRPoint]?,
        fetchStart: Date,
        fetchEnd: Date,
        sessionEnd: Date
    ) async -> (SleepData?, RecoveryVitals?) {
        let hk = healthKit
        let raced: (SleepData?, RecoveryVitals?)? = await withTaskGroup(
            of: (SleepData?, RecoveryVitals?)?.self
        ) { group in
            group.addTask {
                let sleep = await Self.sleepOrNil(hk, from: fetchStart, to: fetchEnd, rrPoints: rrPoints)
                return (sleep, await hk.fetchRecoveryVitals(relativeTo: sessionEnd))
            }
            group.addTask {
                await sleepQuietly(10_000_000_000, context: "fetchSleepAndVitals")
                debugLog("[SessionAcceptanceService] ⚠️ HealthKit fetch timed out after 10s — scoring without sleep/vitals")
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return raced ?? (nil, nil)
    }

    /// The frozen inputs one acceptance scores against.
    struct AcceptanceInputs {
        let scoringConfig: RecoveryScoreCalculator.ScoringConfiguration
        let trainingContext: TrainingContext?
        let baselineStats: BaselineTracker.RecoveryBaselineStats?
        let typicalSleepHours: Double
        let sleepSchedule: SleepSchedule
    }

    func processAcceptance(
        session: HRVSession,
        inputs: AcceptanceInputs,
        enableHealthKitExport: Bool,
        clearPersistedRecordingState: () -> Void
    ) async throws -> HRVSession {
        var session = session
        let sleepSchedule = inputs.sleepSchedule
        if let result = session.analysisResult {
            await freezeScore(on: &session, result: result, inputs: inputs)
        }
        debugLog("[SessionAcceptanceService] Accepting and archiving session ID: \(session.id.uuidString)")
        try archive.archive(session)
        rawBackup.markAsArchived(session.id)
        baselineTracker.update(with: session, sleepSchedule: sleepSchedule)
        // Clear persisted recording state - session is now safely archived.
        // NOTE: We intentionally do NOT clear the H10 memory here — data stays
        // on the H10 as a backup until a new recording starts.
        clearPersistedRecordingState()
        exportToHealthIfEnabled(session, enabled: enableHealthKitExport)
        syncToCloud(session)
        return session
    }

    /// Recompute the composite recovery score at acceptance time and snapshot
    /// HealthKit data, so the dashboard stays stable for the rest of the day.
    private func freezeScore(
        on session: inout HRVSession, result: HRVAnalysisResult, inputs: AcceptanceInputs
    ) async {
        let sessionEnd = session.endDate ?? session.startDate
        let resolvedTrainingContext = await resolveTrainingContext(
            given: inputs.trainingContext,
            scoringConfig: inputs.scoringConfig,
            sessionEnd: sessionEnd
        )
        await snapshotHealthData(on: &session, sessionEnd: sessionEnd, sleepSchedule: inputs.sleepSchedule)
        let quality = Self.classifyHRVQuality(
            result: result,
            sleepData: session.sleepSnapshot,
            baselineStats: inputs.baselineStats,
            recordingStart: session.startDate,
            recordingEnd: session.endDate ?? session.startDate
        )
        session.hrvDataQuality = quality.dataQuality
        let breakdown = scoreBreakdown(
            result: result, session: session, inputs: inputs,
            training: resolvedTrainingContext, useBaselineHRV: quality.useBaselineHRV
        )
        applyFrozenScore(breakdown, to: &session, training: resolvedTrainingContext)
    }

    /// Fetch and snapshot sleep + vitals — frozen from this point forward.
    /// HealthKit queries use withCheckedContinuation which can hang if
    /// callbacks never fire, so we race against a 10-second timeout.
    ///
    /// Strap-RHR override: swap Apple's daytime-rest RHR
    /// for the strap's nocturnal analysis-window mean HR when available — same
    /// physiology `BaselineTracker.meanHRBaseline` is built from. Keeps the
    /// score's RHR comparison apples-to-apples. See
    /// `RecoveryVitals.withStrapNocturnalRHR` documentation.
    private func snapshotHealthData(
        on session: inout HRVSession, sessionEnd: Date, sleepSchedule: SleepSchedule
    ) async {
        let (fetchStart, fetchEnd) = sleepFetchRange(
            for: session, sessionEnd: sessionEnd, sleepSchedule: sleepSchedule
        )
        let (sleepData, vitals) = await fetchSleepAndVitals(
            rrPoints: session.rrSeries?.points,
            fetchStart: fetchStart,
            fetchEnd: fetchEnd,
            sessionEnd: sessionEnd
        )
        session.sleepSnapshot = sleepData
        session.vitalsSnapshot = vitals?.withStrapNocturnalRHR(session.analysisResult?.timeDomain.meanHR)
    }

    /// Guarantee Tier 3 freezing when training-load integration
    /// is on, by scoring against the just-resolved context even when the
    /// caller passed nil. See `resolveTrainingContext` for the tester
    /// report this guards against (score frozen at Tier 2, then a 24-point
    /// drop on the first re-analyze).
    private func scoreBreakdown(
        result: HRVAnalysisResult,
        session: HRVSession,
        inputs: AcceptanceInputs,
        training: TrainingContext?,
        useBaselineHRV: Bool
    ) -> RecoveryScoreCalculator.ScoreBreakdown {
        let ansBalance: Double? = {
            guard let pns = result.ansMetrics?.pnsIndex, let sns = result.ansMetrics?.snsIndex else { return nil }
            return pns - sns
        }()
        return RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: result.ansMetrics?.readinessScore, rmssd: result.timeDomain.rmssd,
                meanHR: result.timeDomain.meanHR, dfaAlpha1: result.nonlinear.dfaAlpha1,
                baselineStats: inputs.baselineStats, sleepData: session.sleepSnapshot,
                vitals: session.vitalsSnapshot, typicalSleepHours: inputs.typicalSleepHours
            ),
            trainingContext: training,
            config: inputs.scoringConfig,
            useBaselineHRV: useBaselineHRV,
            ansBalance: ansBalance
        )
    }

    /// Stamp the resolved training context onto the session so every read path
    /// (dashboard, history, AI context) sees the exact ATL/CTL/TSB/ACWR that
    /// produced the frozen score. Without this, later code reading
    /// `analysisResult.trainingContext` would still see nil and recompute
    /// Tier 2 against stale frozen scores.
    ///
    /// Training readiness freezes alongside the score — same EWMA step logic
    /// as `ReanalysisService.computeFrozenReadiness`.
    private func applyFrozenScore(
        _ breakdown: RecoveryScoreCalculator.ScoreBreakdown,
        to session: inout HRVSession,
        training: TrainingContext?
    ) {
        let score = RecoveryScoreCalculator.toTenScale(breakdown.compositeScore)
        debugLog("[SessionAcceptanceService] Updating recovery score: \(session.recoveryScore.map { String(format: "%.1f", $0) } ?? "nil") → \(String(format: "%.1f", score)) (tier=\(breakdown.tier), trainingContext=\(training == nil ? "nil" : "present"))")
        session.recoveryScore = score
        session.scoreBreakdown = breakdown
        session.analysisResult?.trainingContext = training
        if session.trainingSnapshot == nil {
            session.trainingSnapshot = training
        }
        session.frozenReadiness = ReanalysisService.computeFrozenReadiness(
            compositeScore: breakdown.compositeScore,
            trainingContext: training
        )
        debugLog("[SessionAcceptanceService] Frozen readiness: \(String(format: "%.1f", session.frozenReadiness ?? 0))")
    }

    /// Export to Apple Health if enabled (fire-and-forget, non-blocking).
    /// Deliberately untracked — the session is already
    /// persisted to the local archive at this point; these post-save
    /// mirrorings should finish even if the user dismisses the post-summary
    /// view. Cancellation here would lose the HealthKit row, which is the
    /// OPPOSITE of what the user wants.
    private func exportToHealthIfEnabled(_ session: HRVSession, enabled: Bool) {
        guard enabled else { return }
        let exportSession = session
        let hk = healthKit
        Task {
            do {
                try await hk.exportSessionMetrics(from: exportSession)
            } catch {
                debugLog("[SessionAcceptanceService] HealthKit export failed: \(error.localizedDescription)")
            }
        }
    }

    /// Sync to iCloud (fire-and-forget) and clean up the live backup. Same
    /// intentional-untracked rationale as the HealthKit export above.
    private func syncToCloud(_ session: HRVSession) {
        let sessionId = session.id
        let cloudSync = onCloudSync
        let cloudDelete = onCloudDelete
        Task {
            await cloudSync(session)
            await cloudDelete(sessionId)
        }
    }

    // MARK: - Update Composite Recovery Score

    /// Recompute and re-archive the composite recovery score for an already-archived session.
    /// Also snapshots sleep and vitals data so the dashboard stays stable.
    ///
    /// Called when dismissing results for already-archived sessions (e.g., streaming/quick).
    ///
    /// - Parameter exportMetrics: When `true`, exports the final metrics to Apple Health
    ///   (if the user has HealthKit export enabled).
    /// - Returns: `true` if the archive was successfully updated.
    @discardableResult
    func updateCompositeRecoveryScore(
        for session: HRVSession,
        scoringConfig: RecoveryScoreCalculator.ScoringConfiguration,
        trainingContext: TrainingContext?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        typicalSleepHours: Double,
        sleepSchedule: SleepSchedule,
        exportMetrics: Bool = false,
        enableHealthKitExport: Bool = false
    ) async -> Bool {
        guard let result = session.analysisResult else { return false }
        var updated = session
        let inputs = AcceptanceInputs(
            scoringConfig: scoringConfig, trainingContext: trainingContext,
            baselineStats: baselineStats, typicalSleepHours: typicalSleepHours,
            sleepSchedule: sleepSchedule
        )
        await refreshHealthSnapshots(on: &updated, result: result, sleepSchedule: sleepSchedule)
        let breakdown = scoreBreakdown(
            result: result, session: updated, inputs: inputs,
            training: trainingContext, useBaselineHRV: false
        )
        debugLog("[SessionAcceptanceService] Updating archived recovery score for \(session.id.uuidString.prefix(8)): \(session.recoveryScore.map { String(format: "%.1f", $0) } ?? "nil") → \(String(format: "%.1f", RecoveryScoreCalculator.toTenScale(breakdown.compositeScore)))")
        applyFrozenScore(breakdown, to: &updated, training: trainingContext)
        guard reArchive(updated) else { return false }
        exportToHealthIfEnabled(updated, enabled: exportMetrics && enableHealthKitExport)
        return true
    }

    private func reArchive(_ updated: HRVSession) -> Bool {
        do {
            try archive.archive(updated)
            return true
        } catch {
            debugLog("[SessionAcceptanceService] Failed to re-archive with updated score: \(error)")
            return false
        }
    }

    /// Fetch and snapshot sleep + vitals for an already-archived session.
    /// Unlike the acceptance path this doesn't race a timeout — the caller is
    /// a background refresh, not a user waiting on a save.
    ///
    /// Strap-RHR override: see `snapshotHealthData`.
    private func refreshHealthSnapshots(
        on session: inout HRVSession, result: HRVAnalysisResult, sleepSchedule: SleepSchedule
    ) async {
        let sessionEnd = session.endDate ?? session.startDate
        let (fetchStart, fetchEnd) = sleepFetchRange(
            for: session, sessionEnd: sessionEnd, sleepSchedule: sleepSchedule
        )
        let sleepData: SleepData?
        do {
            sleepData = try await healthKit.fetchSleepData(
                for: fetchStart, recordingEnd: fetchEnd, rrPoints: session.rrSeries?.points
            )
        } catch {
            debugLog("[SessionAcceptanceService] Sleep fetch failed during score update: \(error)")
            sleepData = nil
        }
        session.sleepSnapshot = sleepData
        session.vitalsSnapshot = await healthKit.fetchRecoveryVitals(relativeTo: sessionEnd)
            .withStrapNocturnalRHR(result.timeDomain.meanHR)
    }

    // MARK: - Reject Session

    /// Rejects the current session — discards without archiving and cleans up CloudKit.
    ///
    /// - Parameters:
    ///   - sessionId: The ID of the session to reject (for CloudKit cleanup).
    ///   - clearPersistedRecordingState: Callback to clear RRCollector's persisted state.
    func processRejection(
        sessionId: UUID?,
        clearPersistedRecordingState: () -> Void
    ) async {
        onDiscardExercise()

        // Clear persisted recording state - user explicitly rejected
        clearPersistedRecordingState()

        // Clean up live backup from iCloud
        if let sessionId {
            let cloudDelete = onCloudDelete
            Task { await cloudDelete(sessionId) }
        }
    }

    // MARK: - Sleep Fetch Range Helper

    /// Expand the sleep fetch range to capture all sleep from this night.
    ///
    /// Covers three scenarios:
    /// 1. Linked sessions (pause/resume split-night): expand to include all segments.
    /// 2. Unlinked split sleep (user went back to sleep tracked by Apple Watch only):
    ///    extend the end to the morning cutoff so HealthKit returns later segments.
    /// 3. Normal single-segment: end stays at session end (morning cutoff is usually later).
    ///
    /// This ensures the frozen sleepSnapshot captures the FULL night's sleep,
    /// not just the recording window.
    func sleepFetchRange(
        for session: HRVSession,
        sessionEnd _: Date,
        sleepSchedule: SleepSchedule
    ) -> (start: Date, end: Date) {
        // Sleep is about the recovery window, not the recording session.
        // Always use the full overnight window so any session type
        // (overnight, quick reading, streaming) captures last night's sleep.
        let referenceDate = session.startDate
        let start = sleepSchedule.overnightWindowStart(relativeTo: referenceDate)
        let end = sleepSchedule.morningCutoff(relativeTo: referenceDate)

        return (start, end)
    }
}
