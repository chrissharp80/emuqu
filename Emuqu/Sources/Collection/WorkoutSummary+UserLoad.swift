import Foundation
import os

// One per-workout load for every screen.
//
// The daily buckets behind ATL / CTL / TSB use `effectiveLoad` against the
// resolved heart-rate anchors (`TrainingLoadSeries.HeartRateAnchors`: Apple
// Health's latest resting HR, else the setting; the user's max HR). The
// workout lists, the PDF's training snapshot, the morning summary and the
// readiness acute-fatigue term read the same load here, so the same ride
// reads the same on each.

extension HealthKitManager.WorkoutSummary {
    /// The load the daily totals count for this workout.
    var userScaledLoad: Double {
        let anchors = WorkoutLoadRestingHR.anchors
        return effectiveLoad(restingHR: anchors.restingHR, maxHR: anchors.maxHR)
    }
}

/// The heart-rate anchors the load calculation uses, read synchronously:
/// the latest Apple Health resting HR the training queries fetched, else the
/// user's own setting, resolved the same way as `trainingHeartRateAnchors`.
enum WorkoutLoadRestingHR {
    private static let lastAppleValue = OSAllocatedUnfairLock<Double?>(initialState: nil)

    static var anchors: TrainingLoadSeries.HeartRateAnchors {
        let settings = AppDependencies.current.app.settingsManager.settingsSnapshot
        return .resolve(
            appleRestingHR: lastAppleValue.withLock { $0 },
            settingRestingHR: settings.effectiveRestingHR,
            settingMaxHR: settings.effectiveMaxHR
        )
    }

    /// Called by `fetchAppleRestingHR` with each value it reads.
    static func record(_ value: Double) {
        guard value.isFinite, value > 0 else { return }
        lastAppleValue.withLock { $0 = value }
    }
}
