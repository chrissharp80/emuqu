import CoreLocation
import Foundation
import MapKit

// MARK: - DirectionsService
//
// Backend for the AI's `directions.routeTo` tool. Resolves
// a named destination (breadcrumb origin, parking lot, park, hospital,
// or a typed address) into a coordinate, then asks MapKit for a walking
// (or driving) route. The AI uses this to answer questions like:
//
//   "Get me back to where I started."
//   "What's the closest parking from here?"
//   "Where's the nearest hospital?"
//   "Walk me to Lakeside Park trailhead."
//
// **Offline behaviour.** MKLocalSearch and MKDirections both require
// network. When connectivity is poor the action returns a structured
// `notRecorded` so the AI tells the user "I can't reach the routing
// service right now" — never makes up directions. The breadcrumb-back
// arrow in `GetMeBackView` does NOT depend on this service; it works
// fully offline using the raw breadcrumb origin.

enum DirectionsService {
    /// Logical destination kinds the AI can ask for. Decoded from a
    /// string argument so the tool registration stays JSON-friendly.
    enum Destination {
        /// Breadcrumb-trail origin from `AppDependencies.current.location.breadcrumbStore`.
        case origin
        /// Generic POI search via MKLocalSearch. The literal string is
        /// passed through as the natural-language query, so "parking
        /// lot" / "hospital" / "park" / "police station" / "fire
        /// station" all work.
        case poi(query: String)
        /// Typed free-form address; forward-geocoded.
        case address(String)
    }

    /// What the user wants the route optimised for. Drives MKDirections
    /// transport type. Default walking — the breadcrumb-back use case
    /// is a foot trail.
    enum Mode {
        case walking, driving

        var transportType: MKDirectionsTransportType {
            self == .walking ? .walking : .automobile
        }
    }

    /// Resolved route ready for the AI to read out. All fields plain
    /// scalars + small step list so the JSON envelope stays small.
    struct RouteResult {
        let destinationLabel: String
        let destinationLatitude: Double
        let destinationLongitude: Double
        let distanceMeters: Double
        let durationSeconds: TimeInterval
        let mode: String
        let steps: [String] // first N step instructions
    }

    /// The resolved route is engaged as ACTIVE so subsequent
    /// `directions.next_step` calls answer against the user's live position.
    /// One active session at a time; calling `directions.routeTo` again
    /// replaces it. The AI tells the user to "say 'never mind' to clear" —
    /// which routes through `disengage()`.
    ///
    /// Throws `CancellationError` instead of engaging when its task was
    /// cancelled while the destination or route was being resolved: the
    /// assistant's caller gives up after a few seconds, cancels the lookup and
    /// tells the user the route is unavailable, so a route arriving later must
    /// not start guidance behind that answer.
    static func resolveRoute(
        from origin: CLLocationCoordinate2D,
        to destination: Destination,
        mode: Mode
    ) async throws -> RouteResult {
        // 1) Resolve destination coordinate + label.
        let (destLabel, destCoord) = try await resolveDestination(destination, near: origin)
        // 2) Ask MapKit for a route.
        let route = try await mapKitRoute(from: origin, to: destCoord, mode: mode)
        try Task.checkCancellation()
        AppDependencies.current.location.activeRouteSession.engage(
            route: route, destinationLabel: destLabel, destinationCoord: destCoord
        )
        // First N step instructions for the AI to narrate.
        let steps = route.steps.prefix(3).map(\.instructions).filter { !$0.isEmpty }
        return RouteResult(
            destinationLabel: destLabel,
            destinationLatitude: destCoord.latitude,
            destinationLongitude: destCoord.longitude,
            distanceMeters: route.distance,
            durationSeconds: route.expectedTravelTime,
            mode: mode == .walking ? "walking" : "driving",
            steps: Array(steps)
        )
    }

    private static func mapKitRoute(
        from origin: CLLocationCoordinate2D, to destCoord: CLLocationCoordinate2D, mode: Mode
    ) async throws -> MKRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destCoord))
        request.transportType = mode.transportType
        request.requestsAlternateRoutes = false
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else {
            throw DirectionsError.noRoute
        }
        return route
    }

    // MARK: - Destination resolvers

    private static func resolveDestination(
        _ destination: Destination,
        near origin: CLLocationCoordinate2D
    ) async throws -> (label: String, coord: CLLocationCoordinate2D) {
        switch destination {
        case .origin:
            return try breadcrumbOrigin()
        case let .poi(query):
            return try await nearestPOI(matching: query, near: origin)
        case let .address(text):
            return try await geocodedAddress(text)
        }
    }

    /// Read the breadcrumb origin off disk so this works whether or not the
    /// recorder is currently engaged.
    private static func breadcrumbOrigin() throws -> (label: String, coord: CLLocationCoordinate2D) {
        guard let trail = AppDependencies.current.location.breadcrumbStore.load(), let originFix = trail.origin else {
            throw DirectionsError.noBreadcrumbOrigin
        }
        let label = trail.label ?? trail.resolvedOriginLabel
            ?? String(localized: "where you started", bundle: LanguageManager.appBundle)
        return (label, originFix.coordinate)
    }

    /// Searches within `poiRadiusMeters` (25 km) of origin — enough for
    /// "nearest hospital" in a rural area, tight enough that "parking" in a
    /// city doesn't suggest a lot 60 km away. The search region is only a hint
    /// to MKLocalSearch, so results beyond the radius are dropped here. The
    /// closest remaining result wins: MKLocalSearch sorts by relevance, not
    /// distance, and "nearest" is what the user asked for.
    private static func nearestPOI(
        matching query: String, near origin: CLLocationCoordinate2D
    ) async throws -> (label: String, coord: CLLocationCoordinate2D) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: origin, latitudinalMeters: 2 * poiRadiusMeters, longitudinalMeters: 2 * poiRadiusMeters
        )
        request.resultTypes = [.pointOfInterest, .address]
        let response = try await MKLocalSearch(request: request).start()
        let originLoc = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        let nearest = response.mapItems
            .filter { distance(from: $0, to: originLoc) <= poiRadiusMeters }
            .min { distance(from: $0, to: originLoc) < distance(from: $1, to: originLoc) }
        guard let nearest else { throw DirectionsError.noPOIMatch }
        return (nearest.name ?? nearest.placemark.thoroughfare ?? query, nearest.placemark.coordinate)
    }

    /// How far a point-of-interest destination may be from the user.
    private static let poiRadiusMeters: CLLocationDistance = 25_000

    private static func distance(from item: MKMapItem, to origin: CLLocation) -> CLLocationDistance {
        CLLocation(
            latitude: item.placemark.coordinate.latitude,
            longitude: item.placemark.coordinate.longitude
        ).distance(from: origin)
    }

    /// Reuses the existing forward-geocoder so the answer comes out the same
    /// as `location.set_address` — same Apple CLGeocoder, same
    /// loose-natural-language acceptance.
    private static func geocodedAddress(
        _ text: String
    ) async throws -> (label: String, coord: CLLocationCoordinate2D) {
        guard let resolved = await RoadGeocodingService.geocodeAddress(text) else {
            debugLog("[DirectionsService] address geocode returned no result (network boundary)", level: .warning)
            throw DirectionsError.geocoderFailed(query: text)
        }
        let label = [resolved.road, resolved.locality].compactMap { $0 }.joined(separator: ", ")
        return (label.isEmpty ? text : label, resolved.observedAtCoord)
    }
}

enum DirectionsError: Error {
    case noBreadcrumbOrigin
    case noPOIMatch
    case geocoderFailed(query: String)
    case noRoute
}
