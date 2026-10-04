import Foundation

// The tier composite helpers, detail builders and baseline-staleness logic.
// Members are internal rather than `private` because Swift's `private` does
// not reach across files.

/// The tier composition and the human-readable detail sentences behind each
/// score factor: HRV, sleep, resting HR, baseline staleness, α1 and CV.
///
/// Split out of `RecoveryScoreCalculator` to keep the calculator under the
/// 1500-line limit.
enum ScoreDetailBuilder {
    // MARK: - Tier Composite Helpers
    //
    // Post-ACWR removal:
    //   Tier 3 = HRV + Sleep + Vitals (60/25/15) — full signal day
    //   Tier 2 = HRV + Sleep (70/30) — vitals data missing
    //   Tier 1 = HRV only — no sleep, no vitals (cold start, watch off)
    //
    // Comeback mode (21 days post illness/injury): when active, Tier 3
    // weights shift to HRV 80 / Sleep 20 / Vitals 0 — the vitals factor is
    // surfaced for observation but carries no weight, because RR/RHR/temp
    // can stay noisy for weeks after a viral illness and shouldn't drag
    // a HRV-recovered user's score down. Tier 2 has no vitals factor and
    // keeps its weights. The post-composite SpO2 flag
    // (`RecoveryScoreCalculator.applyVitalsOverrides`) is not a factor and
    // applies in every tier, Comeback mode included.

    /// Every signal the tier ladder can consume. Which tier actually runs is
    /// decided by which of `sleepScore` / `vitalsScore` are present.
    struct TierInputs {
        let tier1: Double
        let sleepScore: Double?
        let vitalsScore: Double?
        let vitals: RecoveryVitals?
        let baselineStats: BaselineTracker.RecoveryBaselineStats?
        let hrvDetail: String
        let sleepData: SleepData?
        let rmssd: Double?
        let typicalSleepHours: Double
        let comebackModeActive: Bool
    }

    static func buildTierComposite(
        _ inputs: TierInputs
    ) -> (composite: Double, tier: Int, factors: [RecoveryScoreCalculator.ScoreFactor]) {
        if let sleep = inputs.sleepScore, let vitalsScore = inputs.vitalsScore {
            buildTier3(inputs, sleep: sleep, vitalsScore: vitalsScore)
        } else if let sleep = inputs.sleepScore {
            buildTier2(inputs, sleep: sleep)
        } else {
            buildTier1(inputs)
        }
    }

    /// Tier 3 — HRV + Sleep + Vitals (full-signal day).
    /// Weights: standard 60/25/15, or Comeback 80/20/0 when comeback mode
    /// is active. Vitals are still listed in the breakdown when comeback
    /// is active (with weight 0) so the user sees the underlying numbers
    /// even when they're not contributing to the score.
    static func buildTier3(
        _ inputs: TierInputs,
        sleep: Double,
        vitalsScore: Double
    ) -> (Double, Int, [RecoveryScoreCalculator.ScoreFactor]) {
        let (hrvW, sleepW, vitalsW) = tier3Weights(comebackModeActive: inputs.comebackModeActive)
        let factors = [
            hrvFactor(tier1: inputs.tier1, detail: inputs.hrvDetail, weight: hrvW),
            sleepFactor(
                sleep: sleep, sleepData: inputs.sleepData,
                typicalSleepHours: inputs.typicalSleepHours, weight: sleepW
            ),
            RecoveryScoreCalculator.ScoreFactor(
                label: "Vitals",
                detail: VitalsScoring.buildVitalsDetail(
                    vitals: inputs.vitals, baselineStats: inputs.baselineStats, score: vitalsScore
                ),
                score: vitalsScore,
                weight: vitalsW,
                impact: vitalsScore >= 80 ? .positive : (vitalsScore >= 60 ? .neutral : .negative)
            )
        ]
        return (inputs.tier1 * hrvW + sleep * sleepW + vitalsScore * vitalsW, 3, factors)
    }

