import Foundation
import os

// One per-workout load for every screen.
//
// The daily buckets behind ATL / CTL / TSB use `effectiveLoad` with the
// user's resting HR (Apple Health's latest, else the setting). The workout
// lists, the PDF's training snapshot, the morning summary and the readiness
// acute-fatigue term used `calculateTrimp()` with the 60 bpm default, which
// also ignores power-based load: the same ride read differently on each.

extension HealthKitManager.WorkoutSummary {
    /// The load the daily totals count for this workout.
    var userScaledLoad: Double {
        effectiveLoad(restingHR: WorkoutLoadRestingHR.current)
    }
}

/// The resting HR the load calculation uses: the latest Apple Health value
/// the training queries fetched, else the user's own setting.
enum WorkoutLoadRestingHR {
    private static let lastAppleValue = OSAllocatedUnfairLock<Double?>(initialState: nil)

    static var current: Double {
        lastAppleValue.withLock { $0 }
            ?? Double(AppDependencies.current.app.settingsManager.settingsSnapshot.effectiveRestingHR)
    }

    /// Called by `fetchAppleRestingHR` with each value it reads.
    static func record(_ value: Double) {
        guard value.isFinite, value > 0 else { return }
        lastAppleValue.withLock { $0 = value }
    }
}
