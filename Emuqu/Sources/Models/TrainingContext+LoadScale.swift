import Foundation

// Reading a training snapshot's load figures on the TSS scale, whatever
// scale they were recorded on (`TrainingContext.loadScale`).

extension TrainingContext {
    /// The scale the recorded figures are on.
    var scale: LoadScale { loadScale ?? .trimp }

    /// Acute Training Load (7-day EWMA of daily load), TSS scale - "fatigue"
    var atl: Double { onTSSScale(recordedATL) }
    /// Chronic Training Load (42-day EWMA of daily load), TSS scale - "fitness"
    var ctl: Double { onTSSScale(recordedCTL) }
    /// Training-load balance (CTL - ATL), TSS scale - "form/freshness"
    var tsb: Double { onTSSScale(recordedTSB) }
    /// The load of the day before this reading, TSS scale.
    var yesterdayLoad: Double { onTSSScale(recordedYesterdayLoad) }
    /// `yesterdayLoad` on Banister's TRIMP scale, for a surface that labels
    /// the figure TRIMP and grades it with TRIMP bands.
    var yesterdayTRIMP: Double {
        Self.trimp(fromTSS: yesterdayLoad, anchors: WorkoutLoadRestingHR.anchors)
    }

    /// This context with every load figure on the TSS scale at `anchors`,
    /// stamped `.tss`: the copy a context built from it with new load
    /// figures starts from.
    func onTSSScale(anchors: TrainingLoadSeries.HeartRateAnchors) -> TrainingContext {
        let convert = { (value: Double) in self.scale == .tss ? value : anchors.tss(fromTRIMP: value) }
        return TrainingContext(
            atl: convert(recordedATL), ctl: convert(recordedCTL), tsb: convert(recordedTSB),
            yesterdayTrimp: convert(recordedYesterdayLoad), vo2Max: vo2Max,
            daysSinceHardWorkout: daysSinceHardWorkout, recentWorkouts: recentWorkouts, loadScale: .tss
        )
    }

    /// The same recorded figures with the Health readings replaced, on the
    /// same scale.
    func withHealthReadings(vo2Max: Double?, recentWorkouts: [WorkoutSnapshot]?) -> TrainingContext {
        TrainingContext(
            atl: recordedATL, ctl: recordedCTL, tsb: recordedTSB, yesterdayTrimp: recordedYesterdayLoad,
            vo2Max: vo2Max, daysSinceHardWorkout: daysSinceHardWorkout, recentWorkouts: recentWorkouts,
            loadScale: loadScale
        )
    }

    fileprivate func onTSSScale(_ recorded: Double) -> Double {
        scale == .tss ? recorded : WorkoutLoadRestingHR.anchors.tss(fromTRIMP: recorded)
    }

    /// A TSS-scale load on Banister's TRIMP scale at `anchors`: the inverse
    /// of `HeartRateAnchors.tss(fromTRIMP:)`, which is linear, so one hour at
    /// threshold maps back to its TRIMP.
    static func trimp(fromTSS tss: Double, anchors: TrainingLoadSeries.HeartRateAnchors) -> Double {
        let perHundred = anchors.tss(fromTRIMP: 100)
        guard perHundred > 0 else { return tss }
        return tss * 100 / perHundred
    }
}
