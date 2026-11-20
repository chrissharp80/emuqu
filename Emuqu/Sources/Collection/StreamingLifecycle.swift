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

    /// One caller's hold on ending the overnight session. Only the claim
    /// that is still held releases it, so a caller whose claim was dropped
    /// for a new night cannot end that night's ending.
    struct OvernightEndingClaim: Equatable {
        fileprivate let number: Int
    }

    /// The claim held while one caller (the morning stop, a pause or a
    /// discard) is ending the overnight session: from its claim, taken before
    /// its first suspension, until the night is on the review card, paused,
    /// discarded or failed. `RRCollector.isOvernightEnding` is different: it
    /// stays set until the next night starts, so a late arming attempt is
    /// still refused after the ending is over.
    private(set) var overnightEndingClaim: OvernightEndingClaim?

    @ObservationIgnored private var claimsMade = 0

    /// Only one caller can end a night, and while it does the night still
    /// counts as live although `isOvernightStreaming` is already false.
    var isEndingOvernight: Bool { overnightEndingClaim != nil }

    /// Claims the ending of the overnight session for the caller. Nil when
    /// no night is streaming or another caller is already ending it; the
    /// caller then leaves the night alone.
    func claimOvernightEnding() -> OvernightEndingClaim? {
        guard isOvernightStreaming, overnightEndingClaim == nil else { return nil }
        claimsMade += 1
        let claim = OvernightEndingClaim(number: claimsMade)
        overnightEndingClaim = claim
        return claim
    }

    /// The claimed ending is over. Nothing happens when this claim is no
    /// longer the one held.
    func releaseOvernightEnding(_ claim: OvernightEndingClaim) {
        guard overnightEndingClaim == claim else { return }
        overnightEndingClaim = nil
    }

    /// A night is starting: no earlier ending can still own the recorder,
    /// so a claim left behind (a caller that never returned) is dropped
    /// rather than blocking every Stop, Pause and Discard until relaunch.
    /// Returns whether one was held.
    func dropStaleOvernightEnding() -> Bool {
        guard overnightEndingClaim != nil else { return false }
        overnightEndingClaim = nil
        return true
    }
}
