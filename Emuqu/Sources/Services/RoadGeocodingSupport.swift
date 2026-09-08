import CoreLocation
import Foundation

// The wall-clock timeout race and the bearing helper, split out of
// `RoadGeocodingService.swift`. Both are free functions the service
// uses but neither belongs to it — `bearingDegrees` already has its own tests.

// MARK: - Wall-clock timeout for async work
//
// Seen in a real user log: a single `MKLocalSearch.start()`
// hung for 30.7 s on workout start, blocking the AI's "where am I"
// answer for the user's first half-minute in the app. MKLocalSearch
// has no documented hard timeout — Apple's tile service can stall
// indefinitely under load.
//
// `runWithTimeout` races the work future against a sleeping task; the
// loser is cancelled. Returns nil on timeout (caller logs + falls
// through to the next radius / bails) so we never propagate a
// timeout error up the chain.
//
// Pattern matches the existing `LocationFinder` group-race shape; kept
// generic + file-private here so it doesn't grow into a third copy.
enum TimeoutError: Error { case timedOut }

func runWithTimeout<T: Sendable>(
    seconds: Double,
    operation: @Sendable @escaping () async throws -> T
) async -> T? {
    try? await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError.timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TimeoutError.timedOut }
        return first
    }
}

// MARK: - Bearing helper
//
// Initial bearing from one coordinate to another, in degrees clockwise
// from true north (0°). Standard great-circle formula. Used by the
// tile-search ranking so the road parallel to the
// user's heading wins over a perpendicular cross street at intersections.
/// Initial great-circle bearing from `a` to `b`, in degrees clockwise from
/// true north, normalised to `[0, 360)`.
///
/// Internal rather than file-private so it is reachable from tests: it decides
/// which cross-street the assistant names during a workout, and a sign or
/// quadrant error there is silently wrong rather than visibly broken.
func bearingDegrees(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
    let lat1 = a.latitude * .pi / 180
    let lat2 = b.latitude * .pi / 180
    let dLon = (b.longitude - a.longitude) * .pi / 180
    let y = sin(dLon) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
    let radians = atan2(y, x)
    let degrees = radians * 180 / .pi
    return (degrees + 360).truncatingRemainder(dividingBy: 360)
}
