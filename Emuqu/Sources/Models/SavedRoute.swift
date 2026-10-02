import CoreLocation
import Foundation

// MARK: - SavedRoute
//
// A user-curated entry in the route library. Distinct from a one-off
// `Route` (loaded from a GPX) and from a workout's recorded track:
// these are the routes the user explicitly told the app "remember this,
// I do it regularly." Each has a user-chosen name ("Daily 1", "Long
// loop", "Saturday hill") and gets matched against future workouts both
// forwards AND reversed — same physical loop, either direction.
//
// Lives separately from sessions so saving a workout to the library
// doesn't depend on / mutate the session's archive entry. The polyline
// is stored encoded (same codec as session.workoutMetadata.gpsPolyline)
// to keep the file small for users with many saved routes.
struct SavedRoute: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    /// User-chosen name. Free text; no constraint.
    var name: String
    /// When the user added it to the library.
    let createdAt: Date
    /// Sport this route is bound to. Recognition only matches against
    /// routes for the same sport — a "Daily walk" loop won't recognise
    /// when the user is biking it, even if the path overlaps.
    let sport: Sport
    /// Encoded polyline (same format as WorkoutMetadata.gpsPolyline) so
    /// the route can be reconstructed any time without a separate decoder.
    let encodedPolyline: Data
    /// Cached precomputes from the polyline so recognition + UI don't
    /// re-derive every tick. All filled at save time.
    let totalDistanceMeters: Double
    let totalAscentMeters: Double
    let totalDescentMeters: Double
    /// Number of climbs in the saved route — used by the live banner
    /// ("3 climbs ahead") without needing to re-decode the polyline.
    let climbCount: Int

    /// Climbs with road names resolved via reverse geocoding. Populated
    /// by the background enrichment task in `SavedRouteStore` after the
    /// user saves the route. nil before enrichment completes (live
    /// recognition still gets a usable Route via climb detection on the
    /// polyline — the road names just won't be there yet). Persisted so
    /// the geocoding work is one-shot per saved route, not redone every
    /// time the user runs the loop.
    var enrichedClimbs: [Route.Climb]?

    /// Decode the polyline into a runnable `Route` (with climbs detected
    /// and cumulative distances baked in). Lazy because the live workout
    /// only needs this once per session — at the moment recognition fires.
    /// If `enrichedClimbs` is present, it replaces the freshly-detected
    /// climbs so the road-name annotations land in the live topology.
    func toRoute() -> Route {
        let track = GPXExporter.decode(polyline: encodedPolyline, startDate: createdAt)
        let route = Route.fromGPX(name: name, track: track)
        guard let enriched = enrichedClimbs, !enriched.isEmpty else { return route }
        // Replace the auto-detected climbs with the enriched ones; the
        // rest of the Route (trackpoints, cumulative distances, totals)
        // stays as computed from the polyline.
        return Route(
            id: route.id,
            name: route.name,
            trackpoints: route.trackpoints,
            cumulativeDistanceMeters: route.cumulativeDistanceMeters,
            climbs: enriched,
            totalDistanceMeters: route.totalDistanceMeters,
            totalAscentMeters: route.totalAscentMeters,
            totalDescentMeters: route.totalDescentMeters
        )
    }

    /// Build a SavedRoute from a finished workout. Pulls the encoded
    /// polyline straight off the metadata — no re-encoding — so save is
    /// fast even on a long route.
    static func from(session: HRVSession, name: String) -> SavedRoute? {
        guard let meta = session.workoutMetadata else { return nil }
        guard let polyline = meta.gpsPolyline else { return nil }
        let track = GPXExporter.decode(polyline: polyline, startDate: session.startDate)
        guard track.count >= 2 else { return nil }
        let route = Route.fromGPX(name: name, track: track)
        return SavedRoute(
            id: UUID(),
            name: name,
            createdAt: Date(),
            sport: meta.sport,
            encodedPolyline: polyline,
            totalDistanceMeters: route.totalDistanceMeters,
            totalAscentMeters: route.totalAscentMeters,
            totalDescentMeters: route.totalDescentMeters,
            climbCount: route.climbs.count
        )
    }
}

