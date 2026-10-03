import Foundation

// MARK: - Load & Trajectory
//
// The trajectory verdict the dashboard chip shows, exposed to the fact
// catalog. Split out of `AppFactResolver+Sessions.swift` so
// `TrainingLoadNamespace` stays under the type-body budget.

extension TrainingLoadNamespace {
    /// The Load & Trajectory verdict — assembled from the SAME inputs the
    /// dashboard chip uses (TrainingMetricsCache daily series + live load +
    /// the user's comeback/overreach/peaking flags) so the AI and the UI can
    /// never disagree. Covers trajectory direction, ramp band + rate, form
    /// descriptor, and Foster monotony/strain.
    ///
    /// Yesterday-vs-8-days-ago (both completed end-of-day states) matches
    /// the dashboard's apples-to-apples ramp; see DashboardV2View.
    func trajectoryRecord() -> FactValue {
        let seriesDict = MainActor.assumeIsolated { AppDependencies.current.analysis.trainingMetricsCache.dailySeries }
        let series = seriesDict.values.sorted { $0.date < $1.date }
        guard series.count >= 2, let live = liveOrCached() else {
            return .missing(reason: .notYetComputed, detail: "not enough training history to judge a trajectory yet")
        }
        let yesterdayCTL = series[series.count - 2].ctl
        let weekAgoCTL: Double? = series.count >= 9 ? series[series.count - 9].ctl : nil
        let rampRate = weekAgoCTL.map { yesterdayCTL - $0 } ?? 0
        let verdict = Self.verdict(
            series: series, currentCTL: yesterdayCTL, ctlOneWeekAgo: weekAgoCTL,
            rampRate: rampRate, tsb: live.tsb, cfg: settings())
        let form = FormDescriptor(tsb: live.tsb)
        var record: [String: FactValue] = [
            "trajectory": .string(verdict.rawValue), "trajectory_label": .string(verdict.chipLabel),
            "ramp_rate_ctl_per_week": .double(rampRate), "ramp_band": .string(RampBand(tssPerDayPerWeek: rampRate).rawValue),
            "form_descriptor": .string(form.rawValue), "form_word": .string(form.word),
            "current_ctl": .double(live.ctl), "current_atl": .double(live.atl), "current_tsb": .double(live.tsb)
        ]
        record.merge(Self.fosterFields(seriesDict)) { current, _ in current }
        return .record(record)
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
    /// high monotony means under-varied training, an overtraining-risk signal.
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
