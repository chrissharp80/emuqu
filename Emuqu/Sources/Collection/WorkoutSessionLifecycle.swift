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
/// a straight move: every reference is compiler-checked, and the eleven
/// `[weak self]` captures inside (Combine sinks, detached tasks, the context
/// providers handed to `LiveWorkoutBroker`) now weakly hold this object rather
/// than the recorder. That is equivalent — the recorder is the only strong
/// reference, so this dies exactly when it would have, and every one of those
/// closures already answers nil-safely.
///
/// Holds its owner strongly and is built on demand by the recorder — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct WorkoutSessionLifecycle {
    let recorder: WorkoutRecorder

}
