import Foundation

/// The vitals contribution to the recovery score: resting-HR, respiratory
/// rate and wrist-temperature sub-scores, the refreshed-vitals factor, and
/// the legacy SpO2 override path.
///
/// Split out of `RecoveryScoreCalculator`. The composite
/// `calculate` entry points and the display helpers stayed behind — they are
/// the calculator's own API and only happened to share this file.
enum VitalsScoring {
    // MARK: - Vitals Sub-Score (Tier 3 contributor)

    /// Compute the 0–100 Vitals sub-score that feeds the recovery composite at
    /// 15% weight. Combines RHR (against personal baseline), respiratory rate
    /// (against 7-day baseline), and wrist-temperature deviation. Returns nil
    /// if no vitals input is available — the caller falls back to Tier 2
    /// (HRV + Sleep only) in that case.
    ///
    /// **Sub-score rules:**
    /// - RHR: 100 if at/below personal baseline; linear penalty of
    ///   `Vitals.rhrPenaltyPerSD` per +1 SD above baseline; floor 0.
    /// - RR: 100 if within ±`respiratoryRateBandBreathsPerMin` br/min of
    ///   baseline; linear penalty of `respiratoryRatePenaltyPerBreath` per
    ///   br/min above baseline; floor 0.
    /// - Temperature deviation: step function on the POSITIVE deviation
    ///   only — ≤0.3°C = 100, 0.3–0.5 = 75, 0.5–1.0 = 50, >1.0 = 25.
    ///   **Negative deviation (cooler than baseline) returns 100.** The
    ///   peer-reviewed signal is fever/inflammation (Snyder et al. 2020,
    ///   Apple's Wrist Temperature white paper, DETECT-AI). A cooler
    ///   reading typically reflects bedroom temperature, lighter
    ///   bedding, deeper SWS (when core temp drops naturally), or
    ///   menstrual-cycle phase — none of which are recovery deficits.
    ///   A symmetric `abs(dev)` rule would penalize those normal
    ///   patterns and is not scientifically defensible.
    ///
    /// Missing inputs are dropped — score is the average of available
    /// sub-scores. A user with only RR data gets the RR sub-score as the
    /// vitals factor (no penalty for missing temp/RHR).
    ///
    /// **Why these rules?** RHR/RR/temperature can move on nights when HRV
    /// does not. Apple's respiratory-rate work reports elevated overnight
    /// rates in the days before self-reported illness; that is an
    /// association in their data, not a validated lead time for this app,
    /// and nothing user-facing may state one. The penalty magnitudes are
    /// practitioner-calibrated to register meaningful mid-day fatigue
    /// without overwhelming the HRV signal that drives the 60% bulk of
    /// the score.
    static func calculateVitalsScore(
        vitals: RecoveryVitals?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?
    ) -> Double? {
        guard let vitals else { return nil }
        var subScores: [Double] = []
        if let rhr = restingHRSubScore(vitals: vitals, baselineStats: baselineStats) { subScores.append(rhr) }
        if let rr = respiratorySubScore(vitals: vitals) { subScores.append(rr) }
        // Wrist temperature arrives as a deviation already, and the bands are
        // asymmetric — see `temperatureSubScore`.
        if let tempDev = vitals.wristTemperature { subScores.append(temperatureSubScore(tempDev)) }
        guard !subScores.isEmpty else { return nil }
        return subScores.reduce(0, +) / Double(subScores.count)
    }

    /// Nil without a personal HR baseline to compare against — there is no
    /// honest way to score a resting HR in isolation.
    private static func restingHRSubScore(
        vitals: RecoveryVitals,
        baselineStats: BaselineTracker.RecoveryBaselineStats?
    ) -> Double? {
        guard let rhr = vitals.restingHeartRate,
              let baseline = baselineStats?.meanHRBaseline, baseline > 0,
              let baselineSD = baselineStats?.meanHRSD, baselineSD > 0 else { return nil }
        let aboveBaseline = max(0, (rhr - baseline) / baselineSD)
        return max(0, 100 - aboveBaseline * ScoringWeights.Vitals.rhrPenaltyPerSD)
    }

