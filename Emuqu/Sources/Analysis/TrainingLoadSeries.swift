import Foundation

/// The one daily-load bucketing and Banister EWMA behind both training-load
/// paths: the live value (`TrainingHealthQueries.calculateTrainingMetrics`,
/// published as `TrainingMetricsCache.current`) and the cache's day-by-day
/// `dailySeries`. Both call these functions with the same heart-rate anchors,
/// so a day's load and the EWMA step are computed one way only; the two paths
/// differ only in how many days they replay.
enum TrainingLoadSeries {
    /// Everything a workout without a precomputed load is scored against:
    /// the heart rates of Banister TRIMP's heart-rate reserve and the
    /// coefficients for the user's biological sex, and the LTHR that puts
    /// every TRIMP-scale load on the TSS scale (`tss(fromTRIMP:)`). Resolved
    /// once per refresh and handed to both paths; the cache's `LoadSettings`
    /// carries the settings behind them, so a change rebuilds both paths.
    struct HeartRateAnchors: Hashable, Codable, Sendable {
        let restingHR: Double
        let maxHR: Double
        /// Lactate-threshold HR: one hour here is 100 on the TSS scale.
        let lthr: Double
        /// Banister's coefficients: female for a female setting, else male.
        let sex: WorkoutAnalyzer.BanisterSex

        /// `lthr` nil, or at or below `restingHR`, takes the estimate the
        /// strap's hrTSS falls back to (`WorkoutAnalyzer.computeHrTSS`):
        /// 0.88 x max HR.
        init(restingHR: Double, maxHR: Double, lthr: Double? = nil, sex: WorkoutAnalyzer.BanisterSex = .male) {
            self.restingHR = restingHR
            self.maxHR = maxHR
            self.lthr = lthr.flatMap { $0 > restingHR ? $0 : nil } ?? maxHR * 0.88
            self.sex = sex
        }

        /// Resting HR is Apple's measured value when Health has one, else the
        /// user's resting-HR setting (`UserSettings.effectiveRestingHR`);
        /// max HR is the user's physiological max (`effectiveMaxHR`); LTHR is
        /// the user's (`effectiveLTHR`), the one the strap's hrTSS divides by;
        /// the sex is the setting's, male when it is not set, as at finalize.
        static func resolve(
            appleRestingHR: Double?, settingRestingHR: Int, settingMaxHR: Int, settingLTHR: Int? = nil,
            settingSex: UserSettings.BiologicalSex? = nil
        ) -> HeartRateAnchors {
            HeartRateAnchors(
                restingHR: appleRestingHR ?? Double(settingRestingHR), maxHR: Double(settingMaxHR),
                lthr: settingLTHR.map(Double.init), sex: WorkoutAnalyzer.BanisterSex(settingSex)
            )
        }

        /// `trimp` (Banister's scale) on the TSS scale the power, hrTSS and
        /// METs tiers share, through the strap's own hrTSS rule
        /// (`WorkoutAnalyzer.hrTSS(fromTRIMP:)`) at these anchors. Anchors
        /// with no reserve cannot place it, and score a workout's own HR 0
        /// already; a stored TRIMP is then returned as it is.
        func tss(fromTRIMP trimp: Double) -> Double {
            WorkoutAnalyzer.hrTSS(fromTRIMP: trimp, lthr: lthr, maxHR: maxHR, restHR: restingHR, sex: sex) ?? trimp
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
    /// Each workout adds its `effectiveLoad`, on the TSS scale whatever its
    /// source (power TSS, hrTSS, METs load, or a TRIMP placed on that scale at
    /// `anchors`). Workouts outside the window are
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
            daily[workoutDay, default: 0] += workout.effectiveLoad(anchors: anchors)
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

    /// The EWMA after `day`: `replay` over every day of `dailyLoad` up to and
    /// including it, read at the last of them. `.zero` when none is.
    static func point(through day: Date, in dailyLoad: [Date: Double]) -> Point {
        let upToDay = dailyLoad.filter { $0.key <= day }
        guard let lastDay = upToDay.keys.max() else { return .zero }
        return replay(upToDay)[lastDay] ?? .zero
    }
}
