import CoreLocation
import Foundation

// MARK: - Route
//
// A planned course the user binds before starting a workout. Distinct from
// a recorded session — this is the BLUEPRINT (track + elevation profile)
// the user intends to follow today, loaded from a GPX file.
//
// Lets the AI coach become predictive: instead of waiting until the user
// is suffering on the climb, the coach can see "big climb in 400 m" and
// pace accordingly. Post-workout, the coach can attribute fatigue to
// known effort points instead of pure rear-view analysis.
//
// Lightweight by design — we keep only the data the live tick needs:
// trackpoints (lat/lon/altitude) and pre-computed climb segments. The
// derived totals (distance, ascent, descent) are stored on the instance
// because they're stable for a route and computed once at load.
struct Route: Codable, Identifiable, Equatable {
    let id: UUID
    /// User-supplied or filename-derived display name ("Tahoe Rim Trail loop").
    let name: String
    /// Original GPX-parsed track: latitude, longitude and altitude from the
    /// source file. Timestamps are not kept.
    let trackpoints: [Point]
    /// Pre-computed cumulative distance along the track at each point, in
    /// meters. Indexed parallel to `trackpoints`. Cached because every
    /// per-tick "where am I on the route" query needs it.
    let cumulativeDistanceMeters: [Double]
    /// Detected climb segments — sustained gain ≥ 30 m at ≥ 3 % avg grade.
    /// Sorted by start distance, so "the next one past my current position"
    /// is the first climb that ends beyond it.
    let climbs: [Climb]
    let totalDistanceMeters: Double
    let totalAscentMeters: Double
    let totalDescentMeters: Double

    struct Point: Codable, Equatable {
        let latitude: Double
        let longitude: Double
        let altitudeMeters: Double
    }

    /// A sustained climb worth flagging to the user. Distance is from the
    /// start of the route (NOT from the climb's start) so progress
    /// comparison is one subtraction.
    struct Climb: Codable, Equatable, Hashable {
        let startDistanceMeters: Double
        let endDistanceMeters: Double
        let gainMeters: Double
        let averageGradePercent: Double
        /// Reverse-geocoded road name where the climb starts ("Elm Street",
        /// "Ridge Rd"). nil for routes that haven't gone through the
        /// `SavedRouteStore` enrichment pass — climbs detected from a
        /// freshly-imported GPX have nil here until the user saves the
        /// route to their library, at which point a background task
        /// geocodes each climb's start point. Codable defaults to nil
        /// for old saved routes that were created before this field
        /// existed.
        var roadName: String?

        var lengthMeters: Double { endDistanceMeters - startDistanceMeters }

        // Custom decoder so old saved routes (no roadName field) decode
        // cleanly.
        init(
            startDistanceMeters: Double,
            endDistanceMeters: Double,
            gainMeters: Double,
            averageGradePercent: Double,
            roadName: String? = nil
        ) {
            self.startDistanceMeters = startDistanceMeters
            self.endDistanceMeters = endDistanceMeters
            self.gainMeters = gainMeters
            self.averageGradePercent = averageGradePercent
            self.roadName = roadName
        }

        enum CodingKeys: String, CodingKey {
            case startDistanceMeters, endDistanceMeters, gainMeters, averageGradePercent, roadName
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            startDistanceMeters = try c.decode(Double.self, forKey: .startDistanceMeters)
            endDistanceMeters = try c.decode(Double.self, forKey: .endDistanceMeters)
            gainMeters = try c.decode(Double.self, forKey: .gainMeters)
            averageGradePercent = try c.decode(Double.self, forKey: .averageGradePercent)
            roadName = try c.decodeIfPresent(String.self, forKey: .roadName)
        }
    }

    /// Build from a parsed GPX track. Computes cumulative distance + ascent /
    /// descent + climb detection in one pass.
    static func fromGPX(name: String, track: [CLLocation]) -> Route {
        guard track.count >= 2 else { return empty(named: name) }
        let profile = elevationProfile(track: track)
        let points = track.map {
            Point(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, altitudeMeters: $0.altitude)
        }
        return Route(
            id: UUID(),
            name: name,
            trackpoints: points,
            cumulativeDistanceMeters: profile.cumulative,
            climbs: detectClimbs(track: track, cumulative: profile.cumulative),
            totalDistanceMeters: profile.cumulative.last ?? 0,
            totalAscentMeters: profile.ascent,
            totalDescentMeters: profile.descent
        )
    }

