import CoreLocation
import Foundation

// The navigation half of `WorkoutLiveCoachingNamespace`, split out of
// `AppFactResolver+LiveCoaching.swift` to keep that struct's body under
// the 500-line limit. Coaching state — location, pace targets, the workout
// controls — stays there; the journey / route / roads-ahead facts live here.
//
// Anything these entries call in the other file is internal rather than
// `private`, because Swift's `private` does not reach across files.

extension WorkoutLiveCoachingNamespace {
    /// Journey, route topology and roads-ahead facts.
    var navigationEntries: [FactEntry] {
        [
            journeyEntry,
            locationRoadsAheadEntry,
            locationCurrentDetailedEntry,
            locationSetAddressEntry,
            directionsRouteToEntry,
            directionsNextStepEntry,
            directionsClearEntry,
            workoutLiveThresholdsActiveEntry,
            workoutLiveThresholdsAnyBreachingEntry,
            workoutLiveThresholdsBreachStateEntry,
            workoutLiveIntervalActiveEntry,
            workoutLiveIntervalCurrentStepEntry,
            workoutLiveIntervalNextStepEntry,
            workoutLiveHrrCaptureStatusEntry
        ]
    }

    // `location.roads_ahead`: forward-looking
    // road network awareness ("you're approaching Birch Lane
    // in 200 ft") WITHOUT a destination route engaged.
    // Built on RoadAwarenessEngine over the OSM road graph
    // fetched + cached by RoadGraphService. Pure tile-cached
    // after the first call into a cell — no per-query latency
    // for repeated lookups within a 250 m radius. Returns a
    // structured event list AND a pre-built spoken phrase
    // the AI can read verbatim.
    private var locationRoadsAheadEntry: FactEntry {
        .actionAsync(
            key: "location.roads_ahead",
            description: """
            [ACTION] Forward-looking road awareness — what's on the road AHEAD of the user, NOT behind them. Returns: current_road (snapped from OSM, may differ from `location.current.road` in newly-mapped areas), confidence (0–1, low \
            values mean don't quote it), road_continues_for_meters (distance until the current road ends or the name changes), events (ordered list of upcoming intersections with cross_streets + distance_meters + is_roundabout, OR a \
            final road_ends event with continuations). Each event includes a `kind` field ('intersection' or 'road_ends') and `distance_meters`. Also returns a pre-built `phrase` ('on Pintail Pointe, approaching Riverwood Dr in 220 \
            ft') the AI can speak verbatim — but ONLY when the engine could safely construct one. When the engine returns confidence < 0.4 OR phrase = null, do NOT invent a road name; say 'I don't have road data for this stretch' instead. \
            Works globally where OSM has road coverage; degrades gracefully in unnamed-street regions (Japan, Korea, parts of Latin America) by falling back to neighborhood phrasing. PRIVACY: precise location is only released during \
            an active workout — when none is running this returns notRecorded.
            """,
            parameters: []
        ) { _ in await self.resolveLocationRoadsAhead() }
    }

    @MainActor private func resolveLocationRoadsAhead() async -> FactValue {
        // Privacy: gate precise location on
        // an active workout (roads_ahead returns the user's
        // snapped road + lat/lon-derived geometry).
        guard self.workoutActive() else { return self.locationGatedOffMessage() }
        guard let cachedLoc = AppDependencies.current.location.ambientLocationService.cachedLocation(maxAgeSec: 60) else {
            return .missing(reason: .notRecorded, detail: "no fresh GPS fix — open the app foreground or start a workout")
        }
        let neighborhoodFallback = AppDependencies.current.location.ambientLocationService.cachedResolvedAddress(maxAgeSec: 300)?.subdivision
        guard let result = await roadAwareness(at: cachedLoc, neighborhoodFallback: neighborhoodFallback) else {
            return noRoadGraphMissing
        }
        guard roadsAheadIsSafeToQuote(result) else { return lowConfidenceMissing }
        return .record(roadsAheadRecord(result))
    }

    private var noRoadGraphMissing: FactValue {
        .missing(
            reason: .notRecorded,
            detail: "no road graph available for this area — OSM may not have coverage, or the tile fetch timed out"
        )
    }

    // Enforce the safety contract IN CODE, not just via
    // prompt: the AI has quoted tentative results despite
    // the prompt rule ('low-confidence roads ahead
    // fabrication and produced at least one unsolicited
    // turn'). When confidence
    // is below the safety threshold OR the engine
    // couldn't construct a phrase, return .missing so
    // the model literally can't quote a road name —
    // there's nothing to quote.
    private func roadsAheadIsSafeToQuote(_ result: RoadAwarenessEngine.AwarenessResult) -> Bool {
        result.confidence >= 0.4 && result.phrase != nil
    }

