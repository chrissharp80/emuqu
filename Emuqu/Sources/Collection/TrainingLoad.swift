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
    /// Last 7 days of workouts, newest first (the init sorts them, so
    /// `prefix(n)` is always the n most recent whatever order HealthKit or
    /// dedup handed over).
    let recentWorkouts: [HealthKitManager.WorkoutSummary]
    let weeklyLoadScore: Double // 0-100 based on workout intensity/duration
    let daysSinceHardWorkout: Int? // Days since last intense session
    let acuteChronicRatio: Double? // Training load ratio (injury risk indicator)
    let metrics: TrainingMetrics? // Full TRIMP/ATL/CTL/TSB metrics

    init(
        vo2Max: Double?,
        recentWorkouts: [HealthKitManager.WorkoutSummary],
        weeklyLoadScore: Double,
        daysSinceHardWorkout: Int?,
        acuteChronicRatio: Double?,
        metrics: TrainingMetrics?
    ) {
        self.vo2Max = vo2Max
        self.recentWorkouts = recentWorkouts.sorted { $0.date > $1.date }
        self.weeklyLoadScore = weeklyLoadScore
        self.daysSinceHardWorkout = daysSinceHardWorkout
        self.acuteChronicRatio = acuteChronicRatio
        self.metrics = metrics
    }

    /// Calendar days from the MOST RECENT hard workout to `referenceDate`:
    /// 0 means the same day, 1 yesterday, whatever the hour. Counting 24-hour
    /// periods made yesterday evening's session read as "today" at a 07:00
    /// morning reading. Order-independent: dedup returns workouts
    /// oldest-first, so taking the first hard one found the oldest and
    /// reported "6 days" for a hard session done yesterday.
    static func daysSinceHardWorkout(
        in workouts: [HealthKitManager.WorkoutSummary], relativeTo referenceDate: Date
    ) -> Int? {
        let latestHard = workouts.filter(\.isHardWorkout).max { $0.date < $1.date }
        guard let latestHard else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: latestHard.date), to: calendar.startOfDay(for: referenceDate)
        ).day
    }

    /// Adjustment factor for readiness based on training load (-2 to 0).
    /// Negative = recent hard training, so lower HRV is expected; 0 = rested
    /// or no hard workout on record, normal expectations.
    var readinessAdjustment: Double {
        guard let days = daysSinceHardWorkout else { return 0 }

        // Hard workout today, then tapering over the next two days.
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