    /// A route with no track — what a GPX carrying fewer than two points
    /// produces. Kept as a real Route so callers never special-case nil.
    private static func empty(named name: String) -> Route {
        Route(
            id: UUID(),
            name: name,
            trackpoints: [],
            cumulativeDistanceMeters: [],
            climbs: [],
            totalDistanceMeters: 0,
            totalAscentMeters: 0,
            totalDescentMeters: 0
        )
    }

    /// Cumulative distance at each trackpoint, plus total ascent and descent.
    private static func elevationProfile(
        track: [CLLocation]
    ) -> (cumulative: [Double], ascent: Double, descent: Double) {
        var cumulative: [Double] = [0]
        var ascent: Double = 0
        var descent: Double = 0
        // `1 ..< 0` traps on an empty track.
        guard track.count > 1 else { return (cumulative, ascent, descent) }
        for i in 1 ..< track.count {
            cumulative.append(cumulative[i - 1] + track[i].distance(from: track[i - 1]))
            let dh = track[i].altitude - track[i - 1].altitude
            if dh > 0 { ascent += dh } else { descent += abs(dh) }
        }
        return (cumulative, ascent, descent)
    }

    /// Find sustained climbs along the track. A climb is a contiguous
    /// stretch where elevation is rising (smoothed by a 5-point window
    /// to ignore GPS altitude noise) and the segment totals ≥ 30 m of
    /// gain at ≥ 3 % average grade. Anything shorter / shallower is
    /// "rolling terrain" and not worth a coaching cue.
    private static func detectClimbs(track: [CLLocation], cumulative: [Double]) -> [Climb] {
        guard track.count >= 5 else { return [] }
        let smoothed = smooth(track.map(\.altitude), window: 5)
        return risingRuns(in: smoothed).compactMap { run in
            qualifyingClimb(
                fromIdx: run.startIdx, toIdx: run.endIdx,
                startAlt: smoothed[run.startIdx], smoothed: smoothed, cumulative: cumulative
            )
        }
    }

    /// Index ranges over which the smoothed elevation is rising. The last run
    /// is closed out at the end of the track when the route finishes uphill.
    /// Contiguous rising stretches. A FLAT step neither opens nor closes one.
    ///
    /// If a flat step counted as "not rising" and closed the run in progress,
    /// a shelf partway up a hill would split one climb into two, and the 30 m
    /// qualifying threshold would then discard the shorter half — a 59.5 m
    /// climb with a flat shelf announced to the user as a 31.5 m climb
    /// starting halfway up. Same rule as `TopoElevationService.sustainedClimb`.
    ///
    /// `internal` so it can be tested.
    static func risingRuns(in smoothed: [Double]) -> [(startIdx: Int, endIdx: Int)] {
        // `1 ..< 0` is an invalid range and traps on an empty profile.
        guard smoothed.count > 1 else { return [] }

        var runs: [(startIdx: Int, endIdx: Int)] = []
        var climbStartIdx: Int?
        for i in 1 ..< smoothed.count {
            let delta = smoothed[i] - smoothed[i - 1]
            if delta == 0 { continue }
            if delta > 0, climbStartIdx == nil {
                climbStartIdx = i - 1
            } else if delta < 0, let start = climbStartIdx {
                runs.append((start, i - 1))
                climbStartIdx = nil
            }
        }
        if let start = climbStartIdx { runs.append((start, smoothed.count - 1)) }
        return runs
    }

    /// One rising stretch as a Climb, or nil when it's too short or too
    /// shallow to be worth a coaching cue.
    private static func qualifyingClimb(
        fromIdx: Int, toIdx: Int, startAlt: Double, smoothed: [Double], cumulative: [Double]
    ) -> Climb? {
        let gain = smoothed[toIdx] - startAlt
        let length = cumulative[toIdx] - cumulative[fromIdx]
        guard gain >= 30, length > 0 else { return nil }
        let grade = (gain / length) * 100
        guard grade >= 3.0 else { return nil }
        return Climb(
            startDistanceMeters: cumulative[fromIdx],
            endDistanceMeters: cumulative[toIdx],
            gainMeters: gain,
            averageGradePercent: grade
        )
    }

