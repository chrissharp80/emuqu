import CoreLocation
import Foundation

// MARK: - Journey Intelligence Service
//
// Step 1 of the "where am I heading, why, how long" research
// recommendation: infer journey shape + projected
// remaining time from `BreadcrumbStore`'s active trail alone. No new
// permissions, no new APIs, works for the majority of un-routed runs
// and walks the user does.
//
// What we extract from the breadcrumb trail:
//
//   • **Shape**: out-and-back vs loop vs point-to-point. Heuristic:
//     compare crow-fly-from-current-to-origin against total path
//     length, plus check whether the recent fixes are heading toward
//     vs away from the origin.
//
//   • **Projected total time**: when shape == .outAndBack, we assume
//     the return mirrors the outbound. Projected total ≈ 2 × elapsed
//     to current turnaround point. The "turnaround point" is the
//     fix farthest from the origin in path-distance terms.
//
//   • **Direction-of-travel**: heading-toward-origin vs heading-away.
//     Compares the last 60 s of fixes' net displacement against the
//     origin direction. Useful for "you're heading back" inference
//     without needing an engaged route.
//
// Pure analysis — no side effects, no caching. Caller (the AI fact
// resolver for `location.journey`) calls once per tool invocation
// and gets a fresh snapshot. Cost is bounded by `fixes.count`,
// typically < 1500 for a 90-minute walk.
//
// Future tiers (per the research output) layer on top of this:
//   - Tier 2: recurrence classifier over BreadcrumbStore.loadArchive()
//   - Tier 3: EKEventStore tie-in (calendar-inferred destination)
//   - Tier 4: WeatherKit at destination + CLMonitor home-return
// All of those need new permissions or new dependencies; this tier
// needs neither.

enum JourneyIntelligenceService {
    enum Shape: String, Sendable {
        /// We've been out, we've turned around, we're heading back.
        case outAndBackReturning
        /// We're still moving away from the origin; haven't turned yet.
        case outAndBackOutbound
        /// Path length grossly exceeds crow-fly — likely a loop.
        case loop
        /// Net distance ≈ path length AND not close to origin —
        /// probably a one-way journey to somewhere new.
        case pointToPoint
        /// Not enough fixes yet to infer.
        case unknown
    }

    enum Direction: String, Sendable {
        case towardOrigin
        case awayFromOrigin
        case stationary
        case unknown
    }

    /// Snapshot of journey intelligence derivable from the active
    /// breadcrumb trail alone.
    struct Snapshot: Sendable {
        let shape: Shape
        let direction: Direction
        let elapsedSeconds: TimeInterval
        /// Total accumulated path length from origin to current fix.
        let pathLengthMeters: Double
        /// Straight-line distance from current fix to origin. Nil
        /// when origin or current fix is missing.
        let crowFlyToOriginMeters: Double?
        /// Maximum distance from origin reached so far (in
        /// path-distance terms — meters along the trail). Helps
        /// detect "you've turned around" — if `crowFlyToOriginMeters`
        /// is now well under `maxDistanceFromOriginMeters`, the user
        /// is on the return leg.
        let maxDistanceFromOriginMeters: Double
        /// Path-time at which we were farthest from the origin. Used
        /// for projecting return-leg duration in out-and-back shapes.
        let elapsedAtFarthestSeconds: TimeInterval?
        /// Best-effort projected total journey duration. Only set
        /// when shape is `.outAndBackReturning` or
        /// `.outAndBackOutbound`. For loops + point-to-point we
        /// don't have enough info to project without a destination.
        let projectedTotalSeconds: TimeInterval?
        /// Best-effort projected remaining time. Same caveat — only
        /// for out-and-back. Loops and point-to-point return nil.
        let projectedRemainingSeconds: TimeInterval?
        /// Origin label (street name or trailhead) when the
        /// breadcrumb has one cached. Lets the AI say "you're 12 min
        /// from getting back to Cumberland Falls trailhead" rather
        /// than "back to your starting coordinates."
        let originLabel: String?
    }

    static func snapshot(for trail: BreadcrumbTrail) -> Snapshot? {
        guard trail.fixes.count >= 3 else { return nil }
        guard let originFix = trail.origin else { return nil }
        let originLoc = originFix.asCLLocation
        let lastFix = trail.fixes[trail.fixes.count - 1]
        let elapsed = lastFix.timestamp.timeIntervalSince(originFix.timestamp)
        let crowFly = lastFix.asCLLocation.distance(from: originLoc)
        let pathLength = trail.walkedTrailLengthMeters()
        let farthest = farthestPoint(in: trail, from: originFix)
        let direction = inferDirection(trail: trail, originFix: originFix)
        let shape = inferShape(crowFly: crowFly, pathLength: pathLength, maxFromOrigin: farthest.meters, direction: direction)
        let projection = project(shape: shape, elapsed: elapsed, farthest: farthest)
        return Snapshot(
            shape: shape, direction: direction, elapsedSeconds: elapsed,
            pathLengthMeters: pathLength, crowFlyToOriginMeters: crowFly,
            maxDistanceFromOriginMeters: farthest.meters,
            elapsedAtFarthestSeconds: farthest.elapsed > 0 ? farthest.elapsed : nil,
            projectedTotalSeconds: projection.total,
            projectedRemainingSeconds: projection.remaining,
            originLabel: trail.label ?? trail.resolvedOriginLabel
        )
    }

