import Foundation
import Observation

/// Published streaming and pause/resume lifecycle state.
///
/// Split out from `RRCollector` so views that care about recording mode /
/// elapsed time / paused-session state don't re-render on every archive,
/// BLE telemetry, or morning-processing property the collector also
/// publishes.
///
/// Covers both active streaming (quick 3–5 min or overnight) and the
/// paused/resume-able fragment of an overnight session. The collector
/// retains thin back-compat getters/setters so the many extension files
/// that orchestrate these transitions don't all have to change at once.
@MainActor
@Observable
final class StreamingLifecycle {
    /// True while a streaming-mode recording is active (quick or overnight).
    /// Drives `DeviceStatus.isStreaming` through the collector's binding.
    var isStreamingMode: Bool = false

    /// Target duration for a quick streaming session (seconds).
    var streamingTargetSeconds: Int = 180

    /// Elapsed seconds of the active streaming session.
    var streamingElapsedSeconds: Int = 0

    /// True while an overnight streaming session is active (vs. a quick one).
    var isOvernightStreaming: Bool = false

    /// True while the overnight session is paused (e.g. brief device
    /// disconnect that the user chose to resume).
    var isPaused: Bool = false

    /// Snapshot of the session that was captured at pause time, or nil if
    /// not currently paused.
    var pausedSession: HRVSession?

    /// Number of beats captured up to the pause point.
    var pausedBeatCount: Int = 0

    /// True while one caller (the morning stop, a pause or a discard) is
    /// ending the overnight session: from its claim, taken before its first
    /// suspension, until the night is archived, paused, discarded or
    /// failed. Only one caller can hold it, so a night is never ended
    /// twice, and while it is held the night still counts as live although
    /// `isOvernightStreaming` is already false. `RRCollector.isOvernightEnding`
    /// is different: it stays set until the next night starts, so a late
    /// arming attempt is still refused after the ending is over.
    private(set) var isEndingOvernight: Bool = false

    /// Claims the ending of the overnight session for the caller. False when
    /// no night is streaming or another caller is already ending it; the
    /// caller then leaves the night alone.
    func claimOvernightEnding() -> Bool {
        guard isOvernightStreaming, !isEndingOvernight else { return false }
        isEndingOvernight = true
        return true
    }

    /// The claimed ending is over.
    func releaseOvernightEnding() {
        isEndingOvernight = false
    }
}