    static func smooth(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, values.count > window else { return values }
        let half = window / 2
        var out = values
        for i in half ..< (values.count - half) {
            var sum: Double = 0
            for j in (i - half) ... (i + half) { sum += values[j] }
            out[i] = sum / Double(window)
        }
        return out
    }
}

// MARK: - RouteProgress
//
// Live snapshot of the user's position along a bound route. Recomputed
// each tick from the user's current GPS coordinate vs. the route's track.
//
// The position is matched to a trackpoint by linear scan, cheap for a
// few-thousand-point GPX and free of a kd-tree dependency.
struct RouteProgress: Equatable {
    /// Index of the route trackpoint nearest the user's current location.
    let nearestPointIndex: Int
    /// Cumulative distance along the route at `nearestPointIndex`, meters.
    let distanceAlongMeters: Double
    /// Fraction of the route completed, 0...1.
    let percentComplete: Double
    /// Distance from current position to the route's end, meters.
    let metersToFinish: Double
    /// Distance from current position to the next climb's start, meters.
    /// Nil when no climb remains ahead of the user.
    let metersToNextClimb: Double?
    /// The next climb itself — distance, gain, grade. Nil when none ahead.
    let nextClimb: Route.Climb?

    /// `previousIndex` is the `nearestPointIndex` of the last tick. With it,
    /// the match continues along the route from there, so a loop's shared
    /// start/finish or an out-and-back's two legs do not make the position
    /// jump; the user rejoining far away falls back to the nearest point.
    /// Without it (the first tick), the earliest of the nearest points wins,
    /// so standing at a loop's start reads as the start, not the finish.
    static func compute(currentLocation: CLLocation, route: Route, previousIndex: Int? = nil) -> RouteProgress? {
        guard !route.trackpoints.isEmpty, !route.cumulativeDistanceMeters.isEmpty else {
            return nil
        }
        let bestIdx = min(
            nearestPointIndex(to: currentLocation, in: route, after: previousIndex),
            route.cumulativeDistanceMeters.count - 1
        )
        let along = route.cumulativeDistanceMeters[bestIdx]
        let total = route.totalDistanceMeters
        let nextClimb = route.climbs.first { $0.startDistanceMeters > along }
        return RouteProgress(
            nearestPointIndex: bestIdx,
            distanceAlongMeters: along,
            percentComplete: total > 0 ? min(1.0, along / total) : 0,
            metersToFinish: max(0, total - along),
            metersToNextClimb: nextClimb.map { max(0, $0.startDistanceMeters - along) },
            nextClimb: nextClimb
        )
    }

    /// How far behind the last match a GPS wobble may place the user.
    private static let backtrackMeters = 100.0
    /// How far ahead of the last match one tick may move the user.
    private static let lookaheadMeters = 1_000.0
    /// Beyond this from every point near the last match, the user has left
    /// that stretch and is matched anywhere on the route.
    private static let rejoinMeters = 100.0
    /// Points this close to the best distance count as equally near.
    private static let tieToleranceMeters = 25.0

    private static func nearestPointIndex(to location: CLLocation, in route: Route, after previous: Int?) -> Int {
        let distances = route.trackpoints.map {
            location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
        }
        if let window = continuityWindow(after: previous, in: route, count: distances.count),
           let local = window.min(by: { distances[$0] < distances[$1] }),
           distances[local] <= rejoinMeters {
            return local
        }
        let best = distances.min() ?? 0
        return distances.firstIndex { $0 <= best + tieToleranceMeters } ?? 0
    }

    /// Trackpoints from a little behind the last match to a stretch ahead of it.
    private static func continuityWindow(after previous: Int?, in route: Route, count: Int) -> Range<Int>? {
        let cumulative = route.cumulativeDistanceMeters
        guard let previous, cumulative.indices.contains(previous), count > 0 else { return nil }
        let along = cumulative[previous]
        let lo = min(cumulative.firstIndex { $0 >= along - backtrackMeters } ?? 0, count - 1)
        let hi = min(cumulative.firstIndex { $0 > along + lookaheadMeters } ?? count, count)
        return lo ..< max(lo + 1, hi)
    }
}