    private var lowConfidenceMissing: FactValue {
        .missing(
            reason: .notRecorded,
            detail: "road awareness confidence too low for this fix (snap perpendicular distance > 15m, bearing untrusted at <0.7m/s, or no named segments ahead) — say 'I don't have road data for this stretch'"
        )
    }

    // The engine is async (tile fetch).
    // Capped at 3 s. iOS App Watchdog
    // kills the app at ~10 s of unresponsive main;
    // a real-user termination report attributed a
    // workout kill to this kind of cumulative blocking.
    // When we time out, we return nil and the caller
    // (the AI) degrades gracefully ("road data not
    // available right now"). The Overpass fetch
    // continues in the background and warms the cache
    // for the next call.
    // Implemented as a suspending timeout race (no
    // semaphore bridge). FactResolveTimeout deliberately
    // does NOT cancel the loser, so the background
    // cache-warm contract above still holds.
    @MainActor private func roadAwareness(
        at location: CLLocation,
        neighborhoodFallback: String?
    ) async -> RoadAwarenessEngine.AwarenessResult? {
        await FactResolveTimeout.withTimeout(seconds: 3) {
            await RoadAwarenessEngine.awareness(
                for: location,
                neighborhoodFallback: neighborhoodFallback
            )
        }
    }

    private func roadsAheadRecord(_ result: RoadAwarenessEngine.AwarenessResult) -> [String: FactValue] {
        var rec: [String: FactValue] = [
            "confidence": .double(result.confidence)
        ]
        if let name = result.currentRoadName {
            rec["current_road"] = .string(name)
        }
        if let cont = result.roadContinuesForMeters {
            rec["road_continues_for_meters"] = .double(cont)
        }
        if let phrase = result.phrase {
            rec["phrase"] = .string(phrase)
        }
        rec["events"] = .list(result.events.map { roadEventRecord($0) })
        return rec
    }

    private func roadEventRecord(_ event: RoadAwarenessEngine.LookaheadEvent) -> FactValue {
        var er: [String: FactValue] = [
            "distance_meters": .double(event.distanceMeters)
        ]
        switch event.kind {
        case let .intersection(crossStreets, isRoundabout):
            er["kind"] = .string("intersection")
            er["cross_streets"] = .list(crossStreets.map { .string($0) })
            er["is_roundabout"] = .boolean(isRoundabout)
        case let .roadEnds(continuations):
            er["kind"] = .string("road_ends")
            er["continuations"] = .list(continuations.map { .string($0) })
        }
        return .record(er)
    }

    private var locationCurrentDetailedEntry: FactEntry {
        .action(
            key: "location.current_detailed",
            description: """
            [ACTION] Get the user's current location with FULL navigation detail in ONE call: precise coords, heading (course over ground in degrees, 0=N/90=E + heading_compass cardinal), speed (m/s, mph, km/h), altitude (m + ft), GPS \
            horizontal_accuracy_m, plus the full reverse-geocoded address bundle (road / locality / subdivision (OSM-sourced neighborhood, preferred answer to 'what neighborhood am I in') / sub_locality / administrative_area / sub_administrative_area \
            / country / country_code / postal_code / time_zone / area_of_interest / nearest_cross_street / nearest_intersection / compact_address / apple_maps_url / google_maps_url / lat_lon_string). Use for directional / precision \
            questions: 'which way am I facing', 'am I going up or down', 'how fast am I moving', 'what's the zip code here', 'am I in a different time zone'. Heading and speed are nil when stationary. PRIVACY: precise location is only \
            released during an active workout — when none is running this returns notRecorded (location is workout-only; don't guess coordinates). For 'what's around me' / 'turn right in 200 ft' use the directions namespace.
            """,
            parameters: []
        ) { _ in self.resolveLocationCurrentDetailed() }
    }

    private func resolveLocationCurrentDetailed() -> FactValue {
        // Privacy: gate precise location on
        // an active workout. This action returns the FULL nav
        // envelope (3-5 m coords + heading + speed + altitude),
        // so it must honor the same workout gate.
        guard self.workoutActive() else { return self.locationGatedOffMessage() }
        // Cache-only read. The app populates AmbientLocationService
        // on foreground; the AI doesn't need to know anything about
        // permissions, GPS pipelines, or timeouts.
        if let cachedLoc = AppDependencies.current.location.ambientLocationService.cachedLocation(maxAgeSec: 60),
           let cachedRoad = AppDependencies.current.location.ambientLocationService.cachedResolvedAddress(maxAgeSec: 300) {
            return .record(detailedLocationRecord(cachedLoc, road: cachedRoad))
        }
        return .missing(
            reason: .notRecorded,
            detail: "location cache not warm yet — ask the user to open Emuqu for a moment, then ask again"
        )
    }

    private func detailedLocationRecord(
        _ cachedLoc: CLLocation,
        road cachedRoad: RoadGeocodingService.RoadContext
    ) -> [String: FactValue] {
        let lat = cachedLoc.coordinate.latitude
        let lon = cachedLoc.coordinate.longitude
        var rec = addressFields(lat: lat, lon: lon, cachedLoc: cachedLoc, cachedRoad: cachedRoad)
        addMotionFields(&rec, from: cachedLoc)
        return rec
    }