    /// The farthest point from origin in the trail's history (path-distance
    /// order), with both the meters and the time at which it occurred.
    private static func farthestPoint(
        in trail: BreadcrumbTrail, from originFix: BreadcrumbFix
    ) -> (meters: Double, elapsed: TimeInterval) {
        let originLoc = originFix.asCLLocation
        var maxFromOrigin: Double = 0
        var elapsedAtMax: TimeInterval = 0
        for fix in trail.fixes {
            let d = fix.asCLLocation.distance(from: originLoc)
            if d > maxFromOrigin {
                maxFromOrigin = d
                elapsedAtMax = fix.timestamp.timeIntervalSince(originFix.timestamp)
            }
        }
        return (maxFromOrigin, elapsedAtMax)
    }

    /// Out-and-back shapes can project return time as
    /// (time-to-reach-farthest) for the remaining outbound +
    /// (elapsed-at-farthest) mirrored back, modulated by current direction.
    /// This is intentionally simple — Step 1 should produce a USEFUL signal,
    /// not a perfect one.
    ///
    /// Returning: projected total ≈ 2 × elapsed-at-farthest, and remaining is
    /// (projectedTotal − elapsed).
    ///
    /// Outbound: the user will turn around at some point and return. Without
    /// knowing their plan we can only project IF they turn around now, so
    /// `total` is deliberately left nil — the result is just an "if you turned
    /// around now, ~N min back" hint via `remaining`.
    private static func project(
        shape: Shape, elapsed: TimeInterval, farthest: (meters: Double, elapsed: TimeInterval)
    ) -> (total: TimeInterval?, remaining: TimeInterval?) {
        switch shape {
        case .outAndBackReturning:
            guard farthest.meters > 50 else { return (nil, nil) } // moved <50m, useless
            let total = 2 * farthest.elapsed
            return (total, max(0, total - elapsed))
        case .outAndBackOutbound:
            return (nil, elapsed)
        default:
            return (nil, nil)
        }
    }

    // MARK: - Heuristics

    /// Never force-unwrap `trail.fixes.last!`. If the
    /// trail is empty (no fixes captured yet on a fresh recording, or after a
    /// reset), each unwrap crashes. Guarded once at the top; everything below
    /// reads the bound `lastFix` directly.
    private static func inferDirection(
        trail: BreadcrumbTrail,
        originFix: BreadcrumbFix
    ) -> Direction {
        let lookbackSeconds: TimeInterval = 60
        guard let lastFix = trail.fixes.last else { return .unknown }
        let cutoff = lastFix.timestamp.addingTimeInterval(-lookbackSeconds)
        let recent = trail.fixes.filter { $0.timestamp >= cutoff }
        guard let first = recent.first, recent.count >= 2 else { return .unknown }
        let lastLoc = lastFix.asCLLocation
        let firstLoc = first.asCLLocation
        guard lastLoc.distance(from: firstLoc) >= 5 else { return .stationary }
        let netDx = lastLoc.coordinate.longitude - firstLoc.coordinate.longitude
        let netDy = lastLoc.coordinate.latitude - firstLoc.coordinate.latitude
        let originDx = originFix.asCLLocation.coordinate.longitude - lastLoc.coordinate.longitude
        let originDy = originFix.asCLLocation.coordinate.latitude - lastLoc.coordinate.latitude
        // Dot product of (net displacement) · (toward-origin) — sign tells direction.
        return netDx * originDx + netDy * originDy > 0 ? .towardOrigin : .awayFromOrigin
    }

    /// Shape classification:
    /// - `loop`: path length is much greater (>2.5x) than crow-fly
    ///   AND user has been moving away from origin recently. Suggests
    ///   they've taken a meandering path that's not a simple straight
    ///   line out.
    /// - `outAndBackReturning`: max-from-origin > current-from-origin
    ///   by >25%, AND direction is `.towardOrigin`. They turned
    ///   around and are heading back.
    /// - `outAndBackOutbound`: current crow-fly ≈ max-from-origin
    ///   (they're at or near their farthest point), AND direction is
    ///   `.awayFromOrigin` or `.stationary`. They're still going out.
    /// - `pointToPoint`: path length is close to crow-fly (ratio < 1.3)
    ///   AND crow-fly > 200m. They're going somewhere in a roughly
    ///   straight line.
    /// - `unknown`: not enough movement to classify.
    private static func inferShape(
        crowFly: Double,
        pathLength: Double,
        maxFromOrigin: Double,
        direction: Direction
    ) -> Shape {
        guard pathLength > 50 else { return .unknown }
        // Returning to origin?
        if maxFromOrigin > 0,
           crowFly < maxFromOrigin * 0.75,
           direction == .towardOrigin {
            return .outAndBackReturning
        }
        // Loop vs point-to-point: ratio of path to crow-fly.
        let pathToCrowFly = crowFly > 1 ? pathLength / crowFly : Double.infinity
        if pathToCrowFly > 2.5 {
            return .loop
        }
        if pathToCrowFly < 1.3, crowFly > 200 {
            return .pointToPoint
        }
        // Default: outbound on an out-and-back. They're at-or-near
        // the farthest point so far and not heading back.
        return .outAndBackOutbound
    }
}
