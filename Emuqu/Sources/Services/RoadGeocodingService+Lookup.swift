// `@preconcurrency` on CoreLocation and MapKit, matching
// `RoadGeocodingService.swift`. Both modules predate Swift concurrency, so
// `CLGeocoder`, `MKLocalSearch.Request` and `MKLocalSearch.Response` are not
// `Sendable` and every use raises a warning under `SWIFT_STRICT_CONCURRENCY`.
// The attribute is inert at runtime and does not weaken checking of our own
// types. A file that uses these types without the attribute adds seven
// diagnostics, so every file that touches them carries it.
@preconcurrency import CoreLocation
import Foundation
@preconcurrency import MapKit

// The lookup internals: performing a geocode, resolving from map tiles,
// publishing a context, and the cross-street refinement. The public surface
// and its rate-limiting live in `RoadGeocodingService.swift`.

extension RoadGeocodingService {
    // MARK: - Private

    /// Latency breadcrumbs around the geocoding
    /// pipeline. Each path writes a "[GeocodingLatency]" line with the
    /// elapsed seconds and which fork resolved (tiles / geocoder /
    /// no-result / error). A quick `LC_ALL=C grep -aE 'GeocodingLatency'`
    /// in a debug-log export tells us whether the slow path is
    /// MKLocalSearch tile lookups, CLGeocoder, or the cross-street chain.
    ///
    /// The primary path is MKLocalSearch over the map tile
    /// data. MKLocalSearch hits Apple Maps' indexed road
    /// database directly; CLGeocoder hits a separate reverse-geocode
    /// service that's stricter on rate limits and produces
    /// "stale or wrong street name" results on cornering.
    /// CLGeocoder remains the fallback for (a) areas where MKLocalSearch's
    /// tile data has no thoroughfare indexed (rural / private property)
    /// and (b) when the tile-search path itself errors out.
    func performLookup(at location: CLLocation, enrichCrossStreet: Bool = true) async {
        let lookupStartedAt = Date()
        if let tileResolved = await resolveCurrentRoadFromMapTiles(at: location) {
            debugLog("[GeocodingLatency] tiles resolved in \(String(format: "%.3f", Date().timeIntervalSince(lookupStartedAt)))s — \(tileResolved.road ?? "?")", level: .info)
            publishContext(tileResolved, at: location, source: "tiles")
            await enrich(location: location, road: tileResolved.road, enabled: enrichCrossStreet)
            return
        }
        guard let placemark = await reverseGeocode(location, lookupStartedAt: lookupStartedAt) else {
            return
        }
        publishContext(
            Self.context(from: placemark, at: location), at: location, source: "geocoder-fallback"
        )
        await enrich(location: location, road: placemark.thoroughfare, enabled: enrichCrossStreet)
    }

    /// Seen in a real user log: CLGeocoder hung 26.4s
    /// on workout start (`[GeocodingLatency] geocoder resolved in
    /// 26.372s — Cedar Ln`). Apple's geocoder has no client-tunable
    /// timeout. `runWithTimeout` races a 5 s sleep task against the call;
    /// on timeout we treat it as a failed lookup and let the next refresh
    /// try again. 5 s caps how long a wedged geocoder can starve the rest
    /// of the location pipeline (the cross-street search) —
    /// the full pipeline is gated on this completing.
    ///
    /// Goes through `queuedGeocoderCall`, so it waits its turn behind the
    /// AI-tool and one-shot paths and respects the rate floor and the
    /// backoff after kCLErrorNetwork.
    ///
    /// `runWithTimeout` returns nil on EITHER timeout OR a thrown
    /// CLGeocoder error (kCLErrorNetwork, kCLErrorGeocodeCanceled,
    /// kCLErrorGeocodeFoundNoResult). One nil-handling path covers both —
    /// `current` stays at its previous (slightly stale) value rather than
    /// dropping to nil, so the AI continues to see road context until the
    /// next refresh succeeds.
    private func reverseGeocode(_ location: CLLocation, lookupStartedAt: Date) async -> CLPlacemark? {
        let geocoderStartedAt = Date()
        let placemarksOpt: [CLPlacemark]? = await queuedGeocoderCall {
            await runWithTimeout(seconds: 5.0) {
                try await self.geocoder.reverseGeocodeLocation(location)
            }
        }
        guard let placemarks = placemarksOpt else {
            noteFailure(reason: "performLookup timeout/error")
            debugLogExternal("[GeocodingLatency] CLGeocoder gave nothing back after \(String(format: "%.1f", Date().timeIntervalSince(geocoderStartedAt)))s (\(String(format: "%.1f", Date().timeIntervalSince(lookupStartedAt)))s including the tile search) — no road name this pass, backing off", cause: .os)
            return nil
        }
        guard let placemark = placemarks.first else {
            logNoPlacemark(at: location, geocoderStartedAt: geocoderStartedAt, lookupStartedAt: lookupStartedAt)
            return nil
        }
        debugLog("[GeocodingLatency] geocoder resolved in \(String(format: "%.3f", Date().timeIntervalSince(geocoderStartedAt)))s (total \(String(format: "%.3f", Date().timeIntervalSince(lookupStartedAt)))s) — \(placemark.thoroughfare ?? "?")", level: .info)
        return placemark
    }

