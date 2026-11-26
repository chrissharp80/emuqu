import CoreLocation
import Foundation

/// What the user's own past GPS workouts say about the ground around them:
/// the climb that lies ahead in the direction they are heading, what their
/// heart rate did on it, and how they went at the spot they are on now.
///
/// The recorder never binds a whole route from history
/// (`attemptAutoRouteDetection`): guessing a route from old workouts made
/// false matches. This looks only at the next stretch of ground, only along
/// past tracks that passed within `matchRadiusMeters` heading the same way,
/// and it reports a climb only when most of those passes found it in the
/// same place. Pure functions of their arguments, safe off the main actor.
enum PlaceHistory {
    /// One GPS fix of a past workout and what the body did there.
    struct Point: Sendable, Equatable {
        let latitude: Double
        let longitude: Double
        let altitudeMeters: Double?
        let distanceAlongMeters: Double
        let heartRate: Int?
        let paceSecPerKm: Double?
    }

    struct Track: Sendable, Equatable {
        let date: Date
        let points: [Point]
    }

    /// A climb the past passes agree lies ahead, in medians across them.
    struct ClimbAhead: Codable, Sendable, Equatable {
        let distanceMeters: Double
        let lengthMeters: Double
        let gainMeters: Double
        let passes: Int
        /// From the heart rate at the foot of the climb to the highest on it.
        let heartRateRise: Int?
        let peakHeartRate: Int?

        var gradePercent: Double { lengthMeters > 0 ? gainMeters / lengthMeters * 100 : 0 }
    }

    /// Past passes over the spot the user is on now.
    struct Visits: Codable, Sendable, Equatable {
        let count: Int
        let medianPaceSecPerKm: Double?
        let medianHeartRate: Int?
        let latestDate: Date
        let latestPaceSecPerKm: Double?
        let latestHeartRate: Int?
    }

    static let matchRadiusMeters = 30.0
    static let headingToleranceDegrees = 60.0
    static let lookaheadMeters = 800.0
    static let minimumAgreeingPasses = 2
    static let climbAgreementMeters = 120.0
    static let minimumGainMeters = 8.0
    static let minimumGradePercent = 3.0
    static let gradeWindowMeters = 100.0
    /// A drop this far below the highest point so far ends the climb, so two
    /// hills with a dip between them are not read as one.
    static let climbEndDropMeters = 4.0
    /// Heart rate lags the effort: the peak is looked for this far past the top.
    static let heartRateLagMeters = 100.0
    static let headingSpanMeters = 25.0
    /// A step between fixes that rises less than this is still flat ground.
    static let flatStepMeters = 0.2
    static let maxSampleDeltaSec = 10
}

// MARK: - Loading

extension PlaceHistory {
    /// GPS workouts scanned and kept, as in the spot lookup
    /// (`SegmentPointSampler`), and how far from the start a kept track
    /// has to pass.
    static let scanLimit = 120
    static let trackLimit = 30
    static let nearbyRadiusMeters = 5_000.0

    /// The newest past GPS workouts that passed within `nearbyRadiusMeters`
    /// of `start`, leaving out the workout that began at `excluding`.
    static func load(from archive: SessionArchive, near start: CLLocation, excluding: Date) -> [Track] {
        let entries = archive.store.entries
            .filter { $0.sessionType == .workout && abs($0.date.timeIntervalSince(excluding)) > 1 }
            .sorted { $0.date > $1.date }
        var tracks: [Track] = []
        var read = 0
        for entry in entries.prefix(scanLimit) where read < trackLimit {
            guard let session = archive.retrieveLightweightOrLog(entry.sessionId), let track = track(from: session) else { continue }
            read += 1
            if passesNear(track, start) { tracks.append(track) }
        }
        return tracks
    }

    static func passesNear(_ track: Track, _ location: CLLocation) -> Bool {
        track.points.contains { distance($0, location) <= nearbyRadiusMeters }
    }

    /// A past workout's fixes with the distance covered to each and the
    /// heart rate, pace and altitude its per-second samples had there.
    static func track(from session: HRVSession) -> Track? {
        guard let metadata = session.workoutMetadata, let polyline = metadata.gpsPolyline else { return nil }
        let fixes = GPXExporter.decode(polyline: polyline, startDate: session.startDate, duration: session.duration)
        guard fixes.count >= 2 else { return nil }
        let samples = (metadata.samples ?? []).sorted { $0.offsetSec < $1.offsetSec }
        var along = 0.0
        var points: [Point] = []
        for (index, fix) in fixes.enumerated() {
            if index > 0 { along += fix.distance(from: fixes[index - 1]) }
            let offset = Int(fix.timestamp.timeIntervalSince(session.startDate))
            points.append(point(fix, along: along, sample: sample(in: samples, near: offset)))
        }
        return Track(date: session.startDate, points: points)
    }