    private func addressFields(
        lat: Double,
        lon: Double,
        cachedLoc: CLLocation,
        cachedRoad: RoadGeocodingService.RoadContext
    ) -> [String: FactValue] {
        var rec: [String: FactValue] = [
            "status": .string("resolved"),
            "lat": .double(lat),
            "lon": .double(lon),
            "horizontal_accuracy_m": .double(cachedLoc.horizontalAccuracy)
        ]
        rec.merge(geocodedFields(cachedRoad)) { _, new in new }
        rec.merge(mapLinkFields(lat: lat, lon: lon, cachedLoc: cachedLoc)) { _, new in new }
        return rec
    }

    private func geocodedFields(_ cachedRoad: RoadGeocodingService.RoadContext) -> [String: FactValue] {
        let rec: [String: FactValue] = [
            "road": .from(cachedRoad.road),
            "locality": .from(cachedRoad.locality),
            "administrative_area": .from(cachedRoad.administrativeArea),
            "country": .from(cachedRoad.country),
            "country_code": .from(cachedRoad.countryCode),
            "compact_address": .string(cachedRoad.compactAddress),
            "nearest_cross_street": .from(cachedRoad.nearestCrossStreet),
            "nearest_intersection": .from(cachedRoad.nearestIntersection),
            "sub_locality": .from(cachedRoad.subLocality),
            // OSM Nominatim subdivision; the
            // canonical answer to "what neighborhood am I
            // in?" when populated.
            "subdivision": .from(cachedRoad.subdivision),
            "sub_administrative_area": .from(cachedRoad.subAdministrativeArea),
            "postal_code": .from(cachedRoad.postalCode),
            "time_zone": .from(cachedRoad.timeZoneIdentifier),
            "area_of_interest": .from(cachedRoad.areaOfInterest)
        ]
        return rec
    }

    private func mapLinkFields(lat: Double, lon: Double, cachedLoc: CLLocation) -> [String: FactValue] {
        [
            "apple_maps_url": .string("https://maps.apple.com/?ll=\(lat),\(lon)"),
            "google_maps_url": .string("https://www.google.com/maps/search/?api=1&query=\(lat),\(lon)"),
            "lat_lon_string": .string(String(format: "%.5f,%.5f", lat, lon)),
            "age_seconds": .double(Date().timeIntervalSince(cachedLoc.timestamp)),
            "source": .string("cached")
        ]
    }

    private func addMotionFields(_ rec: inout [String: FactValue], from cachedLoc: CLLocation) {
        if cachedLoc.verticalAccuracy >= 0 {
            rec["altitude_m"] = .double(cachedLoc.altitude)
            rec["altitude_ft"] = .double(cachedLoc.altitude * UnitConstants.feetPerMeter)
        }
        if cachedLoc.course >= 0 {
            rec["heading_degrees"] = .double(cachedLoc.course)
            rec["heading_compass"] = .string(Self.compassDirection(degrees: cachedLoc.course))
        }
        if cachedLoc.speed >= 0 {
            rec["speed_mps"] = .double(cachedLoc.speed)
            rec["speed_mph"] = .double(cachedLoc.speed * UnitConstants.mphPerMetersPerSecond)
            rec["speed_kmh"] = .double(cachedLoc.speed * 3.6)
        }
    }

    // ── Forward geocoding (AI-driven location override) ───────
    private var locationSetAddressEntry: FactEntry {
        .actionAsync(
            key: "location.set_address",
            description: """
            [ACTION] Forward-geocode a free-text address the user TOLD you (e.g. 'I'm at the corner of Elm and 5th in Knoxville', 'I'm at Sequoyah Park entrance'). Apple's geocoder resolves loose natural-language queries — most corner-of \
            / landmark / address phrasings work. On success, the resolved road / city / state / country override the ambient road context so all subsequent live-location reads (and your own next-turn answers) reflect what the user said. \
            Use this when `workout.live.location.road` returns missing or stale and the user provides a verbal location. Returns the resolved address record on success; returns invalidParameter when the geocoder can't match.
            """,
            parameters: [
                ActionParam("address", "The free-text address the user gave. Examples: 'corner of Cherokee Pkwy and Lyons View, Knoxville', 'Sequoyah Park trailhead', '1600 Pennsylvania Ave Washington DC'. Pass it verbatim — Apple's geocoder handles the parsing.")
            ]
        ) { args in await self.resolveLocationSetAddress(args) }
    }

