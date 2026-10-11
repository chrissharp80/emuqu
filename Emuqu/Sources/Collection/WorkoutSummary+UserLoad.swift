import Foundation
import os

// One per-workout load for every screen.
//
// The daily buckets behind ATL / CTL / TSB use `effectiveLoad` against the
// resolved heart-rate anchors (`TrainingLoadSeries.HeartRateAnchors`: Apple
// Health's latest resting HR, else the setting; the user's max HR). The
// workout lists, the PDF's training snapshot, the morning summary and the
// readiness acute-fatigue term read the same load here, so the same ride
// reads the same on each (`WorkoutLoadRestingHR` keeps the Apple value across
// launches for that).

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
///
/// The fetched value is kept across launches (with when it was measured), so
/// a screen drawn before this launch's first HealthKit fetch scores a workout
/// against the same resting HR as one drawn after it. A value measured more
/// than `maxAgeDays` ago is not used, the same window `fetchAppleRestingHR`
/// reads.
enum WorkoutLoadRestingHR {
    /// How recent an Apple resting HR must be to anchor training load.
    static let maxAgeDays = 30

    private static let storeKey = "WorkoutLoadRestingHR.lastApple.v1"
    private static let lastAppleValue = OSAllocatedUnfairLock<(value: Double, at: Date)?>(initialState: stored())

    static var anchors: TrainingLoadSeries.HeartRateAnchors {
        let settings = AppDependencies.current.app.settingsManager.settingsSnapshot
        return .resolve(
            appleRestingHR: currentAppleValue(),
            settingRestingHR: settings.effectiveRestingHR,
            settingMaxHR: settings.effectiveMaxHR
        )
    }

    /// Called by `fetchAppleRestingHR` with each value it reads and the
    /// sample's date.
    static func record(_ value: Double, measuredAt: Date) {
        guard value.isFinite, value > 0 else { return }
        lastAppleValue.withLock { $0 = (value, measuredAt) }
        UserDefaults.standard.set(["value": value, "at": measuredAt.timeIntervalSince1970], forKey: storeKey)
    }

    private static func currentAppleValue() -> Double? {
        guard let last = lastAppleValue.withLock({ $0 }),
              Date().timeIntervalSince(last.at) <= TimeInterval(maxAgeDays) * 86_400 else { return nil }
        return last.value
    }

    private static func stored() -> (value: Double, at: Date)? {
        guard let entry = UserDefaults.standard.dictionary(forKey: storeKey),
              let value = entry["value"] as? Double, let at = entry["at"] as? Double else { return nil }
        return (value, Date(timeIntervalSince1970: at))
    }
}
