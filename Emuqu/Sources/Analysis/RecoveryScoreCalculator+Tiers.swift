import Foundation

// The per-tier sub-scores: the individual factor computations that the z-score
// mapping and tier composition in `RecoveryScoreCalculator.swift` combine.

extension RecoveryScoreCalculator {
    // MARK: - Tier 1: HRV Recovery Score

    /// Calculate HRV-only recovery score from the ln(RMSSD) z-score against the baseline
    /// - Parameters:
    ///   - rmssd: Today's RMSSD value (ms)
    ///   - meanHR: Today's mean heart rate (bpm), optional for RHR adjustment
    ///   - dfaAlpha1: Today's DFA α1 value, optional for fractal organization check
    ///   - baselineStats: 60-day rolling baseline statistics from BaselineTracker
    ///   - readiness: Legacy readiness score (1-10) as fallback when no baseline exists
    ///   - referenceDate: "Now" for the baseline-staleness penalty; injected so
    ///     the score is deterministic (defaults to the wall clock)
    /// - Returns: HRV recovery score 0-100
    static func calculateTier1(
        rmssd: Double,
        meanHR: Double?,
        dfaAlpha1: Double?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        readiness: Double?,
        ansBalance: Double? = nil,
        referenceDate: Date = Date()
    ) -> Double {
        if let stats = baselineStats, rmssd > 0 {
            return min(100, max(0, baselineNormalisedScore(
                rmssd: rmssd, meanHR: meanHR, dfaAlpha1: dfaAlpha1,
                stats: stats, ansBalance: ansBalance, referenceDate: referenceDate
            )))
        }
        // With fewer than 3 days of baseline data (no stats yet), fall back to the legacy readiness
        // score (1-10 → 10-100), then to absolute RMSSD thresholds.
        if let readinessScore = readiness { return min(100, max(0, readinessScore * 10)) }
        guard rmssd > 0 else { return RecoveryScoreConstants.AbsoluteRMSSDFallback.neutralScore }
        return min(100, max(0, absoluteRMSSDScore(rmssd)))
    }

    /// Primary path: ln(RMSSD) z-score normalization (Plews/Buchheit), then the
    /// four independent adjustments.
    private static func baselineNormalisedScore(
        rmssd: Double,
        meanHR: Double?,
        dfaAlpha1: Double?,
        stats: BaselineTracker.RecoveryBaselineStats,
        ansBalance: Double?,
        referenceDate: Date
    ) -> Double {
        // Map z-score to 0-100 via the SWC band model: z in [-0.5, +0.5] → 72
        // (at baseline = recovered), asymmetric drop below, plateau above
        // (above-baseline is ambiguous per the research).
        var score = zToRecoveryScore((log(rmssd) - stats.lnRmssdMean) / stats.lnRmssdSD)
        score += rhrAdjustment(meanHR: meanHR, stats: stats)
        score += dfaAlpha1Adjustment(dfaAlpha1)
        // Reduced day-to-day variability signals overreaching (Plews); excessive
        // variability signals instability. Deductions only.
        score += cvAdjustment(stats.lnRmssdCV7Day)
        score += ansBalanceAdjustment(ansBalance)
        score -= stalenessPenalty(stats: stats, referenceDate: referenceDate)
        return score
    }

    /// Elevated resting HR independent of RMSSD suggests incomplete recovery,
    /// worth ±10 points. Inverted: higher HR = worse recovery.
    private static func rhrAdjustment(meanHR: Double?, stats: BaselineTracker.RecoveryBaselineStats) -> Double {
        guard let hr = meanHR else { return 0 }
        let zHR = (hr - stats.meanHRBaseline) / stats.meanHRSD
        return max(
            RecoveryScoreConstants.HRVAdjustments.rhrClampMin,
            min(RecoveryScoreConstants.HRVAdjustments.rhrClampMax, zHR * RecoveryScoreConstants.HRVAdjustments.rhrZScoreMultiplier)
        )
    }

    /// After 7+ days without a session the baseline is increasingly unreliable,
    /// so the score is penalized to reflect reduced confidence — the z-score
    /// comparison is against stale data that may no longer represent current
    /// physiology.
    private static func stalenessPenalty(
        stats: BaselineTracker.RecoveryBaselineStats,
        referenceDate: Date
    ) -> Double {
        guard let lastDate = stats.lastDataPointDate else { return 0 }
        let daysSince = baselineStalenessDays(baselineDate: lastDate, referenceDate: referenceDate)
        guard daysSince >= RecoveryScoreConstants.BaselineStaleness.staleAfterDays else { return 0 }
        let weeksStale = Double(daysSince - RecoveryScoreConstants.BaselineStaleness.staleAfterDays) / 7.0
        return min(
            RecoveryScoreConstants.BaselineStaleness.maxPenalty,
            RecoveryScoreConstants.BaselineStaleness.penaltyPerWeek * (1.0 + weeksStale)
        )
    }

