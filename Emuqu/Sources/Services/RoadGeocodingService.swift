// `@preconcurrency` on these imports: CoreLocation, MapKit, CoreBluetooth and
// WatchConnectivity predate Swift concurrency, so their delegate types and
// handler closures are not `Sendable` and every use of them raises a warning
// under `SWIFT_STRICT_CONCURRENCY`. The attribute tells the compiler the module
// is pre-concurrency and suppresses those specific warnings. It is inert at
// runtime and does not weaken checking of OUR types — it only stops Apple's
// un-annotated SDKs from drowning the real diagnostics.
@preconcurrency import CoreLocation
import Foundation
@preconcurrency import MapKit

// MARK: - RoadGeocodingService
//
// Reverse-geocodes the user's current GPS coordinate into human-readable
// road names ("Elm Street") + locality ("Knoxville") + country, so the
// AI coach can say "climb on Elm Street in 0.3 miles" instead of "a
// climb ahead." Closes the geography gap the user raised — the AI has
// raw lat/lon in its context but no notion of road names without this.
//
// Backed by Apple's `CLGeocoder.reverseGeocodeLocation`. Free, on-device
// where possible, and gives us .thoroughfare / .locality / .country
// fields directly. NO third-party API key required.
//
// **Rate limiting**: Apple documents CLGeocoder as rate-limited (~50
// requests/minute, throttled at the device level — not per-app). We
// cache aggressively to stay well under that:
//   • Distance threshold — re-geocode only when the user has moved
//     >50 m since the last successful lookup. Walking 50 m takes ~30 s
//     at a casual pace, so even a brisk-pace user generates <2 lookups/min.
//   • Time threshold — also re-geocode if >2 minutes have passed even
//     without movement (handles the "stopped at a stoplight then turned
//     onto a new road" case).
//   • In-flight de-duplication — one lookup at a time per service.
//   • Hard fail mode — three consecutive failures back the service off
//     for the rest of the workout (Apple's throttle isn't worth burning
//     more requests against).
//
// Failures are silent. The AI gets `currentRoad = nil` and stays quiet
// rather than making up a street name.
@Observable
@MainActor
final class RoadGeocodingService {
    static let shared = RoadGeocodingService()

    var current: RoadContext?
    var lastLookupCoord: CLLocationCoordinate2D?
    var lastLookupAt: Date?
    @ObservationIgnored private var inflightTask: Task<Void, Never>?
    var consecutiveFailures: Int = 0
    /// When we hit `backoffAfterFailures`, we don't permanently disable —
    /// we throttle to one lookup every `recoveryRetrySec` seconds and
    /// keep trying. Real CLGeocoder failures are usually transient
    /// (network blip, rate limit elsewhere on the device) and resolve
    /// within a minute. The previous "permanent backoff for the rest
    /// of the workout" was wrong: if the FIRST lookup failed we'd
    /// never try again, leaving the AI without road context for the
    /// whole walk.
    var backoffStartedAt: Date?
    /// Last road we logged a "no cross-street
    /// candidates" line for, so the steady-state failure (MapKit lacks
    /// cross-street data on this road) doesn't drown the log file.
    var lastNoCrossStreetRoad: String?
    /// Sticky "we're in a tile-data gap" flag — same throttle pattern
    /// as the cross-street miss above so the fallback log doesn't
    /// repeat every minute through a known-blank stretch.
    var tileSearchBlankActive: Bool = false

    /// A tighter threshold (3) let a run of transient blips at workout
    /// start permanently disable geocoding for the rest of the walk.
    /// 8 is forgiving without inviting runaway retry storms.
    private static let backoffAfterFailures = 8
    /// After backoff, try again every 30 seconds. Reset the failure
    /// counter on the next success so a recovered network gets us back
    /// to per-50m cadence.
    private static let recoveryRetrySec: TimeInterval = 30
    /// Movement threshold. The user crosses 15 m often enough that the
    /// road name stays current as they turn corners. Larger values
    /// (25 m, 50 m) produced the user report "Location resolver
    /// is returning stale or incorrect street names": at a fast walk
    /// the user can cross 25 m in ~10 s — and at a corner crossing,
    /// the cached "previous road" still wins long enough for an AI
    /// query to use the wrong name. 15 m at a casual walk is ~10 s,
    /// at a fast walk ~5 s — well below typical chat round-trip.
    /// Apple's per-second rate cap can absorb the extra lookups.
    private static let movementThresholdMeters: Double = 15
    /// Time threshold. 60 s (rather than 120 s) catches the
    /// "stopped at a stoplight then turned onto a new road" case
    /// faster.
    private static let timeThresholdSec: TimeInterval = 60