    /// Prefers the user's 7-day baseline (carried on the RecoveryVitals payload
    /// itself, distinct from the HR/HRV baseline). When the user has the rate
    /// but the baseline hasn't accumulated yet — Apple Watch needs 7 nights of
    /// overnight RR samples before `fetchRespiratoryRateBaseline` returns
    /// non-nil — this falls back to the published-population window (12–18
    /// br/min for healthy adults asleep). Better than silently dropping the
    /// sub-score and pretending we have "no data" when we clearly have a value.
    private static func respiratorySubScore(vitals: RecoveryVitals) -> Double? {
        if let dev = vitals.respiratoryDeviation {
            let aboveBand = max(0, dev - ScoringWeights.Vitals.respiratoryRateBandBreathsPerMin)
            return max(0, 100 - aboveBand * ScoringWeights.Vitals.respiratoryRatePenaltyPerBreath)
        }
        guard let rate = vitals.respiratoryRate else { return nil }
        return respiratoryPopulationScore(rate: rate)
    }

    /// Build a plain-English explanation of the Vitals factor for the
    /// score breakdown UI.
    ///
    /// Listing only sub-inputs that
    /// crossed thresholds (RR > 0.5 dev, temp > band) is not enough: for a session
    /// with RHR +12 but RR/temp at baseline, the user saw "RHR 66 (+12
    /// bpm vs baseline)" and could not tell whether the 71 score came
    /// from RHR alone (other inputs missing) or RHR plus two perfect
    /// 100s averaging in. So this lists all three sub-input states with
    /// their resolved sub-scores so the average is reconstructable
    /// from the breakdown.
    static func buildVitalsDetail(
        vitals: RecoveryVitals?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        score: Double
    ) -> String {
        guard let vitals else { return "No overnight vitals captured" }
        let parts = [
            sleepHRDetail(vitals: vitals, baselineStats: baselineStats),
            respiratoryDetail(vitals: vitals),
            temperatureDetail(vitals: vitals)
        ]
        return parts.joined(separator: " · ") + " · avg \(Int(score.rounded()))"
    }

    /// Value, baseline delta AND the sub-score, so the user can see the
    /// contribution.
    ///
    /// The field is called restingHeartRate for
    /// legacy-storage reasons, but the value is the strap's analysis-window
    /// mean HR (nocturnal) when available — same physiology as
    /// `meanHRBaseline`. It is labelled "Sleep HR" in the breakdown so the user
    /// reads the right comparison. Apple's daytime RHR survives only as a
    /// fallback when no strap recording exists, and the label still works there.
    private static func sleepHRDetail(
        vitals: RecoveryVitals,
        baselineStats: BaselineTracker.RecoveryBaselineStats?
    ) -> String {
        guard let sleepHR = vitals.restingHeartRate else { return "Sleep HR — no data" }
        // See `respiratoryDetail`. Same duplication,
        // same fix: ask `restingHRSubScore` for the number that was scored
        // instead of deriving a second one from the same constants. Its own
        // guard covers "baseline present and positive", so this branch reduces
        // to "did we get a sub-score".
        guard let baseline = baselineStats?.meanHRBaseline,
              let subScore = restingHRSubScore(vitals: vitals, baselineStats: baselineStats) else {
            return "Sleep HR \(Int(sleepHR.rounded())) (no baseline yet)"
        }
        let delta = sleepHR - baseline
        let label: String
        if abs(delta) < 1.0 {
            label = String(format: "Sleep HR %.0f at baseline", sleepHR)
        } else if delta > 0 {
            label = String(format: "Sleep HR %.0f (+%.0f bpm)", sleepHR, delta)
        } else {
            label = String(format: "Sleep HR %.0f (%.0f bpm)", sleepHR, delta)
        }
        return "\(label) → \(Int(subScore.rounded()))"
    }

