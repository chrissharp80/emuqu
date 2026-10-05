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

    /// The Vitals row of a breakdown, with the facts its line is written from.
    static func vitalsFactor(
        vitals: RecoveryVitals?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        score: Double,
        weight: Double
    ) -> RecoveryScoreCalculator.ScoreFactor {
        let detail = describeVitals(vitals: vitals, baselineStats: baselineStats, score: score)
        return RecoveryScoreCalculator.ScoreFactor(
            label: "Vitals",
            detail: detail.text,
            score: score,
            weight: weight,
            impact: score >= 80 ? .positive : (score >= 60 ? .neutral : .negative),
            facts: detail.facts
        )
    }

    /// The explanation of the Vitals factor for the score breakdown, in
    /// `NarrativeLanguage`, as stored at scoring time (temperature in °C).
    static func buildVitalsDetail(
        vitals: RecoveryVitals?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        score: Double
    ) -> String {
        describeVitals(vitals: vitals, baselineStats: baselineStats, score: score).text
    }

    /// Listing only sub-inputs that crossed thresholds is not enough: for a
    /// session with RHR +12 but RR/temp at baseline, "RHR 66 (+12 bpm vs
    /// baseline)" could not tell the user whether the 71 came from RHR alone
    /// (other inputs missing) or RHR plus two perfect 100s averaging in. So
    /// every sub-input is listed with its resolved sub-score, and the
    /// average is reconstructable from the line.
    static func describeVitals(
        vitals: RecoveryVitals?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        score: Double
    ) -> ScoreDetailBuilder.DescribedDetail {
        guard let vitals else { return .note(.noVitals) }
        let facts = vitalsFacts(vitals: vitals, baselineStats: baselineStats, score: score)
        return ScoreDetailBuilder.DescribedDetail(
            text: vitalsLine(facts, temperatureUnit: .celsius), facts: ScoreFactorFacts(vitals: facts)
        )
    }

    /// Each sub-input with the sub-score it got. The sub-scores come from
    /// the functions that scored them, never a second derivation from the
    /// same constants, so the line can't quote a number other than the one
    /// that fed the composite.
    private static func vitalsFacts(
        vitals: RecoveryVitals,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        score: Double
    ) -> ScoreFactorFacts.Vitals {
        var facts = ScoreFactorFacts.Vitals(average: score)
        facts.sleepHR = vitals.restingHeartRate
        if let sleepHR = vitals.restingHeartRate, let baseline = baselineStats?.meanHRBaseline,
           let subScore = restingHRSubScore(vitals: vitals, baselineStats: baselineStats) {
            facts.sleepHRDelta = sleepHR - baseline
            facts.sleepHRScore = subScore
        }
        facts.respiratoryDeviation = vitals.respiratoryDeviation
        facts.respiratoryRate = vitals.respiratoryRate
        facts.respiratoryScore = respiratorySubScore(vitals: vitals)
        facts.temperatureDeviationCelsius = vitals.wristTemperature
        facts.temperatureScore = vitals.wristTemperature.map(temperatureSubScore)
        return facts
    }

    /// The Vitals line in `NarrativeLanguage`, temperature in
    /// `temperatureUnit`: "Sleep HR 52 at baseline → 100 · RR +0.4 br/min →
    /// 100 · Temp +0.2°C → 100 · avg 100".
    static func vitalsLine(_ facts: ScoreFactorFacts.Vitals, temperatureUnit: TemperatureUnit) -> String {
        let average = NarrativeLanguage.integer(Int(facts.average.rounded()))
        let parts = [
            sleepHRClause(facts),
            respiratoryClause(facts),
            temperatureClause(facts, unit: temperatureUnit),
            String(localized: "avg \(average)", bundle: NarrativeLanguage.bundle)
        ]
        return parts.joined(separator: " · ")
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
    private static func sleepHRClause(_ facts: ScoreFactorFacts.Vitals) -> String {
        guard let sleepHR = facts.sleepHR else { return String(localized: "Sleep HR — no data", bundle: NarrativeLanguage.bundle) }
        guard let delta = facts.sleepHRDelta, let subScore = facts.sleepHRScore else {
            let rate = NarrativeLanguage.integer(Int(sleepHR.rounded()))
            return String(localized: "Sleep HR \(rate) (no baseline yet)", bundle: NarrativeLanguage.bundle)
        }
        let (rate, score) = (NarrativeLanguage.number(sleepHR), NarrativeLanguage.integer(Int(subScore.rounded())))
        if abs(delta) < 1.0 {
            return String(localized: "Sleep HR \(rate) at baseline → \(score)", bundle: NarrativeLanguage.bundle)
        }
        let change = NarrativeLanguage.signedNumber(delta, decimals: 0)
        return String(localized: "Sleep HR \(rate) (\(change) bpm) → \(score)", bundle: NarrativeLanguage.bundle)
    }

    /// Three states, as Sleep HR has. Rate AND baseline → deviation +
    /// sub-score; rate only → the population-window fallback, shown as "vs
    /// pop" so the user can see it is not anchored to their baseline yet
    /// even though the value IS contributing; neither → the only honest "no
    /// data". (Apple Watch needs 7 days of respiratory samples before
    /// `fetchRespiratoryRateBaseline` returns a baseline.)
    private static func respiratoryClause(_ facts: ScoreFactorFacts.Vitals) -> String {
        guard let subScore = facts.respiratoryScore else { return rrNoData }
        let score = NarrativeLanguage.integer(Int(subScore.rounded()))
        if let dev = facts.respiratoryDeviation {
            let change = NarrativeLanguage.signedNumber(dev, decimals: 1)
            return String(localized: "RR \(change) br/min → \(score)", bundle: NarrativeLanguage.bundle)
        }
        guard let rate = facts.respiratoryRate else { return rrNoData }
        let value = NarrativeLanguage.number(rate, decimals: 1)
        return String(localized: "RR \(value) br/min (vs pop) → \(score)", bundle: NarrativeLanguage.bundle)
    }

    /// The deviation in the user's unit (a °F deviation is the °C one × 9/5,
    /// with no +32 offset) and its sub-score. Scored asymmetrically: cooler
    /// than baseline scores 100, mirroring `temperatureSubScore`.
    private static func temperatureClause(_ facts: ScoreFactorFacts.Vitals, unit: TemperatureUnit) -> String {
        guard let deviation = facts.temperatureDeviationCelsius else {
            return String(localized: "Temp — no data", bundle: NarrativeLanguage.bundle)
        }
        let change = NarrativeLanguage.signedNumber(unit.convert(deviation), decimals: 1) + unit.symbol
        let subScore = facts.temperatureScore ?? temperatureSubScore(deviation)
        let score = NarrativeLanguage.integer(Int(subScore.rounded()))
        return String(localized: "Temp \(change) → \(score)", bundle: NarrativeLanguage.bundle)
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
            guard factor.label == "Vitals", reportsNoRespiration(factor) else { return factor }
            changed = true
            return refreshedVitalsFactor(factor, fresh: fresh, baselineStats: baselineStats)
        }
        guard changed else { return breakdown }
        return RecoveryScoreCalculator.ScoreBreakdown(
            compositeScore: breakdown.compositeScore,
            tier: breakdown.tier,
            factors: refreshed,
            penalties: breakdown.penalties,
            spo2PenaltyApplied: breakdown.spo2PenaltyApplied,
            scoringVersion: breakdown.scoringVersion
        )
    }

    /// The respiratory clause when there is no rate.
    private static var rrNoData: String { String(localized: "RR — no data", bundle: NarrativeLanguage.bundle) }

    /// Whether a frozen Vitals factor says respiration was missing: from its
    /// facts when it carries them, else from its stored line, which is in
    /// the language it was scored in (English for breakdowns scored before
    /// the lines were localized, else the app language of that night).
    private static func reportsNoRespiration(_ factor: RecoveryScoreCalculator.ScoreFactor) -> Bool {
        if let vitals = factor.facts?.vitals { return vitals.respiratoryScore == nil }
        return factor.detail.contains("RR — no data") || factor.detail.contains(rrNoData)
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
        return vitalsFactor(vitals: fresh, baselineStats: baselineStats, score: newScore, weight: factor.weight)
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

    /// Describe the vitals penalties without applying them, in
    /// `NarrativeLanguage`. Only the SpO2 penalty is one (the other vitals
    /// contribute to the score via `calculateVitalsScore`, surfaced in the
    /// Vitals breakdown row rather than as standalone penalties). Whether it
    /// applied is `ScoreBreakdown.spo2PenaltyApplied`, not this text.
    static func vitalsPenaltyDescriptions(_ vitals: RecoveryVitals?) -> [String] {
        guard let vitals, vitals.isSpO2Concerning else { return [] }
        return [ScoreBreakdownCopy.lowBloodOxygenPenalty]
    }
}
