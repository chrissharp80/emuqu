import Foundation

/// Everything the app does to rescue a recording that did not end cleanly.
///
/// Interrupted workouts, sessions still sitting on the strap, corrupted files,
/// cloud backups, the trash, and the paused-state restore path.
///
/// Holds its owner strongly and is built on demand by the collector — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct SessionRecoveryCoordinator {
    let collector: RRCollector

}