    /// Routed through `noteFailure` so the backoff throttle actually arms
    /// (backoffStartedAt). The prior bare `consecutiveFailures += 1`
    /// incremented the counter but never set backoffStartedAt, so the
    /// exponential backoff after repeated no-result responses never engaged.
    /// The coordinate is truncated to ~3dp (≈100 m) because debugLog is
    /// user-exportable and raw lat/lon is precise location (PHI).
    private func logNoPlacemark(at location: CLLocation, geocoderStartedAt: Date, lookupStartedAt: Date) {
        noteFailure(reason: "performLookup no placemark")
        // log-redaction-ok: truncated to 3dp (~100 m) per the note above.
        debugLog("[RoadGeocoding] no placemark near (\(String(format: "%.3f", location.coordinate.latitude)), \(String(format: "%.3f", location.coordinate.longitude))) — failures=\(consecutiveFailures)", level: .warning)
        debugLog("[GeocodingLatency] geocoder no-placemark in \(String(format: "%.3f", Date().timeIntervalSince(geocoderStartedAt)))s (total \(String(format: "%.3f", Date().timeIntervalSince(lookupStartedAt)))s)", level: .info)
    }

    /// Provisional context with no cross-street — published immediately so
    /// the AI sees the road name without waiting on the additional
    /// MKLocalSearch round-trip.
    private static func context(from p: CLPlacemark, at location: CLLocation) -> RoadContext {
        RoadContext(
            road: p.thoroughfare,
            locality: p.locality ?? p.subLocality,
            administrativeArea: p.administrativeArea,
            country: p.country,
            countryCode: p.isoCountryCode,
            nearestCrossStreet: nil,
            subLocality: p.subLocality,
            subAdministrativeArea: p.subAdministrativeArea,
            postalCode: p.postalCode,
            timeZoneIdentifier: p.timeZone?.identifier,
            areaOfInterest: p.areasOfInterest?.first,
            observedAt: Date(),
            observedAtCoord: location.coordinate
        )
    }

    /// Fire MKLocalSearch for the nearest cross street.
    /// Independent of the reverse-geocode round-trip so it never blocks the
    /// road-name update; if it succeeds we upgrade `current` with the
    /// cross-street name. The result is read by
    /// `RoadContext.nearestIntersection` so the AI can answer "what's the
    /// nearest intersection".
    ///
    /// Silent on failure; the road-name floor is already published. The
    /// OSM Nominatim subdivision lookup is not run: it stalled launches for
    /// seconds and rarely returned a neighbourhood, so `subdivision` stays nil
    /// and readers fall back to `subLocality` / `areaOfInterest`.
    ///
    /// `enabled` gates it. The prewarm path skips this so the
    /// launch window doesn't touch overpass-api.
    private func enrich(location: CLLocation, road: String?, enabled: Bool) async {
        guard enabled else { return }
        await refreshNearestCrossStreet(for: location, currentRoad: road)
    }

