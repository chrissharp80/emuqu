import Foundation

// Readiness is scored by `ReadinessScoring`, the vitals sub-score by
// `VitalsScoring` and the tier composition by `ScoreDetailBuilder`; callers
// name those types directly. The two input types below are also named
// through the calculator, whose inputs they are.

extension RecoveryScoreCalculator {
    typealias WorkoutLoad = ReadinessScoring.WorkoutLoad
    typealias TierInputs = ScoreDetailBuilder.TierInputs
}
