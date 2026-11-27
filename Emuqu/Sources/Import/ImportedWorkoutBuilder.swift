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
// one value every few seconds. So an imported workout has distance, route, an
// altitude profile, cadence and a heart-rate trace, and it has no RMSSD, no
// SDNN and no DFA alpha-1. `rrSeries` and `analysisResult` stay nil rather than
// being filled with something derived from averaged HR, because a
// plausible-looking HRV number computed from the wrong input is worse than an
// absent one. No workout analysis runs either, so mean HR, TRIMP, hrTSS and
// elevation gain stay empty (a Health rebuild sets gain from flights climbed).

/// The common shape every importer reduces its source format to.
struct ImportedWorkoutTrack {
    let startDate: Date
    let endDate: Date
    let track: [CLLocation]
    let heartRateSamples: [(Date, Int)]
    let cadenceSamples: [(Date, Double)]
    let sport: Sport
    /// The fixes of `track` that begin a new recorded segment
    /// (`TrackSegments`): a GPX `<trkseg>`, a second Health route, a pause.
    var segmentStarts: [Int] = []

    /// The same track with its points in time order, each keeping its
    /// segment. A GPX file or a route query can hand points over out of
    /// order, and the builder sums distance and sweeps altitude in array order.
    func timeOrdered() -> ImportedWorkoutTrack {
        let ordered = TrackSegments.timeOrdered(track, starts: segmentStarts)
        return ImportedWorkoutTrack(
            startDate: startDate, endDate: endDate, track: ordered.fixes,
            heartRateSamples: heartRateSamples, cadenceSamples: cadenceSamples, sport: sport,
            segmentStarts: ordered.starts
        )
    }
}

