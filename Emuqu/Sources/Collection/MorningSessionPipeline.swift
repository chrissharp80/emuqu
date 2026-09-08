import Foundation

/// What happens to a night between the strap stopping and a score on screen:
/// gathering the data off the device, processing it into a session, running the
/// analysis and recovery score, and the accept/reject step where the user
/// decides whether to keep it.
///
/// ## Why this is not on `RRCollector`
///
/// As extensions it would add 623 lines to the collector.
///
/// All four live together because they are one flow — gather feeds process,
/// process runs analysis, analysis produces the score the acceptance step keeps
/// or discards — and they call each other directly at every stage. Split
/// individually, each of those crossings would have needed a forwarder.
///
/// The coupling to the collector was measured before the move rather than
/// assumed: the archive, the live session, the analysis pipeline and the
/// published state the morning screen binds to.
///
/// Holds its owner strongly and is built on demand by the collector — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct MorningSessionPipeline {
    let collector: RRCollector

}
