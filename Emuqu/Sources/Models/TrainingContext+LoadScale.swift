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
}
