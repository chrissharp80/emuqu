import Foundation

/// Correlation-scope plumbing for a workout.
///
/// Split out of `WorkoutRecorder.swift` because that file sits at the 2,000-line
/// SwiftLint error tier and this is a self-contained concern: it touches one
/// stored property and nothing else in the recorder.
///
/// The scope spans `start()` to the end of `stop()` — minutes to hours — so it
/// uses the explicit `begin`/`end` pair rather than `LogCorrelation.scope`. The
/// log lines that most need the tag come from `CBPeripheralDelegate` callbacks,
/// `CLLocationManager` updates, and pedometer ticks, none of which are children
/// of the call that opened the scope, so no lexical scope would cover them.
extension WorkoutRecorder {

    /// Opens the workout-wide correlation scope.
    ///
    /// Closes any scope still open first. A previous workout that failed to
    /// finalize — a crash mid-recording, a `stop()` that never ran — would
    /// otherwise leave its tag on this workout's lines, which is worse than no
    /// tag at all because it reads as authoritative.
    func beginWorkoutCorrelation() {
        endWorkoutCorrelation()
        logCorrelation = LogCorrelation.begin("workout")
    }

    /// Closes the workout-wide correlation scope.
    ///
    /// Safe to call when none is open, so both the success path at the end of
    /// `stop()` and the failure `defer` in `start()` can call it unconditionally.
    func endWorkoutCorrelation() {
        guard let token = logCorrelation else { return }
        LogCorrelation.end(token)
        logCorrelation = nil
    }
}
