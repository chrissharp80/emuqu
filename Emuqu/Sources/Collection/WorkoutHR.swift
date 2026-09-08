import Combine
import Foundation

/// Published heart-rate metrics for an active workout.
///
/// Split out from `WorkoutRecorder` so HR-display chips only re-render on
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

    /// Total RR beats collected during this workout.
    var beatCount: Int = 0

    /// Reset to a fresh workout's initial state.
    func reset() {
        currentHR = nil
        peakHR = 0
        beatCount = 0
    }
}
