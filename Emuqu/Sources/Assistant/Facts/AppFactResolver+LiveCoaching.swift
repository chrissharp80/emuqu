import CoreLocation
import Foundation

// The live-coaching namespace: the workout's reverse-geocoded location and
// the location.current / location.situation actions. Thresholds, intervals,
// HRR, journey, roads-ahead and directions are in
// `AppFactResolver+LiveNavigation.swift`.
//
// Lives in a separate namespace from `WorkoutLiveNamespace` so the
// existing one stays focused on per-tick sensor metrics and these
// stay focused on coaching state. Both have `namespace = "workout"`
// and their entries merge naturally in the registry's first-token
// dispatch.
struct WorkoutLiveCoachingNamespace: FactNamespaceResolver {
    let namespace = "workout"

    func snapshot() -> AssistantContext.LiveWorkoutSnapshot? {
        MainActor.assumeIsolated { AppDependencies.current.assistant.liveWorkoutBroker.currentSnapshot() }
    }

    /// Privacy: the `location.*` action family
    /// (current / current_detailed / situation / roads_ahead) must not
    /// hand raw lat/lon + street address to a consented cloud LLM at
    /// ANY time; the consent sheet names your position during a workout,
    /// not a live fix whenever the model asks for one. This gate mirrors
    /// the static-context rule (AssistantContext: `liveWorkout != nil`
    /// before `ambientLocation` is included): precise location is only
    /// released to the model while a workout is actively recording.
    /// When no workout is active, the action returns a structured
    /// `notRecorded` instead of coordinates, so the assistant can say
    /// "I only have your location during a workout" rather than leaking
    /// a fix. The on-device `workout.live.location.*` reads already gate
    /// on the same snapshot.
    func workoutActive() -> Bool {
        snapshot() != nil
    }

    /// Standard "no precise location outside a workout" envelope so the
    /// gated location.* actions all refuse identically.
    func locationGatedOffMessage() -> FactValue {
        .missing(
            reason: .notRecorded,
            detail: """
            your current coordinates and street address are only shared during an active workout. No workout is running, so I can't share them right now. \
            Start a workout if you want location-aware coaching.
            """
        )
    }

    /// Convert a heading in degrees (0=N, 90=E, 180=S, 270=W) to a
    /// 16-point compass label ("N", "NNE", "NE", etc.). Used by the
    /// `location.current_detailed` action so the AI can read back
    /// "you're heading northwest" without doing the math itself.
    static func compassDirection(degrees: Double) -> String {
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        let labels = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((normalized / 22.5).rounded()) % 16
        return labels[index]
    }

    var entries: [FactEntry] {
        coachingEntries + navigationEntries
    }

    /// The workout's reverse-geocoded location and the location actions. The
    /// thresholds, intervals, HRR and navigation facts are in
    /// `AppFactResolver+LiveNavigation.swift`.
    private var coachingEntries: [FactEntry] {
        [
            locationFieldEntries,
            [locationCurrentEntry, locationSituationEntry]
        ]
        .flatMap { $0 }
    }

    // ── Location (reverse-geocoded street + locality) ─────────
    // Street, town, region and country for the live workout position, so
    // the assistant can say "you're on Elm Street" instead of reading
    // lat/lon at the user. Workout-only, like every precise-location read.
    private var locationFieldEntries: [FactEntry] {
        [
            workoutLiveLocationRoadEntry,
            workoutLiveLocationLocalityEntry,
            locationAdminAreaEntry,
            workoutLiveLocationCountryCodeEntry,
            workoutLiveLocationCompactAddressEntry
        ]
    }

    private var workoutLiveLocationRoadEntry: FactEntry {
        .fixed(
            key: "workout.live.location.road",
            description: """
            Reverse-geocoded street/road name where the user currently is ('Elm Street', 'US-441'). Refreshed every ~30 s during the workout (or every ~50 m of movement). Use this in spoken output instead of raw lat/lon. Returns missing \
            when the geocoder hasn't responded yet, when the user is somewhere CLGeocoder doesn't recognise (water, wilderness), or when the workout is indoor.
            """,
            valueType: "String"
        ) {
            guard let s = self.snapshot() else {
                return .missing(reason: .notRecorded, detail: "no live workout")
            }
            return .from(s.currentRoadName, detail: "geocoder hasn't returned yet (or no street match for this coordinate)")
        }
    }

    private var workoutLiveLocationLocalityEntry: FactEntry {
        .fixed(
            key: "workout.live.location.locality",
            description: "City / town / village name for the user's current GPS coordinate.",
            valueType: "String"
        ) {
            guard let s = self.snapshot() else {
                return .missing(reason: .notRecorded, detail: "no live workout")
            }
            return .from(s.currentLocality, detail: "geocoder hasn't returned yet")
        }
    }