    @MainActor private func resolveLocationSetAddress(_ args: [String: String]) async -> FactValue {
        guard let query = args["address"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty
        else {
            return .missing(reason: .invalidParameter, detail: "address is required")
        }
        guard let context = await geocodedRoadContext(query) else {
            return .missing(reason: .invalidParameter, detail: "geocoder couldn't match '\(query)' — try a more specific address (street + city)")
        }
        // Apply the override on MainActor so the published
        // `current` propagates correctly.
        AppDependencies.current.location.roadGeocodingService.overrideContext(context)
        return .record(roadContextRecord(context))
    }

    // Forward-geocode is async; suspend on it directly.
    // 3 s budget, same App Watchdog rationale as above.
    // CLGeocoder is typically <500ms; 3s keeps a slow
    // network from stalling the answer.
    // Suspending timeout race (no semaphore bridge); timeout
    // and no-match collapse into the same envelope as the
    // empty-box path.
    @MainActor private func geocodedRoadContext(_ query: String) async -> RoadGeocodingService.RoadContext? {
        await FactResolveTimeout.withTimeout(seconds: 3) {
            await RoadGeocodingService.geocodeAddress(query)
        }
    }

    private func roadContextRecord(_ context: RoadGeocodingService.RoadContext) -> [String: FactValue] {
        [
            "status": .string("resolved"),
            "road": .from(context.road),
            "locality": .from(context.locality),
            "administrative_area": .from(context.administrativeArea),
            "country": .from(context.country),
            "country_code": .from(context.countryCode),
            "compact_address": .string(context.compactAddress),
            "lat": .double(context.observedAtCoord.latitude),
            "lon": .double(context.observedAtCoord.longitude)
        ]
    }

    // ── Directions (route the user back to a meaningful place) ─
    private var directionsRouteToEntry: FactEntry {
        .actionAsync(
            key: "directions.routeTo",
            description: """
            Compute a walking (or driving) route from the user's CURRENT position to a meaningful destination, using MapKit / MKDirections. Use this when the user says 'get me back to where I started' / 'where's the nearest parking' \
            / 'walk me to the trailhead' / 'hospital nearest me' / 'lead me home'. The breadcrumb origin only exists when the user has engaged Get Me Back mode (see the Fitness tab's 'Get Me Back' card) — if the user hasn't, the 'origin' \
            destination returns notRecorded; route to a typed address or a POI category instead. Returns destination label, lat/lon, total distance in meters, expected travel time in seconds, transport mode, and the first 1–3 turn-by-turn \
            step instructions ready to read aloud. Network-required: MKLocalSearch + MKDirections both call out, so this tool returns notRecorded when offline (the offline compass-arrow back to the breadcrumb origin lives in the Get \
            Me Back screen, not this tool).
            """,
            parameters: [
                ActionParam("destination", """
                What to route to. One of: 'origin' (the breadcrumb origin where the user dropped the pin via Get Me Back mode), 'home' (the user's saved home address from Settings — returns notRecorded if unset, hint-the-user to add it), 'parking' \
                (nearest parking lot), 'park' (nearest park), 'help' (nearest hospital — use this for any 'I'm hurt / need help / closest medical' phrasing), 'police' (nearest police station), 'fire' (nearest fire station), 'address' (forward-geocode \
                the `address` argument). Pick 'origin' for 'lead me back', 'home' for 'lead me home', 'help' for any urgent-medical phrasing, 'address' when the user names a specific place ('Sequoyah Park trailhead').
                """),
                ActionParam("address", "Required when destination=='address'. Free-text address — Apple's geocoder handles loose phrasings like 'corner of Cherokee Pkwy and Lyons View, Knoxville'. Ignored for the other destinations."),
                ActionParam("mode", "Transport mode. 'walking' (default — best for breadcrumb-back / get-me-help scenarios) or 'driving'.")
            ]
        ) { args in await self.resolveDirectionsRouteTo(args) }
    }

    @MainActor private func resolveDirectionsRouteTo(_ args: [String: String]) async -> FactValue {
        let destinationKey = (args["destination"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()) ?? ""
        guard !destinationKey.isEmpty else {
            return .missing(reason: .invalidParameter, detail: "destination is required (origin / parking / park / help / police / fire / address)")
        }
        let mode = routingMode(args)
        let destination: DirectionsService.Destination
        switch destinationResolution(for: destinationKey, args: args) {
        case let .resolved(value): destination = value
        case let .failed(value): return value
        }
        guard let userLoc = await routingUserLocation() else {
            return .missing(reason: .notRecorded, detail: "couldn't get a current location fix to route from — open the app foreground or start a workout to warm up the GPS pipeline")
        }
        guard let route = await computeRoute(from: userLoc, to: destination, mode: mode) else {
            return .missing(reason: .notRecorded, detail: routeUnavailableDetail(for: destination))
        }
        return .record(routeRecord(route))
    }

    private func routingMode(_ args: [String: String]) -> DirectionsService.Mode {
        let modeRaw = (args["mode"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()) ?? "walking"
        return (modeRaw == "driving") ? .driving : .walking
    }

    private enum DestinationResolution {
        case resolved(DirectionsService.Destination)
        case failed(FactValue)
    }

    // Map the AI-friendly key onto a concrete destination.
    private func destinationResolution(
        for destinationKey: String,
        args: [String: String]
    ) -> DestinationResolution {
        if let poi = poiDestination(for: destinationKey) { return .resolved(poi) }
        switch destinationKey {
        case "origin", "start", "where i started", "trailhead":
            return .resolved(.origin)
        case "address":
            return addressDestination(args)
        case "home":
            return homeDestination()
        default:
            return .failed(.missing(reason: .invalidParameter, detail: "unknown destination '\(destinationKey)'. Use one of: origin, parking, park, help, police, fire, address."))
        }
    }

    private func poiDestination(for destinationKey: String) -> DirectionsService.Destination? {
        switch destinationKey {
        case "parking", "parking lot":
            .poi(query: "parking lot")
        case "park":
            .poi(query: "park")
        case "help", "hospital", "medical", "emergency", "er":
            .poi(query: "hospital")
        case "police", "police station":
            .poi(query: "police station")
        case "fire", "fire station":
            .poi(query: "fire station")
        default: nil
        }
    }

    private func addressDestination(_ args: [String: String]) -> DestinationResolution {
        let addr = (args["address"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        guard !addr.isEmpty else {
            return .failed(.missing(reason: .invalidParameter, detail: "address is required when destination=='address'"))
        }
        return .resolved(.address(addr))
    }

    // "Lead me home". Forward-geocodes the
    // user's saved home address (Settings → Profile &
    // Health → Home address). When unset, returns
    // notRecorded with a clear hint so the AI can tell
    // the user to set it.
    private func homeDestination() -> DestinationResolution {
        let saved = (AppDependencies.current.app.settingsManager.settingsSnapshot.homeAddress ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.isEmpty else {
            return .failed(.missing(reason: .notRecorded, detail: "no home address saved — tell the user to set it in Settings → Biometrics → Home Address, then ask again"))
        }
        return .resolved(.address(saved))
    }

    // Fast-path the cache. Workout running
    // with phone locked = AmbientLocationService /
    // WorkoutLocationManager have been keeping fresh fixes
    // in `AppDependencies.current.location.roadGeocodingService.current` and
    // `AppDependencies.current.location.ambientLocationService.latestLocation`. No
    // reason to cold-fetch.
    @MainActor private func routingUserLocation() async -> CLLocation? {
        if let cached = AppDependencies.current.location.ambientLocationService.cachedLocation(maxAgeSec: 60) {
            return cached
        }
        return await coldGPSFix()
    }

    // Cold-GPS fix as a suspending timeout race (no
    // semaphore bridge). Budgets:
    // 7 s outer ceiling around LocationFinder's own 5 s
    // fix timeout; failure or timeout falls into the
    // same "couldn't get a fix" envelope.
    @MainActor private func coldGPSFix() async -> CLLocation? {
        await FactResolveTimeout.withTimeout(seconds: 7) {
            do {
                let fix = try await LocationFinder.detachedCurrentDetailedFix(timeoutSec: 5)
                return CLLocation(
                    latitude: fix.coordinate.latitude,
                    longitude: fix.coordinate.longitude
                )
            } catch {
                // Fall through with no fix — return below.
                return nil
            }
        }
    }

    // Compute the route.
    // 4 s budget. iOS App Watchdog kills at
    // ~10s of unresponsive main; this resolver runs on
    // @MainActor (via runToolUseLoop). 4s is well under
    // the watchdog ceiling and still covers a typical
    // walking-route compute (200-800ms) plus geocoder
    // (CLGeocoder is fast).
    // A suspending timeout race rather than a DispatchSemaphore
    // bridge: a semaphore wait would park the MainActor (this
    // resolver runs on @MainActor via runToolUseLoop) for up to
    // 4 s on a slow MapKit calculate.
    @MainActor private func computeRoute(
        from userLoc: CLLocation,
        to destination: DirectionsService.Destination,
        mode: DirectionsService.Mode
    ) async -> DirectionsService.RouteResult? {
        await FactResolveTimeout.withTimeout(seconds: 4) {
            try? await DirectionsService.resolveRoute(
                from: userLoc.coordinate,
                to: destination,
                mode: mode
            )
        }
    }

    private func routeUnavailableDetail(for destination: DirectionsService.Destination) -> String {
        return switch destination {
        case .origin:
            "no breadcrumb origin set — engage Get Me Back mode first"
        case let .poi(q):
            "couldn't find a nearby \(q) — try a different query or check connectivity"
        case let .address(text):
            "couldn't route to '\(text)' — geocoder or routing service unavailable"
        }
    }

    private func routeRecord(_ route: DirectionsService.RouteResult) -> [String: FactValue] {
        [
            "destination_label": .string(route.destinationLabel),
            "destination_lat": .double(route.destinationLatitude),
            "destination_lon": .double(route.destinationLongitude),
            "distance_meters": .double(route.distanceMeters),
            "duration_seconds": .double(route.durationSeconds),
            "mode": .string(route.mode),
            "first_steps": .list(route.steps.map { .string($0) }),
            "session_engaged": .boolean(true)
        ]
    }

    // Continuous turn-by-turn. After
    // `directions.routeTo` engages a session, this tool
    // answers "what's my next turn / how far / am I there
    // yet" against the user's live position. Reads from
    // `ActiveRouteSession` (in-memory; offline once engaged)
    // and the cached current location. NO new network round-
    // trips — fast (<10 ms typical).
    private var directionsNextStepEntry: FactEntry {
        .fixed(
            key: "directions.next_step",
            description: """
            Live next-turn info for the currently-engaged route from `directions.routeTo`. Returns the upcoming instruction (e.g. 'Turn right onto Eastland Ave'), distance to that turn in meters, total remaining route distance, and \
            an `arrived` boolean that flips true when the user is within 25 m of the destination. Use this on EVERY turn that asks 'what's next' / 'how far now' / 'did I miss the turn' / 'am I there yet' during navigation. Returns notRecorded \
            when no route is engaged — call `directions.routeTo` first or tell the user there's no active route. Computed against the cached location (kept fresh by the workout / ambient location pipeline), so no GPS round-trip.
            """,
            valueType: "Record"
        ) { self.resolveDirectionsNextStep() }
    }

    private func resolveDirectionsNextStep() -> FactValue {
        guard let session = AppDependencies.current.location.activeRouteSession.snapshot() else {
            return .missing(reason: .notRecorded, detail: "no active route — call directions.routeTo to engage one first")
        }
        guard let currentLoc = AppDependencies.current.location.ambientLocationService.cachedLocation(maxAgeSec: 60) else {
            return .missing(reason: .notRecorded, detail: "no current location fix — open the app foreground or start a workout to warm up the GPS pipeline")
        }
        guard let step = AppDependencies.current.location.activeRouteSession.currentStep(for: currentLoc) else {
            return .missing(reason: .notRecorded, detail: "route engaged but step lookup returned nothing — try directions.routeTo again")
        }
        return .record(nextStepRecord(session: session, step: step))
    }

    private func nextStepRecord(
        session: ActiveRouteSession.Snapshot,
        step: ActiveRouteSession.StepResult
    ) -> [String: FactValue] {
        [
            "destination_label": .string(step.destinationLabel),
            "current_step_index": .integer(step.currentStepIndex),
            "step_count": .integer(session.stepCount),
            "current_instruction": .string(step.currentInstruction),
            "upcoming_instruction": .string(step.upcomingInstruction),
            "distance_to_upcoming_step_meters": .double(step.distanceToUpcomingStepMeters),
            "remaining_distance_meters": .double(step.remainingDistanceMeters),
            "arrived": .boolean(step.arrived)
        ]
    }
    // Clear / dismiss the active route session. Use when the
    // user says "never mind", "I'm not going there anymore",
    // or has clearly arrived (the AI can decide based on the
    // `arrived` flag from `directions.next_step`).
    private var directionsClearEntry: FactEntry {
        .action(
            key: "directions.clear",
            description: """
            [ACTION] Clear the currently-engaged route from `directions.routeTo`. Call this when the user says 'never mind' / 'cancel that' / 'I'm not going there' / 'forget it' OR when `directions.next_step` returned `arrived=true` \
            and the user has acknowledged arrival. After clearing, `directions.next_step` returns notRecorded. Idempotent — safe to call when nothing is engaged.
            """,
            parameters: []
        ) { _ in
            AppDependencies.current.location.activeRouteSession.disengage()
            return .record([
                "status": .string("cleared")
            ])
        }
    }

    // ── Thresholds (user-declared physiological constraints) ──
    private var workoutLiveThresholdsActiveEntry: FactEntry {
        .fixed(
            key: "workout.live.thresholds.active",
            description: "List of physiological thresholds the user pre-set for THIS workout (e.g. 'HR > 135 for 30s', 'stay above zone 2 power'). Empty when the user chose silent mode. Returned only while a workout is recording.",
            valueType: "List"
        ) { self.resolveActiveThresholds() }
    }

    private func resolveActiveThresholds() -> FactValue {
        guard let s = self.snapshot() else {
            return .missing(reason: .notRecorded, detail: "no workout active")
        }
        if s.activeThresholds.isEmpty {
            return .missing(reason: .notRecorded, detail: "no thresholds set for this workout")
        }
        return .list(s.activeThresholds.map { activeThresholdRecord($0) })
    }

    private func activeThresholdRecord(_ t: AssistantContext.LiveWorkoutSnapshot.ThresholdSnapshot) -> FactValue {
        .record([
            "id": .string(t.id),
            "metric": .string(t.metric),
            "condition": .string(t.condition),
            "value": .double(t.value),
            "debounce_sec": .integer(t.debounceSec),
            "cooldown_sec": .integer(t.cooldownSec),
            "user_cue": .from(t.userCue)
        ])
    }

    private var workoutLiveThresholdsAnyBreachingEntry: FactEntry {
        .fixed(
            key: "workout.live.thresholds.any_breaching",
            description: "Whether any user-declared threshold is currently breached past its debounce. Cheap; useful as a guard before fetching the per-threshold breach detail.",
            valueType: "Bool"
        ) {
            guard let s = self.snapshot() else {
                return .missing(reason: .notRecorded, detail: "no workout active")
            }
            let breaching = s.activeThresholds.contains { t in
                let secs = s.thresholdBreachSec[t.id] ?? 0
                return secs >= t.debounceSec
            }
            return .boolean(breaching)
        }
    }

    private var workoutLiveThresholdsBreachStateEntry: FactEntry {
        .fixed(
            key: "workout.live.thresholds.breach_state",
            description: "Per-threshold breach progress: for each active threshold, how many CONSECUTIVE seconds the metric has been outside the band. 0 means safely inside. When the value crosses the threshold's debounce_sec the coach fires.",
            valueType: "List"
        ) { self.resolveThresholdBreachState() }
    }

    private func resolveThresholdBreachState() -> FactValue {
        guard let s = self.snapshot() else {
            return .missing(reason: .notRecorded, detail: "no workout active")
        }
        if s.activeThresholds.isEmpty {
            return .missing(reason: .notRecorded, detail: "no thresholds set for this workout")
        }
        return .list(s.activeThresholds.map { breachStateRecord($0, secs: s.thresholdBreachSec[$0.id] ?? 0) })
    }

    private func breachStateRecord(_ t: AssistantContext.LiveWorkoutSnapshot.ThresholdSnapshot, secs: Int) -> FactValue {
        .record([
            "id": .string(t.id),
            "metric": .string(t.metric),
            "breach_seconds": .integer(secs),
            "debounce_seconds": .integer(t.debounceSec),
            "is_breaching_past_debounce": .boolean(secs >= t.debounceSec)
        ])
    }

    // ── Interval plan progress ────────────────────────────────
    private var workoutLiveIntervalActiveEntry: FactEntry {
        .fixed(
            key: "workout.live.interval.active",
            description: "Whether a structured interval plan is currently bound to this workout. False when the user chose free-form, or when the plan finished.",
            valueType: "Bool"
        ) {
            guard let s = self.snapshot() else {
                return .missing(reason: .notRecorded, detail: "no workout active")
            }
            return .boolean(s.intervalProgress != nil)
        }
    }

    private var workoutLiveIntervalCurrentStepEntry: FactEntry {
        .fixed(
            key: "workout.live.interval.current_step",
            description: "Current interval step, with label, 1-based step number, total steps, elapsed seconds in this step, and (when duration-based) seconds remaining.",
            valueType: "Record"
        ) {
            guard let s = self.snapshot() else {
                return .missing(reason: .notRecorded, detail: "no workout active")
            }
            guard let p = s.intervalProgress else {
                return .missing(reason: .notRecorded, detail: "no interval plan bound")
            }
            return .record([
                "step_number": .integer(p.currentStepNumber),
                "total_steps": .integer(p.totalSteps),
                "label": .string(p.currentStepLabel),
                "elapsed_sec": .integer(p.stepElapsedSec),
                "remaining_sec": .from(p.stepRemainingSec, detail: "distance-based step")
            ])
        }
    }

    private var workoutLiveIntervalNextStepEntry: FactEntry {
        .fixed(
            key: "workout.live.interval.next_step",
            description: "Label for the step that comes after the current one. Null when this is the final step.",
            valueType: "String"
        ) {
            guard let s = self.snapshot() else {
                return .missing(reason: .notRecorded, detail: "no workout active")
            }
            guard let p = s.intervalProgress else {
                return .missing(reason: .notRecorded, detail: "no interval plan bound")
            }
            return .from(p.nextStepLabel, detail: "this is the final step")
        }
    }

    // ── HRR capture state (post-stop window) ──────────────────
    private var workoutLiveHrrCaptureStatusEntry: FactEntry {
        .fixed(
            key: "workout.live.hrr_capture_status",
            description: """
            State of the post-Stop heart-rate-recovery capture window (which can run for up to 120 s after the user taps Stop). Values: 'capturing' (window is open, sampling), 'captured' (drops written to the session), 'idle' (no recent \
            capture / no workout). Use this when the user asks 'how's my HRR?' immediately after stopping.
            """,
            valueType: "String"
        ) {
            // The HRR capture state isn't currently published on a
            // singleton broker. Derive a coarse signal from whether
            // a workout is "recently finished" (broker still holds
            // a snapshot from <130s ago after stop). Honest scope
            // until HRRCaptureService gains a published status.
            if MainActor.assumeIsolated({ AppDependencies.current.assistant.liveWorkoutBroker.currentSnapshot() }) != nil {
                return .string("capturing_or_active")
            }
            return .string("idle")
        }
    }

    // MARK: - location.journey
    //
    // A named entry, a hoisted description constant and three resolver steps,
    // rather than one deeply nested element inside the `navigationEntries`
    // array literal. The description is a `static let` because its exact text
    // is the contract sent to the model — moving it must not reflow it.

    /// Journey shape, direction and recurrence for the active breadcrumb trail.
    private var journeyEntry: FactEntry {
        .fixed(
            key: "location.journey",
            description: Self.journeyDescription,
            valueType: "Record"
        ) {
            self.resolveJourney()
        }
    }

    private func resolveJourney() -> FactValue {
        let trail = MainActor.assumeIsolated { AppDependencies.current.location.breadcrumbStore.load() }
        guard let trail else {
            return .missing(reason: .notRecorded, detail: "no active breadcrumb trail — engage Get Me Back mode or start a workout to enable journey intelligence")
        }
        guard let snap = JourneyIntelligenceService.snapshot(for: trail) else {
            return .missing(reason: .notYetComputed, detail: "trail too short to infer (need at least 3 fixes)")
        }
        var rec = Self.journeyRecord(from: snap)
        // Tier 2 recurrence — match the active trail against the archive's
        // historical patterns. Only emitted when >= 2 prior matching trails
        // exist in the bucket; otherwise the model gets nothing for this slot
        // and shouldn't fabricate a "your usual route" claim.
        if let recurrence = Self.journeyRecurrence(for: trail) {
            rec["recurrence"] = recurrence
        }
        return .record(rec)
    }

    /// The always-present half of the journey record.
    private static func journeyRecord(from snap: JourneyIntelligenceService.Snapshot) -> [String: FactValue] {
        var rec: [String: FactValue] = [
            "shape": .string(snap.shape.rawValue),
            "direction": .string(snap.direction.rawValue),
            "elapsed_seconds": .double(snap.elapsedSeconds),
            "path_length_meters": .double(snap.pathLengthMeters),
            "max_distance_from_origin_meters": .double(snap.maxDistanceFromOriginMeters)
        ]
        rec["crow_fly_to_origin_meters"] = snap.crowFlyToOriginMeters.map { .double($0) }
        rec["elapsed_at_farthest_seconds"] = snap.elapsedAtFarthestSeconds.map { .double($0) }
        rec["projected_total_seconds"] = snap.projectedTotalSeconds.map { .double($0) }
        rec["projected_remaining_seconds"] = snap.projectedRemainingSeconds.map { .double($0) }
        if let label = snap.originLabel, !label.isEmpty {
            rec["origin_label"] = .string(label)
        }
        return rec
    }

    /// nil when the trail does not match a historical cluster.
    private static func journeyRecurrence(for trail: BreadcrumbTrail) -> FactValue? {
        let archive = MainActor.assumeIsolated { AppDependencies.current.location.breadcrumbStore.loadArchive() }
        guard let recurrence = RecurrenceClassifier.match(current: trail, archive: archive) else { return nil }
        return .record([
            "label": .string(recurrence.label),
            "prior_occurrences": .integer(recurrence.priorOccurrences),
            "median_duration_seconds": .double(recurrence.medianDurationSeconds),
            "median_path_length_meters": .double(recurrence.medianPathLengthMeters),
            "average_match_offset_meters": .double(recurrence.averageMatchOffsetMeters)
        ])
    }

    private static let journeyDescription = """
    [INTELLIGENCE] Where the user is heading, what shape the journey has, how long until they're done, AND whether this is a recurring route — derived from the active breadcrumb trail (Get Me Back mode OR an in-flight workout) \
    plus the breadcrumb archive. Returns: shape ('out_and_back_outbound' | 'out_and_back_returning' | 'loop' | 'point_to_point' | 'unknown'), direction ('toward_origin' | 'away_from_origin' | 'stationary' | 'unknown'), elapsed_seconds, \
    path_length_meters, crow_fly_to_origin_meters, max_distance_from_origin_meters, elapsed_at_farthest_seconds, projected_total_seconds (out-and-back only), projected_remaining_seconds (out-and-back only), origin_label, AND \
    when the route matches a historical pattern: recurrence { label ('Tuesday morning route near Benelli Dr'), prior_occurrences (count of matching trails in the archive), median_duration_seconds (typical duration), median_path_length_meters \
    (typical distance), average_match_offset_meters (how tightly the current shape matches the cluster — under 50m = strong match, 50-75m = loose). When recurrence is present the AI can say 'this is your usual Tuesday morning \
    loop, you typically finish in 47 min'. Use for any 'where am I going / how long / am I almost back / is this my normal route' question. Returns notRecorded when there's no active breadcrumb trail.
    """

}
