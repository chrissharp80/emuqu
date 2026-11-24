import CoreLocation
import Foundation

// The per-second loop lives in `WorkoutTicker`; these forwarders give
// `WorkoutRecorder` callers the same entry points.

extension WorkoutRecorder {
    /// The tick loop. Built when a workout starts.
    var ticker: WorkoutTicker {
        WorkoutTicker(recorder: self)
    }

    func startTicker() { ticker.startTicker() }
    func stopTicker() { ticker.stopTicker() }
    func observeHeartRate() { ticker.observeHeartRate() }
    func strapSilentSeconds() -> Double? { ticker.strapSilentSeconds() }
    func liveRecoveryHoursNeeded() -> Double? { ticker.liveRecoveryHoursNeeded() }
    func liveZoneBreakdown() -> WorkoutZoneBreakdown { ticker.liveZoneBreakdown() }
    func syncedLiveTrends() -> WorkoutLiveTrends.Tally { ticker.syncedLiveTrends() }

    /// The HR-source arbitration lives on the ticker; this keeps
    /// `WorkoutRecorder.HRArbitration` resolving for its tests and call sites.
    typealias HRArbitration = WorkoutTicker.HRArbitration

    /// A pure location guard — no recorder state — so it forwards to the type.
    static func validCourse(_ loc: CLLocation?) -> Double? { WorkoutTicker.validCourse(loc) }
}