    static func tier3Weights(comebackModeActive: Bool) -> (Double, Double, Double) {
        comebackModeActive
            ? (ScoringWeights.Comeback.hrv, ScoringWeights.Comeback.sleep, ScoringWeights.Comeback.vitals)
            : (ScoringWeights.Tier3.hrv, ScoringWeights.Tier3.sleep, ScoringWeights.Tier3.vitals)
    }

    /// The HRV row of a breakdown. Shared so tiers 2 and 3 can never disagree
    /// about how the same score maps to an impact.
    static func hrvFactor(tier1: Double, detail: String, weight: Double) -> RecoveryScoreCalculator.ScoreFactor {
        RecoveryScoreCalculator.ScoreFactor(
            label: "HRV",
            detail: detail,
            score: tier1,
            weight: weight,
            impact: tier1 >= 60 ? .positive : (tier1 >= 40 ? .neutral : .negative)
        )
    }

    static func sleepFactor(
        sleep: Double,
        sleepData: SleepData?,
        typicalSleepHours: Double,
        weight: Double
    ) -> RecoveryScoreCalculator.ScoreFactor {
        RecoveryScoreCalculator.ScoreFactor(
            label: "Sleep",
            detail: buildSleepDetail(score: sleep, sleepData: sleepData, typicalSleepHours: typicalSleepHours),
            score: sleep,
            weight: weight,
            impact: sleep >= 70 ? .positive : (sleep >= 50 ? .neutral : .negative)
        )
    }

    /// Tier 2 — HRV + Sleep, no vitals.
    ///
    /// A well-below-baseline HRV night that also slept badly shifts weight
    /// toward HRV (70/30 → 85/15), so the poor sleep isn't counted twice on
    /// top of the HRV drop it usually causes.
    static func buildTier2(_ inputs: TierInputs, sleep: Double) -> (Double, Int, [RecoveryScoreCalculator.ScoreFactor]) {
        let zHrv: Double = if let stats = inputs.baselineStats, let r = inputs.rmssd, r > 0 {
            (log(r) - stats.lnRmssdMean) / stats.lnRmssdSD
        } else {
            0
        }
        let dampened = zHrv < -1.0 && sleep < 50
        let hrvW = dampened ? ScoringWeights.Tier2.hrvDampened : ScoringWeights.Tier2.hrvNormal
        let sleepW = dampened ? ScoringWeights.Tier2.sleepDampened : ScoringWeights.Tier2.sleepNormal
        let factors = [
            hrvFactor(tier1: inputs.tier1, detail: inputs.hrvDetail, weight: hrvW),
            sleepFactor(
                sleep: sleep, sleepData: inputs.sleepData,
                typicalSleepHours: inputs.typicalSleepHours, weight: sleepW
            )
        ]
        return (inputs.tier1 * hrvW + sleep * sleepW, 2, factors)
    }

    /// Tier 1 — HRV only. The weighted sum is the HRV factor itself; the
    /// missing-sleep deduction is a penalty, applied and listed with the
    /// others in `RecoveryScoreCalculator.computeBreakdown`, so it is never
    /// hidden inside the factor sum.
    static func buildTier1(_ inputs: TierInputs) -> (Double, Int, [RecoveryScoreCalculator.ScoreFactor]) {
        let factors = [
            RecoveryScoreCalculator.ScoreFactor(
                label: "HRV",
                detail: inputs.hrvDetail,
                score: inputs.tier1,
                weight: 1.0,
                impact: inputs.tier1 >= 60 ? .positive : (inputs.tier1 >= 40 ? .neutral : .negative)
            )
        ]
        return (inputs.tier1, 1, factors)
    }

    // MARK: - Detail Builders

