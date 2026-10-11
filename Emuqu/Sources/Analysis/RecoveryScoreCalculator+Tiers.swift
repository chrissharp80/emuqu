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
        score += dfaAlpha1Adjustment(dfaAlpha1)?.points ?? 0
        // Reduced day-to-day variability signals overreaching (Plews); excessive
        // variability signals instability. Deductions only.
        score += cvAdjustment(stats.lnRmssdCV7Day)?.points ?? 0
        score += ansBalanceAdjustment(ansBalance)
        score -= baselineStaleness(stats: stats, referenceDate: referenceDate)?.penalty ?? 0
        return score
    }

    /// Elevated resting HR independent of RMSSD suggests incomplete recovery,
    /// worth ±10 points. Inverted: higher HR = worse recovery.
    ///
    /// Each Tier-1 adjustment below is the one place its arithmetic lives:
    /// `ScoreDetailBuilder` reads these to write the shown adjustments, so the
    /// detail line cannot drift from the score.
    static func rhrAdjustment(meanHR: Double?, stats: BaselineTracker.RecoveryBaselineStats) -> Double {
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
    /// physiology. Nil when the baseline is not stale (or has no last date);
    /// otherwise its age in days and the points deducted.
    static func baselineStaleness(
        stats: BaselineTracker.RecoveryBaselineStats,
        referenceDate: Date
    ) -> (days: Int, penalty: Double)? {
        guard let lastDate = stats.lastDataPointDate else { return nil }
        let daysSince = baselineStalenessDays(baselineDate: lastDate, referenceDate: referenceDate)
        guard daysSince >= RecoveryScoreConstants.BaselineStaleness.staleAfterDays else { return nil }
        let weeksStale = Double(daysSince - RecoveryScoreConstants.BaselineStaleness.staleAfterDays) / 7.0
        let penalty = min(
            RecoveryScoreConstants.BaselineStaleness.maxPenalty,
            RecoveryScoreConstants.BaselineStaleness.penaltyPerWeek * (1.0 + weeksStale)
        )
        return (daysSince, penalty)
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
    ///
    /// Every night with sleep minutes, staged or not, is scored by
    /// `SleepScienceAnalyzer`'s enhanced score (fragmentation, cycles,
    /// architecture, age-adjusted norms), which gives neutral half credit to
    /// whatever the night did not measure. `analyze` returns nil only for a
    /// night with no sleep minutes; that night gets `zeroMinuteNightScore`.
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
        return zeroMinuteNightScore(sleep, typicalSleepHours: typicalSleepHours)
    }

    /// The sleep sub-score for a night with no sleep minutes — the only
    /// night `SleepScienceAnalyzer.analyze` declines.
    ///
    /// Duration uses 24h sleep, so a qualifying daytime nap still counts.
    /// Efficiency is the measured value (neutral 0.5 when unmeasured). With
    /// no night minutes there is no deep or REM share to score, so both take
    /// the neutral 0.5 an unrecorded stage gets.
    ///
    /// This replaced a "basic weighted formula" whose deep/REM share branch
    /// could never run here (mutation testing found swapping its weights left
    /// every test green): the share always fell back to 0.5 for a zero-minute
    /// night. The arithmetic is unchanged; it now says what it does.
    private static func zeroMinuteNightScore(
        _ sleep: SleepData,
        typicalSleepHours: Double
    ) -> Double {
        let sleepHours = Double(sleep.totalSleepIncludingNapMinutes) / 60.0
        let durationRatio = min(sleepHours / max(typicalSleepHours, 1.0), 1.2)
        // Unmeasured efficiency (passive Watch HR estimate) is neutral 0.5, like an unrecorded stage.
        let efficiency = sleep.measuredSleepEfficiency.map { min($0, 100.0) / 100.0 } ?? 0.5
        let neutralStageShare = 0.5
        let sleepScore = (durationRatio * ScoringWeights.Sleep.duration
            + efficiency * ScoringWeights.Sleep.efficiency
            + neutralStageShare * ScoringWeights.Sleep.deepSleep
            + neutralStageShare * ScoringWeights.Sleep.remSleep) * 100.0
        return min(ScoringBounds.maxScore, max(ScoringBounds.minScore, sleepScore))
    }

    // MARK: - Tier 1 adjustments
    //
    // One function per physiological input. Each returns the points it
    // contributes, so `calculateTier1` reads as the sum of its adjustments
    // rather than as a single accumulating branch tree.

    /// DFA α1 against the app's resting reference range (0.75–1.0): inside
    /// it, `dfaOptimalBonus` (+5). Well above it (> `dfaAlpha1Fatigue`, 1.2),
    /// more correlated than the range, `dfaFatiguePenalty` (−5); well below it
    /// (< `dfaAlpha1FlexibleLower`, 0.60), less correlated, `dfaIrregularPenalty`
    /// (−3). The margins between (1.0–1.2 and 0.60–0.75) score nothing. Nil
    /// for no α1 or a neutral margin; otherwise the kind the detail line names
    /// and the points it adds.
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
    static func dfaAlpha1Adjustment(_ dfaAlpha1: Double?) -> (kind: ScoreFactorFacts.Adjustment, points: Double)? {
        guard let a1 = dfaAlpha1 else { return nil }
        if a1 >= HRVThresholds.dfaAlpha1OptimalLower, a1 <= HRVThresholds.dfaAlpha1OptimalUpper {
            return (.alphaBalanced, RecoveryScoreConstants.HRVAdjustments.dfaOptimalBonus)
        }
        if a1 > HRVThresholds.dfaAlpha1Fatigue {
            return (.alphaStrained, RecoveryScoreConstants.HRVAdjustments.dfaFatiguePenalty)
        }
        if a1 < HRVThresholds.dfaAlpha1FlexibleLower {
            return (.alphaReduced, RecoveryScoreConstants.HRVAdjustments.dfaIrregularPenalty)
        }
        return nil
    }

    /// 7-day coefficient of variation: deductions only. Suspiciously flat
    /// day-to-day variability signals overreaching (Plews); excessive
    /// variability signals instability. Nil for no CV or a CV in range.
    static func cvAdjustment(_ cv7Day: Double?) -> (kind: ScoreFactorFacts.Adjustment, points: Double)? {
        guard let cv = cv7Day else { return nil }
        if cv < RecoveryScoreConstants.HRVAdjustments.cvFlatThreshold {
            return (.variabilityFlat, RecoveryScoreConstants.HRVAdjustments.cvFlatPenalty)
        }
        if cv > RecoveryScoreConstants.HRVAdjustments.cvErraticThreshold {
            return (.variabilityErratic, RecoveryScoreConstants.HRVAdjustments.cvErraticPenalty)
        }
        return nil
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
