import Foundation

/// What happens to a night between the strap stopping and a score on screen:
/// gathering the data off the device, processing it into a session, running the
/// analysis and recovery score, and the accept/reject step where the user
/// decides whether to keep it.
///
/// All four live together because they are one flow — gather feeds process,
/// process runs analysis, analysis produces the score the acceptance step keeps
/// or discards — and they call each other directly at every stage. Split
/// individually, each of those crossings would need a forwarder.
///
/// Holds its owner strongly and is built on demand by the collector — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct MorningSessionPipeline {
    let collector: RRCollector

}