    private var locationAdminAreaEntry: FactEntry {
        .fixed(
            key: "workout.live.location.administrative_area",
            description: "State / province name for the user's current location ('Illinois', 'Greater London'). Useful for region-aware suggestions.",
            valueType: "String"
        ) {
            guard let s = self.snapshot() else {
                return .missing(reason: .notRecorded, detail: "no live workout")
            }
            return .from(s.currentAdministrativeArea, detail: "geocoder hasn't returned yet")
        }
    }

    private var workoutLiveLocationCountryCodeEntry: FactEntry {
        .fixed(
            key: "workout.live.location.country_code",
            description: "ISO country code for the user's current location ('US', 'GB'). Useful for choosing units/idioms when speaking even when the user hasn't explicitly set a units preference.",
            valueType: "String"
        ) {
            guard let s = self.snapshot() else {
                return .missing(reason: .notRecorded, detail: "no live workout")
            }
            return .from(s.currentCountryCode, detail: "geocoder hasn't returned yet")
        }
    }

    private var workoutLiveLocationCompactAddressEntry: FactEntry {
        .fixed(
            key: "workout.live.location.compact_address",
            description: "One-line human-readable address ('Elm Street, Springfield, IL, US') ready to read back to the user verbatim. Skips nil components. Returns missing if no road context resolved yet.",
            valueType: "String"
        ) {
            guard let s = self.snapshot() else {
                return .missing(reason: .notRecorded, detail: "no live workout")
            }
            return .from(s.currentCompactAddress, detail: "geocoder hasn't returned yet")
        }
    }

    // The cached address bundle, released only during a workout.
    private var locationCurrentEntry: FactEntry {
        .action(
            key: "location.current",
            description: Self.locationCurrentDescription,
            parameters: []
        ) { _ in self.resolveLocationCurrent() }
    }

    // Privacy: precise location only during an active workout (see
    // `workoutActive()`); otherwise refuse rather than leak coordinates.
    private func resolveLocationCurrent() -> FactValue {
        guard self.workoutActive() else { return self.locationGatedOffMessage() }
        // AmbientLocationService keeps the cache warm while the app is in the
        // foreground and a workout pushes fixes too, so this only reads: no
        // cold fetch, no permission prompt.
        guard let cached = AppDependencies.current.location.ambientLocationService.cachedResolvedAddress(maxAgeSec: 300) else {
            return .missing(
                reason: .notRecorded,
                detail: "location cache not warm yet — the app populates it automatically on foreground; ask the user to open Emuqu for a moment, then ask again"
            )
        }
        return .record(cachedAddressRecord(cached))
    }

    private func cachedAddressRecord(_ cached: RoadGeocodingService.RoadContext) -> [String: FactValue] {
        let lat = cached.observedAtCoord.latitude
        let lon = cached.observedAtCoord.longitude
        var rec: [String: FactValue] = ["status": .string("resolved")]
        rec.merge(addressFields(cached)) { _, new in new }
        rec.merge(mapLinkFields(lat: lat, lon: lon)) { _, new in new }
        rec["age_seconds"] = .double(Date().timeIntervalSince(cached.observedAt))
        rec["source"] = .string("cached")
        return rec
    }

    private func mapLinkFields(lat: Double, lon: Double) -> [String: FactValue] {
        // Coordinates plus tap-to-open map links, built from the coordinates
        // with no network call.
        [
            "lat": .double(lat),
            "lon": .double(lon),
            "apple_maps_url": .string("https://maps.apple.com/?ll=\(lat),\(lon)"),
            "google_maps_url": .string("https://www.google.com/maps/search/?api=1&query=\(lat),\(lon)"),
            "lat_lon_string": .string(String(format: "%.5f,%.5f", lat, lon))
        ]
    }

    private static let locationCurrentDescription = """
    [ACTION] Get the user's current location bundle in ONE call. Returns: road / locality / \
    sub_locality (Apple's neighborhood field, often nil in suburban areas) / administrative_area (state) / country / country_code / postal_code \
    / area_of_interest (named landmark like 'Lakeside Park' when applicable) / nearest_cross_street / nearest_intersection ('Maple Ave & Oak St' style) / compact_address / lat / lon / lat_lon_string / apple_maps_url \
    / google_maps_url / age_seconds. PRIVACY: precise location is only released while a workout is actively recording. When no workout is running this returns notRecorded \
    — tell the user you can only share location during a workout, don't guess coordinates. No permission probing, no GPS spin-up, no waiting; during a workout, if there's a cached fix it returns instantly.
    """