    private static func point(_ fix: CLLocation, along: Double, sample: WorkoutSample?) -> Point {
        Point(
            latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
            altitudeMeters: sample?.altitudeMeters ?? (fix.verticalAccuracy >= 0 ? fix.altitude : nil),
            distanceAlongMeters: along, heartRate: sample?.heartRate, paceSecPerKm: sample?.paceSecPerKm
        )
    }

    /// The sample nearest `offset` in offset-sorted `samples`, when it is
    /// within `maxSampleDeltaSec`.
    static func sample(in samples: [WorkoutSample], near offset: Int) -> WorkoutSample? {
        var low = 0
        var high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].offsetSec < offset { low = mid + 1 } else { high = mid }
        }
        let candidates = [low - 1, low].filter { samples.indices.contains($0) }.map { samples[$0] }
        guard let best = candidates.min(by: { abs($0.offsetSec - offset) < abs($1.offsetSec - offset) }) else { return nil }
        return abs(best.offsetSec - offset) <= maxSampleDeltaSec ? best : nil
    }
}

// MARK: - Where a past track passed

extension PlaceHistory {
    static func distance(_ point: Point, _ location: CLLocation) -> Double {
        CLLocation(latitude: point.latitude, longitude: point.longitude).distance(from: location)
    }

    /// The index where `track` passed within `matchRadiusMeters` of
    /// `location`, going within `headingToleranceDegrees` of `heading` when
    /// a heading is given.
    static func passIndex(in track: Track, at location: CLLocation, heading: Double?) -> Int? {
        let points = track.points
        var best: (index: Int, meters: Double)?
        for index in points.indices {
            let meters = distance(points[index], location)
            guard meters <= matchRadiusMeters, meters < (best?.meters ?? .infinity) else { continue }
            if heading == nil || headingMatches(points, at: index, heading: heading ?? 0) { best = (index, meters) }
        }
        return best?.index
    }

    private static func headingMatches(_ points: [Point], at index: Int, heading: Double) -> Bool {
        let origin = points[index].distanceAlongMeters
        guard let ahead = points[index...].first(where: { $0.distanceAlongMeters - origin >= headingSpanMeters }) else { return false }
        let delta = abs(WorkoutGeometry.signedBearingDelta(from: bearing(points[index], ahead), to: heading))
        return delta <= headingToleranceDegrees
    }

    static func bearing(_ from: Point, _ to: Point) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let deltaLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

// MARK: - The climb ahead

extension PlaceHistory {
    /// One past pass's climb: where it started past the user's spot, its
    /// size, and the heart rate at its foot and highest on it.
    struct PassClimb: Equatable {
        let distanceMeters: Double
        let lengthMeters: Double
        let gainMeters: Double
        let startHeartRate: Int?
        let peakHeartRate: Int?

        var heartRateRise: Int? {
            guard let startHeartRate, let peakHeartRate else { return nil }
            return peakHeartRate - startHeartRate
        }
    }

    /// The climb ahead (when there is a heading to look along) and the past
    /// passes over this spot, in one pass for `LivePlaceMemory`.
    static func answers(in tracks: [Track], at location: CLLocation, heading: Double?) -> (climbAhead: ClimbAhead?, visits: Visits?) {
        let climb = heading.flatMap { climbAhead(in: tracks, at: location, heading: $0) }
        return (climb, visits(in: tracks, at: location, heading: heading))
    }

    /// The climb the past passes heading this way agree on: at least
    /// `minimumAgreeingPasses`, and at least half of the passes that went
    /// this way, found it within `climbAgreementMeters` of each other.
    static func climbAhead(in tracks: [Track], at location: CLLocation, heading: Double) -> ClimbAhead? {
        let passes = tracks.compactMap { track in passIndex(in: track, at: location, heading: heading).map { (track, $0) } }
        let climbs = passes.compactMap { climb(in: $0.0.points, from: $0.1) }
        guard let middle = median(climbs.map(\.distanceMeters)) else { return nil }
        let agreeing = climbs.filter { abs($0.distanceMeters - middle) <= climbAgreementMeters }
        guard agreeing.count >= minimumAgreeingPasses, agreeing.count * 2 >= passes.count else { return nil }
        let rises = agreeing.compactMap(\.heartRateRise)
        return ClimbAhead(
            distanceMeters: median(agreeing.map(\.distanceMeters)) ?? middle,
            lengthMeters: median(agreeing.map(\.lengthMeters)) ?? 0,
            gainMeters: median(agreeing.map(\.gainMeters)) ?? 0,
            passes: agreeing.count,
            heartRateRise: median(rises.map(Double.init)).map { Int($0.rounded()) },
            peakHeartRate: median(agreeing.compactMap(\.peakHeartRate).map(Double.init)).map { Int($0.rounded()) }
        )
    }

