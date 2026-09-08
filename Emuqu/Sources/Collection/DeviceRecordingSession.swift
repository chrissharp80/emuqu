import Foundation

/// A capture session that runs on the strap's own memory rather than streaming
/// to the phone: starting it, stopping it, backing up the raw intervals, and
/// running the analysis that turns them into a scored session.
///
/// ## Why this is not on `RRCollector`
///
/// As a 451-line extension it would be, on the largest type in the codebase
/// (3,890 lines across seventeen files even with the recovery and
/// overnight-streaming coordinators split out).
///
/// The coupling was measured before the move rather than assumed: 36 collector
/// members, including live pipeline state — the current session, the archive,
/// the strap. This is the recording pipeline and does not claim otherwise. What
/// changes is that the reads are explicit instead of looking like this type's
/// own state.
///
/// Holds its owner strongly and is built on demand by the collector — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct DeviceRecordingSession {
    let collector: RRCollector

}
