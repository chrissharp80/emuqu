// `@preconcurrency`: CLLocationManager predates Sendable; the compiler asks for this.
@preconcurrency import CoreLocation
import Foundation

// MARK: - AmbientLocationService
//
// Without this, the AI assistant keeps saying "Location is timing out on
// my end" because the `location.current` tool fires a brand-new
// `CLLocationUpdate.liveUpdates()` every call and waits up to 30 s for
// a cold first fix. Meanwhile the phone — the same phone running the
// chat — has known the user's coordinates the whole time.
//
// **Primary case (app backgrounded, workout running).** The user's
// realistic scenario is "phone in pocket, locked, audiobook in
// earbuds, voice chat from a Bluetooth tap". In that scenario the
// workout's `WorkoutLocationManager` is already streaming GPS fixes
// at `BestForNavigation` accuracy under the `location` background
// mode, AND piping them into `AppDependencies.current.location.roadGeocodingService`. The AI's
// location tools just need to READ that cache (instead of triggering
// a fresh fetch). That's what makes the voice query instant — see
// the cache fast-path in `location.current` / `location.current_detailed`
// / `directions.routeTo`.
//
// **Secondary case (foregrounded, no workout).** When the user is in
// the app and asks "where am I" without a workout running, this
// service is the cache-keeper. Low-power CLLocationManager streams
// fixes into the same `RoadGeocodingService` so the tool's cache hit
// path also works outside workouts. Foreground-only to keep iOS happy
// — backgrounded ambient updates without a workout would either get
// throttled by iOS or burn battery for nothing the user can act on.
//
// **Power.** Accuracy is `kCLLocationAccuracyHundredMeters` and the
// distance filter is 50 m — enough to know what street you're on,
// nowhere near the GPS-burn cost of `BestForNavigation`. iOS shares
// the location stream across all managers in the app, so this doesn't
// double-bill against `WorkoutLocationManager` or `BreadcrumbRecorder`
// when those are also active.
//
// **Coexistence.** When a workout is active, both this service AND the
// workout's manager may be running (foreground). Both feed
// `RoadGeocodingService`, which already debounces (25 m / 60 s) so
// duplicate fixes are cheap.
//
// **Why four CLLocationManager instances?** A reasonable question. The
// app currently has:
//   - `WorkoutLocationManager` — `BestForNavigation`, runs during
//      workouts, has the `location` background-mode entitlement.
//   - `BreadcrumbRecorder` — `NearestTenMeters`, runs while Get Me
//      Back is engaged, lower power for long hikes.
//   - `BackgroundLocationManager` — `ThreeKilometers`, low-power
//      keep-alive only; doesn't record fixes anywhere meaningful.
//   - `AmbientLocationService` (this file) — `HundredMeters`,
//      foreground-only, fills the cache when no workout / breadcrumb
//      is providing fixes.
// Each has a different accuracy / power / lifecycle profile that
// can't be cleanly satisfied by a single shared manager — workouts
// need GPS-grade precision, ambient just needs a city-block-level
// fix, breadcrumb sits between. Apple's docs confirm multiple
// `CLLocationManager` instances per app is supported and the
// underlying GPS hardware stream is shared (no extra battery cost
// from "more managers"; the cost is the highest accuracy any of them
// requests). Auth dialogs are also handled per-process, not per-
// manager, so no race there. Consolidation would be a large refactor
// for cosmetic benefit only — explicitly chosen NOT to do it.

