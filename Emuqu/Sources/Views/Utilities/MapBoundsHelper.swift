import CoreLocation
import MapKit

/// Computes an `MKCoordinateRegion` that bounds a list of coordinates with
/// padding. Centralised so the previous four near-identical copies in
/// FitnessRecordingView, FitnessPostSummaryView, FitnessPostSummaryView+EpicReport,
/// and WorkoutPDFReport stop drifting independently. Returns a sensible
/// fallback region for empty input rather than crashing on `min()!` / `max()!`.
enum MapBoundsHelper {
    static func region(
        for coordinates: [CLLocationCoordinate2D],
        paddingFactor: Double = 1.3,
        minimumDelta: Double = 0.002,
        emptyFallbackDelta: Double = 0.01
    ) -> MKCoordinateRegion {
        let fallback = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: emptyFallbackDelta, longitudeDelta: emptyFallbackDelta)
        )
        guard !coordinates.isEmpty else { return fallback }
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return fallback }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * paddingFactor, minimumDelta),
                longitudeDelta: max((maxLon - minLon) * paddingFactor, minimumDelta)
            )
        )
    }
}