// MARK: - SavedRouteStore
//
// Persists the user's named route library to disk. Single JSON file in
// Application Support — small, infrequently-written, easy to back up to
// iCloud later. Owns its own queue so writes don't fight with the live
// recording path.
@Observable
@MainActor
final class SavedRouteStore {
    static let shared = SavedRouteStore()

    private(set) var routes: [SavedRoute] = []

    private let storeURL: URL

    /// Set when the store file exists but could not be decoded (corrupt /
    /// partially-written / newer-format). While true, `save()` refuses to
    /// write so we never overwrite the good-but-unreadable file with an
    /// empty (or lossy) library. A successful decode or an absent file
    /// clears it. Mirrors `SettingsManager`'s file-absent-vs-unreadable
    /// distinction.
    private var loadFailed = false

    /// Delete All My Data removed the file; this drops the in-memory copy so
    /// nothing reads it afterwards and the next save cannot write it back.
    func forgetAfterPurge() {
        routes = []
        loadFailed = false
    }

    /// App Group container — same reason as `SettingsManager`: Application
    /// Support / Documents directories don't survive an uninstall + reinstall
    /// cycle, but the App Group container does. Without this, every botched
    /// build install or structural change to the iOS bundle silently wipes the
    /// user's saved route library.
    init() {
        let appGroupURL = AppConfig.sharedContainerURL().appendingPathComponent("saved_routes.json")
        Self.migrateLegacyStoreIfNeeded(to: appGroupURL)
        self.storeURL = appGroupURL
        load()
    }