    /// Primary road-resolution path. Uses the
    /// same Apple Maps tile data the dashboard renders against, queried
    /// via MKLocalSearch with a tight radius around the user's current
    /// fix. The closest result whose thoroughfare differs from `nil`
    /// becomes the road name. We also keep the placemark's
    /// locality/administrativeArea/country fields when populated so
    /// downstream callers don't lose the city/state context.
    ///
    /// Returns nil — and the caller falls back to CLGeocoder — when:
    ///   • MKLocalSearch errors (offline, throttled).
    ///   • No result has a thoroughfare (rural, private property,
    ///     parks).
    ///   • The closest hit is more than 50 m from the user (the
    ///     "current road" claim would be too loose to trust).
    /// Hard 5 s wall-clock cap. A real-world log showed this
    /// call hanging for 30+ s, blocking the entire location pipeline at
    /// workout start. MKLocalSearch has no built-in timeout. `runWithTimeout`
    /// returns nil on overrun; we treat that the same as "no usable results"
    /// and fall through to CLGeocoder.
    func resolveCurrentRoadFromMapTiles(at location: CLLocation) async -> RoadContext? {
        guard let response = await runWithTimeout(seconds: 5.0, operation: {
            try await MKLocalSearch(request: Self.tileSearchRequest(around: location)).start()
        }) else {
            debugLog("[RoadGeocoding] tile search timed out (>5s) — falling back to CLGeocoder", level: .info)
            return nil
        }
        guard let best = bestTileCandidate(in: response, near: location) else { return nil }
        tileSearchBlankActive = false
        // 50 m is the "you're on this road" trust threshold. Beyond
        // that, the next-nearest road might be the right answer
        // and CLGeocoder's authoritative path is safer.
        guard best.distance <= 50 else {
            debugLog("[RoadGeocoding] tile search closest=\(best.placemark.thoroughfare ?? "?") at \(Int(best.distance))m — too far for tile-confidence; falling back to CLGeocoder", level: .info)
            return nil
        }
        return Self.context(from: best.placemark, at: location)
    }

    /// ~120 m bounding box; tight enough that the closest indexed road is
    /// genuinely the user's current road, wide enough to produce results in
    /// suburban grids where the named road segment may be a few tens of
    /// metres away.
    private static func tileSearchRequest(around location: CLLocation) -> MKLocalSearch.Request {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "street"
        request.resultTypes = .address
        let latDelta = (120.0 / UnitConstants.metersPerDegreeLatitude) * 2
        let lonDelta = latDelta / max(0.1, cos(location.coordinate.latitude * .pi / 180))
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
        return request
    }

    /// Bearing-aware ranking. Picking the
    /// closest result by raw distance at an intersection routinely
    /// returns the CROSS street instead of the road the user is actually
    /// walking on. When the user has a
    /// usable course (course >= 0 means "valid heading from CL"), we compute
    /// the bearing from user to each candidate and SCORE candidates by
    /// `distance * (1 + 1.5 * |angleDelta|/90)`. The angle delta is the
    /// smaller of the two possible alignments (a road runs both ways), so a
    /// road parallel to the user's heading scores 1.0× distance and a road
    /// perpendicular scores 2.5× distance — usually flipping the choice to
    /// the right one without making rural-area selection broken.
    private func bestTileCandidate(
        in response: MKLocalSearch.Response, near location: CLLocation
    ) -> (placemark: MKPlacemark, distance: Double, score: Double)? {
        let userCourseDeg: Double? = location.course >= 0 ? location.course : nil
        let scored = response.mapItems.compactMap { item in
            score(item.placemark, from: location, userCourseDeg: userCourseDeg)
        }
        guard let best = scored.min(by: { $0.score < $1.score }) else {
            // Only log this transition once
            // per "tile-blank zone." MapKit's road tile data has
            // gaps in suburban / rural grids; the user's debug log
            // had this fire 30+ times along the same stretch.
            if !tileSearchBlankActive {
                debugLog("[RoadGeocoding] tile search blank — falling back to CLGeocoder", level: .info)
                tileSearchBlankActive = true
            }
            return nil
        }
        return best
    }

