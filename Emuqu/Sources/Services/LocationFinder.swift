// `@preconcurrency`: CLLocationManager and CLHeading predate Sendable.
@preconcurrency import CoreLocation
import Foundation

/// On-demand "where am I right now?" location lookup.
///
/// **Why this exists:** the app's `RoadGeocodingService` is fed location
/// updates by `WorkoutLocationManager`, which only runs while a workout is
/// recording. Outside that, `RoadGeocodingService.current` can be nil and the
/// AI would have no way to look up the user's location at all.
///
/// This type plugs that hole with static, off-main one-shot lookups: the
/// first usable live fix → reverse-geocode through the shared
/// `RoadGeocodingService` queue → the same `RoadGeocodingService.RoadContext`
/// the workout pipeline produces.
///
/// **Permission posture.** Uses whatever authorization the user already
/// granted (When-In-Use suffices). When the user has never been asked, it
/// shows the system prompt and waits up to 10 s for an answer; a denial
/// returns `.permissionDenied` so the AI can point the user at Settings.
@MainActor
final class LocationFinder: NSObject {
    static let shared = LocationFinder()

    // MARK: - Detached one-shot path (deadlock-free)
    //
    // The synchronous fact-action handler (in `AppFactResolver`) is
    // called on the @MainActor and uses a `DispatchSemaphore.wait` to
    // bridge async → sync. Any path back to @MainActor inside that
    // wait deadlocks: main is blocked, MainActor's queue is frozen,
    // and any `MainActor.run` inside `Task.detached` hangs until the
    // semaphore times out 32 s later — exactly the failure the user
    // saw as "the AI doesn't know my street."
    //
    // The static methods below run entirely off the main actor.
    // `CLLocationUpdate.liveUpdates()` (iOS 17+) is the modern
    // async-sequence API that doesn't require a runloop on the caller.
    // `CLGeocoder.reverseGeocodeLocation(_:)` async has been available
    // since iOS 16. `CLLocationManager.authorizationStatus` and the
    // class-level `locationServicesEnabled()` are documented
    // thread-safe and used here only for status probes — no delegate
    // setup, no requestLocation() that needs a runloop.
    //
    // Result: the fact-action's `Task.detached` can call this method
    // directly without ever hopping back to the (blocked) main actor.

    nonisolated static func detachedCurrentLocation(timeoutSec: TimeInterval = 30) async throws -> RoadGeocodingService.RoadContext {
        try await ensureAuthorization()
        let location = try await firstUsableLocation(timeoutSec: timeoutSec)
        return await reverseGeocode(location)
    }

    /// Public path to a raw one-shot `CLLocation` for callers
    /// that want to feed it into their own geocoding pipeline (e.g. the
    /// app-launch prewarm of `RoadGeocodingService`). Same auth + cold-
    /// GPS handling as `detachedCurrentLocation`; skips the bundled
    /// reverse-geocode so the caller doesn't pay twice.
    nonisolated static func detachedFirstUsableLocation(timeoutSec: TimeInterval = 30) async throws -> CLLocation {
        try await ensureAuthorization()
        return try await firstUsableLocation(timeoutSec: timeoutSec)
    }

    nonisolated static func detachedCurrentDetailedFix(timeoutSec: TimeInterval = 30) async throws -> DetailedFix {
        try await ensureAuthorization()
        let location = try await firstUsableLocation(timeoutSec: timeoutSec)
        let road = await reverseGeocode(location)
        return DetailedFix(
            coordinate: location.coordinate,
            altitudeMeters: location.verticalAccuracy >= 0 ? location.altitude : nil,
            horizontalAccuracyMeters: location.horizontalAccuracy,
            courseDegrees: location.course >= 0 ? location.course : nil,
            speedMetersPerSec: location.speed >= 0 ? location.speed : nil,
            observedAt: location.timestamp,
            road: road
        )
    }

