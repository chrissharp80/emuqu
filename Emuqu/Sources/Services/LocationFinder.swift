// `@preconcurrency`: CLLocationManager and CLHeading predate Sendable.
@preconcurrency import CoreLocation
import Foundation

/// On-demand "where am I right now?" location lookup.
///
/// **Why this exists:** the user noticed the AI couldn't
/// answer "what street am I on" outside a workout. The app's
/// `RoadGeocodingService` is fed location updates from
/// `WorkoutLocationManager` — which only runs while a workout is
/// recording. Outside that, `RoadGeocodingService.current` is nil,
/// the `workout.live.location.*` facts return missing, and the AI
/// has no way to look up the user's location at all.
///
/// This service plugs that hole with a single-shot
/// `CLLocationManager.requestLocation()` call → reverse-geocode →
/// returns the same `RoadGeocodingService.RoadContext` that the
/// workout pipeline produces. The AI's new `location.current` fact
/// awaits this when there's no active workout context.
///
/// **Permission posture.** Uses whatever authorization the user
/// already granted (When-In-Use suffices). Does NOT prompt — if the
/// user hasn't authorized, returns `.permissionDenied` so the AI can
/// say "I need location permission, tap Settings to grant."
///
/// **Shared instance.** A single `AppDependencies.current.location.locationFinder` is used
/// process-wide so concurrent requests coalesce instead of spinning
/// up multiple CLLocationManager instances.
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

    @MainActor
    private static func requestAuthorizationOnMainActor() {
        // Apple's docs: CLLocationManager init + requestWhenInUseAuthorization
        // must happen on the main thread. The manager instance is throwaway —
        // iOS coalesces the prompt at the system level so even a
        // short-lived manager triggers the dialog.
        let manager = CLLocationManager()
        manager.requestWhenInUseAuthorization()
        // Hold the reference long enough for the prompt to register.
        _ = manager
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

    /// Routes through AppDependencies.current.location.roadGeocodingService's gated path
    /// instead of spinning up our own CLGeocoder. The singleton enforces
    /// Apple's 1-req/min/app rate limit + retry backoff that an independent
    /// instance would silently violate.
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

    private let manager = CLLocationManager()
    private var pending: [(Result<RoadGeocodingService.RoadContext, LookupError>) -> Void] = []
    private var detailPending: [(Result<DetailedFix, LookupError>) -> Void] = []
    private var lastRawLocation: CLLocation?
    private var timeoutTask: Task<Void, Never>?
    private var currentMode: Accuracy = .quick

    enum Accuracy {
        /// `kCLLocationAccuracyHundredMeters` — fast, low battery, fine
        /// for "what city/street am I on?" queries.
        case quick
        /// `kCLLocationAccuracyBestForNavigation` — sub-meter when GPS
        /// is good (3-5m typical, 10m worst). Higher battery cost.
        /// Use for "exactly where am I, which way am I going, how
        /// fast?" queries.
        case precise
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
        manager.delegate = self
        applyAccuracy(.quick)
    }

    private func applyAccuracy(_ accuracy: Accuracy) {
        currentMode = accuracy
        switch accuracy {
        case .quick:
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        case .precise:
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        }
    }

    /// Coalesces against BOTH queues. Checking only `pending.isEmpty` fires a
    /// SECOND requestLocation() while a detailed lookup (detailPending
    /// non-empty) is still outstanding. The single in-flight fix's delivery
    /// fans out to both `pending` and `detailPending`.
    func currentLocation() async throws -> RoadGeocodingService.RoadContext {
        try checkAuthorization()
        // If a workout is already streaming location and we have a
        // recent geocoded fix, just return it — no need to spin up a
        // new request. "Recent" = within 60s.
        if let cached = AppDependencies.current.location.roadGeocodingService.current,
           Date().timeIntervalSince(cached.observedAt) < 60 {
            return cached
        }
        return try await withCheckedThrowingContinuation { continuation in
            let wasIdle = pending.isEmpty && detailPending.isEmpty
            pending.append(Self.forward(to: continuation))
            if wasIdle { startLookup() }
        }
    }

    /// Permission check. Doesn't prompt except in the never-asked case — use
    /// what's already granted.
    private func checkAuthorization() throws {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            throw LookupError.permissionDenied
        case .notDetermined:
            // Edge case: user hasn't been asked yet. Trigger the prompt
            // so the AI can complete the request once the user accepts.
            manager.requestWhenInUseAuthorization()
            throw LookupError.permissionDenied
        case .authorizedWhenInUse, .authorizedAlways:
            break
        @unknown default:
            throw LookupError.permissionDenied
        }
        guard CLLocationManager.locationServicesEnabled() else {
            throw LookupError.locationServicesDisabled
        }
    }

    /// First caller kicks off the actual lookup and arms the timeout. Both
    /// the plain and detailed queues share the one in-flight fix.
    private func startLookup() {
        manager.requestLocation()
        timeoutTask = Task { [weak self] in
            await sleepQuietly(30_000_000_000, context: "startLookup")
            guard let self, !self.pending.isEmpty || !self.detailPending.isEmpty else { return }
            self.deliverAll(.failure(.timeout))
        }
    }

    func currentDetailedLocation() async throws -> DetailedFix {
        try checkAuthorization()
        applyAccuracy(.precise)
        return try await withCheckedThrowingContinuation { continuation in
            let wasIdle = pending.isEmpty && detailPending.isEmpty
            detailPending.append(Self.forward(to: continuation))
            if wasIdle { startLookup() }
        }
    }

    /// Bridge a queued lookup result onto a continuation.
    private static func forward<T: Sendable>(
        to continuation: CheckedContinuation<T, Error>
    ) -> (Result<T, LookupError>) -> Void {
        { result in
            switch result {
            case let .success(value): continuation.resume(returning: value)
            case let .failure(err): continuation.resume(throwing: err)
            }
        }
    }

    /// Detailed callers also need to be notified — they're waiting on the
    /// same lookup. The road context is mapped up using the cached raw
    /// location for heading/speed/altitude.
    private func deliverAll(_ result: Result<RoadGeocodingService.RoadContext, LookupError>) {
        let snapshot = pending
        pending.removeAll()
        let detailSnapshot = detailPending
        detailPending.removeAll()
        timeoutTask?.cancel()
        timeoutTask = nil
        for callback in snapshot { callback(result) }
        deliverDetailed(result, to: detailSnapshot)
    }

    /// Only on success do we have the underlying CLLocation to map into a
    /// DetailedFix; on failure the same failure is forwarded.
    private func deliverDetailed(
        _ result: Result<RoadGeocodingService.RoadContext, LookupError>,
        to callbacks: [(Result<DetailedFix, LookupError>) -> Void]
    ) {
        let mapped: Result<DetailedFix, LookupError>
        switch result {
        case let .success(road):
            mapped = detailedFix(for: road).map(Result.success) ?? .failure(.noFix)
        case let .failure(err):
            mapped = .failure(err)
        }
        for callback in callbacks { callback(mapped) }
    }

    /// Nil when the raw CLLocation behind the geocode is gone — there is
    /// nothing to build a DetailedFix from.
    private func detailedFix(for road: RoadGeocodingService.RoadContext) -> DetailedFix? {
        guard let raw = lastRawLocation else { return nil }
        return DetailedFix(
            coordinate: raw.coordinate,
            altitudeMeters: raw.verticalAccuracy >= 0 ? raw.altitude : nil,
            horizontalAccuracyMeters: raw.horizontalAccuracy,
            courseDegrees: raw.course >= 0 ? raw.course : nil,
            speedMetersPerSec: raw.speed >= 0 ? raw.speed : nil,
            observedAt: raw.timestamp,
            road: road
        )
    }

    /// Route CLGeocoder through AppDependencies.current.location.roadGeocodingService's
    /// gated queue (Apple 1-req/min/app rate floor). OSM Nominatim stays
    /// parallel since it hits a different server.
    private func geocode(_ location: CLLocation) async {
        async let placemarkAwait = Task { @MainActor in
            await AppDependencies.current.location.roadGeocodingService.reverseGeocodeQueued(location)
        }.value
        async let osmAwait = AppDependencies.current.location.osmNominatimService.reverse(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        let placemark = await placemarkAwait
        let osm = await osmAwait
        guard let placemark else { deliverAll(.failure(.noFix)); return }
        let context = Self.context(from: placemark, osm: osm, at: location)
        // Push into RoadGeocodingService so subsequent reads of
        // `AppDependencies.current.location.roadGeocodingService.current` see this answer too
        // (e.g. workout.live.location.* facts that read off it).
        await Task { @MainActor in
            AppDependencies.current.location.roadGeocodingService.overrideContext(context)
        }.value
        deliverAll(.success(context))
    }

    private static func context(
        from placemark: CLPlacemark, osm: OSMNominatimService.Result?, at location: CLLocation
    ) -> RoadGeocodingService.RoadContext {
        RoadGeocodingService.RoadContext(
            road: placemark.thoroughfare,
            locality: placemark.locality,
            administrativeArea: placemark.administrativeArea,
            country: placemark.country,
            countryCode: placemark.isoCountryCode,
            nearestCrossStreet: nil,
            subLocality: placemark.subLocality,
            subAdministrativeArea: placemark.subAdministrativeArea,
            postalCode: placemark.postalCode,
            timeZoneIdentifier: placemark.timeZone?.identifier,
            areaOfInterest: placemark.areasOfInterest?.first,
            subdivision: osm?.subdivision,
            observedAt: Date(),
            observedAtCoord: location.coordinate
        )
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationFinder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in
            guard let loc = location else {
                self.deliverAll(.failure(.noFix))
                return
            }
            // Stash the raw CLLocation so DetailedFix can read its
            // heading / speed / altitude / accuracy fields.
            self.lastRawLocation = loc
            await self.geocode(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.deliverAll(.failure(.geocodeFailed(error.localizedDescription)))
        }
    }
}
