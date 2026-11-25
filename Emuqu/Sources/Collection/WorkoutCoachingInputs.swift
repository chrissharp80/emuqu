import Foundation

/// What the coach measures the workout against: the user's thresholds and
/// how long each is breached, what the app knew at the start, and the live
/// grade. Start sets them; the coach context updates the breach counts and
/// the grade each tick.
@Observable
@MainActor
final class WorkoutCoachingInputs {
    /// The user's thresholds for this workout and how long each is breached.
    var thresholds = WorkoutThresholdWatch()
    /// What the app knew at the start: history baselines, today's readiness,
    /// the training-load projection and race predictions. Filled once off the
    /// main thread after start; empty until then.
    var startContext = WorkoutStartContext()
    /// The live grade, with the track and barometer state it was worked out
    /// from (`WorkoutAIContextBuilder.computeCurrentGradePercent`). Reset in
    /// `start()`.
    @ObservationIgnored var gradeMemo: GradeMemo?

    struct GradeMemo {
        struct Key: Equatable {
            let fixCount: Int
            let lastFixAt: Date?
            let baroCount: Int
        }

        let key: Key
        let grade: Double?
    }
}
