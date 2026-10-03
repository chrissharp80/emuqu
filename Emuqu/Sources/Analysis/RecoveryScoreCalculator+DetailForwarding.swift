import Foundation

// Tier composition and detail sentences live in `ScoreDetailBuilder` — the
// cut that keeps RecoveryScoreCalculator under the 1500-line limit.
//
// `TierInputs` is re-exported as a typealias so the call sites that name
// `RecoveryScoreCalculator.TierInputs` keep compiling unchanged.

extension RecoveryScoreCalculator {
    typealias TierInputs = ScoreDetailBuilder.TierInputs

    static func buildTierComposite(
        _ inputs: TierInputs
    ) -> (composite: Double, tier: Int, factors: [ScoreFactor]) {
        ScoreDetailBuilder.buildTierComposite(inputs)
    }

    static func buildHRVDetail(
        rmssd: Double?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        meanHR: Double?,
        dfaAlpha1: Double?,
        hrvReadiness: Double?,
        ansBalance: Double? = nil,
        referenceDate: Date = Date()
    ) -> String {
        ScoreDetailBuilder.buildHRVDetail(
            rmssd: rmssd,
            baselineStats: baselineStats,
            meanHR: meanHR,
            dfaAlpha1: dfaAlpha1,
            hrvReadiness: hrvReadiness,
            ansBalance: ansBalance,
            referenceDate: referenceDate
        )
    }

    static func buildSleepDetail(
        score: Double, sleepData: SleepData?, typicalSleepHours: Double
    ) -> String {
        ScoreDetailBuilder.buildSleepDetail(
            score: score, sleepData: sleepData, typicalSleepHours: typicalSleepHours
        )
    }

    static func hrvFactor(tier1: Double, detail: String, weight: Double) -> ScoreFactor {
        ScoreDetailBuilder.hrvFactor(tier1: tier1, detail: detail, weight: weight)
    }

    static func baselineStalenessDays(baselineDate: Date, referenceDate: Date) -> Int {
        ScoreDetailBuilder.baselineStalenessDays(
            baselineDate: baselineDate, referenceDate: referenceDate
        )
    }
}
