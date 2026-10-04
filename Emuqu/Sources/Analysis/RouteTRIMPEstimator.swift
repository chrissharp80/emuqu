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
///      average directly.
///
/// Every case scales TRIMP-per-metre to today's recorded distance (the
/// whole route only when the recording itself may have stopped early; see
/// `targetDistance`).
///
/// Priors are earlier runs of THIS saved route: same sport, ended before
/// the workout being estimated starts (so a backfilled session never
/// counts itself), whose own shape matches the route, and whose own HR
/// load was not itself a dropout. Ratios under half the median prior
/// ratio are dropped as outliers.
///
/// Confidence: floor 0.4 (no priors, today-only ratio), scales to
/// 0.85 cap with sample size. Never claims gospel — the UI always
/// renders this alongside the recorded value. It feeds CTL/ATL through
/// `WorkoutMetadata.preferredTrainingLoad`: ahead of every HR-derived
/// figure when it rests on prior runs and the recorded TRIMP is a dropout
/// fraction of it (`routeEstimateReplacesHRLoad` — the "TRIMP 2" case this
/// was built for), and otherwise only when nothing else exists.
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
    ///     recording. The estimate is scaled to it (see `targetDistance`).
    ///   - distanceMayBeTruncated: true when the recording itself stopped
    ///     early (crash recovery), so the user may have run further than
    ///     `recordedDistance`; see `recordingMayBeTruncated`.
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
        distanceMayBeTruncated: Bool = false,
        archive: SessionArchive,
        savedRouteStore: SavedRouteStore
    ) -> Estimate? {
        guard let match = RouteLibrary.findMatch(currentTrack: track, sport: sport, store: savedRouteStore),
              let workoutStart = track.first?.timestamp else { return nil }
        let route = PriorRoute(savedRoute: match.savedRoute, sport: sport, store: savedRouteStore)
        let ratios = withoutOutliers(priorTRIMPPerMetre(archive: archive, route: route, before: workoutStart))
        let priorAvgRatio = ratios.isEmpty ? nil : ratios.reduce(0, +) / Double(ratios.count)
        let recordedRatio = trimpPerMetre(trimp: recordedTRIMP, distance: recordedDistance)
        // Case 1: nothing to do — the measured value already tracks the route.
        if let priorAvgRatio, let recordedRatio, recordedRatio >= 0.7 * priorAvgRatio { return nil }
        guard let scaled = scaledEstimate(
            priorAvgRatio: priorAvgRatio, recordedRatio: recordedRatio, priorCount: ratios.count,
            targetDistance: targetDistance(
                recordedDistance: recordedDistance, savedDistance: match.savedRoute.totalDistanceMeters,
                distanceMayBeTruncated: distanceMayBeTruncated
            )
        ) else { return nil }
        return Estimate(
            estimatedTRIMP: scaled.trimp, confidence: scaled.confidence,
            routeName: match.savedRoute.name, priorDominant: scaled.priorDominant
        )
    }

    /// The saved route the priors must have run, with what matching needs.
    private struct PriorRoute {
        let savedRoute: SavedRoute
        let sport: Sport
        let store: SavedRouteStore
    }

    /// TRIMP per metre for each prior run of this route — the shape-independent
    /// intensity the estimate extrapolates from.
    private static func priorTRIMPPerMetre(archive: SessionArchive, route: PriorRoute, before workoutStart: Date) -> [Double] {
        priorSessionsOnRoute(archive: archive, route: route, before: workoutStart).compactMap { session in
            trimpPerMetre(
                trimp: session.workoutMetadata?.luciaTRIMP,
                distance: session.workoutMetadata?.distanceMeters
            )
        }
    }

    /// Drops prior ratios under half the median — a run whose strap dropped
    /// without the app noticing (TRIMP ≈ 2) would otherwise drag the average
    /// toward the very dropout this estimator corrects.
    static func withoutOutliers(_ ratios: [Double]) -> [Double] {
        guard ratios.count > 1 else { return ratios }
        let sorted = ratios.sorted()
        let mid = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        return ratios.filter { $0 >= 0.5 * median }
    }

    /// `internal` rather than `private` so the estimation maths can be tested
    /// directly. This decides the estimated training load shown when the
    /// strap dropped mid-workout, and it can become the load that feeds
    /// CTL/ATL (see the type doc).
    static func trimpPerMetre(trimp: Double?, distance: Double?) -> Double? {
        guard let trimp, trimp > 0, let distance, distance > 0 else { return nil }
        return trimp / distance
    }

    /// The distance the estimate represents: the distance actually covered.
    /// The route's full distance stands in when the user appears to have run
    /// the whole loop (within 10 % either way), when no distance was recorded,
    /// or when the recording stopped early (`distanceMayBeTruncated`) and fell
    /// short of the route. A live recording keeps measuring GPS after the
    /// strap drops, so a short distance there is a run cut short or a partial
    /// run of the route, and crediting the whole route would inflate the load
    /// that feeds CTL/ATL. A run past the saved route is credited in full.
    static func targetDistance(
        recordedDistance: Double?,
        savedDistance savedDist: Double,
        distanceMayBeTruncated: Bool = false
    ) -> Double {
        guard let recordedDistance, recordedDistance > 0 else { return savedDist }
        let isWholeLoop = recordedDistance >= savedDist * 0.9
            && recordedDistance <= savedDist * 1.1
        if isWholeLoop { return savedDist }
        if recordedDistance < savedDist, distanceMayBeTruncated { return savedDist }
        return recordedDistance
    }

    /// Whether the recording stopped before the workout did: the app crashed,
    /// or the user saved an interrupted recording as it was.
    static func recordingMayBeTruncated(_ meta: WorkoutMetadata) -> Bool {
        meta.partialDataReason == .appCrashed || meta.partialDataReason == .userInterrupted
    }

    /// Which of the three estimation cases applies, and the number it produces.
    static func scaledEstimate(
        priorAvgRatio: Double?,
        recordedRatio: Double?,
        priorCount: Int,
        targetDistance: Double
    ) -> (trimp: Double, confidence: Double, priorDominant: Bool)? {
        let floor = WorkoutMetadata.routeEstimateNoPriorConfidence
        let priorConfidence = min(0.85, floor + 0.15 * Double(priorCount))
        switch (priorAvgRatio, recordedRatio) {
        case let (.some(prior), .some(today)):
            // Case 2: recorded data exists but is suspiciously low. Blend,
            // biased toward prior (60/40).
            return ((prior * 0.6 + today * 0.4) * targetDistance, priorConfidence, false)
        case let (.some(prior), nil):
            // Case 3a: no usable recorded TRIMP, but we have prior runs of
            // this route. Use the prior average directly.
            return (prior * targetDistance, priorConfidence, true)
        case let (nil, .some(today)):
            // Case 3b: no priors, but some recorded TRIMP. Scale today's ratio
            // to the target distance, at low confidence — we've never run it before.
            return (today * targetDistance, floor, false)
        case (nil, nil):
            // No basis for any estimate.
            return nil
        }
    }

    /// Archived workouts that ran the same saved route before this one. The
    /// archive index rules out later sessions before anything is decoded; the
    /// 150 m start check (either end of the route) is a cheap pre-filter, and the shape match then ties
    /// each prior to THIS route rather than to any run from the same door.
    private static func priorSessionsOnRoute(
        archive: SessionArchive,
        route: PriorRoute,
        before workoutStart: Date
    ) -> [HRVSession] {
        let anchors = endAnchors(of: route.savedRoute)
        guard !anchors.isEmpty else { return [] }
        return archive.entries
            .filter { $0.sessionType == .workout && ($0.endDate ?? $0.date) <= workoutStart }
            .compactMap { archive.retrieveLightweightOrLog($0.sessionId, caller: "RouteTRIMPEstimator") }
            .filter { isCleanPrior($0, sport: route.sport, before: workoutStart) }
            .filter { startsNear(anchors, session: $0) && ranRoute(route, session: $0) }
    }

    /// The saved route's first and last points. A prior can run the route in
    /// either direction (matching is direction-agnostic), so it may start at
    /// either end.
    private static func endAnchors(of savedRoute: SavedRoute) -> [CLLocation] {
        let track = GPXExporter.decode(polyline: savedRoute.encodedPolyline, startDate: savedRoute.createdAt)
        return [track.first, track.last].compactMap { point in
            point.map { CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        }
    }

    /// A prior must be the same sport, have ENDED before the workout being
    /// estimated began (so a backfilled session is never its own prior), and
    /// carry a trustworthy HR load: not a recovered partial, and not a
    /// dropout whose own load was replaced by a route estimate.
    static func isCleanPrior(_ session: HRVSession, sport: Sport, before workoutStart: Date) -> Bool {
        guard let meta = session.workoutMetadata, meta.sport == sport,
              (session.endDate ?? session.startDate) <= workoutStart
        else { return false }
        return meta.partialDataReason == nil && !meta.routeEstimateReplacesHRLoad
    }

    /// Whether the session's first GPS fix sits within 150 m of either end of
    /// the route.
    private static func startsNear(_ anchors: [CLLocation], session: HRVSession) -> Bool {
        guard let first = track(of: session).first else { return false }
        let firstLoc = CLLocation(latitude: first.coordinate.latitude, longitude: first.coordinate.longitude)
        return anchors.contains { firstLoc.distance(from: $0) <= 150 }
    }

    /// Whether the session's whole track is recognised as this saved route.
    private static func ranRoute(_ route: PriorRoute, session: HRVSession) -> Bool {
        RouteLibrary.findMatch(currentTrack: track(of: session), sport: route.sport, store: route.store)?
            .savedRoute.id == route.savedRoute.id
    }

    private static func track(of session: HRVSession) -> [CLLocation] {
        guard let polyline = session.workoutMetadata?.gpsPolyline else { return [] }
        return GPXExporter.decode(polyline: polyline, startDate: session.startDate)
    }
}