    let geocoder = CLGeocoder()

    // Apple-spec'd rate limit floor.
    //
    // Per Apple's CLGeocoder documentation + developer forum guidance
    // (https://developer.apple.com/forums/thread/20499):
    //   - max ~1 reverse-geocode request per minute per app
    //   - max 50 concurrent requests across all apps on the device
    //   - over-limit requests fail silently with kCLErrorNetwork
    //
    // The per-cell time + movement gates (60s / 15m) cover the per-cell
    // case, but don't cap aggregate calls on their own. The
    // workout ticker (per-second) + AI tool calls (any time) + observer
    // pipes (per HK delivery) could spike concurrent geocoder pressure
    // beyond Apple's documented limit, producing the silent failures
    // that surfaced as "no street name" mid-walk.
    //
    // `lastGeocoderCallAt` tracks the last call across ALL paths. A
    // hard 1-second floor between calls absorbs request bursts without
    // adding meaningful UX latency.
    var lastGeocoderCallAt: Date?
    private let minSecondsBetweenAnyCalls: TimeInterval = 1.0

    /// Exponential-backoff delay after `kCLErrorNetwork`. Per Apple's
    /// docs, that error specifically signals "rate-limited, back off
    /// and try again later." We grow the floor: 5s → 15s → 60s → 5min
    /// cap, reset on the next success.
    private func backoffDelaySec() -> TimeInterval {
        switch consecutiveFailures {
        case 0: return 0
        case 1: return 5
        case 2: return 15
        case 3: return 60
        default: return 300
        }
    }

    /// Single-funnel CLGeocoder reverse-geocode.
    ///
    /// Every CLGeocoder call in the app goes through here so the
    /// 1s-floor + backoff + in-flight coalescing actually apply across
    /// all paths. Independent `CLGeocoder()` instances per call site
    /// (LocationFinder, resolveRoadName, resolveFresh, geocodeAddress…)
    /// could fire concurrently and trip Apple's 1-req/minute/app limit
    /// silently via `kCLErrorNetwork`.
    ///
    /// Returns nil on rate-limit, timeout, or no-placemark. Caller is
    /// expected to fall back to a cached value gracefully.
    func reverseGeocodeQueued(_ location: CLLocation) async -> CLPlacemark? {
        await respectRateFloor()
        lastGeocoderCallAt = Date()
        // `runWithTimeout` swallows CLGeocoder errors and timeouts,
        // returning nil for both — so there's no throwing path here.
        let placemarks: [CLPlacemark]? = await runWithTimeout(seconds: 5.0) {
            try await self.geocoder.reverseGeocodeLocation(location)
        }
        guard let placemarks else {
            noteFailure(reason: "timeout-or-network")
            return nil
        }
        consecutiveFailures = 0
        backoffStartedAt = nil
        return placemarks.first
    }

    /// Single-funnel forward geocode. Same rationale as
    /// the reverse path. Used by `geocodeAddress` (AI's "set my
    /// address" / "I'm at 1600 Pennsylvania Ave" action) and by
    /// `DirectionsService` for "take me to <X>" routing.
    func forwardGeocodeQueued(_ query: String) async -> [CLPlacemark]? {
        await respectRateFloor()
        lastGeocoderCallAt = Date()
        let placemarks: [CLPlacemark]? = await runWithTimeout(seconds: 5.0) {
            try await self.geocoder.geocodeAddressString(query)
        }
        if placemarks == nil {
            noteFailure(reason: "forward-timeout")
        } else {
            consecutiveFailures = 0
            backoffStartedAt = nil
        }
        return placemarks
    }

    /// Sleep just enough to honor the cross-call floor + active
    /// backoff. Cooperatively cancellable.
    func respectRateFloor() async {
        let floor = max(minSecondsBetweenAnyCalls, backoffDelaySec())
        guard let last = lastGeocoderCallAt else { return }
        let elapsed = Date().timeIntervalSince(last)
        let wait = floor - elapsed
        guard wait > 0 else { return }
        await sleepQuietly(UInt64(wait * 1_000_000_000), context: "respectRateFloor")
    }