    /// The first climb starting within `lookaheadMeters` past `start`: where
    /// the ground first rises at `minimumGradePercent` over
    /// `gradeWindowMeters`, up to its highest point before a
    /// `climbEndDropMeters` drop (however far past the look-ahead that is),
    /// kept when it gains `minimumGainMeters` at that grade.
    static func climb(in points: [Point], from start: Int) -> PassClimb? {
        let origin = points[start].distanceAlongMeters
        let ahead = Array(points[start...])
        let reach = ahead.prefix { $0.distanceAlongMeters - origin <= lookaheadMeters }.count
        guard let rising = ahead.indices.prefix(reach).first(where: { risesAtGrade(ahead, from: $0) }) else { return nil }
        let foot = footIndex(ahead, from: rising)
        let top = topIndex(ahead, from: foot)
        guard let footAltitude = ahead[foot].altitudeMeters, let topAltitude = ahead[top].altitudeMeters else { return nil }
        let length = ahead[top].distanceAlongMeters - ahead[foot].distanceAlongMeters
        let gain = topAltitude - footAltitude
        guard length > 0, gain >= minimumGainMeters, gain / length * 100 >= minimumGradePercent else { return nil }
        return PassClimb(
            distanceMeters: ahead[foot].distanceAlongMeters - origin, lengthMeters: length, gainMeters: gain,
            startHeartRate: ahead[foot].heartRate, peakHeartRate: peakHeartRate(in: points, from: ahead[foot], to: ahead[top])
        )
    }

    private static func risesAtGrade(_ points: [Point], from index: Int) -> Bool {
        guard let base = points[index].altitudeMeters else { return false }
        let target = points[index].distanceAlongMeters + gradeWindowMeters
        guard let later = points[index...].first(where: { $0.distanceAlongMeters >= target }), let altitude = later.altitudeMeters else { return false }
        return altitude - base >= gradeWindowMeters * minimumGradePercent / 100
    }

    /// Where the ground actually starts rising: the window that first sees
    /// the grade can begin up to `gradeWindowMeters` short of the climb.
    private static func footIndex(_ points: [Point], from rising: Int) -> Int {
        var foot = rising
        while foot + 1 < points.count, let here = points[foot].altitudeMeters, let next = points[foot + 1].altitudeMeters,
              next - here < flatStepMeters {
            foot += 1
        }
        return foot
    }

    /// The highest point from `foot` on, stopping at the first drop of
    /// `climbEndDropMeters` below it.
    private static func topIndex(_ points: [Point], from foot: Int) -> Int {
        var top = foot
        for index in points.indices where index > foot {
            guard let altitude = points[index].altitudeMeters, let highest = points[top].altitudeMeters else { continue }
            if altitude > highest { top = index }
            if altitude < highest - climbEndDropMeters { break }
        }
        return top
    }

    private static func peakHeartRate(in points: [Point], from foot: Point, to top: Point) -> Int? {
        let end = top.distanceAlongMeters + heartRateLagMeters
        return points
            .filter { $0.distanceAlongMeters >= foot.distanceAlongMeters && $0.distanceAlongMeters <= end }
            .compactMap(\.heartRate)
            .max()
    }
}

// MARK: - This spot before

extension PlaceHistory {
    /// The past passes over `location` (heading the same way when a heading
    /// is given), with their pace and heart rate there.
    static func visits(in tracks: [Track], at location: CLLocation, heading: Double?) -> Visits? {
        let passes = tracks
            .compactMap { track in passIndex(in: track, at: location, heading: heading).map { (track.date, track.points[$0]) } }
            .sorted { $0.0 > $1.0 }
        guard let latest = passes.first else { return nil }
        return Visits(
            count: passes.count,
            medianPaceSecPerKm: median(passes.compactMap { $0.1.paceSecPerKm }),
            medianHeartRate: median(passes.compactMap { $0.1.heartRate }.map(Double.init)).map { Int($0.rounded()) },
            latestDate: latest.0,
            latestPaceSecPerKm: latest.1.paceSecPerKm,
            latestHeartRate: latest.1.heartRate
        )
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
