import Foundation

/// The one real-time clock a series of beats is read on.
///
/// A beat carries two clocks, and neither alone is real time:
///
/// - `RRPoint.t_ms`, the beat clock: the running sum of the intervals kept.
///   An H10's own recording keeps every interval, so there it is real time.
///   A Verity Sense keeps only the intervals its quality gate accepts
///   (`StrapPPIFilter`), so its beat clock runs behind real time by every
///   interval it rejected; a stream's beat clock stops while Bluetooth drops
///   beats.
/// - `RRPoint.wallClockMs`, the recorded clock, in ms from the recording's
///   start. For a Verity Sense recording pulled from its memory, and for a
///   beat the Watch relays, it is the real start of the beat. For a streamed
///   beat it is when its notification batch reached the phone: at or after
///   the beat ended, and shared by every beat of the batch.
///
/// `ms(_:)` gives each beat's start on the real clock, read from those two.
/// Every comparison between two series, every gap, coverage or dedupe test,
/// every spectrum, breathing rate and DFA count of removed beats, and every
/// time axis reads it, never one raw clock against the other: the same beat
/// on the two raw clocks can be seconds or minutes apart.
///
/// The beats are read in runs: consecutive beats that all carry a recorded
/// clock that never steps back, or that all carry none.
///
/// - Without a recorded clock, the beat clock is real time: the sensor kept
///   every interval (an H10's memory, an import).
/// - Where the recorded clock advances at least one interval from each beat
///   to the next, it marks the beats' starts, and is the real clock.
/// - Otherwise it is an arrival time. Each beat ended no later than its batch
///   arrived, so each beat starts at the running sum of the run's intervals,
///   moved later by the least margin by which it or any later beat of the run
///   arrived after it ended. That margin only grows where the beat clock left
///   time out (a dropout, a removed interval), so the time comes back there,
///   and the beats of one batch are laid back from its arrival by their own
///   intervals instead of sharing one time. A series this already places
///   (the beat clock set to these times) reads back unchanged.
///
/// The times always rise, so no two beats share one.
enum BeatTimeline {
    /// The rounding a recorded clock that marks beat starts may lose between
    /// two beats (the Watch places beats in whole ms).
    static let startClockSlackMs: Int64 = 2

    /// Beats read past the end of a range, so the beats near its end are
    /// timed from the batch they arrived in (`ms(_:in:)`).
    static let lookaheadBeats = 32

    /// Each beat's start on the real clock, in ms, parallel to `points`.
    static func ms(_ points: [RRPoint]) -> [Int64] {
        var times: [Int64] = []
        times.reserveCapacity(points.count)
        for run in runs(of: points) {
            times += runTimes(points[run])
        }
        return strictlyRising(times)
    }

    /// The beat times of `range` (clamped to `points`), read from the range
    /// and the `lookaheadBeats` after it: a streamed beat's time depends only
    /// on the beats up to the end of the batch it came in, so an analysis
    /// window is timed without reading the whole night.
    static func ms(_ points: [RRPoint], in range: Range<Int>) -> [Int64] {
        let clamped = range.clamped(to: 0 ..< points.count)
        guard !clamped.isEmpty else { return [] }
        let upper = min(points.count, clamped.upperBound + lookaheadBeats)
        return Array(ms(Array(points[clamped.lowerBound ..< upper])).prefix(clamped.count))
    }

    /// The real-clock time between beat `k - 1` ending and beat `k`
    /// starting, which the beats do not account for; zero for the first.
    static func untimedMs(before k: Int, times: [Int64], points: [RRPoint]) -> Int64 {
        guard k > 0, k < times.count, k < points.count else { return 0 }
        return max(0, times[k] - times[k - 1] - Int64(points[k - 1].rr_ms))
    }

    /// The real-clock time the series did not receive: every stretch between
    /// two beats that no beat accounts for, except the time before a beat
    /// that follows an interval the sensor removed, which was received and
    /// rejected, not lost.
    static func unreceivedMs(_ points: [RRPoint]) -> Int64 {
        let times = ms(points)
        return points.indices.dropFirst()
            .filter { !points[$0].isAfterRemovedBeat }
            .reduce(0) { $0 + untimedMs(before: $1, times: times, points: points) }
    }

    /// From the first beat's start to the last beat's end on the real clock;
    /// zero without beats.
    static func spanMs(_ points: [RRPoint]) -> Int64 {
        let times = ms(points)
        guard let first = times.first, let last = times.last, let lastBeat = points.last else { return 0 }
        return last + Int64(lastBeat.rr_ms) - first
    }

    // MARK: Runs

    private static func runs(of points: [RRPoint]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start = 0
        for i in points.indices.dropFirst() where startsRun(points[i - 1], points[i]) {
            runs.append(start ..< i)
            start = i
        }
        if !points.isEmpty { runs.append(start ..< points.count) }
        return runs
    }

    /// A run ends where a recorded clock starts or stops, or steps back.
    private static func startsRun(_ previous: RRPoint, _ next: RRPoint) -> Bool {
        switch (previous.wallClockMs, next.wallClockMs) {
        case (nil, nil): false
        case let (.some(before), .some(after)): after < before
        default: true
        }
    }

    private static func runTimes(_ run: ArraySlice<RRPoint>) -> [Int64] {
        guard let first = run.first, first.wallClockMs != nil else { return run.map(\.t_ms) }
        if marksBeatStarts(run) { return run.map { $0.wallClockMs ?? $0.t_ms } }
        return arrivalTimes(Array(run), originMs: first.t_ms)
    }

    /// Whether the recorded clock advances at least one interval from every
    /// beat of the run to the next.
    private static func marksBeatStarts(_ run: ArraySlice<RRPoint>) -> Bool {
        zip(run, run.dropFirst()).allSatisfy { previous, next in
            guard let before = previous.wallClockMs, let after = next.wallClockMs else { return false }
            return after - before >= Int64(previous.rr_ms) - startClockSlackMs
        }
    }

    /// The run's running starts from `originMs`, each moved later by the
    /// least arrival margin at or after it.
    private static func arrivalTimes(_ beats: [RRPoint], originMs: Int64) -> [Int64] {
        let starts = runningStarts(beats, originMs: originMs)
        var margins = [Int64](repeating: 0, count: beats.count)
        var least = Int64.max
        for k in beats.indices.reversed() {
            least = min(least, (beats[k].wallClockMs ?? starts[k]) - starts[k] - Int64(beats[k].rr_ms))
            margins[k] = least
        }
        return zip(starts, margins).map { $0 + $1 }
    }

    private static func runningStarts(_ beats: [RRPoint], originMs: Int64) -> [Int64] {
        var sum = originMs
        return beats.map { beat in
            defer { sum += Int64(beat.rr_ms) }
            return sum
        }
    }

    private static func strictlyRising(_ times: [Int64]) -> [Int64] {
        var rising = times
        for i in rising.indices.dropFirst() where rising[i] <= rising[i - 1] {
            rising[i] = rising[i - 1] + 1
        }
        return rising
    }
}

extension [RRPoint] {
    /// Each beat's start on the real clock (`BeatTimeline.ms`).
    var beatTimesMs: [Int64] {
        BeatTimeline.ms(self)
    }
}
