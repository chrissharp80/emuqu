import Foundation

// MARK: - Training Load Sub-Score

extension RecoveryScoreCalculator {
    // MARK: - Tier 3: Training Load Sub-Score

    /// Calculate training load sub-score from TSB with workload modifiers.
    /// Uses Banister impulse-response model: TSB = CTL(42d) - ATL(7d).
    ///
    /// Optimal TSB is around -5 (slightly fatigued — actively training).
    /// Positive TSB means recovering/tapering — this is GOOD and should be
    /// scored high, not penalized. Very negative TSB means overreaching.
    ///
    /// Uses an asymmetric Gaussian (Banister 1975, Morton 1990):
    /// - Positive TSB (resting): σ=35, drops gradually. TSB +20 → ~87.
    ///   Rest is recovery, not a problem.
    /// - Negative TSB (overloading): σ=20, drops faster. TSB -25 → ~78.
    ///   Overreaching carries real injury and maladaptation risk.
    ///
    /// Two workload modifiers are applied multiplicatively:
    ///
    /// 1. **ACWR modifier** — graded signal for load spikes (Gabbett 2016).
    ///    ACWR is a useful directional flag but has known limitations: it doesn't
    ///    distinguish planned periodization from unstructured spikes, and the
    ///    original "sweet spot" thresholds have been debated (Impellizzeri et al. 2020).
    ///    We use gradual ramps rather than hard cutoffs to reflect this nuance.
    ///
    /// 2. **Monotony/Strain modifier** — Foster (1998), Foster et al. (2001).
    ///    Monotony = mean(daily TRIMP) / SD(daily TRIMP) over 7 days. High monotony
    ///    (>2.0) means every day looks the same — the body never gets variation.
    ///    Strain = weekly TRIMP sum × Monotony. High strain with high monotony is
    ///    the classic overtraining pattern regardless of what ACWR says.
    ///
    /// - Parameters:
    ///   - tsb: Training Stress Balance (CTL - ATL)
    ///   - acuteChronicRatio: ACWR (ATL / CTL), optional
    ///   - monotony: Foster's Monotony (mean/SD of 7-day daily TRIMP), optional
    ///   - strain: Foster's Strain (7-day TRIMP sum × Monotony), optional
    /// - Returns: Training readiness score 0-100, or nil if no training data
    static func calculateTrainingScore(
        tsb: Double?,
        acuteChronicRatio: Double?,
        monotony: Double? = nil,
        strain: Double? = nil,
        ctl: Double? = nil,
        atl: Double? = nil,
        todayTrimp: Double = 0,
        recoveryScore: Double = 0
    ) -> Double? {
        if let ctl, ctl >= RecoveryScoreConstants.Readiness.ctlThreshold, let atl {
            let base = capacityReadinessForComposite(
                ctl: ctl, atl: atl, acuteChronicRatio: acuteChronicRatio,
                todayTrimp: todayTrimp, recoveryScore: recoveryScore
            )
            return min(100, max(0, base * monotonyDampener(monotony: monotony, strain: strain)))
        }
        guard let tsb else { return nil }
        let modifiers = acwrModifierForFallback(acuteChronicRatio: acuteChronicRatio)
            * monotonyDampener(monotony: monotony, strain: strain)
        return min(100, max(0, tsbGaussian(tsb) * modifiers))
    }

    /// Fallback for callers without CTL/ATL handy (tests, partial data paths).
    ///
    /// An asymmetric curve centred on optimal TSB = -5. Positive TSB
    /// (resting/recovering) drops off slowly — rest is good; negative TSB
    /// (overreaching) drops off faster — overtraining is dangerous.
    ///
    ///   σ_positive = 35 (gentle: TSB +20 → ~87, TSB +30 → ~72)
    ///   σ_negative = 20 (steep:  TSB -25 → ~78, TSB -40 → ~44)
    ///
    /// This matches the physiological reality: resting athletes recover and
    /// should be scored as ready. Only sustained heavy overtraining or
    /// prolonged detraining should meaningfully lower the training score.
    private static func tsbGaussian(_ tsb: Double) -> Double {
        let optimal: Double = -5.0
        let sigma: Double = tsb >= optimal ? 35.0 : 20.0
        return 100.0 * exp(-0.5 * pow((tsb - optimal) / sigma, 2))
    }

