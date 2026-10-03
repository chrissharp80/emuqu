import MapKit
import SwiftUI
import UIKit

// The two `UIViewRepresentable` map wrappers, split out of
// `WorkoutSummaryV2View.swift`: a plain polyline overlay and the
// α1-coloured route. Both are UIKit bridges with no dependency on the summary
// screen that hosts them.

// MARK: - Map polyline subview

struct MapPolylineView: UIViewRepresentable {
    let coords: [CLLocationCoordinate2D]

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .flat)
        map.isRotateEnabled = false
        map.delegate = context.coordinator
        let polyline = MKPolyline(coordinates: coords, count: coords.count)
        map.addOverlay(polyline)
        if let region = boundingRegion(coords) { map.setRegion(region, animated: false) }
        return map
    }

    func updateUIView(_: MKMapView, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func boundingRegion(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        return MapBoundsHelper.region(for: coords, paddingFactor: 1.3, minimumDelta: 0.005)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer() }
            let r = MKPolylineRenderer(polyline: polyline)
            r.strokeColor = UIColor(AppTheme.primary)
            r.lineWidth = 4
            return r
        }
    }
}

// MARK: - Colored route map

/// Renders the route as a sequence of MKPolyline segments, each
/// colored by the local α1 zone at that point along the workout.
/// Approach: one segment per pair of adjacent GPS fixes (so segments are
/// equal in fix count, not in length), pick the α1 sample whose fractional
/// position-along-the-workout matches that segment's midpoint, and
/// color the segment from a 3-bucket scale.
struct ColoredRouteMapView: UIViewRepresentable {
    let coords: [CLLocationCoordinate2D]
    let alpha1Series: [(progress: Double, alpha: Double)]

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .flat)
        map.isRotateEnabled = false
        map.delegate = context.coordinator
        addColoredSegments(to: map)
        if let region = boundingRegion(coords) { map.setRegion(region, animated: false) }
        return map
    }

    func updateUIView(_: MKMapView, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Bucket α1 → display color. Thresholds match the plan's
    /// aerobic-threshold (α1 ≥ 0.75) and lactate-threshold (α1 ≥ 0.5)
    /// cutpoints, with everything below 0.5 read as "above LT2."
    private static func color(forAlpha1 alpha: Double) -> UIColor {
        if alpha >= 0.75 { return UIColor(AppTheme.wongOptimal) }
        if alpha >= 0.5 { return UIColor(AppTheme.wongCaution) }
        return UIColor(AppTheme.wongAttention)
    }

    private func addColoredSegments(to map: MKMapView) {
        guard coords.count >= 2, !alpha1Series.isEmpty else {
            // Fall back to a single uncolored polyline if α1 data is
            // missing — better than rendering nothing on a map shell.
            let pl = MKPolyline(coordinates: coords, count: coords.count)
            map.addOverlay(pl)
            return
        }

        let totalSegments = coords.count - 1
        for i in 0..<totalSegments {
            let progress = (Double(i) + 0.5) / Double(totalSegments)
            // Find the α1 sample closest to this segment's progress
            // along the workout. Linear scan is fine — typical workout
            // has < 1000 samples and < 1000 segments, well under per-
            // frame budget.
            let alpha = alpha1Series.min(by: { abs($0.progress - progress) < abs($1.progress - progress) })?.alpha ?? 1.0
            let pl = ColoredPolyline(coordinates: [coords[i], coords[i + 1]], count: 2)
            pl.tintColor = Self.color(forAlpha1: alpha)
            map.addOverlay(pl)
        }
    }

    private func boundingRegion(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        return MapBoundsHelper.region(for: coords, paddingFactor: 1.3, minimumDelta: 0.005)
    }

    /// MKPolyline subclass that carries its own color so the
    /// renderer can pull it out without indexing back into a
    /// segment table.
    final class ColoredPolyline: MKPolyline {
        var tintColor: UIColor = .systemBlue
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let segment = overlay as? ColoredPolyline {
                let r = MKPolylineRenderer(polyline: segment)
                r.strokeColor = segment.tintColor
                r.lineWidth = 4
                return r
            }
            if let polyline = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: polyline)
                r.strokeColor = UIColor(AppTheme.primary)
                r.lineWidth = 4
                return r
            }
            return MKOverlayRenderer()
        }
    }
}