    /// Three-state output matching what Sleep HR does. A
    /// binary "have deviation / no data" path lies when the user has a rate
    /// but no baseline yet: Apple Watch needs 7 days of respiratory samples
    /// before `fetchRespiratoryRateBaseline` returns non-nil, so a brand-new
    /// user (or anyone whose baseline window is short) saw "RR — no data" on the
    /// score breakdown while the Vitals detail page rendered "15.9 br/min · No
    /// baseline yet" — directly contradictory. Reported by Mads,
    /// showing Vitals 75 with "RR — no data" alongside a Vitals detail page
    /// showing "15.9 br/min · Within range".
    ///
    /// The three cases: rate AND baseline → deviation + sub-score; rate only →
    /// the population-window fallback, shown as "vs pop" so the user can see we
    /// are not anchoring to their baseline yet even though the value IS
    /// contributing; neither → the only honest "no data".
    private static func respiratoryDetail(vitals: RecoveryVitals) -> String {
        // This must not RECOMPUTE the sub-score from the
        // same constants `respiratorySubScore` uses. Two copies of the same
        // domain maths, one producing the number that feeds the composite and
        // one producing the sentence describing it; if either changed alone the
        // app displayed a sub-score that did not match the one that was scored.
        // Nothing caught the divergence. The detail builder asks for the
        // value rather than deriving it.
        guard let subScore = respiratorySubScore(vitals: vitals) else { return "RR — no data" }
        if let dev = vitals.respiratoryDeviation {
            let sign = dev >= 0 ? "+" : ""
            return String(format: "RR \(sign)%.1f br/min → %d", dev, Int(subScore.rounded()))
        }
        guard let rate = vitals.respiratoryRate else { return "RR — no data" }
        return String(format: "RR %.1f br/min (vs pop) → %d", rate, Int(subScore.rounded()))
    }

    /// Asymmetric on the positive deviation only (cooler than baseline scores
    /// 100). Mirrors the `max(0, tempDev)` rule in `calculateVitalsScore`.
    private static func temperatureDetail(vitals: RecoveryVitals) -> String {
        guard let tempDev = vitals.wristTemperature else { return "Temp — no data" }
        return String(format: "Temp %+.1f°C → %d", tempDev, Int(temperatureSubScore(tempDev).rounded()))
    }

    /// Step function on the POSITIVE deviation: <=0.3°C = 100, 0.3-0.5 = 75,
    /// 0.5-1.0 = 50, >1.0 = 25.
    private static func temperatureSubScore(_ tempDev: Double) -> Double {
        let absDev = max(0, tempDev)
        if absDev <= ScoringWeights.Vitals.temperatureBandNormalCelsius { return 100 }
        if absDev <= ScoringWeights.Vitals.temperatureBandMildCelsius {
            return ScoringWeights.Vitals.temperatureScoreMild
        }
        if absDev <= ScoringWeights.Vitals.temperatureBandModerateCelsius {
            return ScoringWeights.Vitals.temperatureScoreModerate
        }
        return ScoringWeights.Vitals.temperatureScoreSevere
    }

    /// Refresh a FROZEN breakdown's Vitals factor
    /// (detail + sub-score) from a fresher vitals payload without disturbing
    /// the frozen composite or the HRV/Sleep factors. Apple writes overnight
    /// respiratory rate minutes AFTER a recording ends, so the breakdown
    /// frozen at acceptance often reads "RR — no data" even though the
    /// Recovery Vitals card (live re-fetch) shows the value. When the frozen
    /// Vitals factor reports "no data" for RR but `freshVitals` now carries
    /// the rate, its detail + sub-score are recomputed from `freshVitals`;
    /// the frozen composite is preserved (this never re-scores the day).
    /// Canonical respiration source is `RecoveryVitals.respiratoryRate`
    /// (HealthKit overnight), NOT the HRV-derived EDR on `ansMetrics`.
    static func breakdownRefreshingVitalsFactor(
        _ breakdown: RecoveryScoreCalculator.ScoreBreakdown,
        freshVitals: RecoveryVitals?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?
    ) -> RecoveryScoreCalculator.ScoreBreakdown {
        guard let fresh = freshVitals, fresh.respiratoryRate != nil else { return breakdown }
        var changed = false
        let refreshed = breakdown.factors.map { factor -> RecoveryScoreCalculator.ScoreFactor in
            guard factor.label == "Vitals", factor.detail.contains("RR — no data") else { return factor }
            changed = true
            return refreshedVitalsFactor(factor, fresh: fresh, baselineStats: baselineStats)
        }
        guard changed else { return breakdown }
        return RecoveryScoreCalculator.ScoreBreakdown(
            compositeScore: breakdown.compositeScore,
            tier: breakdown.tier,
            factors: refreshed,
            penalties: breakdown.penalties
        )
    }