    private var locationSituationEntry: FactEntry {
        .actionAsync(
            key: "location.situation",
            description: Self.locationSituationDescription,
            parameters: []
        ) { _ in await self.resolveLocationSituation() }
    }

    // Privacy: precise location only during an active workout, checked
    // before reading any fix or running the POI search.
    @MainActor private func resolveLocationSituation() async -> FactValue {
        guard self.workoutActive() else { return self.locationGatedOffMessage() }
        // The freshest cached fix; the address bundle and the POI search
        // both anchor on its coordinate. Already on the MainActor here.
        let cached = AppDependencies.current.location.ambientLocationService.cachedLocation(maxAgeSec: 60)
        guard let cached else {
            return .missing(reason: .notRecorded, detail: "no current location fix in the last 60 s — open the app foreground or start a workout to warm the GPS pipeline")
        }
        let search = await nearbyPOIs(cached.coordinate)
        var rec = situationFixFields(cached)
        addAddressFields(&rec, resolved: roadContext(near: cached))
        rec["nearby_pois"] = .record(poiFields(search.pois))
        rec["empty_categories"] = .list(emptyPOICategories(search).map { .string($0) })
        rec["failed_categories"] = .list(search.failedCategories.map { .string($0.rawValue) })
        addActiveRouteField(&rec, at: cached)
        addJourneyField(&rec)
        rec["observed_age_seconds"] = .integer(Int(Date().timeIntervalSince(cached.timestamp)))
        return .record(rec)
    }

    // Distance-validated cache read, with no per-call geocoder round trip:
    // nil (address_status "pending") when the cached address was resolved
    // too far from this fix. See workout.live.location_bundle.
    @MainActor private func roadContext(near cached: CLLocation) -> RoadGeocodingService.RoadContext? {
        AppDependencies.current.location.roadGeocodingService.cachedIfCloseTo(cached)
    }

    // A suspending timeout race with a 3 s budget. A timeout means no
    // category was searched, so every category is reported as failed rather
    // than empty. This resolver runs on the MainActor, so it must suspend,
    // never block: a blocked main thread would starve the search and risk
    // the watchdog.
    @MainActor private func nearbyPOIs(_ coord: CLLocationCoordinate2D) async -> SurroundingsPOIService.SearchResult {
        await FactResolveTimeout.withTimeout(seconds: 3) {
            await AppDependencies.current.location.surroundingsPOIService.searchWithStatus(
                near: coord,
                radiusMeters: 500,
                topPerCategory: 3
            )
        } ?? SurroundingsPOIService.SearchResult(pois: [], failedCategories: SurroundingsPOIService.Category.allCases)
    }

    private func situationFixFields(_ cached: CLLocation) -> [String: FactValue] {
        var rec: [String: FactValue] = [
            "lat": .double(cached.coordinate.latitude),
            "lon": .double(cached.coordinate.longitude),
            "horizontal_accuracy_m": .double(cached.horizontalAccuracy),
            "altitude_m": .double(cached.altitude)
        ]
        if cached.course >= 0 {
            rec["heading_degrees"] = .double(cached.course)
            rec["heading_compass"] = .string(WorkoutLiveCoachingNamespace.compassDirection(degrees: cached.course))
        }
        if cached.speed >= 0 {
            rec["speed_mps"] = .double(cached.speed)
            rec["speed_mph"] = .double(cached.speed * UnitConstants.mphPerMetersPerSecond)
            rec["speed_kmh"] = .double(cached.speed * 3.6)
        }
        return rec
    }

    private func addAddressFields(_ rec: inout [String: FactValue], resolved: RoadGeocodingService.RoadContext?) {
        if let resolved {
            rec.merge(addressFields(resolved)) { _, new in new }
        }
        // Same address_status values as workout.live.location_bundle.
        rec["address_status"] = .string(addressStatus(resolved))
    }

    private func addressFields(_ resolved: RoadGeocodingService.RoadContext) -> [String: FactValue] {
        var rec: [String: FactValue] = [:]
        rec["road"] = .from(resolved.road)
        rec["locality"] = .from(resolved.locality)
        rec["sub_locality"] = .from(resolved.subLocality)
        rec["administrative_area"] = .from(resolved.administrativeArea)
        rec["country"] = .from(resolved.country)
        rec["country_code"] = .from(resolved.countryCode)
        rec["postal_code"] = .from(resolved.postalCode)
        rec["compact_address"] = .string(resolved.compactAddress)
        rec["nearest_cross_street"] = .from(resolved.nearestCrossStreet)
        rec["nearest_intersection"] = .from(resolved.nearestIntersection)
        rec["area_of_interest"] = .from(resolved.areaOfInterest)
        return rec
    }

