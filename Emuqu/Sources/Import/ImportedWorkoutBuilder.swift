import CoreLocation
import Foundation

// MARK: - Imported Workout Builder
//
// One workout, reconstructed from the only two signals every external source
// actually provides: a timestamped GPS track and timestamped heart rates.
//
// GPX files and Apple Health workouts arrive in completely different shapes but
// carry the same information, so both funnel through `ImportedWorkoutTrack` and
// come out as an `HRVSession` the archive, the history list, the map and the
// charts all treat exactly like a natively recorded workout.
//
// What an import can NEVER carry is beat-to-beat RR intervals. Neither GPX nor
// HealthKit stores them — HealthKit's heart rate is already averaged, typically
// one value every few seconds. So an imported workout has distance, pace,
// route, elevation, cadence and heart rate, and it has no RMSSD, no SDNN and no
// DFA alpha-1. `rrSeries` and `analysisResult` stay nil rather than being
// filled with something derived from averaged HR, because a plausible-looking
// HRV number computed from the wrong input is worse than an absent one.

/// The common shape every importer reduces its source format to.
struct ImportedWorkoutTrack {
    let startDate: Date
    let endDate: Date
    let track: [CLLocation]
    let heartRateSamples: [(Date, Int)]
    let cadenceSamples: [(Date, Double)]
    let sport: Sport
}

@MainActor
enum ImportedWorkoutBuilder {
    /// Where an imported workout came from, in the two ways that matter: what
    /// to show the user, and whether Apple Health already has a copy.
    struct Source {
        /// Stable identifier recorded in the session's provenance.
        let deviceId: String
        /// Human label — "GPX Import", "Apple Health — Strava".
        let label: String
        /// True when the workout was read OUT of Apple Health, and so must not
        /// be written back into it.
        ///
        /// `backfillWorkoutsToHealthKit` exports every workout session whose
        /// `healthKitExportedAt` is nil. Leaving it nil on a workout that came
        /// from Apple Health writes the user's own Strava run back as a second,
        /// Emuqu-authored copy — and the deduplicator in
        /// `TrainingHealthQueries` then has to guess which of the two is real.
        /// Stamping the session as already exported says "this one came from
        /// there", which is both true and the thing that stops the loop.
        let alreadyInHealthKit: Bool

        static let gpxFile = Source(deviceId: "gpx-import", label: "GPX Import", alreadyInHealthKit: false)

        /// Rebuilt from Apple Health's passive samples because no workout
        /// existed to import.
        ///
        /// `alreadyInHealthKit` is false on purpose, and it is the one case
        /// where that is true of a Health-sourced session: there was no
        /// HKWorkout, so exporting one back is not a duplicate — it is the
        /// workout finally existing, and the user's walk showing up in Apple
        /// Fitness alongside everything else.
        static let appleHealthSamples = Source(
            deviceId: "healthkit-rebuild",
            label: "Apple Health — rebuilt",
            alreadyInHealthKit: false
        )

        static func appleHealth(sourceName: String) -> Source {
            Source(
                deviceId: "healthkit-import",
                label: sourceName.isEmpty ? "Apple Health" : "Apple Health — \(sourceName)",
                alreadyInHealthKit: true
            )
        }
    }

    /// Build a finished `HRVSession` so the archive accepts an import
    /// identically to a native workout. Per-second samples are reconstructed
    /// from HR + cadence + track so the charts and the map have something to
    /// draw.
    /// `replacing` reuses an existing session's id so the rebuild REPLACES the
    /// stub a crashed recording left behind, instead of leaving the user with a
    /// one-second ghost sitting next to the hour it should have been.
    static func buildSession(
        from track: ImportedWorkoutTrack,
        source: Source,
        replacing existingID: UUID? = nil
    ) -> HRVSession {
        // Clamp the session length. A single bogus <time> (e.g. an epoch-1970
        // trackpoint in an otherwise-2026 file, which the parser accepts) would
        // otherwise make `duration` ~1.7 billion → an effectively infinite loop
        // allocating billions of samples → OOM crash. Cap 48 h.
        let duration = min(max(0, Int(track.endDate.timeIntervalSince(track.startDate))), 48 * 3_600)
        let samples = perSecondSamples(from: track, duration: duration)
        return session(from: track, samples: samples, source: source, replacing: existingID)
    }

    /// Collapse HR/cadence samples onto per-second keys.
    ///
    /// Real-world GPX (Strava/Garmin pause-resume, >1 Hz sampling,
    /// fractional-second timestamps) routinely emits two samples inside the
    /// same wall-clock second — `Dictionary(uniqueKeysWithValues:)` TRAPS on the
    /// duplicate key (a hard crash on a file the parser itself accepted). The
    /// latest value wins for any colliding second.
    private static func secondKeyedSamples(
        from track: ImportedWorkoutTrack
    ) -> (hr: [Int: Int], cadence: [Int: Double]) {
        let hrMap: [Int: Int] = Dictionary(
            track.heartRateSamples.map { (Int($0.0.timeIntervalSince(track.startDate)), $0.1) },
            uniquingKeysWith: { _, latest in latest }
        )
        let cadMap: [Int: Double] = Dictionary(
            track.cadenceSamples.map { (Int($0.0.timeIntervalSince(track.startDate)), $0.1) },
            uniquingKeysWith: { _, latest in latest }
        )
        return (hrMap, cadMap)
    }

