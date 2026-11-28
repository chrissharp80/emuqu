import Combine
import Foundation

/// Published heart-rate metrics for an active workout.
///
/// Separate from `WorkoutRecorder` so HR-display chips only re-render on
/// real HR updates, not on every motion tick or session-lifecycle change.
///
/// Writers: `WorkoutRecorder` tick + HR-binding closures. Back-compat
/// getters on the recorder forward `recorder.currentHR` / `peakHR` /
/// `beatCount` reads to this object.
@Observable
@MainActor
final class WorkoutHR {
    /// Smoothed current HR in bpm (median of recent beats). Nil when
    /// there are not yet enough beats to report.
    var currentHR: Int?

    /// Highest HR observed during the session so far.
    var peakHR: Int = 0

    /// Whether `peakHR` is the Apple Watch's wrist HR rather than a strap
    /// reading. The iCloud copy leaves a wrist peak out (`CloudSessionPayload`).
    var peakHRFromWrist = false

    /// Total RR beats collected during this workout.
    var beatCount: Int = 0

    /// Reset to a fresh workout's initial state.
    func reset() {
        currentHR = nil
        peakHR = 0
        peakHRFromWrist = false
        beatCount = 0
    }

    /// Raise the peak to `hr` when it is higher, noting whether the reading
    /// that set it was the Watch's wrist HR.
    func raisePeak(to hr: Int, fromWrist: Bool) {
        guard hr > peakHR else { return }
        peakHR = hr
        peakHRFromWrist = fromWrist
    }
}
