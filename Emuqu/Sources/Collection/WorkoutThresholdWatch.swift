import Foundation

/// The limits the user set for a workout before starting (heart rate, power,
/// pace and the rest), and how long each has been breached. The trigger
/// engine reads both beside its built-in rules and fires a breach cue when a
/// metric stays outside its band past the threshold's `debounceSec`.
struct WorkoutThresholdWatch {
    /// The user's thresholds for this workout.
    private(set) var thresholds: [WorkoutThreshold] = []
    /// Seconds each threshold has been breached, by threshold ID: counts up
    /// while breached and drops to 0 the moment the metric is back inside.
    private(set) var breachSec: [UUID: Int] = [:]

    init(thresholds: [WorkoutThreshold] = []) {
        self.thresholds = thresholds
    }

    /// One tick of `threshold`: breached, inside the band, or not measurable
    /// this tick (which leaves its count as it was).
    mutating func record(_ threshold: WorkoutThreshold, breached: Bool?) {
        switch breached {
        case .some(true): breachSec[threshold.id, default: 0] += 1
        case .some(false): breachSec[threshold.id] = 0
        case .none: break
        }
    }
}
