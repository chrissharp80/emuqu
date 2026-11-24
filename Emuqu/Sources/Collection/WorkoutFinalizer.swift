import Foundation

/// Turning a finished workout into an archived session: running the analysis,
/// assembling the metadata, writing it, and everything that has to happen
/// exactly once at the end of a workout.
///
/// Holds its owner strongly and is built on demand by the recorder — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct WorkoutFinalizer {
    let recorder: WorkoutRecorder

}
