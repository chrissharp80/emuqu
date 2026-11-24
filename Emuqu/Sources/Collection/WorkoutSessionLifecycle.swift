import Foundation

/// Bringing a workout up and the derived metrics it reports: the start
/// sequence and its deferred work, pause and resume, the
/// archive write, and normalized power / METs / the coach report.
///
/// Start is the most instrumented path in this codebase (see
/// `WorkoutStartLatencyTracker`). The closures it
/// hands out (detached tasks, interval callbacks, the context providers given
/// to `LiveWorkoutBroker`) capture `[weak recorder]`, so none keeps the
/// recorder alive, and each answers nil-safely once it is gone.
///
/// Holds its owner strongly and is built on demand by the recorder — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct WorkoutSessionLifecycle {
    let recorder: WorkoutRecorder

}
