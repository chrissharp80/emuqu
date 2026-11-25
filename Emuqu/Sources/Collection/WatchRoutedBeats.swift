import Foundation

/// The beats a workout took through the Watch's direct-strap path: when the
/// strap is paired to the Watch rather than the iPhone, the Watch forwards RR
/// and HR over WCSession (`WatchStrapConnector`), and each tick drains the
/// bridge's queue of them (`drainPendingWatchStrapRR`).
struct WatchRoutedBeats {
    /// When this path last produced beats. Separate from the iPhone strap's
    /// own freshness (`WorkoutRecorder.lastStrapHRAt`), so the wrist-HR
    /// fallback can tell "the iPhone's strap dropped and the Watch carries
    /// it" from "both dropped, fall through to wrist".
    var lastAt: Date?
    /// The session-relative time given to the next forwarded beat's
    /// `RRPoint.t_ms`: 0 at workout start, advanced by each beat's interval.
    var cumulativeMs: Int64 = 0
    /// Every beat that came this way, merged into the workout's RR series at
    /// `finalizeSession()`, and kept apart so diagnostics can tell whether
    /// the workout depended on this path.
    var points: [RRPoint] = []
}
