import CoreLocation
import Foundation
import MapKit
import os

// MARK: - Surroundings POI service
//
// Multi-category MKLocalSearch wrapper that powers the AI's
// "what's around me?" tool. Apple's MapKit doesn't expose a single
// "find every nearby useful thing" call — searches are per-category
// and per-radius. This service runs five category searches in
// parallel and consolidates the results into one bundle the AI
// resolver can return in a single tool call.
//
// Categories chosen for the fitness / endurance use case:
//   • water  — fountains, springs, water-only stops (essential mid-run)
//   • restroom — public restrooms (break-need lookups)
//   • food — cafes, restaurants, convenience stores (refuel + carbs)
//   • parking — for "lead me back to my car"
//   • medical — hospitals, urgent care, pharmacies (safety net)
//
// Privacy: all search happens against MapKit's tile data; no third-
// party network calls. Results are ephemeral — a complete result is
// cached for 60 s on the service so a fast follow-up call ("what's the
// closest food?" after "what's around me?") doesn't burn another
// round-trip. A search where any category failed is not cached.

// Not @MainActor: the only mutable state is the cache, kept in an
// `OSAllocatedUnfairLock`, and the work itself (MKLocalSearch +
// TaskGroup) has no MainActor requirement, so callers on the main actor
// suspend on it rather than wait for the main actor to free up.
final class SurroundingsPOIService: Sendable {
    static let shared = SurroundingsPOIService()

    /// One nearby place — name + coords + distance from the query
    /// point + which category the search bucket assigned to it.
    /// Distance is `CLLocation.distance(from:)` great-circle metres,
    /// not walking distance (that requires a routing call per item;
    /// not worth it for a "what's around" lookup).
    struct POI: Sendable {
        let name: String
        let category: Category
        let latitude: Double
        let longitude: Double
        let distanceMeters: Double
    }

    enum Category: String, Sendable, CaseIterable {
        case water
        case restroom
        case food
        case parking
        case medical

        /// MKPointOfInterestCategory subset that maps cleanest to the
        /// user-visible bucket. Some buckets (water, restroom) need a
        /// natural-language query because Apple has no MKPOI category
        /// for them; those are handled in `searchTerm` below.
        var pointOfInterestCategories: [MKPointOfInterestCategory]? {
            switch self {
            case .food: return [.restaurant, .cafe, .bakery, .foodMarket]
            case .parking: return [.parking]
            case .medical: return [.hospital, .pharmacy]
            case .water, .restroom: return nil
            }
        }

        var searchTerm: String {
            switch self {
            case .water: return "water fountain"
            case .restroom: return "restroom"
            case .food: return "food"
            case .parking: return "parking"
            case .medical: return "hospital"
            }
        }
    }

    /// Everything one search found, and the categories whose lookup failed
    /// (offline, MapKit error). A failed category is unknown, not empty: it
    /// must not be reported as "nothing nearby".
    struct SearchResult: Sendable {
        let pois: [POI]
        let failedCategories: [Category]
    }

    /// One category's search: its places, or nil when the lookup failed.
    private struct CategoryOutcome: Sendable {
        let category: Category
        let pois: [POI]?
    }

    /// Sendable so the OSAllocatedUnfairLock<CacheEntry?> generic
    /// parameter satisfies the lock's State: Sendable requirement.
    /// All fields are themselves Sendable (POI is declared so above;
    /// Date and CLLocationCoordinate2D are Sendable in the SDK).
    private struct CacheEntry: Sendable {
        let pois: [POI]
        let observedAt: Date
        let coord: CLLocationCoordinate2D
    }

    /// Cache + its lock as one async-safe primitive. `OSAllocatedUnfairLock`'s
    /// `withLock { state in ... }` is the Swift-6-blessed scoped lock; the
    /// previous `NSLock.lock()/unlock()` calls were rejected by the strict-
    /// concurrency checker as unavailable from async contexts (the methods
    /// can suspend mid-region and leak the lock to other tasks).
    private let cacheStorage = OSAllocatedUnfairLock<CacheEntry?>(initialState: nil)
    private let cacheMaxAgeSec: TimeInterval = 60
    /// Movement threshold (m) above which the cache is invalidated
    /// even if it's fresh — once you've walked more than this, the
    /// "nearby" set materially shifts.
    private let cacheMaxDriftMeters: CLLocationDistance = 75

    private init() {}

    // MARK: - Public API

    /// The places found, nearest first. Use `searchWithStatus` to tell a
    /// category with nothing nearby from one whose lookup failed.
    func search(
        near coord: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance = 500,
        topPerCategory: Int = 3
    ) async -> [POI] {
        await searchWithStatus(near: coord, radiusMeters: radiusMeters, topPerCategory: topPerCategory).pois
    }