final class AmbientLocationService: NSObject, @unchecked Sendable {
    static let shared = AmbientLocationService()

    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var _isRunning = false
    /// Whether some caller has asked for updates since the last `stop()`.
    ///
    /// iOS calls `locationManagerDidChangeAuthorization` when the manager is
    /// created and on every authorization change, and that callback used to
    /// start updates unconditionally — so merely touching this singleton (the
    /// background `stop()` does) began streaming location for a user who had
    /// granted permission somewhere else, with no feature asking for it. The
    /// callback now resumes only a start someone actually requested.
    private var _startRequested = false
    /// Latest fix observed from any source — this manager's own
    /// foreground stream OR a forwarded fix from
    /// `WorkoutLocationManager` / `BreadcrumbRecorder`. Read via the
    /// `cachedLocation()` accessor which applies the freshness
    /// window. Mutated under `lock` so it's safe to read from the
    /// background queues that AI fact actions run on.
    private var _latestLocation: CLLocation?
    /// Thread-safe mirror of `RoadGeocodingService.current`.
    /// The service itself is `@MainActor`, but its resolved-address
    /// output is needed from background contexts (`ContextBuilder`, AI
    /// fact resolvers, telemetry). Pushed here on every successful
    /// `publishContext` so reads stay nonisolated and don't trap on
    /// `MainActor.assumeIsolated` from a Swift Concurrency thread
    /// (a real crash, not a hypothetical).
    private var _latestRoadContext: RoadGeocodingService.RoadContext?
    /// Pending one-shot `currentCoordinate()` waiters, resumed by the
    /// delegate callbacks. Guarded by `lock`.
    private var oneShotContinuations: [CheckedContinuation<CLLocationCoordinate2D?, Never>] = []

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = true
    }

    /// Start streaming, asking for permission first if the user has never
    /// been asked. Call it only from a user action or a screen that explains
    /// why location is needed — the prompt appears over whatever is showing.
    func start() {
        lock.lock()
        _startRequested = true
        lock.unlock()
        guard authorizedOrPrompting() else { return }
        beginUpdates()
    }

    /// Start streaming only if permission is already granted. Never prompts.
    ///
    /// For callers with no user action behind them, such as the app coming to
    /// the foreground: a permission prompt there appears over onboarding or
    /// whatever screen happens to be up, with nothing on it explaining why.
    func startIfAuthorized() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            lock.lock()
            _startRequested = true
            lock.unlock()
            beginUpdates()
        default:
            return
        }
    }

    private func beginUpdates() {
        lock.lock()
        let wasRunning = _isRunning
        _isRunning = true
        lock.unlock()
        guard !wasRunning else { return }
        onMainThread { $0.startUpdatingLocation() }
    }

    /// True when we already hold a usable authorization. When the status is
    /// still `.notDetermined` this fires the prompt and returns false — the
    /// delegate callback at `locationManagerDidChangeAuthorization` resumes the
    /// requested start once the user grants, so we don't chain anything
    /// ourselves.
    private func authorizedOrPrompting() -> Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return true
        case .notDetermined:
            onMainThread { $0.requestWhenInUseAuthorization() }
            return false
        default:
            return false
        }
    }

    /// `CLLocationManager` mutators must be called on the thread it was
    /// created on (main). Run inline when we're already there, hop if not.
    private func onMainThread(_ body: @escaping @Sendable (CLLocationManager) -> Void) {
        if Thread.isMainThread {
            body(manager)
        } else {
            DispatchQueue.main.async { [manager] in body(manager) }
        }
    }

    /// Stop streaming. Called on app background. Doesn't tear down the
    /// manager — restarting via `start()` is cheap.
    func stop() {
        lock.lock()
        let wasRunning = _isRunning
        _isRunning = false
        _startRequested = false
        lock.unlock()
        guard wasRunning else { return }
        if Thread.isMainThread {
            manager.stopUpdatingLocation()
        } else {
            DispatchQueue.main.async { [manager] in
                manager.stopUpdatingLocation()
            }
        }
    }

    /// Cache a fix forwarded from another location stream (the workout or
    /// Get Me Back recorder). Only the raw fix is cached: each of those
    /// owners asks for its own road lookup, and a road-name-only refresh
    /// from here would take the shared geocoder's rate-limit slot ahead of
    /// the workout ticker's cross-street lookup.
    func record(_ location: CLLocation) {
        _ = store(location)
    }

    /// Keep `location` when it is newer than the cached fix. Returns whether
    /// it was kept.
    private func store(_ location: CLLocation) -> Bool {
        guard location.horizontalAccuracy > 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        if let existing = _latestLocation, location.timestamp <= existing.timestamp { return false }
        _latestLocation = location
        return true
    }

    /// Delete All My Data: drop the cached fix and road context so the
    /// assistant cannot answer from them until a new fix arrives.
    func forgetAfterPurge() {
        lock.lock()
        _latestLocation = nil
        _latestRoadContext = nil
        lock.unlock()
    }

    /// Pipe this manager's own fixes through the geocoder too so the
    /// road-context cache stays current alongside the raw CLLocation cache.
    /// The service is @MainActor; hop briefly.
    ///
    /// Ambient (idle-foreground) refresh resolves the road
    /// name only. Skip the cross-street + OSM road-graph enrichment: it
    /// hits a rate-limited overpass-api server that repeatedly times out
    /// in the foreground for no user benefit (cross-street is a workout-
    /// coaching extra). The workout ticker still requests full
    /// enrichment via its own `refreshIfNeeded(...)` default.
    private func refreshRoadContext(for location: CLLocation) {
        Task { @MainActor in
            AppDependencies.current.location.roadGeocodingService.refreshIfNeeded(for: location, enrichCrossStreet: false)
        }
    }

    /// Cached resolved address from `RoadGeocodingService`. AI tools
    /// call this so they don't pay the cold-fetch tax.
    ///
    /// Time-based gate kept as a backstop, but the
    /// PRIMARY validity check is distance-based via
    /// `cachedResolvedAddress(closeTo:maxDistanceMeters:)`. Street
    /// names don't expire with time, they expire when the user moves
    /// past them. Apple's CLGeocoder rate limits (1 req/minute/app)
    /// make distance-based caching not just nicer UX — it's required
    /// to stay under the limit.
    ///
    /// Time-gated form for existing callers. New callers should use the
    /// distance form.
    func cachedResolvedAddress(maxAgeSec: TimeInterval = 30) -> RoadGeocodingService.RoadContext? {
        // Read from the lock-protected mirror, NOT through
        // a `DispatchQueue.main.sync` to `MainActor.assumeIsolated`.
        // That form deadlocks from Swift Concurrency callers
        // ("Potential Structural Swift Concurrency Issue: unsafeForcedSync
        // called from Swift Concurrent context.") and crashed callers
        // that arrived on a non-main-thread cooperative pool worker
        // (EXC_BREAKPOINT in `MainActor.assumeIsolated`). Mirror is
        // updated by `RoadGeocodingService.publishContext` via
        // `recordResolvedAddress` on every successful resolution.
        lock.lock()
        let snapshot = _latestRoadContext
        lock.unlock()
        guard let context = snapshot else { return nil }
        let age = Date().timeIntervalSince(context.observedAt)
        guard age <= maxAgeSec else { return nil }
        return context
    }

    /// Sink for `RoadGeocodingService` to push its latest
    /// resolved-address context. Stored under the same lock as
    /// `_latestLocation` so `cachedResolvedAddress()` is nonisolated and
    /// safe to call from any thread or Swift Concurrency context.
    func recordResolvedAddress(_ context: RoadGeocodingService.RoadContext) {
        lock.lock()
        _latestRoadContext = context
        lock.unlock()
    }

    /// Cached raw CLLocation for tools that want heading / speed /
    /// altitude / accuracy. nil when no fix has been observed yet, OR
    /// when the latest fix is older than `maxAgeSec`.
    func cachedLocation(maxAgeSec: TimeInterval = 60) -> CLLocation? {
        lock.lock()
        let loc = _latestLocation
        lock.unlock()
        guard let loc else { return nil }
        let age = Date().timeIntervalSince(loc.timestamp)
        guard age <= maxAgeSec else { return nil }
        return loc
    }

    func currentCoordinate(timeout: TimeInterval = 6) async -> CLLocationCoordinate2D? {
        if let cached = cachedLocation(maxAgeSec: 6 * 3600) { return cached.coordinate }
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }
        // Make sure updates are flowing (sync method that owns the
        // CLLocationManager on main); the next fix lands in
        // didUpdateLocations, which fans out to every one-shot waiter.
        start()
        return await withCheckedContinuation { (continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>) in
            lock.lock()
            oneShotContinuations.append(continuation)
            let isFirst = oneShotContinuations.count == 1
            lock.unlock()
            guard isFirst else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolveOneShots(with: self?.cachedLocation(maxAgeSec: 6 * 3600)?.coordinate)
            }
        }
    }

    /// Resume every pending one-shot waiter with `coord` (possibly nil).
    func resolveOneShots(with coord: CLLocationCoordinate2D?) {
        lock.lock()
        let waiters = oneShotContinuations
        oneShotContinuations.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: coord) }
    }
}

// MARK: - CLLocationManagerDelegate

extension AmbientLocationService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        // If permission was just granted to a caller that asked for updates,
        // kick them off so the first fix lands without the user having to
        // leave + re-enter the app. Without a pending request, do nothing —
        // see `_startRequested`.
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            lock.lock()
            let requested = _startRequested
            lock.unlock()
            if requested { beginUpdates() }
        } else {
            stop()
        }
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        // Drop garbage fixes outright.
        guard loc.horizontalAccuracy > 0, loc.horizontalAccuracy < 500 else { return }
        let isNewer = store(loc)
        // Satisfy any one-shot `currentCoordinate()` waiters.
        resolveOneShots(with: loc.coordinate)
        // The geocoding service owns rate-limiting (25 m / 60 s); road name
        // only, see `refreshRoadContext`.
        if isNewer { refreshRoadContext(for: loc) }
    }

    func locationManager(_: CLLocationManager, didFailWithError _: Error) {
        // Common during a poor-fix interlude; the AI tools handle
        // "no cached fix yet" gracefully. Don't leave one-shot waiters
        // hanging — resume them with whatever we last had (often nil).
        resolveOneShots(with: cachedLocation(maxAgeSec: 6 * 3600)?.coordinate)
    }
}
