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
    /// Scored the way acceptance scores (`SessionAcceptanceService.scoreBreakdown`):
    /// the recording's HRV quality decides whether the baseline stands in, the
    /// user's perceived readiness is blended in, and staleness is measured from
    /// the night, not from now. A session recovered from backup used to freeze
    /// a score computed without any of the three.
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
        // The morning path's own fetch: frozen snapshots when the session has
        // them, else fresh sleep (with the previous day's nap credited, and a
        // failed fetch logged) and vitals with the strap's nocturnal RHR.
        let snapshots = await collector.morningProcessingService.scoringHealthData(for: session, result: result)
        let training = await scoringTrainingContext(result: result, sessionEnd: sessionEnd)
        let breakdown = scoreBreakdown(session: session, result: result, sleep: snapshots.sleep, vitals: snapshots.vitals, training: training)
        return RecoveryScoreOutcome(
            score: RecoveryScoreCalculator.toTenScale(breakdown.compositeScore),
            breakdown: breakdown,
            sleepSnapshot: snapshots.sleep, vitalsSnapshot: snapshots.vitals,
            trainingContext: training
        )
    }

    /// The composite breakdown with the acceptance path's inputs: baseline
    /// stand-in from `classifyHRVQuality`, perceived readiness, ANS balance,
    /// and the session's end as the reference date.
    private func scoreBreakdown(
        session: HRVSession, result: HRVAnalysisResult, sleep: SleepData?, vitals: RecoveryVitals?, training: TrainingContext?
    ) -> RecoveryScoreCalculator.ScoreBreakdown {
        let sessionEnd = session.endDate ?? session.startDate
        let baselineStats = collector.scoringBaselineStats(for: session)
        let quality = SessionAcceptanceService.classifyHRVQuality(
            result: result, sleepData: sleep, baselineStats: baselineStats,
            recordingStart: session.startDate, recordingEnd: sessionEnd
        )
        return RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: result.ansMetrics?.readinessScore, rmssd: result.timeDomain.rmssd,
                meanHR: result.timeDomain.meanHR, dfaAlpha1: result.nonlinear.dfaAlpha1,
                baselineStats: baselineStats, sleepData: sleep,
                vitals: vitals, typicalSleepHours: collector.settingsManager.settings.typicalSleepHours
            ),
            trainingContext: training, config: collector.currentScoringConfig,
            useBaselineHRV: quality.useBaselineHRV, perceivedReadiness: session.perceivedReadiness,
            ansBalance: ReanalysisService.ansBalance(of: result), referenceDate: sessionEnd
        )
    }

    /// The analysis result's own training context, else the load as of the
    /// session's end — fetched for a past day rather than read from today's
    /// cache. The archival score and acceptance (RRCollector+Acceptance) both
    /// use it.
    func scoringTrainingContext(result: HRVAnalysisResult?, sessionEnd: Date) async -> TrainingContext? {
        if let frozen = result?.trainingContext { return frozen }
        return await collector.createTrainingContextEnsuringFresh(relativeTo: sessionEnd)
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
            ansConfig: collector.ansConfig(for: session)
        )
    }

    /// Analyze full session when no organized recovery window detected
    func analyze(_ session: HRVSession, peakCapacity: PeakCapacity?) async -> HRVAnalysisResult? {
        let sessionDate = session.endDate ?? session.startDate
        return await collector.analysisPipeline.analyzeFullSession(
            session: session,
            peakCapacity: peakCapacity,
            trainingContext: await collector.createTrainingContextEnsuringFresh(relativeTo: sessionDate),
            ansConfig: collector.ansConfig(for: session)
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
            ansConfig: collector.ansConfig(for: session),
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

/// The values a recovery-score computation yields: the score, its breakdown,
/// and the sleep, vitals and training context it was scored with.
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
    /// The training context the score used: the result's own frozen one, or
    /// the fresh one fetched when the result had none.
    let trainingContext: TrainingContext?
}