    func noteFailure(reason: String) {
        consecutiveFailures += 1
        if consecutiveFailures >= Self.backoffAfterFailures, backoffStartedAt == nil {
            backoffStartedAt = Date()
        }
        debugLog("[RoadGeocoding] geocoder call failed (\(reason)) — consecutiveFailures=\(consecutiveFailures) backoffDelay=\(Int(backoffDelaySec()))s", level: .info)
    }

    /// Primary AI-tool accessor. Returns the cached
    /// `current` ONLY if it's within `maxDistanceMeters` of the
    /// supplied location. Triggers a non-blocking refresh in the
    /// background so the NEXT call sees fresh data. Does NOT block
    /// the caller. Returns nil only when no cache exists at all OR
    /// the cache is from far enough away that quoting it would
    /// surface the wrong street.
    ///
    /// Distance, not age, is the validity axis for the AI's "where am I"
    /// tools: street names age with distance, not seconds.
    func cachedIfCloseTo(_ location: CLLocation, maxDistanceMeters: Double = cachedAddressMaxDistanceMeters) -> RoadContext? {
        // Always kick a refresh in the background — refreshIfNeeded
        // is itself rate-floor + in-flight gated, so back-to-back
        // calls collapse cheaply.
        refreshIfNeeded(for: location)
        guard let context = current else { return nil }
        return context.isValid(at: location, maxDistanceMeters: maxDistanceMeters) ? context : nil
    }

    /// Distance helper for cache-validity checks. Streets typically run
    /// 30-150 m segment-to-intersection; 100 m comfortably covers the
    /// user's current block AND most adjacent blocks (the road name is
    /// almost certainly the same one). A stricter 25 m meant any cache-hit
    /// beyond ten paces from the original fix returned nil and the AI saw
    /// "no road" — even though the fresh fix on disk would have resolved
    /// to the same name.
    ///
    /// 100 m is tight enough that the wrong-block
    /// case (user just crossed an intersection) still misses the cache
    /// and triggers a fresh tile lookup; loose enough that "I'm 60 m
    /// down the same street" is a hit. The per-tick refresh inside
    /// `refreshIfNeeded` (15 m / 60 s) keeps `current` fresh on its
    /// own cadence; this constant only governs when a stale-but-close
    /// cache value is acceptable for an AI tool call.
    ///
    /// `nonisolated` so the value can be used as a default parameter
    /// expression on the @MainActor-isolated `cachedIfCloseTo` method
    /// (default-parameter expressions evaluate in the caller's
    /// isolation context, which can be nonisolated).
    nonisolated static let cachedAddressMaxDistanceMeters: Double = 100

    struct RoadContext: Equatable, Sendable {
        static func == (lhs: RoadContext, rhs: RoadContext) -> Bool {
            lhs.road == rhs.road
                && lhs.locality == rhs.locality
                && lhs.administrativeArea == rhs.administrativeArea
                && lhs.country == rhs.country
                && lhs.countryCode == rhs.countryCode
                && lhs.nearestCrossStreet == rhs.nearestCrossStreet
                && lhs.subLocality == rhs.subLocality
                && lhs.subAdministrativeArea == rhs.subAdministrativeArea
                && lhs.postalCode == rhs.postalCode
                && lhs.timeZoneIdentifier == rhs.timeZoneIdentifier
                && lhs.areaOfInterest == rhs.areaOfInterest
                && lhs.subdivision == rhs.subdivision
                && lhs.observedAt == rhs.observedAt
                && lhs.observedAtCoord.latitude == rhs.observedAtCoord.latitude
                && lhs.observedAtCoord.longitude == rhs.observedAtCoord.longitude
        }

