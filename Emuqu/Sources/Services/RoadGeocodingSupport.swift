import CoreLocation
import Foundation
import os

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
// `runWithTimeout` races the work against a timer and returns whichever
// finishes first; the loser is cancelled and never awaited. Returns nil on
// timeout or error (the error is logged; the caller falls through to the
// next radius / bails) so we never propagate a timeout error up the chain.
//
// Not a task group: a group waits for every child before it returns, so work
// that ignores cancellation (a continuation whose callback never fires) held
// the caller for as long as it hung, timeout or not.
func runWithTimeout<T: Sendable>(
    seconds: Double,
    operation: @Sendable @escaping () async throws -> T
) async -> T? {
    await withCheckedContinuation { continuation in
        let gate = FirstResultGate(continuation)
        let work = Task { gate.resume(await resultOrNil(operation)) }
        Task {
            await sleepQuietly(UInt64(seconds * 1_000_000_000), context: "runWithTimeout")
            gate.resume(nil)
            work.cancel()
        }
    }
}

private func resultOrNil<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> T? {
    do {
        return try await operation()
    } catch {
        debugLog("[runWithTimeout] operation failed: \(error)")
        return nil
    }
}

/// Resumes a continuation once, with whichever result arrives first; later
/// results are dropped.
final class FirstResultGate<T: Sendable>: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<T?, Never>?>

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    /// True once a result has been delivered.
    var isResolved: Bool {
        continuation.withLock { $0 == nil }
    }

    func resume(_ value: T?) {
        let pending = continuation.withLock { slot -> CheckedContinuation<T?, Never>? in
            defer { slot = nil }
            return slot
        }
        pending?.resume(returning: value)
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
