import CoreLocation
import Foundation

// The live-coaching namespace.

// MARK: - workout.live.* extensions for thresholds + intervals + HRR
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

    /// Location, pace and the live workout-control actions.
    private var coachingEntries: [FactEntry] {
        [
            locationFieldEntries,
            [locationCurrentEntry, locationSituationEntry]
        ]
        .flatMap { $0 }
    }

    // ── Location (reverse-geocoded street + locality) ─────────
    // Closes the geography gap the AI itself flagged: "I have GPS
    // coords but no idea what street I'm on." With these the
    // assistant can say "you're on Elm Street, halfway through
    private var locationFieldEntries: [FactEntry] {
        [
            workoutLiveLocationRoadEntry,
            workoutLiveLocationLocalityEntry,
            locationAdminAreaEntry,
            workoutLiveLocationCountryCodeEntry,
            workoutLiveLocationCompactAddressEntry
        ]
    }

    // ── On-demand current location (works ANY TIME, not just
    //    during a workout), so the AI can answer "what street am
    //    I on" outside a workout. The `workout.live.location.*`
    //    facts only return data while a workout is recording;
    //    this one fires a one-shot CLLocationManager.requestLocation()
    //    + reverse-geocode so the AI can locate the user
    // ── Precise location with heading + speed + altitude ──────
    //
    // Same lookup path as `location.current` but uses
    // `kCLLocationAccuracyBestForNavigation` (3-5 m typical) and
    // returns the FULL CLLocation envelope: heading (course
    // over ground), speed, altitude, accuracy. Use this when
    // the user asks anything that needs DIRECTIONAL awareness:
    // "which way am I facing", "am I going up or down",
    // "how fast am I moving", "am I about to reach …", etc.
    //
    // The AI can combine this with road context (the `road`
    // field) to reason about local geometry — "you're heading
    // north on Lake Ave at 3 mph, altitude 985 ft" — but the
    // ahead-of-you predictive bits ("turn right in 200 ft")
    // need a separate roads-within-radius lookup; that one's
    // not built yet, the AI should say so when asked.
    //
    // `location.situation`: the unified
    // "what's going on right now AND what's around me" call.
    // Bundles current address + bearing + speed + nearby
    // POIs (water, restroom, food, parking, medical) + the
    // active route's next-step (when one is engaged).
    // Designed so the AI can answer ANY situational question
    // with one tool call instead of stitching together
    // location.current + location.current_detailed +
    // `location.journey`: where am I heading,
    // why, how long. Step 1 of the research-recommended
    // tiered approach (the smallest meaningful, no new
    // permissions). Reads the active BreadcrumbStore trail
    // — origin, fixes, label — and returns a structured
    // shape + projection from JourneyIntelligenceService.
    // Returns notRecorded when there's no active trail
    // (Get Me Back not engaged AND no workout running with
    // breadcrumbs). Future tiers — calendar tie-in,
    // recurrence classifier, weather-at-destination — layer
    // on top of this same fact key without breaking callers.
    // loop 2" instead of reading lat/lon at the user.
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
            description: "State / province name for the user's current location ('Tennessee', 'Greater London'). Useful for region-aware suggestions.",
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
            description: "One-line human-readable address ('Elm Street, Knoxville, TN, US') ready to read back to the user verbatim. Skips nil components. Returns missing if no road context resolved yet.",
            valueType: "String"
        ) {
            guard let s = self.snapshot() else {
                return .missing(reason: .notRecorded, detail: "no live workout")
            }
            return .from(s.currentCompactAddress, detail: "geocoder hasn't returned yet")
        }
    }

    //    whenever they ask, regardless of session state.
    private var locationCurrentEntry: FactEntry {
        .action(
            key: "location.current",
            description: Self.locationCurrentDescription,
            parameters: []
        ) { _ in self.resolveLocationCurrent() }
    }

    // Privacy: gate precise location on
    // an active workout (see `workoutActive()` / the static
    // context rule). Refuse rather than leak coordinates when
    // nothing is recording.
    private func resolveLocationCurrent() -> FactValue {
        guard self.workoutActive() else { return self.locationGatedOffMessage() }
        // The app's AmbientLocationService keeps the cache warm
        // whenever the app is foregrounded (and any workout
        // running pushes fixes too). The AI just reads. No
        // cold-fetch, no permission dance — that all belongs to
        // the app side, not the AI tool.
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
        // Placemark-rich fields populated
        // from CLPlacemark. Nil when the legacy / fallback
        // path didn't capture them; future cache refreshes
        // bring them in.
        // OSM Nominatim subdivision name.
        // Highest-priority answer to "what neighborhood
        // am I in?" when populated; AI should prefer
        // this over sub_locality / area_of_interest.
        // Tap-to-open links — synthesized from coords, no
        // network call. AI can read these out and the user
        // can paste them into a browser / Maps share sheet.
        [
            "lat": .double(lat),
            "lon": .double(lon),
            "apple_maps_url": .string("https://maps.apple.com/?ll=\(lat),\(lon)"),
            "google_maps_url": .string("https://www.google.com/maps/search/?api=1&query=\(lat),\(lon)"),
            "lat_lon_string": .string(String(format: "%.5f,%.5f", lat, lon))
        ]
    }

    private static let locationCurrentDescription = """
    [ACTION] Get the user's current location bundle in ONE call. Returns: road / locality / subdivision (community-mapped neighborhood like 'Woodbridge Glen' from OSM — the highest-confidence answer to 'what neighborhood am \
    I in', preferred over sub_locality when populated) / sub_locality (Apple's neighborhood field, often nil in suburban areas) / administrative_area (state) / sub_administrative_area (county) / country / country_code / postal_code \
    / time_zone / area_of_interest (named landmark like 'Sequoyah Park' when applicable) / nearest_cross_street / nearest_intersection ('Riverwood Dr & Eastland Ave' style) / compact_address / lat / lon / lat_lon_string / apple_maps_url \
    / google_maps_url / age_seconds. PRIVACY: precise location is only released while a workout is actively recording. When no workout is running this returns notRecorded \
    — tell the user you can only share location during a workout, don't guess coordinates. No permission probing, no GPS spin-up, no waiting; during a workout, if there's a cached fix it returns instantly.
    """

    // directions.next_step + speculation.
    private var locationSituationEntry: FactEntry {
        .actionAsync(
            key: "location.situation",
            description: Self.locationSituationDescription,
            parameters: []
        ) { _ in await self.resolveLocationSituation() }
    }

    // Privacy: gate precise location on
    // an active workout before reading any fix / running the
    // POI search.
    @MainActor private func resolveLocationSituation() async -> FactValue {
        guard self.workoutActive() else { return self.locationGatedOffMessage() }
        // Read the freshest cached fix; both the address
        // bundle and the POI search anchor on its coordinate.
        // Already on the MainActor (awaitable resolver body) —
        // the assumeIsolated pin became an async-context warning.
        let cached = AppDependencies.current.location.ambientLocationService.cachedLocation(maxAgeSec: 60)
        guard let cached else {
            return .missing(reason: .notRecorded, detail: "no current location fix in the last 60 s — open the app foreground or start a workout to warm the GPS pipeline")
        }
        let pois = await nearbyPOIs(cached.coordinate)
        var rec = situationFixFields(cached)
        addAddressFields(&rec, resolved: roadContext(near: cached))
        rec["nearby_pois"] = .record(poiFields(pois))
        rec["empty_categories"] = .list(emptyPOICategories(pois).map { .string($0) })
        addActiveRouteField(&rec, at: cached)
        addJourneyField(&rec)
        rec["observed_age_seconds"] = .integer(Int(Date().timeIntervalSince(cached.timestamp)))
        return .record(rec)
    }

    // Distance-validated cache read (no
    // per-call CLGeocoder roundtrip). See
    // workout.live.location_bundle for the full rationale.
    @MainActor private func roadContext(near cached: CLLocation) -> RoadGeocodingService.RoadContext? {
        let svc = AppDependencies.current.location.roadGeocodingService
        return svc.cachedIfCloseTo(cached) ?? svc.current
    }

    // A suspending timeout race, NOT a semaphore bridge: this
    // resolver runs on @MainActor, and blocking in semaphore.wait
    // would deadlock — the inner task could never run and the
    // search would hit its budget every time. 3 s budget with an
    // empty-list fallback — see the routes.library.engage
    // rationale for why this ceiling matters (iOS App
    // Watchdog). Main is never parked, so the search can
    // actually complete inside the budget.
    @MainActor private func nearbyPOIs(_ coord: CLLocationCoordinate2D) async -> [SurroundingsPOIService.POI] {
        await FactResolveTimeout.withTimeout(seconds: 3) {
            await AppDependencies.current.location.surroundingsPOIService.search(
                near: coord,
                radiusMeters: 500,
                topPerCategory: 3
            )
        } ?? []
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
        // address_status to match
        // workout.live.location_bundle. See its docstring for
        // values + plain-English translation guidance.
        rec["address_status"] = .string(addressStatus(resolved))
    }

    private func addressFields(_ resolved: RoadGeocodingService.RoadContext) -> [String: FactValue] {
        var rec: [String: FactValue] = [:]
        rec["road"] = .from(resolved.road)
        rec["locality"] = .from(resolved.locality)
        rec["sub_locality"] = .from(resolved.subLocality)
        // OSM Nominatim subdivision; preferred
        // over sub_locality / area_of_interest in spoken
        // output when populated.
        rec["subdivision"] = .from(resolved.subdivision)
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

    private func emptyPOICategories(_ pois: [SurroundingsPOIService.POI]) -> [String] {
        let byCategory = groupedPOIs(pois)
        return SurroundingsPOIService.Category.allCases
            .filter { (byCategory[$0] ?? []).isEmpty }
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

    // Fold the journey-intelligence snapshot
    // into the unified situational tool so a single
    // `location.situation` call carries "where am I /
    // what's around me / where am I heading" all at
    // once. The dedicated `location.journey` fact stays
    // for callers that just want this slice.
    private func addJourneyField(_ rec: inout [String: FactValue]) {
        guard let journeyTrail = AppDependencies.current.location.breadcrumbStore.load(),
              let journey = JourneyIntelligenceService.snapshot(for: journeyTrail)
        else { return }
        var jrec = journeyRecord(journey)
        addRecurrenceField(&jrec, trail: journeyTrail)
        rec["journey"] = .record(jrec)
    }

    private func journeyRecord(_ journey: JourneyIntelligenceService.Snapshot) -> [String: FactValue] {
        var jrec: [String: FactValue] = [
            "shape": .string(journey.shape.rawValue),
            "direction": .string(journey.direction.rawValue),
            "elapsed_seconds": .double(journey.elapsedSeconds),
            "path_length_meters": .double(journey.pathLengthMeters),
            "max_distance_from_origin_meters": .double(journey.maxDistanceFromOriginMeters)
        ]
        if let crow = journey.crowFlyToOriginMeters {
            jrec["crow_fly_to_origin_meters"] = .double(crow)
        }
        if let total = journey.projectedTotalSeconds {
            jrec["projected_total_seconds"] = .double(total)
        }
        if let remaining = journey.projectedRemainingSeconds {
            jrec["projected_remaining_seconds"] = .double(remaining)
        }
        if let label = journey.originLabel, !label.isEmpty {
            jrec["origin_label"] = .string(label)
        }
        return jrec
    }

    // Tier 2 recurrence inside the bundled journey
    // block, same shape as the dedicated
    // location.journey fact above.
    private func addRecurrenceField(_ jrec: inout [String: FactValue], trail journeyTrail: BreadcrumbTrail) {
        let archive = AppDependencies.current.location.breadcrumbStore.loadArchive()
        guard let recurrence = RecurrenceClassifier.match(current: journeyTrail, archive: archive) else { return }
        jrec["recurrence"] = .record([
            "label": .string(recurrence.label),
            "prior_occurrences": .integer(recurrence.priorOccurrences),
            "median_duration_seconds": .double(recurrence.medianDurationSeconds),
            "median_path_length_meters": .double(recurrence.medianPathLengthMeters),
            "average_match_offset_meters": .double(recurrence.averageMatchOffsetMeters)
        ])
    }

    private static let locationSituationDescription = """
    [ACTION] Comprehensive situational snapshot in ONE call. Returns: current address bundle (road / locality / cross_street / intersection / compact_address / lat / lon / heading_degrees / heading_compass / speed_mph / speed_kmh \
    / altitude_m), nearby POIs grouped by category (water / restroom / food / parking / medical — each up to 3 entries with name + distance_meters + lat / lon), active route snapshot if one is engaged (destination_label / current_instruction \
    / upcoming_instruction / distance_to_next_turn_meters / remaining_distance_meters / arrived), and a list of POI category names that returned zero hits ('empty_categories') so the AI can say 'no water fountains nearby' instead \
    of guessing. Use for ANY 'where am I / what's around me / how do I get to / is there a X nearby' question — replaces stitching location.current + location.current_detailed + directions.next_step. POI search radius defaults \
    to 500 m and runs against MapKit's tile data (no third-party network calls). PRIVACY: precise location is only released during an active workout — when none is running this returns notRecorded (tell the user location is \
    workout-only, don't guess). Returns notRecorded if there's no cached fix yet.
    """
}