/// Nonisolated: the build reads nothing but its arguments (plus the app's
/// language bundle for the labels and `DeviceProvenance.current`, both
/// readable from any isolation), so a GPX file can be rebuilt off the main
/// actor and a Health import keeps calling it from the main actor.
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

        /// Labels are in the app's language at import time; they are stored
        /// on the session as its device name.
        static var gpxFile: Source {
            Source(deviceId: "gpx-import", label: String(localized: "GPX Import", bundle: LanguageManager.appBundle), alreadyInHealthKit: false)
        }

        /// Rebuilt from Apple Health's passive samples because no workout
        /// existed to import.
        ///
        /// `alreadyInHealthKit` is false on purpose, and it is the one case
        /// where that is true of a Health-sourced session: there was no
        /// HKWorkout, so exporting one back is not a duplicate — it is the
        /// workout finally existing, and the user's walk showing up in Apple
        /// Fitness alongside everything else. Only the workout is written:
        /// its heart rate, distance and effort are Health's own samples, and
        /// `HealthKitWorkoutExport.sampleOptions` keeps them out of the
        /// export, so Health never gets a copy of them under Emuqu's name.
        static var appleHealthSamples: Source {
            Source(
                deviceId: "healthkit-rebuild",
                label: String(localized: "Apple Health — rebuilt", bundle: LanguageManager.appBundle),
                alreadyInHealthKit: false
            )
        }

        static func appleHealth(sourceName: String) -> Source {
            Source(
                deviceId: "healthkit-import",
                label: sourceName.isEmpty
                    ? String(localized: "Apple Health", bundle: LanguageManager.appBundle)
                    : String(localized: "Apple Health — \(sourceName)", bundle: LanguageManager.appBundle),
                alreadyInHealthKit: true
            )
        }
    }

    /// Why a track cannot be built into a workout.
    enum InvalidSpan: Error, Equatable {
        /// The track ends before it starts.
        case endsBeforeStart
        /// The track is longer than `maximumDurationSeconds`.
        case tooLong
    }

    /// The longest workout an import builds, one sample a second: 48 hours.
    static let maximumDurationSeconds = 48 * 3_600

    /// Build a finished `HRVSession` so the archive accepts an import
    /// identically to a native workout. Per-second samples are reconstructed
    /// from HR + cadence + track so the charts and the map have something to
    /// draw, and the session ends where its last sample is.
    /// `replacing` reuses an existing session's id so the rebuild REPLACES the
    /// stub a crashed recording left behind, instead of leaving the user with a
    /// one-second ghost sitting next to the hour it should have been.
    /// Throws `InvalidSpan` for a track that ends before it starts or runs
    /// past `maximumDurationSeconds`; nothing is built for it.
    static func buildSession(
        from track: ImportedWorkoutTrack,
        source: Source,
        replacing existingID: UUID? = nil
    ) throws -> HRVSession {
        let ordered = track.timeOrdered()
        let duration = try durationSeconds(from: ordered.startDate, to: ordered.endDate)
        let pauses = breakPauses(of: ordered)
        let samples = perSecondSamples(from: ordered, duration: duration, pauses: pauses)
        var built = session(from: ordered, samples: samples, source: source, replacing: existingID)
        built.workoutMetadata?.pauseSpans = pauses.isEmpty ? nil : pauses
        return built
    }

    /// Each stretch between two segments of the track as a pause of the
    /// workout: nothing was recorded there, so the per-second samples' clock
    /// stops through it, as it does through a recorded pause, and moving
    /// time and pace leave it out. A join less than a second long is none.
    static func breakPauses(of track: ImportedWorkoutTrack) -> [WorkoutPauseSpan] {
        let fixes = track.track
        var pausedBefore = 0.0
        return TrackSegments.starts(track.segmentStarts, count: fixes.count).compactMap { start in
            let from = fixes[start - 1].timestamp.timeIntervalSince(track.startDate)
            let seconds = fixes[start].timestamp.timeIntervalSince(fixes[start - 1].timestamp).rounded(.down)
            guard seconds >= 1 else { return nil }
            defer { pausedBefore += seconds }
            return WorkoutPauseSpan(atElapsed: max(0, Int(from - pausedBefore)), seconds: seconds)
        }
    }

    /// The wall-clock second of active second `active`: the active second
    /// plus every pause that began before it (`WorkoutMetadata.wallClockSeconds`).
    private static func wallSecond(of active: Int, pauses: [WorkoutPauseSpan]) -> Int {
        active + Int(pauses.reduce(0.0) { $1.atElapsed < active ? $0 + $1.seconds : $0 })
    }

    /// The length, in whole seconds, of a workout from `start` to `end`.
    /// Throws for one that ends before it starts, or is longer than
    /// `maximumDurationSeconds`: a single bogus <time> (an epoch-1970
    /// trackpoint in an otherwise-2026 file, which the parser accepts) makes
    /// a span of decades, and building it would allocate a sample for every
    /// second. Cutting the samples short would leave a session whose dates
    /// claim a length its samples do not have, so the track is refused.
    static func durationSeconds(from start: Date, to end: Date) throws -> Int {
        guard end >= start else { throw InvalidSpan.endsBeforeStart }
        let seconds = Int(end.timeIntervalSince(start))
        guard seconds <= maximumDurationSeconds else { throw InvalidSpan.tooLong }
        return seconds
    }

    /// Whether `durationSeconds(from:to:)` accepts this span, so a source can
    /// leave out a workout that cannot be built before offering it.
    static func canBuild(from start: Date, to end: Date) -> Bool {
        do {
            _ = try durationSeconds(from: start, to: end)
            return true
        } catch {
            return false
        }
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

    /// Per-point elapsed seconds and cumulative distance along the track,
    /// precomputed ONCE. `buildSession` puts the track in time order first.
    /// No distance is added from the last fix of a segment to the first of
    /// the next (`TrackSegments`): nothing was recorded between them.
    ///
    /// The previous implementation rescanned the whole track for the nearest
    /// point AND recomputed the full prefix distance for every single second —
    /// O(n²), which froze the app for minutes (and tripped the watchdog) on a
    /// 2 h GPX. This is O(n + duration).
    private static func trackIndex(_ track: ImportedWorkoutTrack) -> (elapsed: [Double], cumulative: [Double]) {
        let elapsed = track.track.map { $0.timestamp.timeIntervalSince(track.startDate) }
        return (elapsed, TrackSegments.cumulativeMeters(track.track, starts: track.segmentStarts))
    }

    /// One sample per active second from start to end (the `pauses` left
    /// out), filling HR + cadence from the nearest GPX sample. Distance and
    /// altitude come from the nearest track point via a single advancing
    /// cursor (two-pointer sweep).
    private static func perSecondSamples(
        from track: ImportedWorkoutTrack, duration: Int, pauses: [WorkoutPauseSpan]
    ) -> [WorkoutSample] {
        let (hrMap, cadMap) = secondKeyedSamples(from: track)
        let (trackElapsed, trackCumDist) = trackIndex(track)
        let active = max(0, duration - Int(pauses.reduce(0.0) { $0 + $1.seconds }))
        var cursor = 0
        return (0 ... active).map { activeSec in
            let sec = wallSecond(of: activeSec, pauses: pauses)
            cursor = advancing(cursor, to: sec, elapsed: trackElapsed)
            let cumulative = trackCumDist.isEmpty ? 0 : trackCumDist[cursor]
            return WorkoutSample(
                offsetSec: activeSec,
                heartRate: hrMap[sec] ?? Self.nearestValue(in: hrMap, near: sec, within: 5),
                distanceMeters: cumulative > 0 ? cumulative : nil,
                paceSecPerKm: nil,
                cadenceStepsPerMin: cadMap[sec] ?? Self.nearestValue(in: cadMap, near: sec, within: 5),
                altitudeMeters: track.track.isEmpty ? nil : track.track[cursor].altitude,
                alpha1: nil, mets: nil, powerWatts: nil
            )
        }
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
        metadata.gpsFixTimes = WorkoutAnalyzer.encodeFixTimes(track: track.track)
        let starts = TrackSegments.starts(track.segmentStarts, count: track.track.count)
        metadata.gpsSegmentStarts = starts.isEmpty ? nil : starts
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
