import Foundation

/// Overnight capture in bluetooth-central (streaming) mode: starting the
/// stream, the keep-alive timer, reconnect handling, the morning gather, and
/// the merge of the strap's own internal recording into the streamed night.
///
/// ## Why this is not on `RRCollector`
///
/// It was, as an 846-line extension. `RRCollector` was still
/// the largest type in the codebase at 4,644 lines across 17 files, and
/// overnight streaming was its single largest remaining piece.
///
/// The coupling was measured before the move rather than assumed, exactly as
/// it was for `SessionRecoveryCoordinator`: these functions read 39 members of
/// the collector, including live pipeline state like `currentSession`,
/// `isStreamingMode`, `recordingPhase` and `streamingElapsedSeconds`. So this
/// is not an independent subsystem and does not claim to be one.
///
/// What changes is that the 39 reads are now `collector.` — explicit, greppable
/// and countable — rather than looking like this type's own state and costing
/// nothing to add. Nine members are reached from outside; those keep forwarders
/// on the collector so no call site moved in the same change as the split.
///
/// Holds its owner strongly and is built on demand — see the note on
/// `CollectorSessionControl`.
@MainActor
struct OvernightStreamingCoordinator {
    let collector: RRCollector

}
