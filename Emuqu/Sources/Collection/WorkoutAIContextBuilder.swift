import Foundation

/// Everything the assistant is told about a workout in progress: the per-tick
/// context snapshot, route topology and climbs ahead, live weather, interval
/// progress, threshold breaches, split paces and current grade.
///
/// ## Why this is not on `WorkoutRecorder`
///
/// As an extension it would add 526 lines to `WorkoutRecorder`, the largest
/// type in the codebase (4,422 lines across 11 files with it), and it is the
/// largest piece that is not the recording pipeline itself.
///
/// The coupling was measured before the move, not assumed: these functions read
/// 44 members of the recorder. It is a reader, though — it derives a snapshot
/// and mutates almost nothing — which is what makes it separable in a way the
/// ticker and the start path are not.
///
/// Chosen ahead of the two larger files deliberately. This one contains no
/// closures capturing `self` and no `Task {}`, so the move cannot change
/// capture semantics; `+Start.swift` has eleven `[weak self]` closures and
/// fifteen tasks on the single most important path in the app, and is a
/// different kind of risk that deserves its own change.
///
/// Holds its owner strongly and is built on demand — see the note on
/// `CollectorSessionControl`.
@MainActor
struct WorkoutAIContextBuilder {
    let recorder: WorkoutRecorder

}
