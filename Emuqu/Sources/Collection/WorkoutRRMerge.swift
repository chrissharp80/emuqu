import Foundation

/// Merging a workout's RR intervals from the two places they can arrive.
///
/// A workout can bounce between an iPhone-paired strap and a Watch-routed one —
/// the user walks away from the phone, the Watch takes over the BLE link, they
/// come back. Both paths buffer RR intervals, and finalize has to turn them into
/// one coherent series before any analysis runs.
///
/// Merge it wrong and every HRV number for that workout is computed on a
/// corrupted series: out-of-order intervals turn into enormous successive
/// differences, which is exactly what RMSSD squares.
enum WorkoutRRMerge {
    /// The strap buffer as a live workout may read it: its own only when the
    /// workout runs on the strap. Any other source never started a stream, so
    /// the buffer there may hold a previous session's points.
    static func liveStrapBuffer(source: WorkoutRecorder.HRSource, streaming: [RRPoint]) -> [RRPoint] {
        source == .strap ? streaming : []
    }

    /// The RR series for a finishing workout.
    ///
    /// - Parameters:
    ///   - source: the HR source the workout actually ran on. `.watch` and
    ///     `.none` never started a strap stream, so that buffer is not theirs to
    ///     read — it may still hold points from a previous session.
    ///   - streaming: the strap stream's buffer.
    ///   - watchRouted: RR that arrived via the Watch direct-strap fallback.
    ///
    /// Watch-routed points are merged whatever the source, because that path can
    /// deliver strap data the phone never saw.
    ///
    /// The sort is applied only when there is something to interleave. With no
    /// Watch-routed points the streaming buffer is returned as-is, which
    /// preserves the existing behaviour: it is already ordered by construction,
    /// and re-sorting a long series on every finalize is work for nothing.
    ///
    /// When every point carries a wall-clock time (milliseconds since the
    /// strap stream started, on both sides), the two are interleaved on the
    /// real clock (`BeatTimeline`) and `t_ms` is rebuilt as the running sum
    /// of intervals. The phone's `t_ms` is that running sum already, so it
    /// leaves out every Bluetooth gap; its wall clock is when each batch
    /// arrived, after its beats ended, while the Watch's is when each beat
    /// started. Ordered by `t_ms`, the beats the Watch carried through a
    /// phone dropout landed among the phone's beats from after it; ordered
    /// by the raw wall clocks, a phone beat sat a beat late against the
    /// Watch's. The interleave keeps each side's own order: a batch of phone
    /// beats shares one wall-clock time.
    static func merged(
        source: WorkoutRecorder.HRSource,
        streaming: [RRPoint],
        watchRouted: [RRPoint]
    ) -> [RRPoint] {
        var points = liveStrapBuffer(source: source, streaming: streaming)
        guard !watchRouted.isEmpty else { return points }
        guard (points + watchRouted).allSatisfy({ $0.wallClockMs != nil }) else {
            points.append(contentsOf: watchRouted)
            points.sort { $0.t_ms < $1.t_ms }
            return points
        }
        return retimed(interleaved(points, watchRouted))
    }

    /// Both lists in their own order, merged by each beat's real start, read
    /// from its own list (`BeatTimeline.ms`).
    private static func interleaved(_ phone: [RRPoint], _ watch: [RRPoint]) -> [RRPoint] {
        let (phoneTimes, watchTimes) = (BeatTimeline.ms(phone), BeatTimeline.ms(watch))
        var merged: [RRPoint] = []
        merged.reserveCapacity(phone.count + watch.count)
        var p = 0, w = 0
        while p < phone.count || w < watch.count {
            let takePhone = w >= watch.count || (p < phone.count && phoneTimes[p] <= watchTimes[w])
            merged.append(takePhone ? phone[p] : watch[w])
            if takePhone { p += 1 } else { w += 1 }
        }
        return merged
    }

    /// `t_ms` as the running sum of intervals from the first point's.
    private static func retimed(_ points: [RRPoint]) -> [RRPoint] {
        var clock = points.first?.t_ms ?? 0
        return points.map { point in
            defer { clock += Int64(point.rr_ms) }
            return point.retimed(t_ms: clock, wallClockMs: point.wallClockMs)
        }
    }
}
