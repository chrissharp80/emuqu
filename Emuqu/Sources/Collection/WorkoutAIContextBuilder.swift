import Foundation

/// Everything the assistant is told about a workout in progress: the per-tick
/// context snapshot, route topology and climbs ahead, live weather, interval
/// progress, threshold breaches, split paces and current grade.
///
/// Holds its owner strongly and is built on demand — see the note on
/// `CollectorSessionControl`.
@MainActor
struct WorkoutAIContextBuilder {
    let recorder: WorkoutRecorder

}
