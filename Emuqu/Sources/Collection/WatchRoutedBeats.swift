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
    /// An interval was removed since the last forwarded beat, so the next one
    /// is marked `followsRemovedBeat`. Carried across drains: a rejection at
    /// the end of one belongs to the first beat of the next.
    var removedSinceLastBeat = false
}

/// One interval the Watch forwarded from its strap, with when it ended by the
/// Watch's own clock. Each `watchStrapSample` carries the time the Watch
/// received it (`ts`); its intervals end there, the last at `ts` and each one
/// before it where the next began. Kept per interval, so beats queued from
/// several samples keep the time between those samples: a sample the Watch
/// failed to send, or a strap that dropped, stays a gap instead of the
/// beats either side being laid end to end.
///
/// An implausible interval (`WatchPayloadBounds.plausibleRRMillis`) is kept
/// as a removed one (`isRemoved`): it is no beat, but the time it took still
/// passed, so the beats before it are placed back across it, and the next
/// beat is marked as following a removed one, the rule the Verity Sense's
/// quality gate follows (`StrapPPIFilter.marksRemovedBeat`).
struct WatchStrapBeat: Equatable {
    let rrMillis: Double
    let endEpochMs: Double
    var isRemoved = false

    /// The intervals of one sample: `rrMillis` as the Watch sent them, placed
    /// back from `sentAt` (seconds since 1970), the implausible ones marked
    /// removed. A removed interval takes its own time when that is a finite
    /// positive number, and none otherwise.
    static func beats(rrMillis: [Double], sentAt: TimeInterval) -> [WatchStrapBeat] {
        var end = sentAt * 1000
        var beats: [WatchStrapBeat] = []
        for sent in rrMillis.reversed() {
            let removed = WatchPayloadBounds.plausibleRRMillis([sent]).isEmpty
            let rr = removed ? (sent.isFinite && sent > 0 ? sent : 0) : sent
            beats.append(WatchStrapBeat(rrMillis: rr, endEpochMs: end, isRemoved: removed))
            end -= rr
        }
        return beats.reversed()
    }

    /// Where each beat of `beats` starts, epoch ms, its interval in whole ms,
    /// and whether an interval was removed right before it (also at the end
    /// of an earlier drain, `removedBefore`, which is left set when `beats`
    /// ends on a removed one). A beat starts at its own end less its
    /// interval, never before the beat ahead of it (or `lastEndEpochMs`,
    /// where the previous drain's last beat ended) ended, so two samples'
    /// times overlapping by a few ms cannot put a beat ahead of the one
    /// before it. Removed intervals yield no beat.
    static func placed(_ beats: [WatchStrapBeat], after lastEndEpochMs: Int64, removedBefore: inout Bool) -> [PlacedWatchBeat] {
        var lastEnd = lastEndEpochMs
        var placed: [PlacedWatchBeat] = []
        for beat in beats {
            guard !beat.isRemoved else {
                removedBefore = true
                continue
            }
            let rrMs = Int(beat.rrMillis.rounded())
            let start = max(Int64((beat.endEpochMs - beat.rrMillis).rounded()), lastEnd)
            lastEnd = start + Int64(rrMs)
            placed.append(PlacedWatchBeat(startEpochMs: start, rrMs: rrMs, followsRemovedBeat: removedBefore))
            removedBefore = false
        }
        return placed
    }

    /// `placed(_:after:removedBefore:)` with no interval removed before.
    static func placed(_ beats: [WatchStrapBeat], after lastEndEpochMs: Int64) -> [PlacedWatchBeat] {
        var removedBefore = false
        return placed(beats, after: lastEndEpochMs, removedBefore: &removedBefore)
    }
}

/// A forwarded beat on the Watch's clock (`WatchStrapBeat.placed`).
struct PlacedWatchBeat: Equatable {
    let startEpochMs: Int64
    let rrMs: Int
    let followsRemovedBeat: Bool
}
