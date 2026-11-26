import Foundation

/// What the app knew about the athlete when a workout started, read once for
/// fast per-tick lookup by the coach context (`WorkoutAIContextBuilder`) and
/// the live snapshot (`WorkoutTicker`). Computed off the main thread after
/// start; empty until that lands.
struct WorkoutStartContext {
    /// This sport's history: average pace, HR and α1. See
    /// `WorkoutHistoryBaselines`.
    var historicalBaselines: WorkoutHistoryBaselines = .empty
    /// Today's morning reading, frozen for the workout. The coach context
    /// surfaces it as `todayRecoveryScore`, `todayTrainingReadiness` and
    /// `todayATL/CTL/TSB`; nil entries when there is no morning reading yet.
    var todayReadiness: ReadinessSnapshot = .empty
    /// The training-load forecast taken with `todayReadiness`.
    var trainingProjection: TrainingProjectionSnapshot = .empty
    /// Riegel race-time predictions (distance in meters → predicted total
    /// seconds). Empty when no comparable history exists.
    var racePredictionsByDistance: [Double: Double] = [:]

    /// Hours of recovery today's training load calls for, from the morning
    /// reading's ATL and CTL; nil without them.
    var recoveryHoursNeeded: Double? {
        RecoveryTimeEstimate.hoursFromTrainingLoad(atl: todayReadiness.atl, ctl: todayReadiness.ctl)
    }

    struct ReadinessSnapshot: Equatable {
        let recoveryScore: Double?
        let trainingReadiness: Double?
        let atl: Double?
        let ctl: Double?
        let tsb: Double?

        static let empty = ReadinessSnapshot(
            recoveryScore: nil, trainingReadiness: nil,
            atl: nil, ctl: nil, tsb: nil
        )
    }

    /// Two forecasts the coach uses: days of rest until fresh, and
    /// tomorrow's TSB if today's load repeats. Both nil when there is no
    /// morning training context.
    struct TrainingProjectionSnapshot: Equatable {
        let daysUntilFresh: Int?
        let tsbTomorrowSteadyState: Double?

        static let empty = TrainingProjectionSnapshot(
            daysUntilFresh: nil, tsbTomorrowSteadyState: nil
        )
    }
}
