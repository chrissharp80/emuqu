import CoreLocation
import Foundation

// MARK: - RouteLibrary
//
// Recognises when today's workout is a route the user has explicitly
// saved to their library — by NAME — and direction-agnostic so "Daily 1
// run east-to-west" and "Daily 1 run west-to-east" both match the same
// saved entry.
//
// Source of truth is `SavedRouteStore`, NOT the full session archive.
// We don't auto-mine random workouts: the user explicitly tells us
// "remember this one, here's its name" via the post-workout summary's
// "Add to my route library" action. The recogniser then checks today's
// path against each saved route in BOTH directions; the better fit wins.
//
// Algorithm: after ~500 m of GPS movement on a fresh workout, take an
// equivalent-length prefix of each saved route (forward AND reversed),
// compute mean nearest-neighbour distance from each live point. ≤ 30 m
// mean fit = match. Best fit wins, with the "direction" flag baked in
// so the AI coach can speak about it ("running Daily 1 in reverse").
@MainActor
enum RouteLibrary {
    /// How many meters of fresh GPS we need before attempting recognition.
    /// Below this the user might still be wandering near the trailhead
    /// and the comparison would be noise.
    static let detectionTriggerMeters: Double = 500

    /// Maximum mean point-to-track distance for a route to count as a
    /// match. 30 m is a generous fit (~2 GPS-fix worth of jitter) — wide
    /// enough that running on the opposite sidewalk still matches, narrow
    /// enough that a parallel street doesn't.
    static let matchToleranceMeters: Double = 30

    /// Sport types where route-matching is worth running. Indoor sports
    /// never have GPS, walks/runs/hikes/bikes do.
    static let supportedSports: Set<Sport> = [.run, .trailRun, .walk, .hike, .bike]

    enum Direction: Equatable {
        case forward
        case reverse
    }

    struct Match: Equatable {
        let savedRoute: SavedRoute
        /// Concrete `Route` rebuilt from the saved polyline, possibly
        /// reversed depending on `direction`. The recorder binds this so
        /// climb-ahead computations match the user's actual heading.
        let route: Route
        let direction: Direction
        /// Mean nearest-neighbor distance in meters. Always ≤ tolerance
        /// for a returned match. Lower = better fit.
        let meanFitMeters: Double
    }

    /// Search the user's saved-route library for a match. Returns nil when
    /// the live track hasn't covered enough ground yet, or when nothing
    /// in the library is close enough.
    /// `@MainActor` because we resolve the default `AppDependencies.current.location.savedRouteStore`
    /// inside the body — `.shared` is itself MainActor-isolated, and
    /// Swift 6 evaluates default-parameter expressions in a separate
    /// nonisolated context regardless of the function's annotation.
    /// Pattern: nil default + resolve-inside.
    @MainActor
    static func findMatch(
        currentTrack: [CLLocation],
        sport: Sport,
        store: SavedRouteStore? = nil
    ) -> Match? {
        let store = store ?? AppDependencies.current.location.savedRouteStore
        guard supportedSports.contains(sport), currentTrack.count >= 2 else { return nil }
        let traveled = totalDistanceMeters(of: currentTrack)
        guard traveled >= detectionTriggerMeters else { return nil }
        var best: Match?
        for saved in store.routes(for: sport) {
            for candidate in candidates(for: saved, liveTrack: currentTrack, liveTraveled: traveled)
                where candidate.meanFitMeters < (best?.meanFitMeters ?? .infinity) {
                best = candidate
            }
        }
        return best
    }

    /// Scores one saved route in both directions.
    ///
    /// Reverse is the same loop travelled the other way: the track is reversed
    /// AND a fresh `Route` is built from the reversed trackpoints, so the climb
    /// queue reflects the climbs the user will actually hit in THIS direction —
    /// a downhill on the forward route is an uphill on the reverse.
    private static func candidates(
        for saved: SavedRoute,
        liveTrack: [CLLocation],
        liveTraveled: Double
    ) -> [Match] {
        let route = saved.toRoute()
        // Reconstruct a CLLocation track from the saved Route's trackpoints so
        // the distance math matches the GPS comparison.
        let track = route.trackpoints.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        guard track.count >= 2 else { return [] }
        let reversedTrack = Array(track.reversed())
        return [
            scoreDirection(
                liveTrack: liveTrack, savedTrack: track, liveTraveled: liveTraveled,
                saved: saved, route: route, direction: .forward
            ),
            scoreDirection(
                liveTrack: liveTrack, savedTrack: reversedTrack, liveTraveled: liveTraveled,
                saved: saved, route: Route.fromGPX(name: saved.name, track: reversedTrack),
                direction: .reverse
            )
        ].compactMap { $0 }
    }

