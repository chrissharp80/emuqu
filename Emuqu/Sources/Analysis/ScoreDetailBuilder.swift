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
        let hrvDetail: DescribedDetail
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
            VitalsScoring.vitalsFactor(
                vitals: inputs.vitals, baselineStats: inputs.baselineStats, score: vitalsScore, weight: vitalsW
            )
        ]
        return (inputs.tier1 * hrvW + sleep * sleepW + vitalsScore * vitalsW, 3, factors)
    }

    static func tier3Weights(comebackModeActive: Bool) -> (Double, Double, Double) {
        comebackModeActive
            ? (ScoringWeights.Comeback.hrv, ScoringWeights.Comeback.sleep, ScoringWeights.Comeback.vitals)
            : (ScoringWeights.Tier3.hrv, ScoringWeights.Tier3.sleep, ScoringWeights.Tier3.vitals)
    }

    /// The HRV row of a breakdown. Shared so every tier maps the same score
    /// to the same impact.
    static func hrvFactor(tier1: Double, detail: DescribedDetail, weight: Double) -> RecoveryScoreCalculator.ScoreFactor {
        RecoveryScoreCalculator.ScoreFactor(
            label: "HRV",
            detail: detail.text,
            score: tier1,
            weight: weight,
            impact: tier1 >= 60 ? .positive : (tier1 >= 40 ? .neutral : .negative),
            facts: detail.facts
        )
    }

    /// The HRV row for a detail line that carries no facts, which is then
    /// shown as written.
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
        let detail = describeSleep(score: sleep, sleepData: sleepData, typicalSleepHours: typicalSleepHours)
        return RecoveryScoreCalculator.ScoreFactor(
            label: "Sleep",
            detail: detail.text,
            score: sleep,
            weight: weight,
            impact: sleep >= 70 ? .positive : (sleep >= 50 ? .neutral : .negative),
            facts: detail.facts
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
        (inputs.tier1, 1, [hrvFactor(tier1: inputs.tier1, detail: inputs.hrvDetail, weight: 1.0)])
    }

    // MARK: - Detail Builders

    /// A factor's detail line as written now, in `NarrativeLanguage`, and
    /// the facts that let it be written again later in another language.
    struct DescribedDetail {
        let text: String
        let facts: ScoreFactorFacts

        static func note(_ note: ScoreFactorFacts.Note) -> DescribedDetail {
            DescribedDetail(text: note.text, facts: ScoreFactorFacts(note: note))
        }
    }

    /// The explanation for the HRV score factor, in `NarrativeLanguage`.
    static func buildHRVDetail(
        rmssd: Double?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        meanHR: Double?,
        dfaAlpha1: Double?,
        hrvReadiness: Double?,
        ansBalance: Double? = nil,
        referenceDate: Date = Date()
    ) -> String {
        describeHRV(
            rmssd: rmssd, baselineStats: baselineStats, meanHR: meanHR, dfaAlpha1: dfaAlpha1,
            hrvReadiness: hrvReadiness, ansBalance: ansBalance, referenceDate: referenceDate
        ).text
    }

    /// The HRV factor's line and the numbers it quotes.
    static func describeHRV(
        rmssd: Double?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        meanHR: Double?,
        dfaAlpha1: Double?,
        hrvReadiness: Double?,
        ansBalance: Double? = nil,
        referenceDate: Date = Date()
    ) -> DescribedDetail {
        guard let stats = baselineStats, let r = rmssd, r > 0 else {
            return .note(hrvReadiness != nil ? .hrvNoBaselineUsingReadiness : .hrvNoBaseline)
        }
        let z = (log(r) - stats.lnRmssdMean) / stats.lnRmssdSD
        // Rounded, not truncated, so base + shown adjustments reconstruct the
        // factor score (which is Int(tier1.rounded())).
        let baseScore = Int(RecoveryScoreCalculator.zToRecoveryScore(z).rounded())
        var adjustments = restingHRAdjustments(meanHR: meanHR, stats: stats)
        adjustments += dfaAlpha1Adjustments(dfaAlpha1) + cvAdjustments(stats.lnRmssdCV7Day)
        adjustments += ansBalanceAdjustments(ansBalance)
        adjustments += baselineStalenessAdjustments(stats: stats, referenceDate: referenceDate)
        return DescribedDetail(
            text: ScoreFactorFacts.HRV.sentence(rmssd: r, z: z, baseScore: baseScore, adjustments: adjustments),
            facts: ScoreFactorFacts(hrv: .init(rmssd: r, z: z, baseScore: baseScore, adjustments: adjustments))
        )
    }

    static func restingHRAdjustments(
        meanHR: Double?,
        stats: BaselineTracker.RecoveryBaselineStats
    ) -> [ScoreFactorFacts.Adjustment] {
        guard let hr = meanHR else { return [] }
        let zHR = (hr - stats.meanHRBaseline) / stats.meanHRSD
        let rhrAdj = max(RecoveryScoreConstants.HRVAdjustments.rhrClampMin, min(RecoveryScoreConstants.HRVAdjustments.rhrClampMax, zHR * RecoveryScoreConstants.HRVAdjustments.rhrZScoreMultiplier))
        let rounded = Int(rhrAdj.rounded())
        return rounded == 0 ? [] : [.restingHR(points: rounded)]
    }

    /// The autonomic-balance adjustment `calculateTier1` applies, so base +
    /// adjustments add up to the HRV factor.
    static func ansBalanceAdjustments(_ ansBalance: Double?) -> [ScoreFactorFacts.Adjustment] {
        let rounded = Int(RecoveryScoreCalculator.ansBalanceAdjustment(ansBalance).rounded())
        return rounded == 0 ? [] : [.autonomicBalance(points: rounded)]
    }

    /// Surface the silent baseline-staleness penalty so
    /// the user understands a score drop attributable to gap-in-recording
    /// rather than physiological change. Mirrors the penalty in
    /// `calculateTier1` — both feed off the shared
    /// `baselineStalenessDays(baselineDate:referenceDate:)` helper.
    static func baselineStalenessAdjustments(
        stats: BaselineTracker.RecoveryBaselineStats,
        referenceDate: Date
    ) -> [ScoreFactorFacts.Adjustment] {
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
        return [.staleBaseline(days: daysSince, points: penaltyRounded)]
    }

    /// "42ms — near your average (base score 61)", one sentence per band of
    /// the z-score against the baseline.
    static func hrvBaseClause(rmssd: String, z: Double, baseScore: String) -> String {
        if z >= 1.5 {
            return String(localized: "\(rmssd)ms — well above your average (base score \(baseScore))", bundle: NarrativeLanguage.bundle)
        } else if z >= 0.5 {
            return String(localized: "\(rmssd)ms — above your average (base score \(baseScore))", bundle: NarrativeLanguage.bundle)
        } else if z >= -0.5 {
            return String(localized: "\(rmssd)ms — near your average (base score \(baseScore))", bundle: NarrativeLanguage.bundle)
        } else if z >= -1.5 {
            return String(localized: "\(rmssd)ms — below your average (base score \(baseScore))", bundle: NarrativeLanguage.bundle)
        }
        return String(localized: "\(rmssd)ms — well below your average (base score \(baseScore))", bundle: NarrativeLanguage.bundle)
    }

    /// The base reading, then the adjustments as one sentence — first
    /// adjustment capitalised so it reads as a sentence of its own.
    static func hrvDetailSentence(base: String, adjustments: [String]) -> String {
        guard !adjustments.isEmpty else { return base }
        var adjList = adjustments
        adjList[0] = adjList[0].prefix(1).uppercased(with: NarrativeLanguage.locale) + adjList[0].dropFirst()
        return "\(base). \(adjList.joined(separator: "; "))"
    }

    /// The explanation for the sleep score factor, in `NarrativeLanguage`.
    static func buildSleepDetail(
        score: Double,
        sleepData: SleepData?,
        typicalSleepHours: Double
    ) -> String {
        describeSleep(score: score, sleepData: sleepData, typicalSleepHours: typicalSleepHours).text
    }

    /// The sleep factor's line and the night it describes.
    static func describeSleep(score: Double, sleepData: SleepData?, typicalSleepHours: Double) -> DescribedDetail {
        guard let sleep = sleepData else { return .note(.noSleepData) }
        let facts = ScoreFactorFacts.Sleep(
            score: score,
            hours: Double(sleep.nightSleepMinutes) / 60.0,
            creditedHours: Double(sleep.totalSleepIncludingNapMinutes) / 60.0,
            efficiency: sleep.measuredSleepEfficiency,
            target: max(typicalSleepHours, 1.0)
        )
        return DescribedDetail(text: facts.line, facts: ScoreFactorFacts(sleep: facts))
    }

    /// The sentence for a sleep sub-score, by band.
    static func sleepSentence(score: Double, _ detail: SleepDetailInputs) -> String {
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
        var targetText: String {
            target.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(NarrativeLanguage.locale))
        }

        /// The night's hours to one decimal.
        var hoursText: String { NarrativeLanguage.number(hours, decimals: 1) }
    }

    /// Duration-debt override. "Only 5h 5m of
    /// sleep" + score 9.0/10 is contradictory copy (a user report). The score is
    /// efficiency-weighted (96% efficiency reads as "locked in") but a high
    /// score with hours well below target hides the duration shortfall. The
    /// narrative names the tradeoff explicitly when hours are short, using
    /// the same threshold the >=65 bucket already uses.
    static func lockedInSleepDetail(_ d: SleepDetailInputs) -> String {
        let (hours, target) = (d.hoursText, d.targetText)
        let short = d.isShort(by: RecoveryScoreConstants.SleepDetail.slightDeficit)
        guard let eff = d.eff.map({ NarrativeLanguage.number($0) }) else {
            return short
                ? String(localized: "\(hours)h — quality is locked in but short of your \(target)h target. Accumulating duration debt", bundle: NarrativeLanguage.bundle)
                : String(localized: "\(hours)h — sleep is locked in. Nothing to fix here", bundle: NarrativeLanguage.bundle)
        }
        if short {
            return String(localized: "\(hours)h at \(eff)% efficiency — quality is locked in but short of your \(target)h target. Efficient but accumulating duration debt", bundle: NarrativeLanguage.bundle)
        }
        return String(localized: "\(hours)h at \(eff)% efficiency — sleep is locked in. Nothing to fix here", bundle: NarrativeLanguage.bundle)
    }

    static func decentSleepDetail(_ d: SleepDetailInputs) -> String {
        let (hours, target) = (d.hoursText, d.targetText)
        let short = d.isShort(by: RecoveryScoreConstants.SleepDetail.slightDeficit)
        guard let effValue = d.eff else {
            return short
                ? String(localized: "\(hours)h is short of your \(target)h target — you just need more time in bed", bundle: NarrativeLanguage.bundle)
                : String(localized: "\(hours)h — decent but room to improve", bundle: NarrativeLanguage.bundle)
        }
        let eff = NarrativeLanguage.number(effValue)
        if short {
            return String(localized: "\(hours)h is short of your \(target)h target. Efficiency is fine (\(eff)%) — you just need more time in bed", bundle: NarrativeLanguage.bundle)
        } else if effValue < 80 {
            return String(localized: "\(hours)h is solid but \(eff)% efficiency means too much time awake in bed. Quality over quantity", bundle: NarrativeLanguage.bundle)
        }
        return String(localized: "\(hours)h, \(eff)% efficiency — decent but room to improve", bundle: NarrativeLanguage.bundle)
    }

    static func mediocreSleepDetail(_ d: SleepDetailInputs) -> String {
        let hours = d.hoursText
        if d.isShort(by: RecoveryScoreConstants.SleepDetail.moderateDeficit) {
            return String(localized: "Only \(hours)h — well short of your \(d.targetText)h target. This is costing you points", bundle: NarrativeLanguage.bundle)
        }
        guard let effValue = d.eff else {
            return String(localized: "\(hours)h — sleep is mediocre and it shows in your score", bundle: NarrativeLanguage.bundle)
        }
        let eff = NarrativeLanguage.number(effValue)
        if effValue < 75 {
            return String(localized: "\(eff)% efficiency is poor — too much tossing or waking. This is dragging your score down", bundle: NarrativeLanguage.bundle)
        }
        return String(localized: "\(hours)h, \(eff)% efficiency — sleep is mediocre and it shows in your score", bundle: NarrativeLanguage.bundle)
    }

    static func poorSleepDetail(_ d: SleepDetailInputs) -> String {
        let hours = d.hoursText
        if d.isShort(by: RecoveryScoreConstants.SleepDetail.severeDeficit) {
            return String(localized: "\(hours)h is nowhere near enough. Your \(d.targetText)h target exists for a reason", bundle: NarrativeLanguage.bundle)
        }
        guard let eff = d.eff.map({ NarrativeLanguage.number($0) }) else {
            return String(localized: "\(hours)h — poor sleep is tanking your recovery", bundle: NarrativeLanguage.bundle)
        }
        return String(localized: "\(hours)h at \(eff)% efficiency — poor sleep is tanking your recovery", bundle: NarrativeLanguage.bundle)
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

    /// The DFA α1 adjustment `calculateTier1` applies.
    static func dfaAlpha1Adjustments(_ dfaAlpha1: Double?) -> [ScoreFactorFacts.Adjustment] {
        guard let a1 = dfaAlpha1 else { return [] }
        if a1 >= HRVThresholds.dfaAlpha1OptimalLower, a1 <= HRVThresholds.dfaAlpha1OptimalUpper {
            return [.alphaBalanced]
        }
        if a1 > HRVThresholds.dfaAlpha1Fatigue { return [.alphaStrained] }
        if a1 < HRVThresholds.dfaAlpha1FlexibleLower { return [.alphaReduced] }
        return []
    }

    /// The 7-day coefficient-of-variation adjustment `calculateTier1` applies.
    static func cvAdjustments(_ cv7Day: Double?) -> [ScoreFactorFacts.Adjustment] {
        guard let cv = cv7Day else { return [] }
        if cv < RecoveryScoreConstants.HRVAdjustments.cvFlatThreshold { return [.variabilityFlat] }
        if cv > RecoveryScoreConstants.HRVAdjustments.cvErraticThreshold { return [.variabilityErratic] }
        return []
    }
}