    private func score(
        _ placemark: MKPlacemark, from location: CLLocation, userCourseDeg: Double?
    ) -> (placemark: MKPlacemark, distance: Double, score: Double)? {
        guard placemark.thoroughfare != nil else { return nil }
        let coord = placemark.coordinate
        let dist = CLLocation(latitude: coord.latitude, longitude: coord.longitude).distance(from: location)
        guard let userBearing = userCourseDeg else { return (placemark, dist, dist) }
        let candBearing = bearingDegrees(from: location.coordinate, to: coord)
        let raw = abs(((candBearing - userBearing).truncatingRemainder(dividingBy: 180)) + 180)
            .truncatingRemainder(dividingBy: 180)
        let aligned = min(raw, 180 - raw) // 0 = parallel, 90 = perpendicular
        return (placemark, dist, dist * (1 + 1.5 * aligned / 90))
    }

    /// Publish a freshly-resolved `RoadContext` and reset the failure
    /// counter. Shared by the tile-first path and the CLGeocoder
    /// fallback so the bookkeeping is identical from both sources.
    func publishContext(_ ctx: RoadContext, at location: CLLocation, source: String) {
        let previousRoad = current?.road
        current = ctx
        // Mirror into AmbientLocationService's thread-safe
        // lock so non-MainActor readers (ContextBuilder, AI fact
        // resolvers running off the cooperative pool) can read the
        // context without trapping in `MainActor.assumeIsolated`.
        AppDependencies.current.location.ambientLocationService.recordResolvedAddress(ctx)
        lastLookupCoord = location.coordinate
        lastLookupAt = Date()
        consecutiveFailures = 0
        backoffStartedAt = nil
        // Only log when the resolved road CHANGES. Logging every
        // refresh (~once per 60s during a workout) repeats identical
        // text and drowns the rest of the log; the transition is the
        // actually-useful information ("turned onto Willow Grove").
        if previousRoad != ctx.road {
            debugLog("[RoadGeocoding] resolved (\(source)) \(ctx.road ?? "(no street)"), \(ctx.locality ?? "(no city)")", level: .info)
        }
    }

    /// Second-stage MKLocalSearch lookup that finds the
    /// nearest cross street to the current location. Runs after the
    /// CLGeocoder reverse-geocode succeeds so we already know the
    /// user's current road name — used to FILTER it out of the
    /// search results (we don't want "nearest cross street" to be the
    /// same street the user is already on).
    ///
    /// **Approach.** MKLocalSearch with a natural-language "street"
    /// query in a tight 200 m bounding box around the user. Results
    /// have `placemark.thoroughfare` populated. We sort by distance
    /// to the user, drop any that names the current road
    /// (`isSameStreet`: "Maple Avenue" matches "Maple Ave", but
    /// "Maple Pl" is a different street), and take the top hit.
    ///
    /// **Network required.** When offline this silently returns —
    /// `current.nearestCrossStreet` stays nil. The AI gracefully
    /// answers "I don't have a cross street name" instead of guessing.
    /// PRIMARY: OSM road-graph cross-street lookup.
    ///
    /// The MKLocalSearch query (`naturalLanguageQuery="street"`) is the
    /// wrong tool, and is only the fallback. MKLocalSearch is
    /// a keyword search, not a road-graph query — `"street"` only
    /// matches places literally containing the token (most cross-
    /// street names — "Drive", "Lane", "Pointe", "Boulevard" —
    /// don't). User report: standing on Cedar Ln
    /// surrounded by visible cross-streets (Willow Grove,
    /// Woodbridge Blvd, Redhead Ln), every cycle logged "no usable
    /// cross-street candidates." MapKit literally couldn't see them.
    ///
    /// OSM has the road graph (already cached for turn-by-turn
    /// awareness): for each intersection node on the user's road,
    /// the OTHER ways meeting there are real cross-streets by
    /// construction. Pick the closest non-self.
    func refreshNearestCrossStreet(
        for location: CLLocation,
        currentRoad: String?
    ) async {
        if let osmHit = await crossStreetFromRoadGraph(at: location, currentRoad: currentRoad) {
            await applyCrossStreet(
                osmHit.name,
                distance: osmHit.distance,
                radius: osmHit.distance,
                for: location,
                searchedAgainstRoad: currentRoad
            )
            debugLog("[RoadGeocoding] cross-street via OSM road graph: \(osmHit.name) at \(Int(osmHit.distance))m", level: .info)
            return
        }
        await scanForCrossStreet(for: location, currentRoad: currentRoad)
    }