    /// On first run after the App Group move, copy the legacy Application
    /// Support file across if no App Group copy exists yet.
    private static func migrateLegacyStoreIfNeeded(to appGroupURL: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: appGroupURL.path),
              let legacySupport = attempt("savedRoutes.legacyDir", {
                  try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
              })
        else { return }
        let legacyURL = legacySupport.appendingPathComponent("saved_routes.json")
        guard fm.fileExists(atPath: legacyURL.path) else { return }
        do {
            try fm.copyItem(at: legacyURL, to: appGroupURL)
            debugLog("[SavedRouteStore] Migrated saved_routes.json from Application Support → App Group container")
        } catch {
            debugLog("[SavedRouteStore] Migration copy failed: \(error)")
        }
    }

    /// Add a new route to the library. Names don't need to be unique —
    /// the user might genuinely have "Loop A" twice if they reuse the
    /// name. We store by ID, render by name; collision is the user's
    /// problem to spot.
    func add(_ route: SavedRoute) {
        routes.append(route)
        save()
    }

    func rename(id: UUID, to newName: String) {
        guard let idx = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[idx].name = newName
        save()
    }

    func remove(id: UUID) {
        routes.removeAll { $0.id == id }
        save()
    }

    /// Geocode each climb's start coordinate into a road name and
    /// persist the enriched climbs back onto the route. Designed to be
    /// fire-and-forget from the post-workout "Add to my route library"
    /// flow — the user doesn't wait on it; road names appear once the
    /// background task finishes (typically within 5–15 s for a 5-climb
    /// route, longer if Apple's geocoder rate-limits us).
    ///
    /// Idempotent: running on an already-enriched route is a no-op.
    /// Per-climb failures (geocoder returns no match for the coordinate)
    /// silently leave that climb's roadName as nil — better than
    /// fabricating a wrong street name.
    func enrichWithRoadNames(routeID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            guard let route = self.routes.first(where: { $0.id == routeID }) else { return }
            if route.enrichedClimbs != nil { return }
            let runtimeRoute = route.toRoute()
            guard !runtimeRoute.climbs.isEmpty else { return }
            let enriched = await Self.climbsWithRoadNames(on: runtimeRoute)
            await MainActor.run { [enriched] in
                self.applyEnrichedClimbs(enriched, to: routeID)
            }
        }
    }

    /// Resolve the coordinate for each climb's start using the trackpoints +
    /// cumulative distances, picking the trackpoint closest to the climb's
    /// `startDistanceMeters`, then reverse-geocode it.
    ///
    /// Paced deliberately — Apple's CLGeocoder is rate-limited at ~50 reqs/min
    /// device-wide. A 600 ms gap is a ~100 reqs/min ceiling, but a route only
    /// needs 2–8 lookups, so bursts stay safely under.
    private static func climbsWithRoadNames(on route: Route) async -> [Route.Climb] {
        var enriched: [Route.Climb] = []
        for climb in route.climbs {
            let coordinate = coordinate(atDistanceMeters: climb.startDistanceMeters, on: route)
            enriched.append(Route.Climb(
                startDistanceMeters: climb.startDistanceMeters,
                endDistanceMeters: climb.endDistanceMeters,
                gainMeters: climb.gainMeters,
                averageGradePercent: climb.averageGradePercent,
                roadName: await roadName(at: coordinate)
            ))
            await sleepQuietly(600_000_000, context: "enriched")
        }
        return enriched
    }

    private static func roadName(at coordinate: CLLocationCoordinate2D?) async -> String? {
        guard let coordinate else { return nil }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return await Task { @MainActor in
            await AppDependencies.current.location.roadGeocodingService.reverseGeocodeQueued(location)?.thoroughfare
        }.value
    }

    /// Replace the saved route in the store with its enriched version.
    private func applyEnrichedClimbs(_ enriched: [Route.Climb], to routeID: UUID) {
        guard let idx = routes.firstIndex(where: { $0.id == routeID }) else { return }
        var copy = routes[idx]
        copy.enrichedClimbs = enriched
        routes[idx] = copy
        save()
    }

    /// Find the trackpoint closest to a given cumulative distance along
    /// the route. Linear search — N is small (typically <2000 points)
    /// and this runs once per climb at enrichment time.
    private static func coordinate(atDistanceMeters target: Double, on route: Route) -> CLLocationCoordinate2D? {
        guard !route.trackpoints.isEmpty,
              route.cumulativeDistanceMeters.count == route.trackpoints.count
        else { return nil }
        var bestIdx = 0
        var bestDelta = Double.greatestFiniteMagnitude
        for (i, dist) in route.cumulativeDistanceMeters.enumerated() {
            let delta = abs(dist - target)
            if delta < bestDelta { bestDelta = delta; bestIdx = i }
        }
        let p = route.trackpoints[bestIdx]
        return CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)
    }

    /// Routes for a given sport, newest first. Recognition uses this to
    /// scope its candidate list.
    func routes(for sport: Sport) -> [SavedRoute] {
        routes.filter { $0.sport == sport }.sorted { $0.createdAt > $1.createdAt }
    }

    /// The on-disk library, or nothing when the file is absent. A file that is
    /// present but unreadable (iOS file protection while locked) or
    /// undecodable (corrupt / partially written / newer format) sets
    /// `loadFailed`, which blocks saves so we never clobber a recoverable
    /// library with an empty one.
    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            loadFailed = false
            return
        }
        guard let data = try? Data(contentsOf: storeURL) else {
            loadFailed = true
            return
        }
        guard let decoded = try? JSONDecoder().decode([SavedRoute].self, from: data) else {
            loadFailed = true
            debugLog("[SavedRouteStore] saved_routes.json present but failed to decode — keeping in-memory routes and blocking saves to avoid clobbering it")
            return
        }
        loadFailed = false
        routes = decoded
    }

    private func save() {
        // Never overwrite a store file we couldn't decode — that would
        // destroy a recoverable library.
        guard !loadFailed else {
            debugLog("[SavedRouteStore] skipping save — prior load failed; refusing to clobber the on-disk file")
            return
        }
        // Encode + write off-main so a 50-route library doesn't stutter
        // the UI thread on every change. Snapshot the array so the
        // background task doesn't read a mid-mutation list.
        let snapshot = routes
        let url = storeURL
        Task.detached(priority: .utility) {
            guard let data = attempt("savedRoutes.encode", { try JSONEncoder().encode(snapshot) }) else { return }
            attempt("savedRoutes.write") {
                try data.write(to: url, options: [.atomic])
            }
        }
    }
}