    private static func scoreDirection(
        liveTrack: [CLLocation],
        savedTrack: [CLLocation],
        liveTraveled: Double,
        saved: SavedRoute,
        route: Route,
        direction: Direction
    ) -> Match? {
        guard let liveStart = liveTrack.first, let savedStart = savedTrack.first else { return nil }
        // Cheap reject: if the saved route's starting point (in this
        // direction) isn't within 150 m of where we are, this direction
        // doesn't fit. Skips the expensive shape comparison.
        guard liveStart.distance(from: savedStart) <= 150 else { return nil }
        let prefix = thinned(trackPrefix(savedTrack, meters: liveTraveled + 200), spacing: prefixSpacingMeters)
        let meanDist = meanNearestDistance(from: evenSample(liveTrack, count: maxScoredPoints), to: prefix)
        guard meanDist <= matchToleranceMeters else { return nil }
        return Match(
            savedRoute: saved,
            route: route,
            direction: direction,
            meanFitMeters: meanDist
        )
    }

    // MARK: - Helpers

    /// Live points scored per comparison. The fit is a MEAN over the live
    /// track, so an even subsample estimates it without bias while capping the
    /// O(|live| × |saved|) cost: a full-resolution hour-long run against a
    /// long route was millions of distance calls, once per prior on every
    /// finalize and backfill.
    static let maxScoredPoints = 300

    /// Spacing the saved prefix is thinned to. A dropped point lies within
    /// half this of a kept one, so thinning adds at most 2.5 m to a fit judged
    /// against a 30 m tolerance.
    static let prefixSpacingMeters: Double = 5

    /// `count` points spread evenly along `track`, or the track itself when it
    /// is no longer than that.
    static func evenSample(_ track: [CLLocation], count: Int) -> [CLLocation] {
        guard count > 0, track.count > count else { return track }
        let step = Double(track.count) / Double(count)
        return (0 ..< count).map { track[Int(Double($0) * step)] }
    }

    /// The track with points closer than `spacing` to the last kept one
    /// dropped; the first and last points are always kept.
    static func thinned(_ track: [CLLocation], spacing: Double) -> [CLLocation] {
        guard var lastKept = track.first, let end = track.last else { return track }
        var out = [lastKept]
        for point in track.dropFirst() where point.distance(from: lastKept) >= spacing {
            out.append(point)
            lastKept = point
        }
        if out.last !== end { out.append(end) }
        return out
    }

    /// `internal` so the route-matching geometry can be tested. This decides
    /// whether a live run is recognised as a saved route, which gates the
    /// route-history TRIMP estimate.
    static func totalDistanceMeters(of track: [CLLocation]) -> Double {
        WorkoutGeometry.trackLengthMeters(track)
    }

    static func trackPrefix(_ track: [CLLocation], meters: Double) -> [CLLocation] {
        guard track.count >= 2, meters > 0 else { return track }
        var out: [CLLocation] = [track[0]]
        var cumulative: Double = 0
        for i in 1 ..< track.count {
            cumulative += track[i].distance(from: track[i - 1])
            out.append(track[i])
            if cumulative >= meters { break }
        }
        return out
    }

    /// Mean nearest-neighbor distance from each point of `a` to its
    /// closest point on `b`. O(|a| × |b|), which is why `scoreDirection`
    /// subsamples `a` and thins `b` first. Always returns the same
    /// number regardless of which way we walk through `a`, so it's
    /// robust to live-track sample-density differences.
    static func meanNearestDistance(from a: [CLLocation], to b: [CLLocation]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return .infinity }
        let sum = a.reduce(0.0) { $0 + Self.nearestDistance(from: $1, to: b) }
        return sum / Double(a.count)
    }

    static func nearestDistance(from pa: CLLocation, to b: [CLLocation]) -> Double {
        var best: Double = .greatestFiniteMagnitude
        for pb in b {
            best = min(best, pa.distance(from: pb))
        }
        return best
    }
}
