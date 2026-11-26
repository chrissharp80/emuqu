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
/// (`WorkoutTicker`), so the second a new fix arrived is a second whose
/// altitude differs from the one before it, and the track stores each fix's
/// altitude to a tenth of a metre. A fix whose altitude differs from the fix
/// before it goes to the first such change, after the previous fix's, that
/// reads its altitude. That is when it arrived, whatever the pedometer said.
/// A fix that reads the same as the one before it left no change to find
/// (the reading held, or the GPS repeated it), so it is placed between the
/// fixes on either side by the ground covered. Only when too few fixes
/// match, or the altitude never changed (a track without altitude, an
/// import, flat ground the GPS read as level), is it placed by distance: the
/// first sample that had covered as much ground. Sample distance is the
/// larger of GPS and pedometer at each second, so it can switch source
/// mid-workout; that is why it comes last. A fix no method places is nil.
enum TrackSampleAlignment {
    /// The track stores altitude in tenths of a metre, so a sample within
    /// this of a fix's stored altitude carries that fix's reading.
    static let altitudeMatchMeters = 0.06
    /// Two stored altitudes this far apart or more are different readings.
    static let storedAltitudeStep = 0.1
    /// A fix is looked for no further than this past the previous one, for
    /// each fix between them: a match further on would be another fix that
    /// happened to read the same.
    static let maxFixGapSec = 120
    /// The share of a track's new readings that must match for the
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

    /// A previous placed fix: its index in `track` and the change it took.
    private typealias Anchor = (fix: Int, change: Int)

    /// Each new reading placed at its change in the samples, the fixes
    /// between placed ones by ground covered; nil when fewer than two
    /// readings are new or fewer than `minAltitudeMatchShare` of them match.
    static func byAltitude(_ track: [CLLocation], samples: [WorkoutSample]) -> [Int?]? {
        let changes = altitudeChanges(samples)
        let isNew = newReadings(track)
        var previous: Anchor?
        let anchors: [Int?] = track.indices.map { fix in
            guard isNew[fix], let found = nextChange(to: track[fix].altitude, in: changes, fix: fix, after: previous) else { return nil }
            previous = (fix, found)
            return changes[found].offset
        }
        let (expected, matched) = (isNew.filter { $0 }.count, anchors.compactMap { $0 }.count)
        guard expected >= 2, Double(matched) >= minAltitudeMatchShare * Double(expected) else { return nil }
        return filledBetweenAnchors(anchors, along: cumulativeDistances(track))
    }

    /// The seconds whose carried altitude differs from the second before:
    /// those a new fix arrived at. The first reading is one.
    private static func altitudeChanges(_ samples: [WorkoutSample]) -> [(offset: Int, meters: Double)] {
        var last: Double?
        return samples.compactMap { sample in
            guard let meters = sample.altitudeMeters, meters != last else { return nil }
            last = meters
            return (sample.offsetSec, meters)
        }
    }

    /// Whether each fix carries an altitude reading the fix with altitude
    /// before it did not.
    private static func newReadings(_ track: [CLLocation]) -> [Bool] {
        var last: Double?
        return track.map { fix in
            guard fix.verticalAccuracy >= 0 else { return false }
            defer { last = fix.altitude }
            return last.map { abs(fix.altitude - $0) >= storedAltitudeStep / 2 } ?? true
        }
    }

    /// The index of the first change after the previous fix's that reads
    /// `altitude`, within `maxFixGapSec` of it for each fix since. The first
    /// fix has no previous one, and is looked for however long the GPS took
    /// to lock.
    private static func nextChange(
        to altitude: Double, in changes: [(offset: Int, meters: Double)], fix: Int, after previous: Anchor?
    ) -> Int? {
        let limit = previous.map { changes[$0.change].offset + (fix - $0.fix) * maxFixGapSec } ?? Int.max
        var index = previous.map { $0.change + 1 } ?? 0
        while index < changes.count, changes[index].offset <= limit {
            if abs(changes[index].meters - altitude) <= altitudeMatchMeters { return index }
            index += 1
        }
        return nil
    }

    /// `anchors` with each fix between two placed ones placed by the share
    /// of the ground between them it had covered (by its place in the track
    /// where they are at one spot). Fixes before the first placed one and
    /// after the last stay nil.
    static func filledBetweenAnchors(_ anchors: [Int?], along: [Double]) -> [Int?] {
        let placed = anchors.enumerated().compactMap { fix, offset in offset.map { (fix: fix, offset: $0) } }
        var filled = anchors
        for (start, end) in zip(placed, placed.dropFirst()) where end.fix > start.fix + 1 {
            for fix in (start.fix + 1) ..< end.fix {
                filled[fix] = interpolated(fix, between: start, and: end, along: along)
            }
        }
        return filled
    }

    private static func interpolated(_ fix: Int, between start: (fix: Int, offset: Int), and end: (fix: Int, offset: Int), along: [Double]) -> Int {
        let ground = along[end.fix] - along[start.fix]
        let share = ground > 0 ? (along[fix] - along[start.fix]) / ground : Double(fix - start.fix) / Double(end.fix - start.fix)
        return start.offset + Int((Double(end.offset - start.offset) * share).rounded())
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
