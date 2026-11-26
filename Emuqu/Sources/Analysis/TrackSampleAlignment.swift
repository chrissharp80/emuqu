import CoreLocation
import Foundation

/// Which second of a workout's per-second samples each fix of its stored GPS
/// track was taken at. Samples run on the active clock, which stops while the
/// workout is paused (`WorkoutMetadata.activeOffset`). The polyline stores no
/// times, so `GPXExporter.decode` spreads its fixes evenly over the session,
/// which places them right only for a workout with a steady fix rate and no
/// pauses. A workout that stored when each fix was taken
/// (`WorkoutMetadata.gpsFixTimes`) is placed by those times.
///
/// One without them (every workout recorded before the times were stored) is
/// placed by altitude: each sample carries the altitude of the latest GPS fix
/// (`WorkoutTicker`), and the track stores each fix's altitude to a tenth of
/// a metre, so a fix goes to the first sample after the previous fix's that
/// carries its altitude. That is when it arrived, whatever the pedometer
/// said. Only when too few fixes match (a track without altitude, an import)
/// is it placed by distance: the first sample that had covered as much
/// ground. Sample distance is the larger of GPS and pedometer at each second,
/// so it can switch source mid-workout; that is why it comes last. A fix no
/// method places is nil.
enum TrackSampleAlignment {
    /// The track stores altitude in tenths of a metre, so a sample within
    /// this of a fix's stored altitude carries that fix's reading.
    static let altitudeMatchMeters = 0.06
    /// A fix is looked for no further than this past the previous one: a
    /// match further on would be another fix that happened to read the same.
    static let maxFixGapSec = 120
    /// The share of a track's fixes with altitude that must match for the
    /// altitude placement to be used.
    static let minAltitudeMatchShare = 0.9

    /// The samples' distance is the larger of GPS, pedometer and foot pod, the
    /// track's is the fixes' own. When their totals differ by more than this
    /// share they measured different things, and matching by distance would
    /// pair the wrong places, so it is not attempted.
    static let maxDistanceMismatch = 0.2

    /// The active second of each fix of `track`, the session's decoded track.
    static func activeOffsets(of track: [CLLocation], session: HRVSession) -> [Int?] {
        guard let metadata = session.workoutMetadata else { return track.map { _ in nil } }
        if let times = GPXExporter.recordedFixTimes(metadata, count: track.count) {
            return times.map { metadata.activeOffset(forWallClockSeconds: $0.timeIntervalSince(session.startDate)) }
        }
        let samples = (metadata.samples ?? []).sorted { $0.offsetSec < $1.offsetSec }
        return byAltitude(track, samples: samples) ?? byDistance(track, samples: samples)
    }

    /// Each fix placed at the first sample, after the previous fix's and
    /// within `maxFixGapSec` of it, that carries the fix's altitude; nil when
    /// fewer than `minAltitudeMatchShare` of the fixes with altitude match.
    static func byAltitude(_ track: [CLLocation], samples: [WorkoutSample]) -> [Int?]? {
        let readings = samples.compactMap { sample in sample.altitudeMeters.map { (offset: sample.offsetSec, meters: $0) } }
        guard !readings.isEmpty else { return nil }
        var cursor: Int?
        let offsets: [Int?] = track.map { fix in
            guard fix.verticalAccuracy >= 0, let found = nextReading(of: fix.altitude, in: readings, after: cursor) else { return nil }
            cursor = found
            return readings[found].offset
        }
        let withAltitude = track.filter { $0.verticalAccuracy >= 0 }.count
        let matched = offsets.compactMap { $0 }.count
        guard withAltitude > 0, Double(matched) >= minAltitudeMatchShare * Double(withAltitude) else { return nil }
        return offsets
    }

    /// The index of the first reading that is `altitude`, at or after the
    /// previous fix's reading `previous` and within `maxFixGapSec` of it. The
    /// first fix has no previous one, and is looked for however long the GPS
    /// took to lock.
    private static func nextReading(of altitude: Double, in readings: [(offset: Int, meters: Double)], after previous: Int?) -> Int? {
        let limit = previous.map { readings[$0].offset + maxFixGapSec } ?? Int.max
        var index = previous ?? 0
        while index < readings.count, readings[index].offset <= limit {
            if abs(readings[index].meters - altitude) <= altitudeMatchMeters { return index }
            index += 1
        }
        return nil
    }

    /// Each fix placed at the first sample that had covered as much ground,
    /// the sample total scaled to the track's.
    static func byDistance(_ track: [CLLocation], samples: [WorkoutSample]) -> [Int?] {
        let along = cumulativeDistances(track)
        let marks = samples.compactMap { sample in sample.distanceMeters.map { (offset: sample.offsetSec, meters: $0) } }
            .sorted { $0.offset < $1.offset }
        guard let trackTotal = along.last, trackTotal > 0, let sampleTotal = marks.last?.meters, sampleTotal > 0,
              abs(sampleTotal / trackTotal - 1) <= maxDistanceMismatch else { return track.map { _ in nil } }
        let scale = sampleTotal / trackTotal
        return along.map { firstOffset(in: marks, reaching: $0 * scale) }
    }

    /// The fix of `track` taken nearest the active second `offset`, given the
    /// track's `offsets`; nil when no fix is placed.
    static func nearestFix(in track: [CLLocation], offsets: [Int?], to offset: Int) -> CLLocation? {
        zip(track, offsets).compactMap { fix, placed in placed.map { (fix, abs($0 - offset)) } }
            .min { $0.1 < $1.1 }?.0
    }

    static func cumulativeDistances(_ track: [CLLocation]) -> [Double] {
        var along = 0.0
        return track.indices.map { index in
            if index > 0 { along += track[index].distance(from: track[index - 1]) }
            return along
        }
    }

    /// The offset of the first mark at or past `meters`, in marks sorted by
    /// offset (cumulative distance never falls); the last mark past the end.
    private static func firstOffset(in marks: [(offset: Int, meters: Double)], reaching meters: Double) -> Int? {
        var low = 0
        var high = marks.count
        while low < high {
            let mid = (low + high) / 2
            if marks[mid].meters < meters { low = mid + 1 } else { high = mid }
        }
        return marks.indices.contains(low) ? marks[low].offset : marks.last?.offset
    }
}
