import Foundation

// MARK: - Recovery Score Calculator

/// Magic numbers extracted from RecoveryScoreCalculator and its extensions.
/// Grouped by the scoring stage they belong to.
enum RecoveryScoreConstants {
    // MARK: - Tier 1: HRV Adjustments

    enum HRVAdjustments {
        /// RHR z-score multiplier (inverted: higher HR = worse recovery).
        /// Design choice: ±10-point adjustment per 2 SD deviation from the
        /// 60-day baseline — matches the asymmetric recovery-score bands
        /// (z≈0 neutral, steep below) so a single signal can't swing the
        /// composite by more than ±10.
        static let rhrZScoreMultiplier: Double = -5.0
        /// RHR adjustment clamp minimum
        static let rhrClampMin: Double = -10.0
        /// RHR adjustment clamp maximum
        static let rhrClampMax: Double = 10.0

        /// Bonus for a resting DFA α1 inside the 0.75–1.0 reference range.
        /// The range is an app convention awaiting validation (science
        /// register `resting-dfa-a1-reference-band`): there is no published
        /// resting readiness band, the 0.75 anchor is an exercise finding,
        /// and published sleep α1 (N3 0.78 ± 0.21) straddles its floor.
        static let dfaOptimalBonus: Double = 5.0
        /// DFA α1 penalty for overly correlated / stress
        static let dfaFatiguePenalty: Double = -5.0
        /// DFA α1 penalty for anti-correlated / irregular
        static let dfaIrregularPenalty: Double = -3.0

        /// CV (coefficient of variation) of the 7-day rolling ln(RMSSD) is
        /// a recognized overreaching signal per Plews et al. 2012/2013 and
        /// Buchheit 2014 — but those papers don't specify the threshold
        /// numbers, they just state "persistently elevated" or "persistently
        /// reduced". The 2% / 12% cutoffs here are empirical design choices
        /// calibrated against HRV4Training / EliteHRV community data; a
        /// 2% flat-line signals suspicious uniformity (possible autonomic
        /// collapse) and 12% erratic signals unstable adaptation.
        /// Ref: Plews DJ et al. 2012 Eur J Appl Physiol 112(11):3729;
        ///      Buchheit M. 2014 Front Physiol 5:73.
        static let cvFlatThreshold: Double = 2.0
        static let cvErraticThreshold: Double = 12.0
        /// CV penalty for flat (overreaching/overtraining)
        static let cvFlatPenalty: Double = -5.0
        /// CV penalty for erratic (unstable recovery)
        static let cvErraticPenalty: Double = -3.0

        /// ANS Balance (PNS − SNS) thresholds and adjustments
        /// Kubios indices are z-scores (Tarvainen 2014 / Nunan 2010 norms).
        /// ±0.5 deadband absorbs measurement noise.
        /// Strong sympathetic dominance threshold (PNS − SNS)
        static let ansStrongSympathetic: Double = -1.5
        /// Mild sympathetic dominance threshold (outside deadband)
        static let ansMildSympathetic: Double = -0.5
        /// Strong parasympathetic dominance threshold
        static let ansStrongParasympathetic: Double = 1.5
        /// Penalty for strong sympathetic dominance
        static let ansStrongSympPenalty: Double = -6.0
        /// Penalty for mild sympathetic dominance
        static let ansMildSympPenalty: Double = -3.0
        /// Bonus for strong parasympathetic dominance
        static let ansStrongParaBonus: Double = 2.0
    }

    // MARK: - Baseline Staleness

    enum BaselineStaleness {
        /// Days without a session before the baseline is considered stale
        static let staleAfterDays: Int = 7
        /// Initial penalty applied once baseline goes stale
        static let penaltyPerWeek: Double = 5.0
        /// Maximum cumulative staleness penalty
        static let maxPenalty: Double = 20.0
    }

    // MARK: - Tier 1: Absolute RMSSD Fallbacks (no baseline, no readiness)

    enum AbsoluteRMSSDFallback {
        static let threshold1: Double = 60.0
        static let score1: Double = 85.0
        static let threshold2: Double = 45.0
        static let score2: Double = 70.0
        static let threshold3: Double = 30.0
        static let score3: Double = 55.0
        static let threshold4: Double = 20.0
        static let score4: Double = 40.0
        static let scoreBelow: Double = 25.0
        /// Score when no HRV data at all
        static let neutralScore: Double = 50.0
    }