    private func addressStatus(_ resolved: RoadGeocodingService.RoadContext?) -> String {
        let hasStreet = (resolved?.road?.isEmpty == false)
        let hasCross = (resolved?.nearestCrossStreet?.isEmpty == false)
        if resolved == nil { return "pending" }
        if hasStreet && hasCross { return "ready" }
        if hasStreet { return "partial_no_cross_street" }
        return "pending"
    }

    // POI bundle, grouped by category.
    private func poiFields(_ pois: [SurroundingsPOIService.POI]) -> [String: FactValue] {
        var poiRec: [String: FactValue] = [:]
        for (category, entries) in groupedPOIs(pois) where !entries.isEmpty {
            poiRec[category.rawValue] = .list(entries.map { poiRecord($0) })
        }
        return poiRec
    }

    private func poiRecord(_ poi: SurroundingsPOIService.POI) -> FactValue {
        .record([
            "name": .string(poi.name),
            "distance_meters": .double(poi.distanceMeters),
            "lat": .double(poi.latitude),
            "lon": .double(poi.longitude)
        ])
    }

    private func groupedPOIs(
        _ pois: [SurroundingsPOIService.POI]
    ) -> [SurroundingsPOIService.Category: [SurroundingsPOIService.POI]] {
        var byCategory: [SurroundingsPOIService.Category: [SurroundingsPOIService.POI]] = [:]
        for poi in pois {
            byCategory[poi.category, default: []].append(poi)
        }
        return byCategory
    }

    // Categories searched with nothing found. A category whose lookup
    // failed is unknown, so it is left out here and listed under
    // `failed_categories` instead.
    private func emptyPOICategories(_ search: SurroundingsPOIService.SearchResult) -> [String] {
        let byCategory = groupedPOIs(search.pois)
        return SurroundingsPOIService.Category.allCases
            .filter { (byCategory[$0] ?? []).isEmpty && !search.failedCategories.contains($0) }
            .map(\.rawValue)
    }

    @MainActor private func addActiveRouteField(_ rec: inout [String: FactValue], at cached: CLLocation) {
        guard AppDependencies.current.location.activeRouteSession.snapshot() != nil,
              let route = AppDependencies.current.location.activeRouteSession.currentStep(for: cached)
        else { return }
        rec["active_route"] = .record([
            "destination_label": .string(route.destinationLabel),
            "current_instruction": .string(route.currentInstruction),
            "upcoming_instruction": .string(route.upcomingInstruction),
            "distance_to_upcoming_step_meters": .double(route.distanceToUpcomingStepMeters),
            "remaining_distance_meters": .double(route.remainingDistanceMeters),
            "arrived": .boolean(route.arrived)
        ])
    }

    // The journey snapshot, so one `location.situation` call answers "where
    // am I, what's around me, where am I heading". `location.journey` returns
    // just this slice, built by the same `journeyRecord(from:)` and
    // `journeyRecurrence(for:)`.
    private func addJourneyField(_ rec: inout [String: FactValue]) {
        guard let journeyTrail = AppDependencies.current.location.breadcrumbStore.load(),
              let journey = JourneyIntelligenceService.snapshot(for: journeyTrail)
        else { return }
        var jrec = Self.journeyRecord(from: journey)
        jrec["recurrence"] = Self.journeyRecurrence(for: journeyTrail)
        rec["journey"] = .record(jrec)
    }

    private static let locationSituationDescription = """
    [ACTION] Comprehensive situational snapshot in ONE call. Returns: current address bundle (road / locality / nearest_cross_street / nearest_intersection / compact_address / address_status / lat / lon / heading_degrees / heading_compass / \
    speed_mph / speed_kmh / altitude_m), nearby POIs grouped by category (water / restroom / food / parking / medical — each up to 3 entries with name + distance_meters + lat / lon), active route snapshot if one is engaged (destination_label / current_instruction \
    / upcoming_instruction / distance_to_upcoming_step_meters / remaining_distance_meters / arrived), the active journey from the breadcrumb trail when one exists ('journey'), \
    a list of POI category names that were searched and returned zero hits ('empty_categories') so the AI can say 'no water fountains nearby' instead \
    of guessing, and the categories whose search failed or timed out ('failed_categories' — unknown, not empty: say you couldn't check, never 'none nearby'). \
    Use for ANY 'where am I / what's around me / how do I get to / is there a X nearby' question — replaces stitching location.current + location.current_detailed + directions.next_step. POI search radius defaults \
    to 500 m and runs against MapKit's tile data (no third-party network calls). PRIVACY: precise location is only released during an active workout — when none is running this returns notRecorded (tell the user location is \
    workout-only, don't guess). Returns notRecorded if there's no cached fix yet.
    """
}