    /// Fallback path (rare — OSM tile unreachable or genuinely empty): an
    /// MKLocalSearch scan, so dead-zone OSM regions still get something,
    /// even if the query shape is weak. Its hits are any address on another
    /// street, not a crossing, so the scan stops at 200 m — the radius the
    /// "nearest intersection" is defined by. Wider, it reported a street up
    /// to 3 km away as the cross street.
    private func scanForCrossStreet(for location: CLLocation, currentRoad: String?) async {
        let radii: [CLLocationDistance] = [100, 200]
        for radius in radii {
            let best = await bestCrossStreet(near: location, radius: radius, currentRoad: currentRoad)
            guard let best else {
                logNoCrossStreetIfLastRadius(radius, radii: radii, currentRoad: currentRoad)
                continue
            }
            await applyCrossStreet(
                best.0, distance: best.1, radius: radius,
                for: location, searchedAgainstRoad: currentRoad
            )
            return
        }
    }

    /// Only the widest radius coming up empty is worth a log line — the
    /// narrower ones failing is the expected path.
    private func logNoCrossStreetIfLastRadius(
        _ radius: CLLocationDistance,
        radii: [CLLocationDistance],
        currentRoad: String?
    ) {
        guard radius == radii.last else { return }
        logNoCrossStreet(currentRoad: currentRoad, radii: radii)
    }

    /// The closest candidate at this radius, or nil when the search returned
    /// nothing usable.
    private func bestCrossStreet(
        near location: CLLocation,
        radius: CLLocationDistance,
        currentRoad: String?
    ) async -> (String, CLLocationDistance)? {
        guard let candidates = await crossStreetCandidates(
            near: location, radius: radius, currentRoad: currentRoad
        ) else { return nil }
        return candidates.min(by: { $0.1 < $1.1 })
    }

    /// One radius of the escalating scan. Nil means the search itself timed
    /// out; an empty array means it returned nothing usable.
    ///
    /// Same 5 s wall-clock cap as the tile-search path. A
    /// real-world log showed this hanging 30+ s on workout start; the 30 s log
    /// line ("cross-street MKLocalSearch radius 200m in 30.724s") was the
    /// smoking gun. A per-radius cap plus escalating fallback means a stalled
    /// tile service caps total cross-street latency at ~20 s across all four
    /// radii instead of multiplying.
    private func crossStreetCandidates(
        near location: CLLocation, radius: CLLocationDistance, currentRoad: String?
    ) async -> [(String, Double)]? {
        let radiusStartedAt = Date()
        let responseOpt = await runWithTimeout(seconds: 5.0, operation: {
            try await MKLocalSearch(request: Self.crossStreetRequest(near: location, radius: radius)).start()
        })
        guard let response = responseOpt else {
            debugLog("[GeocodingLatency] cross-street MKLocalSearch radius \(Int(radius))m TIMED OUT (>5s) — trying next radius", level: .info)
            return nil
        }
        let candidates = response.mapItems.compactMap { item -> (String, Double)? in
            guard let name = item.placemark.thoroughfare,
                  !Self.isSameStreet(name, currentRoad)
            else { return nil }
            let coord = item.placemark.coordinate
            let dist = CLLocation(latitude: coord.latitude, longitude: coord.longitude).distance(from: location)
            return (name, dist)
        }
        debugLog("[GeocodingLatency] cross-street MKLocalSearch radius \(Int(radius))m in \(String(format: "%.3f", Date().timeIntervalSince(radiusStartedAt)))s — \(response.mapItems.count) raw items, \(candidates.count) usable", level: .info)
        return candidates
    }

    /// Convert meters to a coordinate span (1 deg latitude ≈ 111 km).
    private static func crossStreetRequest(
        near location: CLLocation, radius: CLLocationDistance
    ) -> MKLocalSearch.Request {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "street"
        request.resultTypes = .address
        let latDelta = (radius / UnitConstants.metersPerDegreeLatitude) * 2
        let lonDelta = latDelta / max(0.1, cos(location.coordinate.latitude * .pi / 180))
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
        return request
    }