    // MARK: - Tier 1: Missing Sleep Penalty

    /// Points deducted when sleep integration is on but no sleep data exists
    static let missingSleepPenalty: Double = 10.0

    // MARK: - Sleep Detail Thresholds

    enum SleepDetail {
        /// Sleep hour deficit thresholds for detail messages
        static let slightDeficit: Double = 0.5
        static let moderateDeficit: Double = 1.0
        static let severeDeficit: Double = 1.5
    }

    // MARK: - Readiness Calculation

    enum Readiness {
        /// Coefficient for exponential-decay acute fatigue (with workout timestamps)
        static let acuteFatigueCoefficient: Double = 0.30
        /// Coefficient for flat same-day acute fatigue (fallback, no timestamps)
        static let acuteFatigueFallbackCoefficient: Double = 0.35
        /// Exponential decay time constant (hours) for acute fatigue
        static let acuteFatigueTauHours: Double = 24.0

        /// CTL threshold above which capacity-ratio model is used. Below
        /// this, the "novel load" model kicks in — meaning any workout
        /// looks like a lot relative to an effectively-zero fitness base.
        ///
        /// 3.2 = 5.0 × the Banister-TRIMP
        /// 0.64 scaling factor (see HealthWorkoutSummary.calculateTrimp).
        /// The semantic boundary — "has a
        /// meaningful fitness base vs doesn't" — has to move with the
        /// TRIMP scale or every user's CTL silently drops below the
        /// threshold and the app interprets normal training as novel
        /// overload.
        static let ctlThreshold: Double = 3.2
        /// CTL < ctlThreshold path: strain coefficient for novel load
        static let novelLoadStrainCoefficient: Double = 0.5

        /// Capacity ratio breakpoints and corresponding readiness values
        static let capacityRatioBreak1: Double = 0.8
        static let capacityRatioBreak2: Double = 1.0
        static let capacityRatioBreak3: Double = 1.3
        static let capacityRatioBreak4: Double = 1.5
        static let capacityRatioBreak5: Double = 2.0

        static let readinessAtZero: Double = 100.0
        static let readinessAtBreak1: Double = 85.0
        static let readinessAtBreak2: Double = 70.0
        static let readinessAtBreak3: Double = 50.0
        static let readinessAtBreak4: Double = 30.0
        static let readinessAtBreak5: Double = 10.0

        /// ACWR modifier thresholds for readiness
        static let acwrOverreachingThreshold: Double = 1.3
        static let acwrDetrainingThreshold: Double = 0.8
        /// ACWR overreaching penalty base + slope
        static let acwrOverreachingPenaltyBase: Double = 0.05
        static let acwrOverreachingPenaltySlope: Double = 0.50
        static let acwrOverreachingPenaltyCap: Double = 0.40
        /// ACWR detraining penalty slope and cap
        static let acwrDetrainingPenaltySlope: Double = 0.20
        static let acwrDetrainingPenaltyCap: Double = 0.10

        /// ACWR is mathematically noisy at low CTL.
        /// Gabbett's original work was on professional rugby (CTL 60-90);
        /// at CTL=16 a single 40-TRIMP walk swings the ratio by ~0.2.
        /// Penalising readiness off a noisy ratio is a false alarm.
        /// Confidence ramps linearly: full penalty at CTL ≥ 50, zero
        /// effective penalty at CTL = 0. Smooth ramp avoids a cliff.
        static let acwrFullConfidenceCTL: Double = 50.0

        /// When the user's autonomic state clearly says
        /// "recovered" (recovery score above this), cap the ACWR
        /// overreaching penalty. Real tester case:
        /// recovery 73, HRV +7.5ms above baseline, PNS +1.82, but
        /// readiness shouted "Fatigued" because ACWR=1.4 from a low
        /// CTL base. Capping ensures the dashboard's HRV-Readiness
        /// pill and Training-Readiness pill agree on well-recovered
        /// mornings instead of contradicting each other.
        static let acwrRescueRecoveryThreshold: Double = 70.0
        static let acwrPenaltyAutonomicRescueCap: Double = 0.10

