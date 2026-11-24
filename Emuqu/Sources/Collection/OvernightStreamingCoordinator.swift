import Foundation

/// Overnight capture in bluetooth-central (streaming) mode: starting the
/// stream, the keep-alive timer, reconnect handling, and the merge of the
/// strap's own internal recording into the streamed night. The morning
/// gather itself is `MorningSessionPipeline.gatherOvernightData`
/// (RRCollector+OvernightGather).
///
/// Holds its owner strongly and is built on demand — see the note on
/// `CollectorSessionControl`.
@MainActor
struct OvernightStreamingCoordinator {
    let collector: RRCollector

}