        /// Street/road name where the user currently is ("Elm Street",
        /// "US-441"). nil when the geocoder has no street-level match for
        /// the coordinate (water, wilderness, brand-new road).
        let road: String?
        /// City / town / village name. Almost always populated unless
        /// the user is genuinely in the middle of nowhere.
        let locality: String?
        /// State or province name (US: "Tennessee"; UK: "Greater London").
        let administrativeArea: String?
        /// Country name. Useful for the AI to know whether to default to
        /// imperial vs metric phrasing in spoken output even when the user
        /// hasn't set it explicitly.
        let country: String?
        /// ISO country code ("US", "GB"). For programmatic decisions.
        let countryCode: String?
        /// Name of the closest cross street to the user's
        /// current position, distinct from `road`. Resolved via
        /// `MKLocalSearch` with an `.address` query in a small radius
        /// (~200 m). Lets the AI answer "what's the nearest intersection"
        /// with a real name ("Riverwood Dr & Eastland Ave") instead of
        /// guessing or saying "I don't have that data". Nil when the
        /// search returned nothing nearby (rural areas, parks, water),
        /// or while the lookup hasn't completed yet.
        let nearestCrossStreet: String?
        /// Additional CLPlacemark fields the AI can quote
        /// when the user asks "what neighborhood am I in" / "what's the
        /// zip code here" / "is this in the same time zone as where
        /// I'm going". All optional; populated when the geocoder returns
        /// them, nil when the legacy / fallback lookup paths don't.
        let subLocality: String?
        let subAdministrativeArea: String?
        let postalCode: String?
        let timeZoneIdentifier: String?
        let areaOfInterest: String?
        /// Community-mapped subdivision / neighborhood name
        /// from OSM Nominatim (`neighbourhood` → `residential` → `suburb`
        /// → `hamlet` fallback chain). The user's repeat ask was "what
        /// subdivision am I in?" and Apple's `subLocality` is nil for
        /// most suburban-residential areas. OSM is materially denser
        /// here. When populated, this is the highest-confidence answer
        /// to "where am I" and should be preferred over `subLocality` /
        /// `areaOfInterest` in spoken/UI output. Nil when the OSM
        /// reverse-geocode didn't run (offline / throttled / no cached
        /// hit) or returned without any of those four fields.
        let subdivision: String?
        /// When this context was resolved.
        let observedAt: Date
        /// The coordinate the lookup was performed at. Lets callers tell
        /// "this is for where you are right now" vs "this is from 200 m ago."
        let observedAtCoord: CLLocationCoordinate2D

        init(
            road: String?,
            locality: String?,
            administrativeArea: String?,
            country: String?,
            countryCode: String?,
            nearestCrossStreet: String?,
            subLocality: String? = nil,
            subAdministrativeArea: String? = nil,
            postalCode: String? = nil,
            timeZoneIdentifier: String? = nil,
            areaOfInterest: String? = nil,
            subdivision: String? = nil,
            observedAt: Date,
            observedAtCoord: CLLocationCoordinate2D
        ) {
            self.road = road
            self.locality = locality
            self.administrativeArea = administrativeArea
            self.country = country
            self.countryCode = countryCode
            self.nearestCrossStreet = nearestCrossStreet
            self.subLocality = subLocality
            self.subAdministrativeArea = subAdministrativeArea
            self.postalCode = postalCode
            self.timeZoneIdentifier = timeZoneIdentifier
            self.areaOfInterest = areaOfInterest
            self.subdivision = subdivision
            self.observedAt = observedAt
            self.observedAtCoord = observedAtCoord
        }

        /// Compact one-line address ("Elm Street, Knoxville, TN, US")
        /// suitable for the AI to read back to the user verbatim. Skips
        /// nil components.
        var compactAddress: String {
            let parts = [road, locality, administrativeArea, countryCode]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            return parts.joined(separator: ", ")
        }

        /// "Riverwood Dr & Eastland Ave"-style intersection label,
        /// computed when both the current road AND nearest cross are
        /// known. Returns nil otherwise so the AI doesn't speak a
        /// half-sentence.
        var nearestIntersection: String? {
            guard let road, let cross = nearestCrossStreet,
                  road != cross
            else { return nil }
            return "\(road) & \(cross)"
        }

        /// Distance-based validity check (not a time-based
        /// "maxAgeSec" gate). Street names don't expire with
        /// time, they expire with distance. A 5-minute-old answer is
        /// still correct if the user hasn't moved; a 5-second-old
        /// answer is wrong if the user just crossed an intersection.
        ///
        /// Default 25 m keeps the cache valid as long as the user is
        /// on the same street segment with high confidence.
        func isValid(at location: CLLocation, maxDistanceMeters: Double = 25) -> Bool {
            let origin = CLLocation(
                latitude: observedAtCoord.latitude,
                longitude: observedAtCoord.longitude
            )
            return origin.distance(from: location) <= maxDistanceMeters
        }
    }

