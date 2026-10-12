import CoreLocation
import MapKit

/// Computes an `MKCoordinateRegion` that bounds a list of coordinates with
/// padding, for route maps; callers pass their own padding and minimum span.
/// Returns a fallback region for empty input rather than crashing on
/// `min()!` / `max()!`. A route that crosses the ±180° meridian is bounded
/// across it, not around the rest of the globe.
enum MapBoundsHelper {
    static func region(
        for coordinates: [CLLocationCoordinate2D],
        paddingFactor: Double = 1.3,
        minimumDelta: Double = 0.002,
        emptyFallbackDelta: Double = 0.01
    ) -> MKCoordinateRegion {
        let lats = coordinates.map(\.latitude)
        let lons = unwrappedLongitudes(coordinates.map(\.longitude))
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: emptyFallbackDelta, longitudeDelta: emptyFallbackDelta)
            )
        }
        let centerLon = (minLon + maxLon) / 2
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: centerLon > 180 ? centerLon - 360 : centerLon
            ),
            span: MKCoordinateSpan(
                latitudeDelta: min(max((maxLat - minLat) * paddingFactor, minimumDelta), 180),
                longitudeDelta: min(max((maxLon - minLon) * paddingFactor, minimumDelta), 360)
            )
        )
    }

    /// Longitudes on one continuous scale. When the raw values span more than
    /// 180°, the shorter way round is across the antimeridian, so the western
    /// ones are shifted by +360° and the extent is the route's real width.
    private static func unwrappedLongitudes(_ lons: [Double]) -> [Double] {
        guard let minLon = lons.min(), let maxLon = lons.max(), maxLon - minLon > 180 else { return lons }
        return lons.map { $0 < 0 ? $0 + 360 : $0 }
    }
}
