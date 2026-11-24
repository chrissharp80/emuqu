import Foundation

/// The once-per-second loop that drives a live workout: reading the sensors,
/// arbitrating between heart-rate sources, accruing the auto-pause counters,
/// updating the live metrics the UI shows, and taking the incremental backups
/// that make a crash recoverable.
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