    func refreshIfNeeded(for location: CLLocation?, enrichCrossStreet: Bool = true) {
        guard let loc = location, inflightTask == nil, !inRecoveryBackoff() else { return }
        guard movedFar(from: loc) || agedOut() else { return }
        startLookupIfIdle(at: loc, enrichCrossStreet: enrichCrossStreet)
    }

    /// Recovery-mode backoff. After `backoffAfterFailures` consecutive
    /// failures, we don't give up — we throttle to one lookup every
    /// `recoveryRetrySec` seconds. The previous "permanent backoff for the
    /// workout" left the AI without road context for the whole walk if the
    /// first 3 lookups happened to fail.
    ///
    /// When the recovery-retry window is open this returns false (attempt one
    /// more lookup) and restamps the window. The failure counter is NOT reset
    /// until a lookup actually succeeds.
    private func inRecoveryBackoff() -> Bool {
        guard consecutiveFailures >= Self.backoffAfterFailures else { return false }
        if let started = backoffStartedAt,
           Date().timeIntervalSince(started) < Self.recoveryRetrySec {
            return true
        }
        backoffStartedAt = Date()
        return false
    }

    /// Movement gate.
    private func movedFar(from loc: CLLocation) -> Bool {
        guard let prev = lastLookupCoord else { return true }
        let prevLoc = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
        return prevLoc.distance(from: loc) >= Self.movementThresholdMeters
    }

    /// Time gate (catches "turned a corner without moving the threshold").
    private func agedOut() -> Bool {
        guard let last = lastLookupAt else { return true }
        return Date().timeIntervalSince(last) >= Self.timeThresholdSec
    }

    /// Prewarm at app launch.
    ///
    /// Without it, the geocoding pipeline (tile search + CLGeocoder
    /// fallback + cross-street search) kicks off on the FIRST GPS fix
    /// delivered to the workout ticker, and the 5 s tile timeout + 5 s
    /// geocoder timeout + 4 cross-street MKLocalSearch round trips mean
    /// the AI's road context takes 10–20 s to materialise — the app
    /// feels stuck after tapping Start. The user's read on this is:
    /// "this should be done when the app loads, not when I tap Start."
    ///
    /// This method takes a one-shot location (from `CLLocationManager
    /// .requestLocation()` at launch) and runs the same pipeline so
    /// `current` is populated before the user gets near the Start
    /// button. The per-tick `refreshIfNeeded` in the workout ticker
    /// then no-ops until the user has moved >15 m or 60 s have passed
    /// — which is correct, because we already have a fresh cache.
    ///
    /// Safe to call multiple times: shares the same `inflightTask`
    /// guard as `refreshIfNeeded`, so concurrent calls collapse.
    /// Treat as a normal lookup — populate `current`, `lastLookupAt`,
    /// `lastLookupCoord` so the next workout tick's refresh sees a
    /// fresh cache.
    ///
    /// Skip the cross-street + OSM-subdivision enrichment
    /// during prewarm. The overpass-api fetch (RoadGraphService) hits
    /// an external server that's both rate-limited and occasionally
    /// unreachable — beta tester log showed a 60 s NSURLErrorTimedOut
    /// happening DURING the launch window, queueing up against
    /// dashboard rendering, training-cache refresh, iCloud sync, and
    /// archive migrations all firing in the same 10 s. Cross-street
    /// is enrichment, not a core "where am I" need; computing it on
    /// first AI interaction or first workout tick is fast enough that
    /// the user never notices, and keeps the launch path off the
    /// cooperative pool.
    func prewarm(at location: CLLocation) {
        startLookupIfIdle(at: location, enrichCrossStreet: false)
    }

    /// Wait up to `maxWaitSec` for a fresh geocode, kicking off a lookup when
    /// none is already in flight.
    ///
    /// If the deadline passes we return whatever's there even if older — a
    /// stale street name is more useful to the user than nothing at all.
    func awaitFreshContext(for location: CLLocation, maxWaitSec: TimeInterval = 2.5) async -> RoadContext? {
        if let context = freshContext() { return context }
        startLookupIfIdle(at: location, enrichCrossStreet: true)
        let deadline = Date().addingTimeInterval(maxWaitSec)
        while Date() < deadline {
            if let context = freshContext() { return context }
            await sleepQuietly(100_000_000, context: "awaitFreshContext") // 100 ms poll
        }
        return current
    }

