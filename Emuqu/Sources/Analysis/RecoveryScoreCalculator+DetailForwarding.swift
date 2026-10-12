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

    static func baselineStalenessDays(baselineDate: Date, referenceDate: Date) -> Int {
        ScoreDetailBuilder.baselineStalenessDays(
            baselineDate: baselineDate, referenceDate: referenceDate
        )
    }
}
