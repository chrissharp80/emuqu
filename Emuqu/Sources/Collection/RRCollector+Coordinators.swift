import Foundation

// The collector's work, by job. Each coordinator is a value built on each
// access around this collector; callers name the job they ask for.

extension RRCollector {
    /// Gather → process → analyse → accept.
    var morning: MorningSessionPipeline {
        MorningSessionPipeline(collector: self)
    }

    /// Overnight capture in streaming mode. Built on access: a daytime launch
    /// never touches it.
    var overnightStreaming: OvernightStreamingCoordinator {
        OvernightStreamingCoordinator(collector: self)
    }

    /// Capture to the strap's own memory, and its download.
    var deviceRecording: DeviceRecordingSession {
        DeviceRecordingSession(collector: self)
    }

    /// Recovery of interrupted, lost and trashed recordings.
    var recovery: SessionRecoveryCoordinator {
        SessionRecoveryCoordinator(collector: self)
    }

    /// The review card's Discard: the night saved for review leaves the
    /// archive and the baseline first, while `currentSession` still names it,
    /// then the review state is cleared.
    func rejectSession() async {
        morning.discardReviewArchivedSession()
        await morning.rejectSession()
    }

    /// Whether morning processing fetches the strap's own recording.
    enum DeviceFetchPolicy {
        /// Fetch the strap's internal recording (the default).
        case automatic
        /// Skip it: the user asked for streaming-only analysis.
        case skipByUser
    }
}