    /// One lookup at a time: concurrent callers collapse onto `inflightTask`,
    /// which clears itself when the lookup finishes.
    private func startLookupIfIdle(at location: CLLocation, enrichCrossStreet: Bool) {
        guard inflightTask == nil else { return }
        let target = location
        inflightTask = Task { [weak self] in
            defer { self?.clearInflightTask() }
            await self?.performLookup(at: target, enrichCrossStreet: enrichCrossStreet)
        }
    }

    /// Hops back to the main actor to release the in-flight slot; `defer` can't
    /// await, so the clear is queued rather than performed inline.
    nonisolated private func clearInflightTask() {
        Task { @MainActor in self.inflightTask = nil }
    }

    /// `current`, but only when it was observed inside the 5-minute freshness
    /// window `awaitFreshContext` is willing to hand back without a refetch.
    private func freshContext() -> RoadContext? {
        let freshWindow: TimeInterval = 300
        guard let context = current,
              Date().timeIntervalSince(context.observedAt) <= freshWindow else { return nil }
        return context
    }

    /// Reset between workouts so the next session starts with a clean
    /// failure counter.
    ///
    /// Deliberately keeps `current` / `lastLookupCoord` / `lastLookupAt`.
    /// Wiping them would throw away the app-launch prewarm (and any
    /// cache from a workout that just ended a few seconds ago),
    /// forcing the first GPS fix of the new workout to pay the full
    /// 10–20 s geocoding pipeline cost again. Stale cache isn't a
    /// problem in practice: the time-gate (>60 s) and movement-gate
    /// (>15 m) inside `refreshIfNeeded` already cause a refresh when
    /// the cached context is out-of-date. So only the failure state
    /// is reset.
    func reset() {
        inflightTask?.cancel()
        inflightTask = nil
        consecutiveFailures = 0
        backoffStartedAt = nil
    }

    // MARK: - One-shot lookups (route through the shared queued
    // geocoder so they participate in the 1-req/min/app rate floor)

    /// One-shot reverse geocode of a coordinate, returning just the
    /// thoroughfare string. Used by SavedRoute climb-naming.
    /// Goes through `reverseGeocodeQueued` so each call participates
    /// in the rate floor / backoff state.
    static func resolveRoadName(at coord: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return await Task { @MainActor in
            await AppDependencies.current.location.roadGeocodingService.reverseGeocodeQueued(location)?.thoroughfare
        }.value
    }

    /// Forward-geocode a free-text address into a `RoadContext`. Used
    /// by the AI's `location.set_address` + `directions.routeTo`
    /// actions. Goes through `forwardGeocodeQueued`.
    static func geocodeAddress(_ query: String) async -> RoadContext? {
        let placemarksOpt = await Task { @MainActor in
            await AppDependencies.current.location.roadGeocodingService.forwardGeocodeQueued(query)
        }.value
        guard let placemarks = placemarksOpt,
              let p = placemarks.first,
              let loc = p.location
        else { return nil }
        // nearestCrossStreet is nil: not computed for forward-geocode overrides.
        return RoadContext(
            road: p.thoroughfare, locality: p.locality ?? p.subLocality,
            administrativeArea: p.administrativeArea, country: p.country,
            countryCode: p.isoCountryCode, nearestCrossStreet: nil,
            subLocality: p.subLocality, subAdministrativeArea: p.subAdministrativeArea,
            postalCode: p.postalCode, timeZoneIdentifier: p.timeZone?.identifier,
            areaOfInterest: p.areasOfInterest?.first,
            observedAt: Date(), observedAtCoord: loc.coordinate
        )
    }

    /// Override the ambient road context with a user-supplied one.
    /// Called by the AI's `location.set_address` action when the user
    /// tells the AI where they are (because GPS-driven reverse
    /// geocoding is failing). Updates `current` so all downstream
    /// reads (live snapshot, AI facts) see the user-asserted address
    /// until the next ambient lookup overrides it. Safe to call from
    /// any async context.
    func overrideContext(_ context: RoadContext) {
        current = context
        AppDependencies.current.location.ambientLocationService.recordResolvedAddress(context)
        lastLookupCoord = context.observedAtCoord
        lastLookupAt = context.observedAt
        consecutiveFailures = 0
        backoffStartedAt = nil
    }
}