        /// Freshness gain multiplier per ATL unit dissipated
        static let freshnessGainMultiplier: Double = 1.5
        /// Maximum freshness gain from ATL dissipation
        static let freshnessGainCap: Double = 20.0

        /// Recovery modulation: model trust scales with CTL
        static let modelTrustDivisor: Double = 40.0
        /// Maximum model trust fraction when model overestimates.
        /// At 0.55 the blend is ~45% recovery / 55% model, consistent with
        /// the literature recommending 50-70% weighting toward HRV as the
        /// direct physiological signal (Plews 2013, Buchheit 2014, Altini).
        static let modelTrustCeiling: Double = 0.55
        /// Recovery uplift fraction when model underestimates
        static let recoveryUpliftFraction: Double = 0.30

        /// Floor for readiness and capacity model
        static let readinessFloor: Double = 10.0
    }

    // MARK: - Readiness Labels & Messages

    enum ReadinessLabels {
        /// Thresholds for readiness label (0-10 scale).
        ///
        /// Aligned with industry: Garmin "Primed" (ready for high intensity)
        /// starts at 60/100; Whoop Green starts at 67/100. Previous thresholds
        /// (7.5/5.0/2.5) required above-average HRV + fully rested model just
        /// to reach "Ready," which most platforms would label green/go.
        /// The display scale these thresholds live on.
        static let tenScaleMax: Double = 10.0

        static let readyThreshold: Double = 7.0
        static let moderateThreshold: Double = 4.5
        static let fatiguedThreshold: Double = 2.0

        /// ACWR thresholds for readiness message
        static let acwrSevere: Double = 1.8
        static let acwrElevated: Double = 1.5
        static let acwrAboveAverage: Double = 1.3

        /// Readiness score thresholds for message (0-10 scale).
        /// Aligned with label thresholds so labels and messages never contradict.
        static let highCapacity: Double = 8.5
        static let goodCapacity: Double = 7.0
        static let moderateCapacity: Double = 4.5
        static let significantFatigue: Double = 2.0
    }

    // MARK: - Training Score

    enum Training {
        /// Foster's monotony threshold (mean/SD of 7-day daily TRIMP).
        /// This is a RATIO — unchanged by uniform TRIMP scaling.
        static let monotonyThreshold: Double = 2.0
        /// Foster's strain thresholds (weekly TRIMP sum × monotony).
        ///
        /// severe=4000 and moderate=2500 scaled by the
        /// Banister-TRIMP 0.64 factor (see HealthWorkoutSummary.calculateTrimp)
        /// to keep the semantic "severe" / "moderate" bands anchored to
        /// the same physiological load regardless of the TRIMP units.
        static let severeStrainThreshold: Double = 2560.0
        static let moderateStrainThreshold: Double = 1600.0
        /// Monotony modifier values
        static let severeMonotonyModifier: Double = 0.75
        static let moderateMonotonyModifier: Double = 0.85
        static let mildMonotonyModifier: Double = 0.93

        /// Monotony cap when SD is zero
        static let monotonyCap: Double = 10.0
    }

    // MARK: - Vitals Overrides

    /// Only `spo2Penalty` is read (`applyVitalsOverrides`). The respiratory
    /// and temperature values have no callers: the live temperature bands are
    /// `ScoringWeights.Vitals`. They stay because `check_scoring_governance.sh`
    /// hashes these numbers, and removing them is a scoring-version change.
    enum Vitals {
        /// Respiratory rate penalty
        static let respiratoryPenalty: Double = 5.0
        /// Temperature deviation thresholds (°C)
        static let temperatureModerateThreshold: Double = 0.5
        static let temperatureSevereThreshold: Double = 1.0
        /// Temperature penalties
        static let temperatureModeratePenalty: Double = 5.0
        static let temperatureSeverePenalty: Double = 10.0
        /// SpO2 penalty
        static let spo2Penalty: Double = 10.0
    }

    // MARK: - Display Score Thresholds

    /// No longer read: every screen uses `ScoreVerdict`'s bands. Kept
    /// because `check_scoring_governance.sh` hashes these numbers.
    enum DisplayThresholds {
        static let excellent: Double = 80.0
        static let good: Double = 60.0
        static let fair: Double = 40.0
    }
}
