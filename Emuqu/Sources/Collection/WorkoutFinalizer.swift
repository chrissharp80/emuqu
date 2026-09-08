import Foundation

/// Turning a finished workout into an archived session: running the analysis,
/// assembling the metadata, writing it, and everything that has to happen
/// exactly once at the end of a workout.
///
/// ## Why this is not on `WorkoutRecorder`
///
/// As a 600-line extension it made `WorkoutRecorder` the
/// largest type in the codebase (3,947 lines across eleven files).
///
/// Putting these lines in their own file satisfies the
/// 1500-line *file* budget, but that is a different measurement from the aggregate
/// type-size gate, which counts a type across all its files — an extension in
/// a new file is the same object with another window. A separate type moves
/// the lines off `WorkoutRecorder`.
///
/// The coupling was measured before the move rather than assumed: 25 recorder
/// members, mostly the live session and the sub-objects holding what was
/// recorded. Finalize is genuinely the end of the recording pipeline and does
/// not claim to be separable from it. What changes is that those reads are now
/// `recorder.` and countable.
///
/// Holds its owner strongly and is built on demand by the recorder — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct WorkoutFinalizer {
    let recorder: WorkoutRecorder

}