    /// Last resort: absolute RMSSD thresholds, with no baseline and no readiness.
    private static func absoluteRMSSDScore(_ rmssd: Double) -> Double {
        let fallback = RecoveryScoreConstants.AbsoluteRMSSDFallback.self
        if rmssd >= fallback.threshold1 { return fallback.score1 }
        if rmssd >= fallback.threshold2 { return fallback.score2 }
        if rmssd >= fallback.threshold3 { return fallback.score3 }
        if rmssd >= fallback.threshold4 { return fallback.score4 }
        return fallback.scoreBelow
    }

    // MARK: - Tier 2: Sleep Sub-Score

    /// Calculate sleep quality sub-score from HealthKit sleep data.
    /// Uses SleepScienceAnalyzer's enhanced score (incorporating fragmentation, cycles,
    /// architecture, and age-adjusted norms) when stage data is available.
    /// Falls back to basic weighted formula when stage data is missing.
    ///
    /// - Parameters:
    ///   - sleepData: HealthKit sleep data
    ///   - typicalSleepHours: User's typical sleep duration for comparison
    /// - Returns: Sleep quality score 0-100, or nil if no sleep data
    static func calculateSleepScore(
        sleepData: SleepData?,
        typicalSleepHours: Double,
        userAge: Int?
    ) -> Double? {
        guard let sleep = sleepData else { return nil }
        if let analysis = SleepScienceAnalyzer.analyze(
            sleepData: sleep, userAge: userAge, typicalSleepHours: typicalSleepHours
        ) {
            return analysis.enhancedScore
        }
        return basicSleepScore(sleep, typicalSleepHours: typicalSleepHours)
    }

    /// Basic weighted formula for when stage data is missing.
    ///
    /// Duration uses 24h sleep (night + qualifying daytime nap); the deep/REM
    /// proportions stay night-only, since a nap is a separate episode and not
    /// part of this night's architecture.
    ///
    /// ## Its stage branch is currently unreachable
    ///
    /// Found by mutation testing: swapping the deep/REM weights (M13) and
    /// removing the `stageRatio` cap (M12) both left the whole suite green, and
    /// the reason is not a missing test.
    ///
    /// `calculateSleepScore` reaches this function only when
    /// `SleepScienceAnalyzer.analyze` returns nil, and its only nil condition is
    /// `nightSleepMinutes <= 0`. `nightSleepMinutes` IS `totalSleepMinutes`. So
    /// whenever this function runs, `sleep.nightSleepMinutes` is zero — and
    /// `stageRatio` guards `nightMinutes > 0` and returns its neutral 0.5
    /// before either the target division or the cap can matter. The deep/REM
    /// weights, their targets, and the cap therefore have no effect on any
    /// score the app can produce.
    ///
    /// The selection is the bug, not the arithmetic: `calculateSleepScore`'s own
    /// doc says "falls back to basic weighted formula when STAGE DATA is
    /// missing", and `analyze` returns non-nil for a night with no stage data at
    /// all (it sets `architecture = .unknown` and carries on). Making the
    /// fallback reachable as documented would change the score for every user
    /// whose watch reports duration but not stages, which is a product decision
    /// and a re-tune, not a formatting fix. Left alone deliberately; recorded
    /// here so the next reader does not spend an afternoon testing arithmetic
    /// that cannot execute.
    private static func basicSleepScore(
        _ sleep: SleepData,
        typicalSleepHours: Double
    ) -> Double {
        let sleepHours = Double(sleep.totalSleepIncludingNapMinutes) / 60.0
        let durationRatio = min(sleepHours / max(typicalSleepHours, 1.0), 1.2)
        // Unmeasured efficiency (passive Watch HR estimate) is neutral 0.5, like an unrecorded stage.
        let efficiency = sleep.measuredSleepEfficiency.map { min($0, 100.0) / 100.0 } ?? 0.5
        let deepRatio = stageRatio(
            sleep.deepSleepMinutes, of: sleep.nightSleepMinutes,
            target: ScoringWeights.Sleep.deepSleepTargetProportion
        )
        let remRatio = stageRatio(
            sleep.remSleepMinutes, of: sleep.nightSleepMinutes,
            target: ScoringWeights.Sleep.remSleepTargetProportion
        )
        let sleepScore = (durationRatio * ScoringWeights.Sleep.duration
            + efficiency * ScoringWeights.Sleep.efficiency
            + deepRatio * ScoringWeights.Sleep.deepSleep
            + remRatio * ScoringWeights.Sleep.remSleep) * 100.0
        return min(ScoringBounds.maxScore, max(ScoringBounds.minScore, sleepScore))
    }