    /// Per-point elapsed seconds and cumulative distance along the
    /// (time-ordered) track, precomputed ONCE.
    ///
    /// The previous implementation rescanned the whole track for the nearest
    /// point AND recomputed the full prefix distance for every single second —
    /// O(n²), which froze the app for minutes (and tripped the watchdog) on a
    /// 2 h GPX. This is O(n + duration).
    private static func trackIndex(_ track: ImportedWorkoutTrack) -> (elapsed: [Double], cumulative: [Double]) {
        let points = track.track
        var trackElapsed = [Double]()
        var trackCumDist = [Double]()
        trackElapsed.reserveCapacity(points.count)
        trackCumDist.reserveCapacity(points.count)
        var cum = 0.0
        for (i, pt) in points.enumerated() {
            if i > 0 { cum += pt.distance(from: points[i - 1]) }
            trackElapsed.append(pt.timestamp.timeIntervalSince(track.startDate))
            trackCumDist.append(cum)
        }
        return (trackElapsed, trackCumDist)
    }

    /// One sample per second from start to end, filling HR + cadence from the
    /// nearest GPX sample. Distance/altitude come from the nearest track point
    /// via a single advancing cursor (two-pointer sweep).
    private static func perSecondSamples(from track: ImportedWorkoutTrack, duration: Int) -> [WorkoutSample] {
        let (hrMap, cadMap) = secondKeyedSamples(from: track)
        let (trackElapsed, trackCumDist) = trackIndex(track)
        var samples: [WorkoutSample] = []
        samples.reserveCapacity(duration + 1)
        var cursor = 0
        for sec in 0 ... duration {
            cursor = advancing(cursor, to: sec, elapsed: trackElapsed)
            let cumulative = trackCumDist.isEmpty ? 0 : trackCumDist[cursor]
            samples.append(WorkoutSample(
                offsetSec: sec,
                heartRate: hrMap[sec] ?? Self.nearestValue(in: hrMap, near: sec, within: 5),
                distanceMeters: cumulative > 0 ? cumulative : nil,
                paceSecPerKm: nil,
                cadenceStepsPerMin: cadMap[sec] ?? Self.nearestValue(in: cadMap, near: sec, within: 5),
                altitudeMeters: track.track.isEmpty ? nil : track.track[cursor].altitude,
                alpha1: nil, mets: nil, powerWatts: nil
            ))
        }
        return samples
    }

    /// Advances to the track point nearest `sec` in time: the last one at or
    /// before it, unless the next one is closer.
    private static func advancing(_ cursor: Int, to sec: Int, elapsed trackElapsed: [Double]) -> Int {
        let secD = Double(sec)
        var cursor = cursor
        while cursor + 1 < trackElapsed.count, trackElapsed[cursor + 1] <= secD {
            cursor += 1
        }
        guard cursor + 1 < trackElapsed.count,
              abs(trackElapsed[cursor + 1] - secD) < abs(trackElapsed[cursor] - secD)
        else { return cursor }
        return cursor + 1
    }

    private static func session(
        from track: ImportedWorkoutTrack,
        samples: [WorkoutSample],
        source: Source,
        replacing existingID: UUID?
    ) -> HRVSession {
        var metadata = WorkoutMetadata(sport: track.sport)
        metadata.gpsPolyline = WorkoutAnalyzer.encodePolyline(track: track.track)
        metadata.distanceMeters = samples.last?.distanceMeters ?? 0
        metadata.samples = samples
        var session = blankSession(startDate: track.startDate, source: source, existingID: existingID)
        session.endDate = track.endDate
        session.workoutMetadata = metadata
        session.state = HRVSession.SessionState.complete
        if source.alreadyInHealthKit { session.healthKitExportedAt = Date() }
        return session
    }

    private static func blankSession(startDate: Date, source: Source, existingID: UUID?) -> HRVSession {
        let provenance = DeviceProvenance.current(
            deviceId: source.deviceId, deviceModel: source.label,
            firmwareVersion: nil, recordingMode: .imported
        )
        guard let existingID else {
            return HRVSession(
                startDate: startDate, tags: [], sessionType: .workout, deviceProvenance: provenance
            )
        }
        return HRVSession(
            id: existingID, startDate: startDate, endDate: nil, state: .collecting,
            sessionType: .workout, rrSeries: nil, analysisResult: nil, artifactFlags: nil,
            deviceProvenance: provenance
        )
    }

    // Nearest-neighbour lookup by time key, within `within` seconds.
    private static func nearestValue<V>(in dict: [Int: V], near sec: Int, within: Int) -> V? {
        for offset in 1 ... within {
            if let v = dict[sec + offset] { return v }
            if let v = dict[sec - offset] { return v }
        }
        return nil
    }
}