    /// Only log the "no candidates" line once per
    /// road. The user's debug log had this fire 30+ times along a stretch of
    /// road where MapKit just doesn't have cross-street data — same message
    /// every time. Throttled by current road name; a new road logs again.
    private func logNoCrossStreet(currentRoad: String?, radii: [CLLocationDistance]) {
        let key = currentRoad ?? "(unknown)"
        guard lastNoCrossStreetRoad != key else { return }
        debugLog("[RoadGeocoding] no usable cross-street candidates on \(key) (tried \(radii.map { Int($0) }) m)", level: .info)
        lastNoCrossStreetRoad = key
    }

    func crossStreetFromRoadGraph(
        at location: CLLocation,
        currentRoad: String?
    ) async -> (name: String, distance: Double)? {
        guard let road = currentRoad else { return nil }
        guard !Self.normalizeStreetName(road).isEmpty else { return nil }
        guard let tile = await AppDependencies.current.location.roadGraphService.tile(for: location.coordinate) else {
            return nil
        }
        // Find way IDs whose name normalizes to the current road.
        let currentWayIds: Set<Int64> = Set(
            tile.segments.values
                .filter { Self.isSameStreet($0.name, road) }
                .map(\.id)
        )
        guard !currentWayIds.isEmpty else { return nil }
        return Self.nearestCrossing(
            in: tile, from: location, currentWayIds: currentWayIds, currentRoad: road
        )
    }

    /// Every intersection node on the user's road contributes the OTHER ways
    /// meeting there as cross-street candidates; the closest one wins.
    private static func nearestCrossing(
        in tile: RoadGraphService.Tile,
        from location: CLLocation,
        currentWayIds: Set<Int64>,
        currentRoad: String
    ) -> (name: String, distance: Double)? {
        var candidates: [(name: String, distance: Double)] = []
        for node in tile.nodes.values where node.isIntersection {
            guard !Set(node.wayIds).isDisjoint(with: currentWayIds) else { continue }
            let nodeLoc = CLLocation(latitude: node.coord.lat, longitude: node.coord.lon)
            candidates.append(contentsOf: crossingNames(
                at: node, in: tile, currentWayIds: currentWayIds, currentRoad: currentRoad
            ).map { (name: $0, distance: nodeLoc.distance(from: location)) })
        }
        return candidates.min(by: { $0.distance < $1.distance })
    }

    /// The named ways meeting at this node that aren't the road the user is on
    /// (nor another spelling of it).
    private static func crossingNames(
        at node: RoadGraphService.GraphNode,
        in tile: RoadGraphService.Tile,
        currentWayIds: Set<Int64>,
        currentRoad: String
    ) -> [String] {
        node.wayIds.compactMap { wayId -> String? in
            guard !currentWayIds.contains(wayId),
                  let otherName = tile.segments[wayId]?.name, !otherName.isEmpty,
                  !isSameStreet(otherName, currentRoad)
            else { return nil }
            return otherName
        }
    }

    /// The gate is "the road we searched against still matches the current
    /// road", not an exact match on `existing.observedAtCoord`.
    /// During a workout, MKLocalSearch takes ~300-800 ms; meanwhile any 15 m
    /// movement triggers a new performLookup that overwrites `current` with a
    /// fresh coord, so a coordinate-equality gate discards every cross-street
    /// result as "newer reverse-geocode" and cross-street +
    /// nearest-intersection stay nil for every moving user. Road name is the
    /// only property the cross-street result actually depends on (candidates
    /// were filtered by road name). If the road has changed, the hit is stale
    /// and we bail; otherwise upgrade.
    ///
    /// The caller passes the road that was active at search-start
    /// (`searchedAgainstRoad`); THAT is compared against the current road to
    /// detect mid-search road changes. Comparing `existing.road` against
    /// itself would be a no-op self-comparison that always passes.
    func applyCrossStreet(
        _ name: String,
        distance: Double,
        radius: CLLocationDistance,
        for location: CLLocation,
        searchedAgainstRoad: String?
    ) async {
        guard let existing = current else { return }
        let searchedKnown = !Self.normalizeStreetName(searchedAgainstRoad).isEmpty
        let nowKnown = !Self.normalizeStreetName(existing.road).isEmpty
        if searchedKnown, nowKnown, !Self.isSameStreet(searchedAgainstRoad, existing.road) {
            return
        }
        current = Self.withCrossStreet(name, on: existing)
        debugLog("[RoadGeocoding] cross-street resolved: \(name) (\(Int(distance))m away, search radius \(Int(radius))m)", level: .info)
        _ = location  // location parameter retained for caller-side logging consistency
    }

