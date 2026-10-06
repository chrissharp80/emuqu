import CoreLocation
import Foundation

// The per-second loop lives in `WorkoutTicker` — 936 lines off
// `WorkoutRecorder`, its largest single file.
//
// These forwarders keep every existing call site working.

extension WorkoutRecorder {
    /// The tick loop. Built when a workout starts.
    var ticker: WorkoutTicker {
        WorkoutTicker(recorder: self)
    }

    func startTicker() { ticker.startTicker() }
    func stopTicker() { ticker.stopTicker() }
    func observeHeartRate() { ticker.observeHeartRate() }
    func incrementalBackupTick() { ticker.incrementalBackupTick() }
    func strapSilentSeconds() -> Double? { ticker.strapSilentSeconds() }
    func liveProjectedMinutesUntilFade() -> Double? { ticker.liveProjectedMinutesUntilFade() }
    func liveRecoveryHoursNeeded() -> Double? { ticker.liveRecoveryHoursNeeded() }

    /// The HR-source arbitration moved with the ticker; this keeps
    /// `WorkoutRecorder.HRArbitration` resolving for its tests and call sites.
    typealias HRArbitration = WorkoutTicker.HRArbitration

    /// A pure location guard — no recorder state — so it forwards to the type.
    static func validCourse(_ loc: CLLocation?) -> Double? { WorkoutTicker.validCourse(loc) }
}
