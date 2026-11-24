import Foundation

/// A capture session that runs on the strap's own memory rather than streaming
/// to the phone: starting it, stopping it, backing up the raw intervals, and
/// running the analysis that turns them into a scored session.
///
/// Holds its owner strongly and is built on demand by the collector — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct DeviceRecordingSession {
    let collector: RRCollector

}