    /// Build a plain-English explanation for the HRV score factor.
    static func buildHRVDetail(
        rmssd: Double?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        meanHR: Double?,
        dfaAlpha1: Double?,
        hrvReadiness: Double?,
        ansBalance: Double? = nil,
        referenceDate: Date = Date()
    ) -> String {
        guard let stats = baselineStats, let r = rmssd, r > 0 else {
            return hrvReadiness != nil ? "No baseline yet (using readiness score)" : "No baseline yet"
        }
        let z = (log(r) - stats.lnRmssdMean) / stats.lnRmssdSD
        // #8 fix — round (not truncate) the base component so displayed
        // base + shown adjustments reconstruct the factor score (which is
        // Int(tier1.rounded())). Truncating the base (e.g. 19.6→19) while the
        // factor rounds the sum made "base 19, −10, +5 = 14" disagree with 15.
        let baseScore = Int(RecoveryScoreCalculator.zToRecoveryScore(z).rounded())
        let comparison = if z >= 1.5 { "well above" } else if z >= 0.5 { "above" } else if z >= -0.5 { "near" } else if z >= -1.5 { "below" } else { "well below" }
        var adjustments = restingHRPhrases(meanHR: meanHR, stats: stats)
        adjustments += dfaAlpha1Phrases(dfaAlpha1) + cvPhrases(stats.lnRmssdCV7Day) + ansBalancePhrases(ansBalance)
        adjustments += baselineStalenessPhrases(stats: stats, referenceDate: referenceDate)
        return hrvDetailSentence(
            rmssdStr: String(format: "%.0f", locale: .current, r),
            comparison: comparison,
            baseScore: baseScore,
            adjustments: adjustments
        )
    }

    static func restingHRPhrases(
        meanHR: Double?,
        stats: BaselineTracker.RecoveryBaselineStats
    ) -> [String] {
        guard let hr = meanHR else { return [] }
        var adjustments: [String] = []
        let zHR = (hr - stats.meanHRBaseline) / stats.meanHRSD
        let rhrAdj = max(RecoveryScoreConstants.HRVAdjustments.rhrClampMin, min(RecoveryScoreConstants.HRVAdjustments.rhrClampMax, zHR * RecoveryScoreConstants.HRVAdjustments.rhrZScoreMultiplier))
        let rounded = Int(rhrAdj.rounded())
        if rounded != 0 {
            if rounded > 0 {
                adjustments.append("resting HR lower than usual (+\(rounded))")
            } else {
                adjustments.append("resting HR higher than usual (\(rounded))")
            }
        }
        return adjustments
    }

    /// The autonomic-balance adjustment `calculateTier1` applies, so base +
    /// adjustments add up to the HRV factor.
    static func ansBalancePhrases(_ ansBalance: Double?) -> [String] {
        let rounded = Int(RecoveryScoreCalculator.ansBalanceAdjustment(ansBalance).rounded())
        guard rounded != 0 else { return [] }
        return rounded > 0
            ? ["autonomic balance tilted toward rest (+\(rounded))"]
            : ["autonomic balance tilted toward stress (\(rounded))"]
    }

    /// Surface the silent baseline-staleness penalty so
    /// the user understands a score drop attributable to gap-in-recording
    /// rather than physiological change. Mirrors the penalty in
    /// `calculateTier1` — both feed off the shared
    /// `baselineStalenessDays(baselineDate:referenceDate:)` helper.
    static func baselineStalenessPhrases(
        stats: BaselineTracker.RecoveryBaselineStats,
        referenceDate: Date
    ) -> [String] {
        guard let lastDate = stats.lastDataPointDate else { return [] }
        let daysSince = baselineStalenessDays(baselineDate: lastDate, referenceDate: referenceDate)
        guard daysSince >= RecoveryScoreConstants.BaselineStaleness.staleAfterDays else { return [] }
        let weeksStale = Double(daysSince - RecoveryScoreConstants.BaselineStaleness.staleAfterDays) / 7.0
        let penalty = min(
            RecoveryScoreConstants.BaselineStaleness.maxPenalty,
            RecoveryScoreConstants.BaselineStaleness.penaltyPerWeek * (1.0 + weeksStale)
        )
        let penaltyRounded = Int(penalty.rounded())
        guard penaltyRounded > 0 else { return [] }
        return ["baseline data is \(daysSince) days old (−\(penaltyRounded))"]
    }

