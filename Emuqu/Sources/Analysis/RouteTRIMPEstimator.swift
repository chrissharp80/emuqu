import CoreLocation
import Foundation

/// Shared estimator for "what would this workout's TRIMP
/// have been if the strap hadn't dropped?". Shared by
/// `WorkoutRecoveryService` (crash-recovery) and the live finalize path
/// (`WorkoutRecorder.finalizeSession`), so both surface the same number
/// when the strap dies mid-workout but the session otherwise completes
/// cleanly.
///
/// Research context (May 2026 review):
///   • Banister TRIMP requires HR — there's no published HR-free
///     formulation. The honest fallback when HR is missing is to
///     anchor on a different effort proxy.
///   • Power-based TSS (Coggan; Stryd RSS) is the most accurate
///     HR-free intensity proxy and outperforms hrTSS on variable
///     workouts. When a power meter is present we already compute
///     `powerTSS` directly in `WorkoutRecorder+Lifecycle`. This
///     estimator does NOT duplicate that — it's the route-history
///     path for runners without power.
///   • For runners without power, the best HR-free estimate is to
///     use the user's own history on the same route: their prior
///     TRIMP-per-meter is far better than any generic GAP→TRIMP
///     conversion (no published validated formula exists for the
///     latter without HR).
///
/// Algorithm (three cases):
///   1. Recorded TRIMP looks healthy (≥ 70 % of prior route average
///      per meter): no extrapolation — measured value stands.
///   2. Recorded TRIMP exists but is suspiciously low for the route
///      (< 70 % of prior ratio): blend prior 60 % / recorded 40 %.
///   3. Recorded TRIMP is missing or essentially zero AND we have
///      ≥ 1 prior session on this route: use the prior route
///      average directly, scaled to today's recorded distance.
///
/// Confidence: floor 0.4 (no priors, today-only ratio), scales to
/// 0.85 cap with sample size. Never claims gospel — the UI always
/// renders this alongside the recorded value, never replacing it.
@MainActor
enum RouteTRIMPEstimator {
    struct Estimate {
        let estimatedTRIMP: Double
        let confidence: Double
        let routeName: String
        /// True when the recorded TRIMP was so low (or nil) that the
        /// estimate is dominated by route history, not the recorded
        /// session. Lets the UI say "based on N prior runs" rather
        /// than "estimated for the full route."
        let priorDominant: Bool
    }

    /// Compute the route-extrapolated TRIMP for a workout.
    ///
    /// - Parameters:
    ///   - track: GPS samples for the just-finished workout. Used by
    ///     `RouteLibrary` to match a saved route shape; if the user
    ///     started from a saved route this is still required because
    ///     we score the actual recorded shape, not just the binding.
    ///   - sport: filters prior sessions to the same sport.
    ///   - recordedTRIMP: the workout's Banister TRIMP as computed
    ///     from whatever HR the strap delivered. May be `nil` or
    ///     near-zero when the strap dropped entirely.
    ///   - recordedDistance: how far the user actually moved in the
    ///     recording. Used to scale prior ratios into a session-
    ///     comparable number when the recorded TRIMP is missing.
    ///   - archive: source of prior workouts on the same route.
    ///   - savedRouteStore: the user's saved-route library.
    /// - Returns: an estimate, or `nil` if there's not enough data
    ///   (no route match, no priors and no recordedTRIMP, or the
    ///   recorded TRIMP already looks healthy).
    static func estimate(
        track: [CLLocation],
        sport: Sport,
        recordedTRIMP: Double?,
        recordedDistance: Double?,
        archive: SessionArchive,
        savedRouteStore: SavedRouteStore
    ) -> Estimate? {
        guard let match = RouteLibrary.findMatch(currentTrack: track, sport: sport, store: savedRouteStore) else { return nil }
        let ratios = priorTRIMPPerMetre(archive: archive, sport: sport, savedRoute: match.savedRoute)
        let priorAvgRatio = ratios.isEmpty ? nil : ratios.reduce(0, +) / Double(ratios.count)
        let recordedRatio = trimpPerMetre(trimp: recordedTRIMP, distance: recordedDistance)
        // Case 1: nothing to do — the measured value already tracks the route.
        if let priorAvgRatio, let recordedRatio, recordedRatio >= 0.7 * priorAvgRatio { return nil }
        guard let scaled = scaledEstimate(
            priorAvgRatio: priorAvgRatio, recordedRatio: recordedRatio, priorCount: ratios.count,
            targetDistance: targetDistance(
                recordedDistance: recordedDistance, savedDistance: match.savedRoute.totalDistanceMeters
            )
        ) else { return nil }
        return Estimate(
            estimatedTRIMP: scaled.trimp, confidence: scaled.confidence,
            routeName: match.savedRoute.name, priorDominant: scaled.priorDominant
        )
    }

