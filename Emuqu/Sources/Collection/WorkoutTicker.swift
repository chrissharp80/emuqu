import Foundation

/// The once-per-second loop that drives a live workout: reading the sensors,
/// arbitrating between heart-rate sources, accruing the auto-pause counters,
/// updating the live metrics the UI shows, and taking the incremental backups
/// that make a crash recoverable.
///
/// ## Why this is not on `WorkoutRecorder`
///
/// It was, as a 936-line extension — the recorder's largest single file.
///
/// A file split alone satisfies the 1500-line
/// *file* budget, but the aggregate type-size gate counts a type across all its
/// files, so that leaves the god object exactly as large. This moves the lines off
/// the type.
///
/// The coupling was measured before the move rather than assumed, and it is the
/// heaviest in the codebase: 72 recorder members. That is what a per-second loop
/// over every live signal looks like, and this does not pretend to be a
/// separable subsystem. What changes is that all 72 reads are now `recorder.`
/// and countable — the difference between a boundary and a habit.
///
/// The tick timer captures `[weak recorder]` and the strap-HR observation
/// holds the recorder weakly (`ObservationLoop`), so neither keeps it alive
/// and both no-op once it is gone.
///
/// Holds its owner strongly and is built on demand by the recorder — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct WorkoutTicker {
    let recorder: WorkoutRecorder

}
