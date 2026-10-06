import Foundation

/// The one daily-load bucketing and Banister EWMA behind both training-load
/// paths: the live value (`TrainingHealthQueries.calculateTrainingMetrics`,
/// published as `TrainingMetricsCache.current`) and the cache's day-by-day
/// `dailySeries`. Both call these functions with the same heart-rate anchors,
/// so a day's load and the EWMA step are computed one way only; the two paths
/// differ only in how many days they replay.
enum TrainingLoadSeries {
    /// What a workout without a precomputed load is scored against (Banister
    /// TRIMP's heart-rate reserve). Resolved once per refresh and handed to
    /// both paths.
    struct HeartRateAnchors: Equatable, Codable, Sendable {
        let restingHR: Double
        let maxHR: Double

        /// Resting HR is Apple's measured value when Health has one, else the
        /// user's resting-HR setting (`UserSettings.effectiveRestingHR`);
        /// max HR is the user's physiological max (`effectiveMaxHR`).
        static func resolve(appleRestingHR: Double?, settingRestingHR: Int, settingMaxHR: Int) -> HeartRateAnchors {
            HeartRateAnchors(restingHR: appleRestingHR ?? Double(settingRestingHR), maxHR: Double(settingMaxHR))
        }
    }

    /// ATL and CTL after a day's EWMA step.
    struct Point: Equatable, Sendable {
        let atl: Double
        let ctl: Double
        var tsb: Double { ctl - atl }

        static let zero = Point(atl: 0, ctl: 0)

        /// One discrete day of the PMC EWMA, exact `e^(−1/τ)` decay:
        /// X_today = load·(1−e^(−1/τ)) + X_yesterday·e^(−1/τ), CTL τ = 42 d,
        /// ATL τ = 7 d — Coggan Performance Manager Chart (TrainingPeaks);
        /// decay λ = 1−e^(−1/τ) per GoldenCheetah / intervals.icu. The `1/τ`
        /// linear form is ~7 % off on ATL.
        func stepped(load: Double) -> Point {
            let atlDecay = exp(-1.0 / Double(TrainingConstants.EWMA.acuteDays))
            let ctlDecay = exp(-1.0 / Double(TrainingConstants.EWMA.chronicDays))
            return Point(
                atl: load * (1 - atlDecay) + atl * atlDecay,
                ctl: load * (1 - ctlDecay) + ctl * ctlDecay
            )
        }
    }

    /// Load per local calendar day from `firstDay` through `lastDay`, every
    /// day present (rest days 0, so the EWMA decays across them).
    ///
    /// Each workout adds its `effectiveLoad` (precomputed power/HR/METs load,
    /// else Banister TRIMP against `anchors`). Workouts outside the window are
    /// skipped: one older than `firstDay` would sit in a bucket with no rest
    /// days around it, and a future-dated one is a bad clock or import. Each
    /// day is capped at `TrainingConstants.TRIMP.maxDailyLoad`, a backstop
    /// against a dedup miss or a corrupt load.
    static func dailyLoad(
        workouts: [HealthKitManager.WorkoutSummary],
        firstDay: Date,
        lastDay: Date,
        anchors: HeartRateAnchors,
        calendar: Calendar = .current
    ) -> [Date: Double] {
        var daily: [Date: Double] = [:]
        var day = calendar.startOfDay(for: firstDay)
        let end = calendar.startOfDay(for: lastDay)
        while day <= end {
            daily[day] = 0
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        for workout in workouts {
            let workoutDay = calendar.startOfDay(for: workout.date)
            guard daily[workoutDay] != nil else { continue }
            daily[workoutDay, default: 0] += workout.effectiveLoad(restingHR: anchors.restingHR, maxHR: anchors.maxHR)
        }
        return daily.mapValues { min($0, TrainingConstants.TRIMP.maxDailyLoad) }
    }

    /// The EWMA after every day of `dailyLoad`, replayed in date order from a
    /// zero seed.
    static func replay(_ dailyLoad: [Date: Double]) -> [Date: Point] {
        var point = Point.zero
        var series: [Date: Point] = [:]
        for day in dailyLoad.keys.sorted() {
            point = point.stepped(load: dailyLoad[day] ?? 0)
            series[day] = point
        }
        return series
    }

    /// The EWMA after `day`: every day of `dailyLoad` up to and including it.
    static func point(through day: Date, in dailyLoad: [Date: Double]) -> Point {
        dailyLoad.keys.sorted().filter { $0 <= day }.reduce(Point.zero) { point, date in
            point.stepped(load: dailyLoad[date] ?? 0)
        }
    }
}