    // MARK: - Composite training-factor helpers
    //
    // Shared by `calculateTrainingScore`'s capacity-ratio path and the
    // TSB-Gaussian fallback so both use the same dampeners.

    /// Capacity-ratio readiness identical in spirit to
    /// `calculateReadiness` minus the recovery-modulation step. Returns
    /// 0–100 with bigger CTL → more capacity → higher score for the
    /// same absolute load.
    private static func capacityReadinessForComposite(
        ctl: Double,
        atl: Double,
        acuteChronicRatio: Double?,
        todayTrimp: Double,
        recoveryScore: Double = 0
    ) -> Double {
        let acuteFatigue = todayTrimp * RecoveryScoreConstants.Readiness.acuteFatigueFallbackCoefficient
        let base = readiness(forCapacityRatio: (atl + acuteFatigue) / ctl)
        let penalised = base * (1.0 - acwrPenaltyFraction(
            acuteChronicRatio: acuteChronicRatio, ctl: ctl, recoveryScore: recoveryScore
        ))
        return max(0, min(100, penalised))
    }

    /// The same piecewise mapping the readiness pill uses, lifted from
    /// `mapCapacityRatioToReadiness`. Inlined here so this stays a pure
    /// function with no cross-extension call assumptions.
    private static func readiness(forCapacityRatio capacityRatio: Double) -> Double {
        let r = RecoveryScoreConstants.Readiness.self
        guard capacityRatio > 0 else { return r.readinessAtZero }
        let breakpoints: [(ratio: Double, readiness: Double)] = [
            (0.0, r.readinessAtZero),
            (r.capacityRatioBreak1, r.readinessAtBreak1),
            (r.capacityRatioBreak2, r.readinessAtBreak2),
            (r.capacityRatioBreak3, r.readinessAtBreak3),
            (r.capacityRatioBreak4, r.readinessAtBreak4),
            (r.capacityRatioBreak5, r.readinessAtBreak5)
        ]
        // empty-range-ok: `breakpoints` is a literal table declared just above
        // with a fixed set of entries; it cannot be empty.
        for i in 1 ..< breakpoints.count where capacityRatio <= breakpoints[i].ratio {
            let prev = breakpoints[i - 1]
            let curr = breakpoints[i]
            let t = (capacityRatio - prev.ratio) / (curr.ratio - prev.ratio)
            return prev.readiness - t * (prev.readiness - curr.readiness)
        }
        return r.readinessAtBreak5
    }

    /// ACWR overreaching penalty, same threshold/slope as the readiness pill.
    ///
    /// Applies the same low-CTL confidence ramp and high-recovery
    /// autonomic-rescue cap as `applyACWRModifier`, so the composite training
    /// factor and the readiness pill don't disagree.
    private static func acwrPenaltyFraction(
        acuteChronicRatio: Double?,
        ctl: Double,
        recoveryScore: Double
    ) -> Double {
        let r = RecoveryScoreConstants.Readiness.self
        guard let acr = acuteChronicRatio, acr > r.acwrOverreachingThreshold else { return 0 }
        let excess = acr - r.acwrOverreachingThreshold
        var penaltyPct = min(
            r.acwrOverreachingPenaltyBase + excess * r.acwrOverreachingPenaltySlope,
            r.acwrOverreachingPenaltyCap
        )
        penaltyPct *= min(max(ctl, 0) / r.acwrFullConfidenceCTL, 1.0)
        if recoveryScore >= r.acwrRescueRecoveryThreshold {
            penaltyPct = min(penaltyPct, r.acwrPenaltyAutonomicRescueCap)
        }
        return penaltyPct
    }

    /// Foster's monotony / strain modifier shared by both the
    /// capacity-ratio path and the TSB-Gaussian fallback.
    private static func monotonyDampener(monotony: Double?, strain: Double?) -> Double {
        if let m = monotony, let s = strain {
            if m > RecoveryScoreConstants.Training.monotonyThreshold, s > RecoveryScoreConstants.Training.severeStrainThreshold {
                return RecoveryScoreConstants.Training.severeMonotonyModifier
            } else if m > RecoveryScoreConstants.Training.monotonyThreshold, s > RecoveryScoreConstants.Training.moderateStrainThreshold {
                return RecoveryScoreConstants.Training.moderateMonotonyModifier
            } else if m > RecoveryScoreConstants.Training.monotonyThreshold {
                return RecoveryScoreConstants.Training.mildMonotonyModifier
            }
        }
        return 1.0
    }

