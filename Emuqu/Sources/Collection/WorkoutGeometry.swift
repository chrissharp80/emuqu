import CoreLocation
import Foundation

/// Pure geometry and physiology used while a workout is running.
///
/// Extracted from `WorkoutRecorder`. Every function here is a
/// function of its arguments alone — none of them touches a single member of
/// the recorder, which is why they need no forwarding reference
/// or `unowned` parent.
///
/// That property is the point. Inside a 4,845-line class, nothing
/// tested them: a bearing calculation, a Karvonen zone, a great-circle
/// distance. The defects found during the recorder split
/// were all in exactly this shape of code — small, pure, and unreachable by a
/// test because of the type it happened to live in.
enum WorkoutGeometry {
    /// One kilometre-or-mile chunk of a route: the distance span it covers and
    /// the sample indices bounding it.
    struct SplitChunk {
        let distStart: Double
        let distEnd: Double
        let tStart: Int
        let tEnd: Int
    }

    static func trackLengthMeters(_ track: [CLLocation]) -> Double {
        guard track.count >= 2 else { return 0 }
        var total: Double = 0
        for i in 1 ..< track.count {
            total += track[i].distance(from: track[i - 1])
        }
        return total
    }

    /// Index and distance (m) of the fix in `track` nearest `target`.
    static func nearestFix(in track: [CLLocation], to target: CLLocation) -> (Int, Double) {
        var closestIdx = 0
        var closestDist = Double.infinity
        for (i, fix) in track.enumerated() {
            let d = fix.distance(from: target)
            if d < closestDist {
                closestDist = d
                closestIdx = i
            }
        }
        return (closestIdx, closestDist)
    }

    /// Local pace (sec/km) at `closestIdx`: averaged over ±5 fixes around it
    /// so a single outlier doesn't skew the number. Nil when the span is too
    /// short (under 5 m or 1 s) to carry a pace.
    static func localPace(in track: [CLLocation], at closestIdx: Int) -> Double? {
        let lo = max(0, closestIdx - 5)
        let hi = min(track.count - 1, closestIdx + 5)
        let localStart = track[lo]
        let localEnd = track[hi]
        let localDist = localEnd.distance(from: localStart)
        let localDur = localEnd.timestamp.timeIntervalSince(localStart.timestamp)
        return (localDist > 5 && localDur > 1)
            ? (localDur / (localDist / 1_000.0))
            : nil
    }

    /// Find the index in `dists` whose cumulative distance is at least
    /// `meters` past `dists[startIdx]`. Returns nil at end-of-route.
    static func nextIndex(after startIdx: Int, atDistance meters: Double, in dists: [Double]) -> Int? {
        guard startIdx < dists.count else { return nil }
        let target = dists[startIdx] + meters
        return dists[(startIdx + 1)...].firstIndex(where: { $0 >= target })
    }

    /// Initial bearing from `a` to `b` in degrees (0=N, 90=E).
    /// Standard great-circle formula; cheap for short distances.
    static func bearing(from a: Route.Point, to b: Route.Point) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Signed delta from bearing `a` to `b`, range (-180°, +180°].
    /// Positive = right turn, negative = left turn.
    static func signedBearingDelta(from a: Double, to b: Double) -> Double {
        var d = b - a
        while d > 180 { d -= 360 }
        while d <= -180 { d += 360 }
        return d
    }

    /// Convert a signed bearing delta into a human-readable label the
    /// AI can read back verbatim.
    static func turnLabel(deltaDegrees delta: Double) -> String {
        let abs = Swift.abs(delta)
        let side = delta >= 0 ? "right" : "left"
        if abs >= 150 { return "U-turn" }
        if abs >= 110 { return "hard \(side)" }
        if abs >= 60 { return side }
        return "soft \(side)"
    }

    /// 5-zone Karvonen breakpoints: 50/60/70/80/90 % heart-rate reserve.
    static func karvonenZone(hr: Int?, maxHR: Int, restingHR: Int) -> Int? {
        guard let hr, maxHR > restingHR else { return nil }
        let pct = Double(hr - restingHR) / Double(maxHR - restingHR)
        if pct < 0.50 { return 1 }
        if pct < 0.60 { return 2 }
        if pct < 0.70 { return 3 }
        if pct < 0.80 { return 4 }
        return 5
    }

    /// Drop garbage fixes; require at least 25 m movement OR 30 s
    /// since the last commit (mirror of BreadcrumbRecorder throttle
    /// so the on-disk shape is consistent).
    static func decimatedBreadcrumbFixes(track: [CLLocation], origin: BreadcrumbFix) -> [BreadcrumbFix] {
        guard let first = track.first else { return [] }
        var fixes: [BreadcrumbFix] = [origin]
        var lastCommitted = first
        for loc in track.dropFirst() {
            guard loc.horizontalAccuracy > 0 else { continue }
            let movedFar = loc.distance(from: lastCommitted) >= 25
            let elapsed = loc.timestamp.timeIntervalSince(lastCommitted.timestamp) >= 30
            guard movedFar || elapsed else { continue }
            fixes.append(BreadcrumbFix(from: loc))
            lastCommitted = loc
        }
        return fixes
    }

    static func kilometreChunks(_ samples: [WorkoutSample]) -> [SplitChunk] {
        var chunks: [SplitChunk] = []
        var chunkStartDist = 0.0
        var chunkStartSec = 0
        for s in samples {
            guard let d = s.distanceMeters, d - chunkStartDist >= 1_000 else { continue }
            chunks.append(SplitChunk(distStart: chunkStartDist, distEnd: d, tStart: chunkStartSec, tEnd: s.offsetSec))
            chunkStartDist = d
            chunkStartSec = s.offsetSec
        }
        return chunks
    }

    /// Walk backward through the track until we've covered ~100 m, reporting
    /// where that window starts and how much ground it actually covers. A
    /// track shorter than that is all window, so it starts at the first fix.
    static func trailingGradeWindow(track: [CLLocation]) -> (startIdx: Int, meters: Double) {
        var acc = 0.0
        var startIdx = 0
        for i in (1 ..< track.count).reversed() {
            acc += track[i].distance(from: track[i - 1])
            if acc >= 100.0 {
                startIdx = i - 1
                break
            }
        }
        return (startIdx, acc)
    }
}
