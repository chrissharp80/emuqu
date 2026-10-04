import CoreLocation
import Foundation

// MARK: - Recurrence Classifier
//
// Tier 2 of the journey-intelligence stack.
// Looks at the breadcrumb archive — every previously
// completed trail — and tells the AI things like:
//
//   "this is your usual morning route near Cedar Ln —
//    you've done it 6 times, median 47 min."
//
// Tier 1 (`JourneyIntelligenceService`) infers shape + projection
// from the *current* trail alone. Tier 2 adds historical context:
// is this a repeat? How often? How long does it usually take?
// Combined, the AI can give grounded predictions instead of generic
// "I don't know" replies whenever a route isn't engaged.
//
// **Approach** — keep it cheap and good-enough, not perfect:
//
//   1. **Bucket** archived trails by a coarse key:
//        (start coord rounded to 100 m, four-hour band of the day)
//      Two trails share a bucket only if they started near the
//      same place in the same four-hour band, on any day of the
//      week. This already filters most archives down to a handful
//      of candidates per query.
//
//   2. **Signature** each candidate's polyline by resampling its
//      fixes to a fixed length (default 24 evenly-spaced points
//      after path-length reparametrisation). Resampling normalises
//      across pace differences — a fast 25-min loop and a slow
//      45-min loop on the same path produce nearly identical
//      signatures.
//
//   3. **Compare** the current trail's signature to each
//      bucket-mate's signature with a sum-of-paired-distances
//      (mean lat/lon offset → meters). Two signatures match when
//      the average per-point offset is below `matchThresholdMeters`
//      (default 75 m).
//
//   4. **Cluster** when ≥2 historical trails match the current
//      shape. Surface the median duration + path length so the AI
//      can say "you usually finish this in 47 min."
//
// **What we deliberately don't do**:
//   - No DTW. Pair-wise distance on resampled signatures is O(N)
//     and matches the precision a coaching AI actually needs
//     (does the path roughly look the same?). DTW would be
//     O(N×M) per comparison with marginal accuracy gain.
//   - No persistent cluster index. The bucket filter is so cheap
//     (string-key equality) that recomputing on
//     every fact lookup is sub-100 ms even for ~200 archived
//     trails. Adding a cache layer for that is premature.
//   - No cross-bucket fuzzy matching. If the user starts from a
//     slightly different corner of their neighbourhood, that's a
//     different bucket and a fresh classification. False
//     positives on "your usual route" are worse than missing one.

enum RecurrenceClassifier {
    /// What the AI gets back when a recurrence is identified.
    /// Median (not mean) so a single outlier walk doesn't skew the
    /// "you usually take 47 min" estimate.
    struct Match: Sendable {
        /// Human-readable label from the time of day and the origin, e.g.
        /// "morning route near Cedar Ln".
        let label: String
        /// Number of historical trails in the matched cluster.
        let priorOccurrences: Int
        /// Median duration of those historical trails, in seconds.
        let medianDurationSeconds: TimeInterval
        /// Median total path length of those trails, in meters.
        let medianPathLengthMeters: Double
        /// Average per-point offset between the current trail's
        /// signature and the cluster's signatures, in meters. Lower
        /// is a tighter match. Surfaced so the AI can hedge:
        /// 30 m → "looks like" / 70 m → "roughly resembles".
        let averageMatchOffsetMeters: Double
    }

    // MARK: - Tunables

    /// Coarse bucket size for the start-coordinate dimension. Two
    /// trails starting within a ~100 m square share a bucket. Tight
    /// enough to distinguish "from home" vs "from the trailhead a
    /// block away"; loose enough to absorb GPS jitter.
    private static let startCoordRoundingMeters: Double = 100

    /// Number of resampled points in a signature. Higher = more
    /// precise but more compute; 24 keeps O(N) comparisons under
    /// 1 ms each on an A14.
    private static let signatureResolution: Int = 24

    /// Average per-point offset (in meters) below which two
    /// signatures count as the same shape. 75 m is generous enough
    /// to absorb GPS drift + minor route variations (taking a
    /// slightly different sidewalk) without falsely matching
    /// distinct routes.
    private static let matchThresholdMeters: Double = 75

    /// Minimum cluster size to surface a match. Two prior
    /// occurrences = "I've seen this twice"; less than that is
    /// noise.
    private static let minimumClusterSize: Int = 2

    /// Minimum elapsed seconds in the current trail before we'll
    /// attempt a recurrence match. Five minutes is the research
    /// recommendation — gives enough fixes for a stable signature
    /// while still firing early in the journey.
    private static let minimumElapsedSecondsForMatch: TimeInterval = 5 * 60

    // MARK: - Entry point

    /// One archived trail that matched the current one, and how far its
    /// sampled points sat from the current trail's on average.
    private struct ScoredTrail {
        let trail: BreadcrumbTrail
        let offsetMeters: Double
    }

