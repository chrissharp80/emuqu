import CoreLocation
import Foundation

/// Which second of a workout's per-second samples each fix of its stored GPS
/// track was taken at. Samples run on the active clock, which stops while the
/// workout is paused (`WorkoutMetadata.activeOffset`). The polyline stores no
/// times, so `GPXExporter.decode` spreads its fixes evenly over the session,
/// which places them right only for a workout with a steady fix rate and no
/// pauses. A workout that stored when each fix was taken
/// (`WorkoutMetadata.gpsFixTimes`) is placed by those times. One without them
/// is placed by distance: each fix goes to the first sample whose distance
/// reaches the distance covered to that fix, which neither pauses nor an
/// uneven fix rate move. A fix neither places is nil.
enum TrackSampleAlignment {
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
        return byDistance(track, samples: metadata.samples ?? [])
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