    /// Temperature is re-expressed against the user's own baseline first, as
    /// the score reads it, so a refreshed factor matches a fresh score.
    private static func refreshedVitalsFactor(
        _ factor: RecoveryScoreCalculator.ScoreFactor,
        fresh unscaled: RecoveryVitals,
        baselineStats: BaselineTracker.RecoveryBaselineStats?
    ) -> RecoveryScoreCalculator.ScoreFactor {
        let fresh = RecoveryScoreCalculator.wristTemperatureAgainstPersonalBaseline(unscaled)
        let newScore = calculateVitalsScore(vitals: fresh, baselineStats: baselineStats) ?? factor.score
        return RecoveryScoreCalculator.ScoreFactor(
            label: factor.label,
            detail: buildVitalsDetail(vitals: fresh, baselineStats: baselineStats, score: newScore),
            score: newScore,
            weight: factor.weight,
            impact: newScore >= 80 ? .positive : (newScore >= 60 ? .neutral : .negative)
        )
    }

    /// Population-norm fallback for the respiratory-rate
    /// sub-score when the user's personal 7-day baseline hasn't
    /// populated yet. Shared by `calculateVitalsScore` (numeric
    /// contribution) and `buildVitalsDetail` (display string) so the
    /// number the user reads matches the number that fed the score.
    ///
    /// Rules from `ScoringWeights.Vitals` (Constants.swift):
    ///   • Inside [popMin, popMax]: 100 (normal sleeping RR)
    ///   • Above popMax: graded penalty at the same per-breath rate
    ///     the baseline-anchored path uses (15 pts/br/min)
    ///   • Below popMin: flat 90 (low overnight RR mirrors low resting
    ///     HR — generally not a recovery deficit; ding mildly so a
    ///     genuine outlier still surfaces)
    static func respiratoryPopulationScore(rate: Double) -> Double {
        let popMin = ScoringWeights.Vitals.respiratoryRatePopulationMinBPM
        let popMax = ScoringWeights.Vitals.respiratoryRatePopulationMaxBPM
        if rate >= popMin, rate <= popMax {
            return 100
        }
        if rate > popMax {
            let above = rate - popMax
            return max(0, 100 - above * ScoringWeights.Vitals.respiratoryRatePenaltyPerBreath)
        }
        return ScoringWeights.Vitals.respiratoryRateBelowPopulationScore
    }

    // MARK: - Vitals Overrides (legacy SpO2 penalty path retained)

    /// SpO2 retains its post-composite penalty (-10 if <95%) by
    /// design: SpO2 is a flag-rather-than-factor signal
    /// (one threshold, no continuous scoring) that often reflects altitude
    /// or sleep apnea rather than recovery state. The other vitals (RHR /
    /// RR / temp) moved into the 15% Vitals factor.
    static func applyVitalsOverrides(score: Double, vitals: RecoveryVitals?) -> Double {
        guard let vitals else { return score }
        var adjusted = score
        if vitals.isSpO2Concerning {
            adjusted -= RecoveryScoreConstants.Vitals.spo2Penalty
        }
        return max(0, adjusted)
    }

    /// Build human-readable descriptions for vitals penalties without applying them.
    /// Now describes only the SpO2 penalty (the other vitals contribute to the
    /// score via `calculateVitalsScore`, surfaced in the Vitals breakdown row
    /// rather than as standalone penalties).
    static func vitalsPenaltyDescriptions(_ vitals: RecoveryVitals?) -> [String] {
        guard let vitals else { return [] }
        var penalties: [String] = []
        if vitals.isSpO2Concerning {
            penalties.append("Low blood oxygen (−10)")
        }
        return penalties
    }
}