    static func match(
        current: BreadcrumbTrail,
        archive: [BreadcrumbTrail]
    ) -> Match? {
        guard let currentOrigin = current.origin, let currentLast = current.fixes.last else {
            return nil
        }
        let elapsed = currentLast.timestamp.timeIntervalSince(currentOrigin.timestamp)
        guard elapsed >= minimumElapsedSecondsForMatch, current.fixes.count >= 5 else { return nil }
        let candidates = sameBucketCandidates(for: current, in: archive)
        guard candidates.count >= minimumClusterSize else { return nil }
        let currentSignature = signature(for: current)
        guard !currentSignature.isEmpty else { return nil }
        let scored = scoreCandidates(
            candidates, against: currentSignature, walkedMeters: current.walkedTrailLengthMeters()
        )
        guard scored.count >= minimumClusterSize else { return nil }
        return clusterMatch(scored, current: current)
    }

    /// Archived trails that start from the same coarse origin bucket. The
    /// current trail is excluded from its own archive — that shouldn't happen
    /// for an active trail, but be defensive.
    private static func sameBucketCandidates(
        for current: BreadcrumbTrail, in archive: [BreadcrumbTrail]
    ) -> [BreadcrumbTrail] {
        let currentBucket = bucketKey(for: current)
        return archive.filter { trail in
            trail.startedAt != current.startedAt
                && trail.fixes.count >= 5
                && bucketKey(for: trail) == currentBucket
        }
    }

    /// Score every candidate; keep the ones inside the match threshold.
    /// Mid-walk the current trail covers only the start of the route, so
    /// each archived trail is cut at the distance walked so far before it
    /// is resampled — otherwise the current trail's 24 points span the first
    /// tenth of the route while the archived ones span all of it, and the
    /// match only fires near the end of the walk.
    private static func scoreCandidates(
        _ candidates: [BreadcrumbTrail], against currentSignature: [CLLocationCoordinate2D], walkedMeters: Double
    ) -> [ScoredTrail] {
        candidates.compactMap { trail in
            let sig = signature(for: trail, upToMeters: walkedMeters)
            guard sig.count == currentSignature.count else { return nil }
            let offset = averagePerPointDistance(currentSignature, sig)
            guard offset <= matchThresholdMeters else { return nil }
            return ScoredTrail(trail: trail, offsetMeters: offset)
        }
    }

    /// Median stats over the matched cluster.
    private static func clusterMatch(_ scored: [ScoredTrail], current: BreadcrumbTrail) -> Match {
        let durations = scored.compactMap { scoredTrail -> TimeInterval? in
            guard let origin = scoredTrail.trail.origin,
                  let last = scoredTrail.trail.fixes.last
            else { return nil }
            return last.timestamp.timeIntervalSince(origin.timestamp)
        }.sorted()
        let pathLengths = scored.map { $0.trail.walkedTrailLengthMeters() }.sorted()
        let avgOffset = scored.map(\.offsetMeters).reduce(0, +) / Double(scored.count)
        return Match(
            label: describeLabel(
                for: current, originLabel: current.label ?? current.resolvedOriginLabel
            ),
            priorOccurrences: scored.count,
            medianDurationSeconds: median(durations) ?? 0,
            medianPathLengthMeters: median(pathLengths) ?? 0,
            averageMatchOffsetMeters: avgOffset

        )
    }

    // MARK: - Bucket key
    //
    // String key combining rounded start coord + four-hour band.
    // Two trails share a bucket iff their key strings are equal —
    // straightforward Set / Dict semantics, no fuzzy matching.