    /// The base reading, then the adjustments as one sentence — first
    /// adjustment capitalised so it reads as a sentence of its own.
    static func hrvDetailSentence(
        rmssdStr: String,
        comparison: String,
        baseScore: Int,
        adjustments: [String]
    ) -> String {
        var detail = "\(rmssdStr)ms — \(comparison) your average (base score \(baseScore))"
        if !adjustments.isEmpty {
            var adjList = adjustments
            adjList[0] = adjList[0].prefix(1).uppercased() + adjList[0].dropFirst()
            detail += ". \(adjList.joined(separator: "; "))"
        }
        return detail
    }

    /// Build a plain-English explanation for the sleep score factor.
    static func buildSleepDetail(
        score: Double,
        sleepData: SleepData?,
        typicalSleepHours: Double
    ) -> String {
        guard let sleep = sleepData else { return "No sleep data" }
        let detail = SleepDetailInputs(
            hours: Double(sleep.nightSleepMinutes) / 60.0,
            creditedHours: Double(sleep.totalSleepIncludingNapMinutes) / 60.0,
            eff: sleep.measuredSleepEfficiency,
            target: max(typicalSleepHours, 1.0)
        )
        if score >= 85 { return lockedInSleepDetail(detail) }
        if score >= 65 { return decentSleepDetail(detail) }
        if score >= 45 { return mediocreSleepDetail(detail) }
        return poorSleepDetail(detail)
    }

    /// What the sleep sentences read. `hours` is the night, which the
    /// sentences quote; `creditedHours` adds a qualifying nap, as the duration
    /// score does, so a nap that made up the night's shortfall is never called
    /// "short of target". `eff` is nil when the night's efficiency was not
    /// measured, and the sentences then leave it out.
    struct SleepDetailInputs {
        let hours: Double
        let creditedHours: Double
        let eff: Double?
        let target: Double

        func isShort(by deficit: Double) -> Bool { creditedHours < target - deficit }

        /// "7.5" or "8": a half-hour target must not round to the next hour.
        var targetText: String { String(format: "%g", locale: .current, target) }
    }

    /// Duration-debt override. "Only 5h 5m of
    /// sleep" + score 9.0/10 is contradictory copy (a user report). The score is
    /// efficiency-weighted (96% efficiency reads as "locked in") but a high
    /// score with hours well below target hides the duration shortfall. The
    /// narrative names the tradeoff explicitly when hours are short, using
    /// the same threshold the >=65 bucket already uses.
    static func lockedInSleepDetail(_ d: SleepDetailInputs) -> String {
        let short = d.isShort(by: RecoveryScoreConstants.SleepDetail.slightDeficit)
        guard let eff = d.eff else {
            return short
                ? String(format: "%.1fh — quality is locked in but short of your %@h target. Accumulating duration debt", locale: .current, d.hours, d.targetText)
                : String(format: "%.1fh — sleep is locked in. Nothing to fix here", locale: .current, d.hours)
        }
        if short {
            return String(format: "%.1fh at %.0f%% efficiency — quality is locked in but short of your %@h target. Efficient but accumulating duration debt", locale: .current, d.hours, eff, d.targetText)
        }
        return String(format: "%.1fh at %.0f%% efficiency — sleep is locked in. Nothing to fix here", locale: .current, d.hours, eff)
    }

    static func decentSleepDetail(_ d: SleepDetailInputs) -> String {
        let short = d.isShort(by: RecoveryScoreConstants.SleepDetail.slightDeficit)
        guard let eff = d.eff else {
            return short
                ? String(format: "%.1fh is short of your %@h target — you just need more time in bed", locale: .current, d.hours, d.targetText)
                : String(format: "%.1fh — decent but room to improve", locale: .current, d.hours)
        }
        if short {
            return String(format: "%.1fh is short of your %@h target. Efficiency is fine (%.0f%%) — you just need more time in bed", locale: .current, d.hours, d.targetText, eff)
        } else if eff < 80 {
            return String(format: "%.1fh is solid but %.0f%% efficiency means too much time awake in bed. Quality over quantity", locale: .current, d.hours, eff)
        }
        return String(format: "%.1fh, %.0f%% efficiency — decent but room to improve", locale: .current, d.hours, eff)
    }

