import Foundation

/// Bringing a workout up and the derived metrics it reports: the start
/// sequence and its deferred work, pause and resume, the keep-alives, the
/// archive write, and normalized power / METs / the coach report.
///
/// ## Why this is not on `WorkoutRecorder`
///
/// As extensions it would add 1,369 lines to the recorder.
///
/// Start is the most instrumented path in this codebase — the latency tracker
/// exists because a 14-second hang was traced through it — and it is the one
/// the extraction work avoided longest for that reason. It is done last and as
/// a straight move: every reference is compiler-checked. The closures it
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