    /// Original TSB-Gaussian path's ACWR modifier — kept for the
    /// fallback path only. The capacity-ratio path applies its own
    /// ACWR penalty inline (matching `calculateReadiness`).
    private static func acwrModifierForFallback(acuteChronicRatio: Double?) -> Double {
        guard let acr = acuteChronicRatio else { return 1.0 }
        if acr >= TrainingConstants.ACR.detraining, acr <= TrainingConstants.ACR.building {
            return 1.0
        } else if acr > TrainingConstants.ACR.building, acr <= TrainingConstants.ACR.overreaching {
            return 1.0 - (acr - TrainingConstants.ACR.building) * TrainingConstants.ACWRRamp.overreachingSlope
        } else if acr > TrainingConstants.ACR.overreaching {
            return max(
                TrainingConstants.ACWRRamp.heavyOverreachingFloor,
                TrainingConstants.ACWRRamp.detrainingFloor - (acr - TrainingConstants.ACR.overreaching) * TrainingConstants.ACWRRamp.heavyOverreachingSlope
            )
        }
        return max(
            TrainingConstants.ACWRRamp.detrainingFloor,
            1.0 - (TrainingConstants.ACR.detraining - acr) * TrainingConstants.ACWRRamp.detrainingSlope
        )
    }

    // MARK: - Foster's Monotony & Strain

    /// Calculate Foster's Monotony and Strain from daily TRIMP values.
    /// Monotony = mean(daily load) / SD(daily load) over 7 days.
    /// Strain = sum(daily load) × Monotony.
    ///
    /// High monotony (>2.0) means little day-to-day variation — every session
    /// looks the same. When combined with high total strain, this is the classic
    /// predictor of illness and maladaptation (Foster 1998).
    ///
    /// - Parameters:
    ///   - dailyTrimp: Dictionary mapping dates to daily TRIMP values
    ///   - referenceDate: The "today" anchor for the trailing 7-day window.
    ///     Defaults to `Date()` so existing callers are unaffected; passing
    ///     an explicit value makes the window deterministic (testability,
    ///     replaying a historical day) instead of reading the wall clock.
    /// - Returns: Tuple of (monotony, strain), or nil if fewer than 7 days of data
    static func fosterMonotonyStrain(
        dailyTrimp: [Date: Double],
        referenceDate: Date = Date()
    ) -> (monotony: Double, strain: Double)? {
        // Need 7 consecutive recent days for a meaningful calculation.
        // `Calendar.date(byAdding:)` can return nil at calendar discontinuities
        // (DST shifts, minority-calendar leap-month edges); compactMap + a count
        // check keeps this safe on those edges and returns nil rather than
        // crashing.
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceDate)
        let last7 = (0 ..< 7).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        guard last7.count == 7 else { return nil }
        let values = last7.map { dailyTrimp[$0] ?? 0.0 }
        let sum = values.reduce(0, +)
        guard sum > 0 else { return nil } // No training at all — nothing to compute
        let monotony = cappedMonotony(of: values, sum: sum)
        return (monotony: monotony, strain: sum * monotony)
    }

    /// Guards against division by zero: with every day identical the SD is 0 and
    /// monotony is theoretically infinite. The cap must ALSO apply when the SD
    /// is small-but-nonzero (e.g. six 50-TRIMP days plus one 50.01), which
    /// otherwise yields monotony in the thousands and trips the severe-strain
    /// dampener on a perfectly normal week. So both branches are capped,
    /// not just the SD == 0 case.
    ///
    /// The window length is taken from `values`, not a
    /// literal 7. A literal would be correct because the only caller guards
    /// `last7.count == 7`, but the spec asks for illegal states to be
    /// unrepresentable and a helper that takes an arbitrary array and divides
    /// by a constant is the shape that violates it: a second caller with a
    /// 14-day window would get a silently wrong monotony.
    private static func cappedMonotony(of values: [Double], sum: Double) -> Double {
        let days = Double(values.count)
        guard days > 0 else { return RecoveryScoreConstants.Training.monotonyCap }
        let mean = sum / days
        let sd = sqrt(values.map { pow($0 - mean, 2) }.reduce(0, +) / days)
        let rawMonotony = sd > 0 ? mean / sd : RecoveryScoreConstants.Training.monotonyCap
        return min(rawMonotony, RecoveryScoreConstants.Training.monotonyCap)
    }
}