    static func mediocreSleepDetail(_ d: SleepDetailInputs) -> String {
        if d.isShort(by: RecoveryScoreConstants.SleepDetail.moderateDeficit) {
            return String(format: "Only %.1fh — well short of your %@h target. This is costing you points", locale: .current, d.hours, d.targetText)
        }
        guard let eff = d.eff else {
            return String(format: "%.1fh — sleep is mediocre and it shows in your score", locale: .current, d.hours)
        }
        if eff < 75 {
            return String(format: "%.0f%% efficiency is poor — too much tossing or waking. This is dragging your score down", locale: .current, eff)
        }
        return String(format: "%.1fh, %.0f%% efficiency — sleep is mediocre and it shows in your score", locale: .current, d.hours, eff)
    }

    static func poorSleepDetail(_ d: SleepDetailInputs) -> String {
        if d.isShort(by: RecoveryScoreConstants.SleepDetail.severeDeficit) {
            return String(format: "%.1fh is nowhere near enough. Your %@h target exists for a reason", locale: .current, d.hours, d.targetText)
        }
        guard let eff = d.eff else {
            return String(format: "%.1fh — poor sleep is tanking your recovery", locale: .current, d.hours)
        }
        return String(format: "%.1fh at %.0f%% efficiency — poor sleep is tanking your recovery", locale: .current, d.hours, eff)
    }

    // MARK: - Baseline Staleness

    /// Whole days between the baseline's most recent data point and the
    /// reference date. Shared by calculateTier1 (score penalty) and
    /// buildHRVDetail (user-facing explanation) so the two can never
    /// drift. Pure: the reference date is injected — no wall-clock read —
    /// which keeps the recovery score deterministic for a given input.
    static func baselineStalenessDays(baselineDate: Date, referenceDate: Date) -> Int {
        Calendar.current.dateComponents([.day], from: baselineDate, to: referenceDate).day ?? 0
    }

    /// User-facing phrasing for the DFA α1 adjustment.
    ///
    /// "Autonomic regulation {balanced, strained, reduced}", not "heart
    /// rhythm {well-organized, stress, irregular}".
    /// DFA α1 measures autonomic complexity, not cardiac rhythm
    /// pathology, and rhythm copy crosses the wellness/SaMD line by
    /// implying rhythm assessment — "irregular" especially sounds
    /// AFib-adjacent. Apple Review 1.4.1 and the FDA wellness boundary both
    /// call for non-diagnostic phrasing here.
    static func dfaAlpha1Phrases(_ dfaAlpha1: Double?) -> [String] {
        guard let a1 = dfaAlpha1 else { return [] }
        if a1 >= HRVThresholds.dfaAlpha1OptimalLower, a1 <= HRVThresholds.dfaAlpha1OptimalUpper {
            return ["autonomic regulation balanced (+5)"]
        }
        if a1 > HRVThresholds.dfaAlpha1Fatigue {
            return ["autonomic regulation strained (−5)"]
        }
        if a1 < HRVThresholds.dfaAlpha1FlexibleLower {
            return ["autonomic regulation reduced (−3)"]
        }
        return []
    }

    /// User-facing phrasing for the 7-day coefficient-of-variation adjustment.
    static func cvPhrases(_ cv7Day: Double?) -> [String] {
        guard let cv = cv7Day else { return [] }
        if cv < RecoveryScoreConstants.HRVAdjustments.cvFlatThreshold {
            return ["day-to-day HRV unusually flat (−5)"]
        }
        if cv > RecoveryScoreConstants.HRVAdjustments.cvErraticThreshold {
            return ["day-to-day HRV erratic (−3)"]
        }
        return []
    }
}