    /// A copy of `existing` with only the cross-street filled in.
    private static func withCrossStreet(_ name: String, on existing: RoadContext) -> RoadContext {
        RoadContext(
            road: existing.road,
            locality: existing.locality,
            administrativeArea: existing.administrativeArea,
            country: existing.country,
            countryCode: existing.countryCode,
            nearestCrossStreet: name,
            subLocality: existing.subLocality,
            subAdministrativeArea: existing.subAdministrativeArea,
            postalCode: existing.postalCode,
            timeZoneIdentifier: existing.timeZoneIdentifier,
            areaOfInterest: existing.areaOfInterest,
            subdivision: existing.subdivision,
            observedAt: existing.observedAt,
            observedAtCoord: existing.observedAtCoord
        )
    }

    /// Whether two names are the same road: equal once suffixes and
    /// directionals are dropped, and not carrying two DIFFERENT street types.
    /// "N Cedar Ln" and "Cedar Lane" match; "Maple Ave" and
    /// "Maple Pl" do not; "Main" and "Main St" do.
    nonisolated static func isSameStreet(_ a: String?, _ b: String?) -> Bool {
        guard normalizeStreetName(a) == normalizeStreetName(b) else { return false }
        guard let typeA = streetType(a), let typeB = streetType(b) else { return true }
        return typeA == typeB
    }

    /// The canonical street type a name ends with ("dr" and "drive" both
    /// read "drive"), or nil when it names none.
    nonisolated private static func streetType(_ name: String?) -> String? {
        let words = (name ?? "").lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return words.reversed().lazy.compactMap { streetTypeCanonical[$0] }.first
    }

    nonisolated private static let streetTypeCanonical: [String: String] = [
        "st": "street", "street": "street", "ave": "avenue", "avenue": "avenue",
        "blvd": "boulevard", "boulevard": "boulevard", "rd": "road", "road": "road",
        "dr": "drive", "drive": "drive", "ln": "lane", "lane": "lane", "way": "way",
        "ct": "court", "court": "court", "pl": "place", "place": "place",
        "pkwy": "parkway", "parkway": "parkway", "hwy": "highway", "highway": "highway",
        "ter": "terrace", "terrace": "terrace", "trail": "trail", "tr": "trail",
        "circle": "circle", "cir": "circle"
    ]

    /// Street-type suffixes and directional prefixes are dropped so
    /// "N Cedar Ln" and "Cedar Lane" compare equal. Dropping the type
    /// also makes "Maple Ave" equal "Maple Pl"; `isSameStreet` is the
    /// comparison that tells those apart. A name that is nothing but those
    /// words keeps its letter ("E St" → "e", "K St" → "k"), so lettered
    /// streets don't all normalize to "" and compare equal.
    nonisolated static func normalizeStreetName(_ name: String?) -> String {
        guard let name else { return "" }
        let words = name
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let core = words.filter { !streetNameNoiseWords.contains($0) }
        guard core.isEmpty else { return core.joined(separator: " ") }
        return words.filter { streetTypeCanonical[$0] == nil }.joined(separator: " ")
    }

    nonisolated private static let streetNameNoiseWords: Set<String> = [
        "st", "street",
        "ave", "avenue",
        "blvd", "boulevard",
        "rd", "road",
        "dr", "drive",
        "ln", "lane",
        "way", "ct", "court",
        "pl", "place",
        "pkwy", "parkway",
        "hwy", "highway",
        "ter", "terrace",
        "trail", "tr",
        "circle", "cir",
        "n", "s", "e", "w", "ne", "nw", "se", "sw"
    ]
}