    /// A stage's share of the night against its target proportion, capped at 1.
    /// Neutral 0.5 when the stage wasn't recorded — absence is not a deficit.
    private static func stageRatio(_ stageMinutes: Int?, of nightMinutes: Int, target: Double) -> Double {
        guard let stageMinutes, nightMinutes > 0 else { return 0.5 }
        return min((Double(stageMinutes) / Double(nightMinutes)) / target, 1.0)
    }

    // MARK: - Tier 1 adjustments
    //
    // One function per physiological input. Each returns the points it
    // contributes, so `calculateTier1` reads as the sum of its adjustments
    // rather than as a single accumulating branch tree.

    /// DFA α1: ±5 points, against the app's resting reference range
    /// (0.75–1.0). Values above it are more correlated than the reference
    /// range; values below it, less. Both are treated as small deductions.
    ///
    /// Not "physiologically optimal", and a value outside the band is not a
    /// marker of pathology: the reasoning behind a score is held to the same
    /// standard as the copy that explains it (`Tools/copy_linter`), and an
    /// unvalidated band does not become a diagnosis because it is written in
    /// a comment.
    ///
    /// The band itself is a product convention, not a validated readiness
    /// scale: the published 0.75 anchor comes from graded-exercise protocols,
    /// and this app's own sleep classifier puts deep sleep at α1 0.5–0.7. See
    /// `HelpScienceCatalog.dfaExplainedSections` for the full note.
    ///
    /// The ±5 stays as it is. There is no better-evidenced number
    /// to move it to, and moving it would rewrite every user's score history
    /// on no evidence at all.
    private static func dfaAlpha1Adjustment(_ dfaAlpha1: Double?) -> Double {
        guard let a1 = dfaAlpha1 else { return 0 }
        if a1 >= HRVThresholds.dfaAlpha1OptimalLower, a1 <= HRVThresholds.dfaAlpha1OptimalUpper {
            return RecoveryScoreConstants.HRVAdjustments.dfaOptimalBonus
        }
        if a1 > HRVThresholds.dfaAlpha1Fatigue {
            return RecoveryScoreConstants.HRVAdjustments.dfaFatiguePenalty
        }
        if a1 < HRVThresholds.dfaAlpha1FlexibleLower {
            return RecoveryScoreConstants.HRVAdjustments.dfaIrregularPenalty
        }
        return 0
    }

    /// 7-day coefficient of variation: deductions only. Suspiciously flat
    /// day-to-day variability signals overreaching (Plews); excessive
    /// variability signals instability.
    private static func cvAdjustment(_ cv7Day: Double?) -> Double {
        guard let cv = cv7Day else { return 0 }
        if cv < RecoveryScoreConstants.HRVAdjustments.cvFlatThreshold {
            return RecoveryScoreConstants.HRVAdjustments.cvFlatPenalty
        }
        if cv > RecoveryScoreConstants.HRVAdjustments.cvErraticThreshold {
            return RecoveryScoreConstants.HRVAdjustments.cvErraticPenalty
        }
        return 0
    }

    /// ANS balance (PNS − SNS). Kubios indices (Tarvainen et al. 2014) are
    /// z-scores against Nunan et al. 2010 population norms. When the composite
    /// shows sympathetic dominance that RMSSD alone misses — elevated stress
    /// index, low pNN50, compressed Poincaré geometry — pull the score down.
    ///
    /// The ±0.5 deadband absorbs measurement noise: small deviations from the
    /// population mean are not actionable, and scoring them would make the
    /// number twitch for no reason the user could act on.
    static func ansBalanceAdjustment(_ ansBalance: Double?) -> Double {
        guard let bal = ansBalance else { return 0 }
        if bal < RecoveryScoreConstants.HRVAdjustments.ansStrongSympathetic {
            return RecoveryScoreConstants.HRVAdjustments.ansStrongSympPenalty
        }
        if bal < RecoveryScoreConstants.HRVAdjustments.ansMildSympathetic {
            return RecoveryScoreConstants.HRVAdjustments.ansMildSympPenalty
        }
        if bal >= RecoveryScoreConstants.HRVAdjustments.ansStrongParasympathetic {
            return RecoveryScoreConstants.HRVAdjustments.ansStrongParaBonus
        }
        return 0
    }

}
