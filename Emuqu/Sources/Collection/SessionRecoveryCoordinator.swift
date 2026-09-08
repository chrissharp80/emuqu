import Foundation

/// Everything the app does to rescue a recording that did not end cleanly.
///
/// Interrupted workouts, sessions still sitting on the strap, corrupted files,
/// cloud backups, the trash, and the paused-state restore path.
///
/// ## Why this is not on `RRCollector`
///
/// `RRCollector` is by far the largest type in the app (thousands of lines
/// across dozens of files), and recovery — some 1,500 lines — is the largest
/// piece of it that is not recording.
///
/// Recovery is genuinely coupled to the recording pipeline — measured, not
/// assumed: 34 members of the collector are read from
/// these files, including live state like `currentSession`, `isPaused`,
/// `pausedSession` and `recordingPhase`. So this does NOT claim to be an
/// independent subsystem, and the earlier `SessionDataMigrations` split (which
/// needed nothing of the pipeline) is not the same kind of move.
///
/// What changes is that the coupling is now a single explicit reference instead
/// of 34 implicit ones. Inside an extension, every one of those reads looked
/// like the type's own state and cost nothing to add; here each is `collector.`
/// and visible. That is the difference between a boundary and a habit, and it
/// is what makes the next split possible — the reads are now countable without
/// a script.
///
/// Holds its owner strongly and is built on demand by the collector — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct SessionRecoveryCoordinator {
    let collector: RRCollector

}
