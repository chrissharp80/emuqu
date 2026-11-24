import Foundation

// Tier composition and detail sentences live in `ScoreDetailBuilder`; these
// forwarders expose them on `RecoveryScoreCalculator`.
//
// `TierInputs` is re-exported as a typealias so call sites can name
// `RecoveryScoreCalculator.TierInputs`.

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