    static func bucketKey(for trail: BreadcrumbTrail) -> String {
        // No weekday dimension in the key. Users
        // "do the same route every day" — a weekday
        // dimension fragments one logical route into seven
        // buckets, requiring ≥2 prior Mondays / Tuesdays / etc.
        // before any one bucket would fire. Without it
        // a daily walker sees their route classified after their
        // second day rather than their second specific-weekday. Hour
        // band stays — a 6 AM run and an 8 PM walk from the same
        // start ARE different routes (different lighting / traffic /
        // user state) and shouldn't collapse. The label carries no
        // weekday either (see `describeLabel`).
        guard let origin = trail.origin else { return "no-origin" }
        let lat = roundCoord(origin.latitude, toMeters: startCoordRoundingMeters)
        let lon = roundCoord(origin.longitude, toMeters: startCoordRoundingMeters, isLongitude: true, latitudeForCorrection: origin.latitude)
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour], from: trail.startedAt)
        let hourBand = (comps.hour ?? 0) / 4 // 6 four-hour bands
        return "\(lat)|\(lon)|b\(hourBand)"
    }

    /// Round a latitude / longitude value so values within
    /// `meters` of each other round to the same value. For
    /// longitude, the meters-per-degree depends on latitude —
    /// pass `isLongitude: true` to apply the cosine correction.
    /// `internal` so the geo-bucketing can be tested. Two trails land in the
    /// same bucket only if their rounded start coordinates match, so an error
    /// here either splits one recurring route into several or merges two
    /// different ones.
    static func roundCoord(
        _ value: Double,
        toMeters meters: Double,
        isLongitude: Bool = false,
        latitudeForCorrection: Double = 0
    ) -> Double {
        let metersPerDegLat: Double = UnitConstants.metersPerDegreeLatitude
        let metersPerDeg: Double = isLongitude
            ? metersPerDegLat * cos(latitudeForCorrection * .pi / 180)
            : metersPerDegLat
        let stepDegrees = meters / max(1, metersPerDeg)
        return (value / stepDegrees).rounded() * stepDegrees
    }

    // MARK: - Signature
    //
    // Resample the trail's fixes to `signatureResolution` points
    // evenly spaced along the path — or along its first `upToMeters`.
    // Returns an array of CLLocationCoordinate2D. Trails too short to
    // resample produce an empty array (caller skips them).

    private static func signature(
        for trail: BreadcrumbTrail, upToMeters limit: Double = .infinity
    ) -> [CLLocationCoordinate2D] {
        let pts = trail.fixes.map(\.coordinate)
        guard pts.count >= 2 else { return [] }
        let cumulative = cumulativeDistances(along: pts)
        let total = min(cumulative.last ?? 0, limit)
        guard total > 1 else { return [] }
        return resample(pts, cumulative: cumulative, total: total)
    }

    /// Cumulative distance from the first vertex to each vertex, in meters.
    static func cumulativeDistances(along pts: [CLLocationCoordinate2D]) -> [Double] {
        // `1 ..< 0` traps on an empty trail. The neighbouring function guards
        // `pts.count >= 2`, but that guard is not this function's — which is
        // why the empty-range gate stops at the enclosing `func`.
        guard !pts.isEmpty else { return [] }

        var cumulative: [Double] = [0]
        cumulative.reserveCapacity(pts.count)
        for i in 1 ..< pts.count {
            let a = CLLocation(latitude: pts[i - 1].latitude, longitude: pts[i - 1].longitude)
            let b = CLLocation(latitude: pts[i].latitude, longitude: pts[i].longitude)
            cumulative.append(cumulative[i - 1] + a.distance(from: b))
        }
        return cumulative
    }

    /// Walk the cumulative array, interpolating a fixed number of evenly
    /// spaced points so two trails of different sampling density compare
    /// point-for-point.
    private static func resample(
        _ pts: [CLLocationCoordinate2D], cumulative: [Double], total: Double
    ) -> [CLLocationCoordinate2D] {
        let step = total / Double(signatureResolution - 1)
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity(signatureResolution)
        var idx = 0
        for n in 0 ..< signatureResolution {
            let target = Double(n) * step
            while idx < pts.count - 2, cumulative[idx + 1] < target {
                idx += 1
            }
            let segStart = cumulative[idx]
            let span = max(0.001, cumulative[idx + 1] - segStart)
            let alpha = (target - segStart) / span
            out.append(CLLocationCoordinate2D(
                latitude: pts[idx].latitude + alpha * (pts[idx + 1].latitude - pts[idx].latitude),
                longitude: pts[idx].longitude + alpha * (pts[idx + 1].longitude - pts[idx].longitude)
            ))
        }
        return out
    }

    // MARK: - Distance + median helpers

    /// Average distance between paired points across two
    /// equal-length signatures. Meters.
    private static func averagePerPointDistance(
        _ a: [CLLocationCoordinate2D],
        _ b: [CLLocationCoordinate2D]
    ) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var total: Double = 0
        for i in 0 ..< a.count {
            let la = CLLocation(latitude: a[i].latitude, longitude: a[i].longitude)
            let lb = CLLocation(latitude: b[i].latitude, longitude: b[i].longitude)
            total += la.distance(from: lb)
        }
        return total / Double(a.count)
    }

    static func median<T: Comparable & BinaryFloatingPoint>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    // MARK: - Label

    /// Assemble a human-readable label from the trail's start time +
    /// origin label. "morning route near Cedar Ln" — concise enough
    /// for the AI to read aloud verbatim, no false weekday-specificity
    /// (the bucket key does not key on weekday so the cluster can
    /// span any combination of days). The AI gets enough to anchor
    /// "this is your usual" without claiming a Tuesday-specific
    /// pattern that may not exist.
    private static func describeLabel(
        for trail: BreadcrumbTrail,
        originLabel: String?
    ) -> String {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: trail.startedAt)
        let band: String = {
            switch hour {
            case 4 ..< 11: return "morning"
            case 11 ..< 14: return "midday"
            case 14 ..< 18: return "afternoon"
            case 18 ..< 22: return "evening"
            default: return "late-night"
            }
        }()
        let suffix = originLabel.map { " near \($0)" } ?? ""
        return "\(band) route\(suffix)"
    }
}
