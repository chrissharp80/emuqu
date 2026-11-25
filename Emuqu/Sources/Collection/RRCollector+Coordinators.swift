import Foundation

// The collector's work, by job. Each coordinator is built once, in
// `RRCollector`, over the parts it uses; callers name the job they ask for.

extension RRCollector {
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