    nonisolated private static func ensureAuthorization() async throws {
        // First read — cheap, thread-safe.
        switch CLLocationManager().authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        case .denied, .restricted:
            throw LookupError.permissionDenied
        case .notDetermined:
            try await promptForAuthorization()
        @unknown default:
            throw LookupError.permissionDenied
        }
        guard CLLocationManager.locationServicesEnabled() else {
            throw LookupError.locationServicesDisabled
        }
    }

    /// Trigger the iOS prompt. The user sees the dialog; we wait up to 10 s
    /// for a response. Allow → proceed. Don't Allow or dismiss →
    /// permissionDenied.
    nonisolated private static func promptForAuthorization() async throws {
        await requestAuthorizationOnMainActor()
        for _ in 0 ..< 40 { // 40 × 250ms = 10s
            await sleepQuietly(250_000_000, context: "promptForAuthorization")
            let status = CLLocationManager().authorizationStatus
            if status == .authorizedWhenInUse || status == .authorizedAlways { break }
            if status == .denied || status == .restricted {
                throw LookupError.permissionDenied
            }
        }
        let finalStatus = CLLocationManager().authorizationStatus
        guard finalStatus == .authorizedWhenInUse || finalStatus == .authorizedAlways else {
            throw LookupError.permissionDenied
        }
    }

    /// The manager that asked for permission. Kept for the life of the
    /// process: releasing the manager that raised the system prompt dismisses
    /// the prompt.
    private static var authorizationManager: CLLocationManager?

    @MainActor
    private static func requestAuthorizationOnMainActor() {
        // Apple's docs: CLLocationManager init + requestWhenInUseAuthorization
        // must happen on the main thread.
        let manager = authorizationManager ?? CLLocationManager()
        authorizationManager = manager
        manager.requestWhenInUseAuthorization()
    }

    /// First-fix latency. The 30 s budget is long enough
    /// that a "took 18 s" cold-start can hide behind "didn't time out, must be
    /// fine." Time-stamping the entry + return makes the actual
    /// fix-acquisition cost visible.
    nonisolated private static func firstUsableLocation(timeoutSec: TimeInterval) async throws -> CLLocation {
        let fixStartedAt = Date()
        let result: CLLocation
        do {
            result = try await raceFirstFix(timeoutSec: timeoutSec)
        } catch {
            debugLog("[GeocodingLatency] firstUsableLocation FAILED in \(String(format: "%.3f", Date().timeIntervalSince(fixStartedAt)))s: \(error)", level: .warning)
            throw error
        }
        debugLog("[GeocodingLatency] firstUsableLocation in \(String(format: "%.3f", Date().timeIntervalSince(fixStartedAt)))s — accuracy=\(String(format: "%.1f", result.horizontalAccuracy))m", level: .info)
        return result
    }

    /// The live-updates stream against a timeout sleeper; first child to
    /// finish wins and the rest are cancelled.
    ///
    /// The richer `authorizationDenied` / `locationUnavailable` diagnostic
    /// flags are iOS 18+. We rely on the pre-flight authorization probe to
    /// catch denial up front; if the user revokes permission mid-stream the
    /// underlying API will either error or stop yielding, hitting our
    /// timeout — adequate without a hot-loop `#available` guard.
    nonisolated private static func raceFirstFix(timeoutSec: TimeInterval) async throws -> CLLocation {
        try await withThrowingTaskGroup(of: CLLocation.self) { group in
            group.addTask { try await firstUsableLiveFix() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                throw LookupError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw LookupError.noFix
            }
            return first
        }
    }

    /// The first live update carrying a valid horizontal accuracy. A negative
    /// accuracy means CoreLocation has no real fix yet, so those are skipped.
    nonisolated private static func firstUsableLiveFix() async throws -> CLLocation {
        for try await update in CLLocationUpdate.liveUpdates() {
            try Task.checkCancellation()
            guard let loc = update.location, loc.horizontalAccuracy >= 0 else { continue }
            return loc
        }
        throw LookupError.noFix
    }

    /// Routes through AppDependencies.current.location.roadGeocodingService's
    /// queued path instead of spinning up our own CLGeocoder, so the call
    /// shares its rate floor, backoff and one-at-a-time rule.
    nonisolated private static func reverseGeocode(_ location: CLLocation) async -> RoadGeocodingService.RoadContext {
        let placemark: CLPlacemark? = await Task { @MainActor in
            await AppDependencies.current.location.roadGeocodingService.reverseGeocodeQueued(location)
        }.value
        return RoadGeocodingService.RoadContext(
            road: placemark?.thoroughfare,
            locality: placemark?.locality,
            administrativeArea: placemark?.administrativeArea,
            country: placemark?.country,
            countryCode: placemark?.isoCountryCode,
            nearestCrossStreet: nil,
            subLocality: placemark?.subLocality,
            subAdministrativeArea: placemark?.subAdministrativeArea,
            postalCode: placemark?.postalCode,
            timeZoneIdentifier: placemark?.timeZone?.identifier,
            areaOfInterest: placemark?.areasOfInterest?.first,
            observedAt: Date(),
            observedAtCoord: location.coordinate
        )
    }

    enum LookupError: Error, Sendable {
        case permissionDenied
        case locationServicesDisabled
        case timeout
        case noFix
        case geocodeFailed(String)
    }

    /// One detailed location fix bundling everything that's available
    /// from a single CLLocation read — coordinates, heading, speed,
    /// altitude (GPS), horizontal accuracy in meters, plus the
    /// reverse-geocoded `RoadContext`.
    ///
    /// Lets the AI reason about not just WHERE the user is but which
    /// direction they're moving, how fast, and whether the GPS fix is
    /// trustworthy enough to act on.
    struct DetailedFix: Sendable {
        let coordinate: CLLocationCoordinate2D
        let altitudeMeters: Double?
        let horizontalAccuracyMeters: Double
        /// Course over ground in degrees (0 = north, 90 = east). nil
        /// when the device isn't moving fast enough for course to be
        /// meaningful (~3 mph threshold from CoreLocation).
        let courseDegrees: Double?
        /// Speed over ground in m/s. nil when the device is stationary.
        let speedMetersPerSec: Double?
        let observedAt: Date
        let road: RoadGeocodingService.RoadContext
    }

    override private init() {
        super.init()
    }
}
