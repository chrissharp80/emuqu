import Foundation

// Training readiness lives in `ReadinessScoring`.
//
// These forwarders keep every existing call site working, tests included.
// `WorkoutLoad` is re-exported as a typealias so the many call sites that
// name `RecoveryScoreCalculator.WorkoutLoad` keep compiling unchanged.

extension RecoveryScoreCalculator {
    typealias WorkoutLoad = ReadinessScoring.WorkoutLoad

    static func calculateReadiness(
        recoveryScore: Double,
        todayTrimp: Double,
        ctl: Double,
        atl: Double = 0,
        morningATL: Double? = nil,
        acuteChronicRatio: Double? = nil,
        recentWorkoutLoads: [WorkoutLoad]? = nil
    ) -> Double {
        ReadinessScoring.calculateReadiness(
            recoveryScore: recoveryScore,
            todayTrimp: todayTrimp,
            ctl: ctl,
            atl: atl,
            morningATL: morningATL,
            acuteChronicRatio: acuteChronicRatio,
            recentWorkoutLoads: recentWorkoutLoads
        )
    }

    static func dampenedACWRPenalty(acr: Double, ctl: Double, recoveryScore: Double) -> Double {
        ReadinessScoring.dampenedACWRPenalty(acr: acr, ctl: ctl, recoveryScore: recoveryScore)
    }

    static func applyFreshnessBonus(
        _ readiness: Double, morningATL: Double?, atl: Double
    ) -> Double {
        ReadinessScoring.applyFreshnessBonus(readiness, morningATL: morningATL, atl: atl)
    }

    static func readinessLabel(for score: Double) -> String {
        ReadinessScoring.readinessLabel(for: score)
    }

    static func tenScaleClamped(_ score: Double) -> Double {
        ReadinessScoring.tenScaleClamped(score)
    }

    static func readinessMessage(
        for rawReadiness: Double, acuteChronicRatio: Double? = nil
    ) -> String {
        ReadinessScoring.readinessMessage(
            for: rawReadiness, acuteChronicRatio: acuteChronicRatio
        )
    }
}