    /// TRIMP per metre for each prior run of this route — the shape-independent
    /// intensity the estimate extrapolates from.
    private static func priorTRIMPPerMetre(
        archive: SessionArchive,
        sport: Sport,
        savedRoute: SavedRoute
    ) -> [Double] {
        priorSessionsOnRoute(archive: archive, sport: sport, savedRoute: savedRoute).compactMap { session in
            trimpPerMetre(
                trimp: session.workoutMetadata?.luciaTRIMP,
                distance: session.workoutMetadata?.distanceMeters
            )
        }
    }

    /// `internal` rather than `private` so the estimation maths can be tested
    /// directly. This decides the training load a user is credited with when
    /// their strap dropped mid-workout, and that number feeds CTL/ATL and every
    /// recommendation after it.
    static func trimpPerMetre(trimp: Double?, distance: Double?) -> Double? {
        guard let trimp, trimp > 0, let distance, distance > 0 else { return nil }
        return trimp / distance
    }

    /// The distance the estimate represents. The route's full distance is
    /// preferred when the user appears to have run the whole loop (within 10 %
    /// either way); otherwise it scales to whichever is bigger, which covers
    /// both the strap-dropped-near-the-end case (recorded < saved) and the
    /// user-extended case (recorded > saved).
    static func targetDistance(recordedDistance: Double?, savedDistance savedDist: Double) -> Double {
        guard let recordedDistance else { return savedDist }
        // The "whole loop" test is a BAND, not a floor. With
        // `>= savedDist * 0.9` and no upper bound, every recording at
        // or above 90% of the route — including one four times its length —
        // takes the early return, `max` below is unreachable, and the whole
        // function reduces to `return savedDist`. The documented
        // "user-extended case (recorded > saved)" then never works: a user who
        // runs 14 km of a saved 10 km route is credited with 10 km of load,
        // and that under-credit propagates into CTL, ATL and every
        // recommendation built on them.
        let isWholeLoop = recordedDistance >= savedDist * 0.9
            && recordedDistance <= savedDist * 1.1
        if isWholeLoop { return savedDist }
        return max(savedDist, recordedDistance)
    }

    /// Which of the three estimation cases applies, and the number it produces.
    static func scaledEstimate(
        priorAvgRatio: Double?,
        recordedRatio: Double?,
        priorCount: Int,
        targetDistance: Double
    ) -> (trimp: Double, confidence: Double, priorDominant: Bool)? {
        let priorConfidence = min(0.85, 0.4 + 0.15 * Double(priorCount))
        switch (priorAvgRatio, recordedRatio) {
        case let (.some(prior), .some(today)):
            // Case 2: recorded data exists but is suspiciously low. Blend,
            // biased toward prior (60/40).
            return ((prior * 0.6 + today * 0.4) * targetDistance, priorConfidence, false)
        case let (.some(prior), nil):
            // Case 3a: full HR dropout, but we have prior runs of this route.
            // This is the user's exact complaint — TRIMP = 2 because HR was
            // missing. Use the prior average directly.
            return (prior * targetDistance, priorConfidence, true)
        case let (nil, .some(today)):
            // Case 3b: no priors, but some recorded TRIMP. Scale today's ratio
            // to the full route, at low confidence — we've never run it before.
            return (today * targetDistance, 0.4, false)
        case (nil, nil):
            // No basis for any estimate.
            return nil
        }
    }

    /// Find archived workout sessions that ran the same saved route.
    /// Same heuristic as the previous private implementation in
    /// `WorkoutRecoveryService`: sport-equal AND first-point within
    /// 150 m of the saved route's first point. Skips sessions that
    /// are themselves recovered partials so we don't anchor on
    /// estimates.
    private static func priorSessionsOnRoute(
        archive: SessionArchive,
        sport: Sport,
        savedRoute: SavedRoute
    ) -> [HRVSession] {
        guard let savedFirst = GPXExporter.decode(
            polyline: savedRoute.encodedPolyline,
            startDate: savedRoute.createdAt
        ).first else {
            return []
        }
        let savedAnchor = CLLocation(
            latitude: savedFirst.coordinate.latitude,
            longitude: savedFirst.coordinate.longitude
        )
        return archive.entries
            .filter { $0.sessionType == .workout }
            .compactMap { (try? archive.retrieve($0.sessionId)) ?? nil }
            .filter { startsNear(savedAnchor, session: $0, sport: sport) }
    }

    /// Whether the session is a non-partial workout of the same sport whose
    /// first GPS fix sits within 150 m of the route's anchor.
    private static func startsNear(_ savedAnchor: CLLocation, session: HRVSession, sport: Sport) -> Bool {
        guard let meta = session.workoutMetadata, meta.sport == sport,
              meta.partialDataReason == nil,
              let polyline = meta.gpsPolyline,
              let first = GPXExporter.decode(polyline: polyline, startDate: session.startDate).first
        else { return false }
        let firstLoc = CLLocation(
            latitude: first.coordinate.latitude,
            longitude: first.coordinate.longitude
        )
        return firstLoc.distance(from: savedAnchor) <= 150
    }
}
