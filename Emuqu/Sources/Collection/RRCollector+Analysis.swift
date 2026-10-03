import Foundation

// MARK: - Analysis Helpers

extension MorningSessionPipeline {
    // MARK: - Recovery Score

    /// Compute composite recovery score for archival (0-10 scale).
    /// Fetches sleep data, training context, and vitals to match the full composite
    /// score shown on the results screen (RecoveryScoreCalculator.calculate).
    /// Returns both the score and the full breakdown so callers can freeze the
    /// breakdown alongside the score.
    ///
    /// The snapshots are returned too so the caller can persist
    /// them onto the session. If this function fetched sleep + vitals,
    /// used them to score, and threw them away, SessionRecoveryService
    /// would archive the session with `sleepSnapshot=nil` even though it had
    /// just scored at tier 3 with real sleep data. The dashboard then re-renders
    /// the breakdown live, reads nil sleepSnapshot, and drops to tier 1.
    /// User-visible: score 9.75 in the headline, tier-1 factors in the detail
    /// view, within seconds of being archived.
    func computeRecoveryScore(for session: HRVSession, from analysisResult: HRVAnalysisResult?) async -> RecoveryScoreOutcome? {
        guard let result = analysisResult else { return nil }
        let sessionEnd = session.endDate ?? session.startDate
        let snapshots = await recoverySnapshots(for: session, result: result, sessionEnd: sessionEnd)
        let training = await scoringTrainingContext(result: result, sessionEnd: sessionEnd)
        let breakdown = RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: result.ansMetrics?.readinessScore, rmssd: result.timeDomain.rmssd,
                meanHR: result.timeDomain.meanHR, dfaAlpha1: result.nonlinear.dfaAlpha1,
                baselineStats: collector.scoringBaselineStats(for: session), sleepData: snapshots.sleep,
                vitals: snapshots.vitals, typicalSleepHours: collector.settingsManager.settings.typicalSleepHours
            ),
            trainingContext: training,
            config: collector.currentScoringConfig,
            ansBalance: Self.ansBalance(result)
        )
        return RecoveryScoreOutcome(
            score: RecoveryScoreCalculator.toTenScale(breakdown.compositeScore),
            breakdown: breakdown,
            sleepSnapshot: snapshots.sleep, vitalsSnapshot: snapshots.vitals
        )
    }

    /// The analysis result's own training context, else the load as of the
    /// session's end — fetched for a past day rather than read from today's cache.
    private func scoringTrainingContext(result: HRVAnalysisResult, sessionEnd: Date) async -> TrainingContext? {
        if let frozen = result.trainingContext { return frozen }
        return await collector.createTrainingContextEnsuringFresh(relativeTo: sessionEnd)
    }

    /// Use frozen morning snapshots when available so the recovery score stays
    /// stable after acceptance (e.g. during reanalysis). Only fetch fresh
    /// HealthKit data when no snapshots exist yet.
    ///
    /// Strap-RHR override: see
    /// `RecoveryVitals.withStrapNocturnalRHR`. The analysis-window mean HR is
    /// already nocturnal-strap-derived; swapping it for HealthKit's daytime RHR
    /// makes the comparison against `meanHRBaseline` physiologically
    /// self-consistent.
    private func recoverySnapshots(
        for session: HRVSession,
        result: HRVAnalysisResult,
        sessionEnd: Date
    ) async -> (sleep: SleepData?, vitals: RecoveryVitals?) {
        if let frozenSleep = session.sleepSnapshot {
            return (frozenSleep, session.vitalsSnapshot)
        }
        let sleepData = try? await collector.healthKit.fetchSleepData(
            for: session.startDate,
            recordingEnd: sessionEnd,
            rrPoints: session.rrSeries?.points
        )
        let vitals = await collector.healthKit.fetchRecoveryVitals(relativeTo: sessionEnd)
            .withStrapNocturnalRHR(result.timeDomain.meanHR)
        return (sleepData, vitals)
    }

    private static func ansBalance(_ result: HRVAnalysisResult) -> Double? {
        guard let pns = result.ansMetrics?.pnsIndex, let sns = result.ansMetrics?.snsIndex else { return nil }
        return pns - sns
    }

    // MARK: - Analysis (delegates to HRVAnalysisPipeline)

    /// Analyze session using provided window
    func analyze(_ session: HRVSession, window: WindowSelector.RecoveryWindow, flags: [ArtifactFlags], peakCapacity: PeakCapacity? = nil) async -> HRVAnalysisResult? {
        let sessionDate = session.endDate ?? session.startDate
        return await collector.analysisPipeline.analyzeWithWindow(
            session: session,
            window: window,
            flags: flags,
            peakCapacity: peakCapacity,
            trainingContext: await collector.createTrainingContextEnsuringFresh(relativeTo: sessionDate),
            ansConfig: collector.ansConfig(asOf: sessionDate)
        )
    }

    /// Analyze full session when no organized recovery window detected
    func analyze(_ session: HRVSession, peakCapacity: PeakCapacity?) async -> HRVAnalysisResult? {
        let sessionDate = session.endDate ?? session.startDate
        return await collector.analysisPipeline.analyzeFullSession(
            session: session,
            peakCapacity: peakCapacity,
            trainingContext: await collector.createTrainingContextEnsuringFresh(relativeTo: sessionDate),
            ansConfig: collector.ansConfig(asOf: sessionDate)
        )
    }

    /// Fallback: analyze session with automatic window selection
    func analyze(_ session: HRVSession) async -> HRVAnalysisResult? {
        let boundaries = await resolvedSleepBoundaries(session)
        let sessionDate = session.endDate ?? session.startDate
        return await collector.analysisPipeline.analyzeWithAutoWindow(
            session: session,
            sleepStartMs: boundaries.sleepStartMs,
            wakeTimeMs: boundaries.wakeTimeMs,
            trainingContext: await collector.createTrainingContextEnsuringFresh(relativeTo: sessionDate),
            ansConfig: collector.ansConfig(asOf: sessionDate),
            // Pass the same baseline the scorer uses so window selection
            // agrees with scoring — no more "higher-RMSSD window scores lower"
            // mismatch.
            baselineStats: collector.scoringBaselineStats(for: session)
        )
    }

    /// Sleep bounds for auto-window selection. A session that never recorded an
    /// end date has no window to resolve against, so both come back nil.
    private func resolvedSleepBoundaries(_ session: HRVSession) async -> (sleepStartMs: Int64?, wakeTimeMs: Int64?) {
        guard let endDate = session.endDate else { return (nil, nil) }
        let boundaries = await collector.sleepBoundaryResolver.resolve(
            sessionStart: session.startDate,
            recordingEnd: endDate
        )
        return (boundaries.sleepStartMs, boundaries.wakeTimeMs)
    }
}

/// The four values a recovery-score computation yields.
///
/// Was a 4-tuple, which tripped `large_tuple` at every declaration site the
/// closure travelled through (SessionRecoveryService takes it as a parameter
/// in two places). Naming it keeps those signatures readable and the field
/// names identical, so every `.score` / `.breakdown` / `.sleepSnapshot` /
/// `.vitalsSnapshot` read at the call sites is unchanged.
struct RecoveryScoreOutcome {
    let score: Double
    let breakdown: RecoveryScoreCalculator.ScoreBreakdown
    let sleepSnapshot: SleepData?
    let vitalsSnapshot: RecoveryVitals?
}
