import CoreLocation
import Foundation

// MARK: - Track Segments
//
// A GPS track is a run of segments, not one line. A GPX file splits its
// track at each `<trkseg>` and `<trk>` (the device stopped recording: a
// pause, a GPS loss, a second activity in one file), Apple Health keeps one
// route per recorded stretch, and a workout paused on another device records
// nothing until it resumes. Between two segments nothing was recorded, so
// the straight line from the last fix of one to the first of the next is
// not a place the user went: no distance, time, climb or drawn line is
// taken across it.
//
// A track is stored as its fixes plus `starts`, the index of the first fix
// of every segment after the first (`WorkoutMetadata.gpsSegmentStarts`).
// Every reader of a stored or imported track that sums, times or draws its
// fixes goes through this one rule.

/// A track's fixes and the index of the first fix of each segment after the
/// first (`TrackSegments`).
struct SegmentedTrack: Sendable {
    var fixes: [CLLocation]
    var starts: [Int] = []
}

enum TrackSegments {
    /// `raw` made safe for a `count`-fix track: ascending, unique and inside
    /// `1 ..< count` (index 0 always starts the first segment). A stored
    /// list that does not fit its track (a polyline re-encoded by a build
    /// that dropped the starts) keeps only the starts it still can.
    static func starts(_ raw: [Int]?, count: Int) -> [Int] {
        guard let raw, count > 1 else { return [] }
        return Array(Set(raw.filter { $0 > 0 && $0 < count })).sorted()
    }

    /// The index ranges of each segment of a `count`-fix track.
    static func ranges(count: Int, starts raw: [Int]?) -> [Range<Int>] {
        guard count > 0 else { return [] }
        let bounds = [0] + starts(raw, count: count) + [count]
        return zip(bounds, bounds.dropFirst()).map { $0 ..< $1 }
    }

    /// `items`, one array per segment.
    static func split<T>(_ items: [T], starts raw: [Int]?) -> [[T]] {
        ranges(count: items.count, starts: raw).map { Array(items[$0]) }
    }

    /// Whether step `index` (from fix `index - 1` to fix `index`) crosses
    /// from one segment into the next.
    static func crossesBreak(_ index: Int, starts raw: [Int]?) -> Bool {
        raw?.contains(index) ?? false
    }

    /// The distance covered up to each fix, adding nothing for a step that
    /// crosses into a new segment.
    static func cumulativeMeters(_ track: [CLLocation], starts raw: [Int]?) -> [Double] {
        let breaks = Set(starts(raw, count: track.count))
        var along = 0.0
        return track.indices.map { index in
            if index > 0, !breaks.contains(index) { along += track[index].distance(from: track[index - 1]) }
            return along
        }
    }

    /// The length of the track, the segments summed and the gaps between
    /// them left out.
    static func lengthMeters(_ track: [CLLocation], starts raw: [Int]?) -> Double {
        cumulativeMeters(track, starts: raw).last ?? 0
    }

    /// The starts of `track` once it is sorted by time: each fix is tagged
    /// with its segment, the fixes are sorted (stable, so equal times keep
    /// their order), and a new segment starts wherever the tag changes.
    static func timeOrdered(_ track: [CLLocation], starts raw: [Int]?) -> SegmentedTrack {
        let ranges = ranges(count: track.count, starts: raw)
        let tagged = ranges.enumerated().flatMap { segment, range in range.map { (fix: track[$0], segment: segment, index: $0) } }
        let sorted = tagged.sorted { ($0.fix.timestamp, $0.index) < ($1.fix.timestamp, $1.index) }
        let newStarts = sorted.indices.dropFirst().filter { sorted[$0].segment != sorted[$0 - 1].segment }
        return SegmentedTrack(fixes: sorted.map(\.fix), starts: Array(newStarts))
    }

    /// One track built from several recorded stretches, each starting a new
    /// segment; empty stretches are left out.
    static func joined(_ stretches: [[CLLocation]]) -> SegmentedTrack {
        var joined = SegmentedTrack(fixes: [])
        for stretch in stretches where !stretch.isEmpty {
            if !joined.fixes.isEmpty { joined.starts.append(joined.fixes.count) }
            joined.fixes += stretch
        }
        return joined
    }

    /// `track` (in time order) with a new segment at every fix whose step
    /// from the fix before overlaps one of `pauses`, spans the source
    /// stopped recording through: no distance or line is taken across a
    /// pause, nor between fixes inside one.
    static func breakingAtPauses(_ track: SegmentedTrack, pauses: [ClosedRange<Date>]) -> SegmentedTrack {
        let fixes = track.fixes
        let paused = fixes.indices.dropFirst().filter { index in
            let (from, to) = (fixes[index - 1].timestamp, fixes[index].timestamp)
            return pauses.contains { $0.lowerBound < to && $0.upperBound > from }
        }
        return SegmentedTrack(fixes: fixes, starts: starts(track.starts + paused, count: fixes.count))
    }
}

extension WorkoutMetadata {
    /// `gpsSegmentStarts` checked against the decoded track's fix count.
    func gpsSegmentStarts(count: Int) -> [Int] {
        TrackSegments.starts(gpsSegmentStarts, count: count)
    }

    /// The decoded `track`, one array per recorded segment.
    func gpsSegments<T>(of track: [T]) -> [[T]] {
        TrackSegments.split(track, starts: gpsSegmentStarts)
    }
}

// MARK: - Series runs
//
// A time series drawn as a line follows the same rule: where nothing was
// recorded for longer than its usual spacing (a strap out of range, two
// merged recordings, a dropout the analysis cleared), the line stops and
// starts again rather than joining the points either side.

enum SeriesRuns {
    /// The longest silence an overnight chart bridges, as the overnight
    /// HRV canvas splits its path (`OvernightHRVChartCanvas`).
    static let overnightMaxGapSeconds: TimeInterval = 5 * 60
    /// The longest stretch without a value a per-second workout chart
    /// bridges: Apple Watch heart rate arrives every few seconds, a strap
    /// that dropped out leaves far longer holes.
    static let workoutMaxGapMinutes = 0.5

    /// The run of each point of `xs` (ascending): a new run starts after
    /// every gap wider than `maxGap`. Charts pass it as the line's series.
    static func runs(of xs: [Double], maxGap: Double) -> [Int] {
        var run = 0
        return xs.indices.map { index in
            if index > 0, xs[index] - xs[index - 1] > maxGap { run += 1 }
            return run
        }
    }

    static func runs(of times: [Date], maxGap: TimeInterval) -> [Int] {
        runs(of: times.map(\.timeIntervalSinceReferenceDate), maxGap: maxGap)
    }
}
