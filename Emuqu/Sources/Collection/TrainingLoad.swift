import Foundation

/// Training load data for readiness context
struct TrainingLoad {
    let vo2Max: Double? // ml/kg/min (from HealthKit or nil)
    /// VO2max change over the last 30 days (latest minus
    /// earliest in window). Positive = improving fitness, negative =
    /// detraining. Nil when fewer than 2 samples in HealthKit.
    var vo2MaxChange30Days: Double?
    /// Count of HealthKit VO2max samples in the trend
    /// window. Lets the AI caveat the trend ("based on 2 samples" vs
    /// "based on 12 samples").
    var vo2MaxSampleCount30Days: Int = 0
    let recentWorkouts: [HealthKitManager.WorkoutSummary] // Last 7 days of workouts
    let weeklyLoadScore: Double // 0-100 based on workout intensity/duration
    let daysSinceHardWorkout: Int? // Days since last intense session
    let acuteChronicRatio: Double? // Training load ratio (injury risk indicator)
    let metrics: TrainingMetrics? // Full TRIMP/ATL/CTL/TSB metrics

    /// Adjustment factor for readiness based on training load (-2 to +1)
    /// Negative = recent hard training, expect lower HRV
    /// Positive = well rested, expect normal/higher HRV
    var readinessAdjustment: Double {
        guard let days = daysSinceHardWorkout else { return 0 }

        // Day after hard workout: expect suppressed HRV, don't penalize readiness
        if days == 0 { return -2.0 }
        if days == 1 { return -1.0 }
        if days == 2 { return -0.5 }

        // Well rested: normal expectations
        return 0
    }

    static let empty = TrainingLoad(
        vo2Max: nil,
        recentWorkouts: [],
        weeklyLoadScore: 0,
        daysSinceHardWorkout: nil,
        acuteChronicRatio: nil,
        metrics: nil
    )
}
