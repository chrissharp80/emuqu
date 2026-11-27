import Foundation

/// The beats a workout took through the Watch's direct-strap path: when the
/// strap is paired to the Watch rather than the iPhone, the Watch forwards RR
/// and HR over WCSession (`WatchStrapConnector`), and each tick drains the
/// bridge's queue of them (`drainPendingWatchStrapRR`).
struct WatchRoutedBeats {
    /// When this path last produced beats. Separate from the iPhone strap's
    /// own freshness (`WorkoutLiveSignals.lastStrapHRAt`), so the wrist-HR
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
    /// Where the last forwarded beat ended, epoch ms, so the next one never
    /// starts before it when two samples' times overlap by a few ms.
    var lastEndEpochMs: Int64 = 0
}

/// One beat the Watch forwarded from its strap, with when it ended by the
/// Watch's own clock. Each `watchStrapSample` carries the time the Watch
/// received it (`ts`); its beats end there, the last at `ts` and each one
/// before it where the next began. Kept per beat, so beats queued from
/// several samples keep the time between those samples: a sample the Watch
/// failed to send, or a strap that dropped, stays a gap instead of the
/// beats either side being laid end to end.
struct WatchStrapBeat: Equatable {
    let rrMillis: Double
    let endEpochMs: Double

    /// The beats of one sample: `rrMillis` as the Watch sent them, the
    /// implausible ones dropped (`WatchPayloadBounds.plausibleRRMillis`),
    /// the rest placed back from `sentAt` (seconds since 1970).
    static func beats(rrMillis: [Double], sentAt: TimeInterval) -> [WatchStrapBeat] {
        var end = sentAt * 1000
        var beats: [WatchStrapBeat] = []
        for rr in WatchPayloadBounds.plausibleRRMillis(rrMillis).reversed() {
            beats.append(WatchStrapBeat(rrMillis: rr, endEpochMs: end))
            end -= rr
        }
        return beats.reversed()
    }

    /// Where each of `beats` starts, epoch ms, and its interval in whole ms:
    /// at its own end less its interval, never before the beat ahead of it
    /// (or `lastEndEpochMs`, where the previous drain's last beat ended)
    /// ended, so two samples' times overlapping by a few ms cannot put a
    /// beat ahead of the one before it.
    static func placed(_ beats: [WatchStrapBeat], after lastEndEpochMs: Int64) -> [(startEpochMs: Int64, rrMs: Int)] {
        var lastEnd = lastEndEpochMs
        return beats.map { beat in
            let rrMs = Int(beat.rrMillis.rounded())
            let start = max(Int64((beat.endEpochMs - beat.rrMillis).rounded()), lastEnd)
            lastEnd = start + Int64(rrMs)
            return (start, rrMs)
        }
    }
}