    func searchWithStatus(
        near coord: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance = 500,
        topPerCategory: Int = 3
    ) async -> SearchResult {
        if let cached = cachedPOIs(near: coord) { return SearchResult(pois: cached, failedCategories: []) }
        let region = MKCoordinateRegion(
            center: coord,
            latitudinalMeters: radiusMeters * 2,
            longitudinalMeters: radiusMeters * 2
        )
        let result = await allCategories(
            in: region,
            from: CLLocation(latitude: coord.latitude, longitude: coord.longitude),
            radiusMeters: radiusMeters,
            topPerCategory: topPerCategory
        )
        guard result.failedCategories.isEmpty else { return result }
        cacheStorage.withLock { state in
            state = CacheEntry(pois: result.pois, observedAt: Date(), coord: coord)
        }
        return result
    }

    /// `OSAllocatedUnfairLock`'s `withLock` is the Swift-6 async-safe scoped
    /// lock. It returns the snapshot — a value type, so post-unlock mutation
    /// by another task can't corrupt what we read. Nil when the cache is
    /// stale or the user has drifted too far from where it was captured.
    private func cachedPOIs(near coord: CLLocationCoordinate2D) -> [POI]? {
        guard let snapshot = cacheStorage.withLock({ $0 }),
              Date().timeIntervalSince(snapshot.observedAt) < cacheMaxAgeSec else { return nil }
        let drift = CLLocation(latitude: snapshot.coord.latitude, longitude: snapshot.coord.longitude)
            .distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
        return drift <= cacheMaxDriftMeters ? snapshot.pois : nil
    }

    /// Run all category searches in parallel, then merge nearest-first.
    private func allCategories(
        in region: MKCoordinateRegion,
        from queryLocation: CLLocation,
        radiusMeters: CLLocationDistance,
        topPerCategory: Int
    ) async -> SearchResult {
        let outcomes: [CategoryOutcome] = await withTaskGroup(of: CategoryOutcome.self) { group in
            Self.addCategorySearches(
                to: &group, region: region, queryLocation: queryLocation,
                radiusMeters: radiusMeters, topPerCategory: topPerCategory
            )
            var collected: [CategoryOutcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }
        return SearchResult(
            pois: outcomes.flatMap { $0.pois ?? [] }.sorted { $0.distanceMeters < $1.distanceMeters },
            failedCategories: outcomes.filter { $0.pois == nil }.map(\.category)
        )
    }

    private static func addCategorySearches(
        to group: inout TaskGroup<CategoryOutcome>,
        region: MKCoordinateRegion,
        queryLocation: CLLocation,
        radiusMeters: CLLocationDistance,
        topPerCategory: Int
    ) {
        for category in Category.allCases {
            group.addTask { [region] in
                await searchCategory(
                    category, in: region, from: queryLocation,
                    radiusMeters: radiusMeters, topN: topPerCategory
                )
            }
        }
    }

    // MARK: - Per-category search
    //
    // Static so it doesn't capture self in the TaskGroup closure; it is a
    // stateless helper.

    /// A failed lookup comes back as nil pois — logged at .warning, one line
    /// per failed category — so the caller reports it as failed, not empty.
    private static func searchCategory(
        _ category: Category,
        in region: MKCoordinateRegion,
        from queryLocation: CLLocation,
        radiusMeters: CLLocationDistance,
        topN: Int
    ) async -> CategoryOutcome {
        let request = MKLocalSearch.Request()
        request.region = region
        request.naturalLanguageQuery = category.searchTerm
        request.resultTypes = .pointOfInterest
        if let cats = category.pointOfInterestCategories {
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: cats)
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            let found = response.mapItems.compactMap {
                poi($0, category: category, from: queryLocation, radiusMeters: radiusMeters)
            }
            let nearest = Array(found.sorted { $0.distanceMeters < $1.distanceMeters }.prefix(topN))
            return CategoryOutcome(category: category, pois: nearest)
        } catch {
            debugLog("[SurroundingsPOI] category search failed: \(error.localizedDescription)", level: .warning)
            return CategoryOutcome(category: category, pois: nil)
        }
    }

    /// One map item as a POI, or nil when it's unnamed or sits beyond 1.5×
    /// the requested radius (MapKit's region is a box, not a circle).
    private static func poi(
        _ item: MKMapItem,
        category: Category,
        from queryLocation: CLLocation,
        radiusMeters: CLLocationDistance
    ) -> POI? {
        guard let name = item.name, !name.isEmpty else { return nil }
        let coord = item.placemark.coordinate
        let distance = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            .distance(from: queryLocation)
        guard distance <= radiusMeters * 1.5 else { return nil }
        return POI(
            name: name,
            category: category,
            latitude: coord.latitude,
            longitude: coord.longitude,
            distanceMeters: distance
        )
    }
}
