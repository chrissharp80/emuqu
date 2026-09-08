import Foundation

// The vitals sub-score lives in `VitalsScoring` — part of keeping
// RecoveryScoreCalculator under the 1500-line limit.
//
// These forwarders keep every existing call site working, tests included. The
// scoring itself is unchanged: same inputs, same arithmetic, same output.

extension RecoveryScoreCalculator {
    static func calculateVitalsScore(
        vitals: RecoveryVitals?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?
    ) -> Double? {
        VitalsScoring.calculateVitalsScore(vitals: vitals, baselineStats: baselineStats)
    }

    static func buildVitalsDetail(
        vitals: RecoveryVitals?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        score: Double
    ) -> String {
        VitalsScoring.buildVitalsDetail(
            vitals: vitals, baselineStats: baselineStats, score: score
        )
    }

    static func breakdownRefreshingVitalsFactor(
        _ breakdown: ScoreBreakdown,
        freshVitals: RecoveryVitals?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?
    ) -> ScoreBreakdown {
        VitalsScoring.breakdownRefreshingVitalsFactor(
            breakdown, freshVitals: freshVitals, baselineStats: baselineStats
        )
    }

    static func respiratoryPopulationScore(rate: Double) -> Double {
        VitalsScoring.respiratoryPopulationScore(rate: rate)
    }

    static func applyVitalsOverrides(score: Double, vitals: RecoveryVitals?) -> Double {
        VitalsScoring.applyVitalsOverrides(score: score, vitals: vitals)
    }

    static func vitalsPenaltyDescriptions(_ vitals: RecoveryVitals?) -> [String] {
        VitalsScoring.vitalsPenaltyDescriptions(vitals)
    }
}
