import Foundation

// MARK: - Load & Trajectory
//
// The trajectory verdict the dashboard chip shows, exposed to the fact
// catalog. Split out of `AppFactResolver+Sessions.swift` so
// `TrainingLoadNamespace` stays under the type-body budget.

extension TrainingLoadNamespace {
    /// The Load & Trajectory verdict — assembled from the SAME inputs the
    /// Load & Trajectory screen uses (`LoadTrajectoryLoader`): the last 90
    /// days of the TrainingMetricsCache daily series with today's bucket
    /// replaced by the live load, the ramp as
    /// `TrajectoryVerdict.ctlSlopePerWeek`, today's CTL as the verdict's
    /// current value, and the user's comeback/overreach/peaking flags — so the AI and the screen agree.
    /// Covers trajectory direction, ramp band + rate, form descriptor, and
    /// Foster monotony/strain.
    func trajectoryRecord() -> FactValue {
        let seriesDict = MainActor.assumeIsolated { AppDependencies.current.analysis.trainingMetricsCache.dailySeries }
        guard let live = liveOrCached() else {
            return .missing(reason: .notYetComputed, detail: "not enough training history to judge a trajectory yet")
        }
        let series = Self.screenSeries(seriesDict, live: live)
        guard series.count >= 2, let today = series.last else {
            return .missing(reason: .notYetComputed, detail: "not enough training history to judge a trajectory yet")
        }
        let rampRate = Self.ctlRampPerWeek(series)
        let weekAgoCTL: Double? = series.count >= 8 ? series[series.count - 8].ctl : nil
        let verdict = Self.verdict(
            series: series, currentCTL: today.ctl, ctlOneWeekAgo: weekAgoCTL,
            rampRate: rampRate, tsb: live.tsb, cfg: settings())
        var record = Self.trajectoryFields(verdict: verdict, rampRate: rampRate, live: live)
        record.merge(Self.fosterFields(seriesDict)) { current, _ in current }
        return .record(record)
    }

    private static func trajectoryFields(verdict: TrajectoryVerdict, rampRate: Double, live: TrainingLoadState) -> [String: FactValue] {
        let form = FormDescriptor(tsb: live.tsb)
        return [
            "trajectory": .string(verdict.rawValue), "trajectory_label": .string(verdict.chipLabel),
            "ramp_rate_ctl_per_week": .double(rampRate), "ramp_band": .string(RampBand(tssPerDayPerWeek: rampRate).rawValue),
            "form_descriptor": .string(form.rawValue), "form_word": .string(form.word),
            "current_ctl": .double(live.ctl), "current_atl": .double(live.atl), "current_tsb": .double(live.tsb)
        ]
    }

    /// The screen's series: the last 90 days oldest → newest, today's bucket
    /// carrying the live CTL/ATL (historical days stay on the daily EWMA).
    private static func screenSeries(
        _ seriesDict: [Date: TrainingMetricsCache.DaySample],
        live: TrainingLoadState
    ) -> [TrainingMetricsCache.DaySample] {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        return seriesDict.values
            .filter { $0.date >= cutoff }
            .sorted { $0.date < $1.date }
            .map { day in
                guard calendar.isDateInToday(day.date) else { return day }
                return TrainingMetricsCache.DaySample(date: day.date, atl: live.atl, ctl: live.ctl, trimp: day.trimp)
            }
    }

    /// The screen's ramp rate: `TrajectoryVerdict.ctlSlopePerWeek` over the
    /// series' daily CTL, so the chip, the assistant and the Trajectory
    /// screen share one slope.
    static func ctlRampPerWeek(_ series: [TrainingMetricsCache.DaySample]) -> Double {
        TrajectoryVerdict.ctlSlopePerWeek(series.map(\.ctl))
    }

    /// The trajectory verdict for one snapshot of the series.
    private static func verdict(
        series: [TrainingMetricsCache.DaySample],
        currentCTL: Double,
        ctlOneWeekAgo: Double?,
        rampRate: Double,
        tsb: Double,
        cfg: UserSettings
    ) -> TrajectoryVerdict {
        TrajectoryVerdict.compute(.init(
            currentCTL: currentCTL, ctlOneWeekAgo: ctlOneWeekAgo, sampleCount: series.count,
            comebackActive: cfg.isComebackModeActive, overreachActive: cfg.isIntentionalOverreachInEffect,
            peakingDetected: cfg.peakingDetectionEnabled && isPeaking(series),
            rampRate: rampRate, currentTSB: tsb
        ))
    }

    /// Four consecutive days with TSB more than 10 % of CTL above zero — the
    /// dashboard's peaking signature.
    private static func isPeaking(_ series: [TrainingMetricsCache.DaySample]) -> Bool {
        let last4 = series.suffix(4)
        guard last4.count == 4 else { return false }
        return last4.allSatisfy { $0.ctl > 0 && ($0.ctl - $0.atl) / $0.ctl > 0.10 }
    }

    /// Foster monotony (mean/SD of daily load) + strain (load × monotony):
    /// high monotony means little day-to-day variation in load.
    private static func fosterFields(
        _ seriesDict: [Date: TrainingMetricsCache.DaySample]
    ) -> [String: FactValue] {
        let trimpByDay = seriesDict.reduce(into: [Date: Double]()) { $0[$1.key] = $1.value.trimp }
        guard let foster = RecoveryScoreCalculator.fosterMonotonyStrain(dailyTrimp: trimpByDay) else {
            return [:]
        }
        return ["monotony": .double(foster.monotony), "strain": .double(foster.strain)]
    }
}
