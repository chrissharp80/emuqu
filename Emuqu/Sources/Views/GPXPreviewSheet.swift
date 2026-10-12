import MapKit
import SwiftUI

// The GPX preview sheet.

// MARK: - GPX Preview

/// User-requested preview before the GPX share sheet.
/// Carries the temp-file URL plus the decoded track + parent session
/// so the preview can render a map + summary without re-loading.
/// Identifiable so SwiftUI's `.sheet(item:)` correctly tracks it.
struct GPXPreviewPayload: Identifiable {
    let id = UUID()
    let url: URL
    let track: [CLLocation]
    let session: HRVSession
}

/// Map preview + summary stats + Send button. Send only invokes `onSend`;
/// the presenter dismisses the sheet (by clearing its payload) and opens the
/// system share sheet. Cancel just closes the preview without sharing.
struct GPXPreviewSheet: View {
    let payload: GPXPreviewPayload
    let onSend: () -> Void

    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            previewStack
                .navigationTitle(String(localized: "Preview", bundle: LanguageManager.appBundle))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { previewToolbar }
        }
    }

    private var previewStack: some View {
        VStack(spacing: 0) {
            mapView
                .frame(maxWidth: .infinity)
                .frame(height: 320)
            statsRow
                .padding(.horizontal, 16)
                .padding(.top, 16)
            fileInfo
                .padding(.horizontal, 16)
                .padding(.top, 12)
            Spacer()
        }
    }

    @ToolbarContentBuilder
    private var previewToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(String(localized: "Cancel", bundle: LanguageManager.appBundle)) { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) { sendGPXButton }
    }

    private var sendGPXButton: some View {
        Button {
            onSend()
        } label: {
            Label(String(localized: "Send", bundle: LanguageManager.appBundle), systemImage: "square.and.arrow.up")
        }
        .disabled(payload.track.isEmpty)
    }

    @ViewBuilder
    var mapView: some View {
        if payload.track.isEmpty {
            routeUnavailablePlaceholder
        } else {
            GPXPreviewMap(track: payload.track)
        }
    }

    private var routeUnavailablePlaceholder: some View {
        ZStack {
            Color.gray.opacity(0.15)
            VStack(spacing: 8) {
                Image(systemName: "map")
                    .scaledFont(size: 32)
                    .foregroundStyle(AppTheme.textSecondary)
                Text(String(localized: "No GPS points decoded", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    var statsRow: some View {
        let meta = payload.session.workoutMetadata
        let units = UnitsPreferenceStore.current
        let distanceText: String = {
            guard let m = meta?.distanceMeters, m > 0 else { return "—" }
            return units.formatDistance(meters: m)
        }()
        let durationText: String = {
            let secs = max(0, (payload.session.endDate ?? payload.session.startDate)
                .timeIntervalSince(payload.session.startDate))
            return LocalizedDuration.hoursMinutes(minutes: Int(secs / 60))
        }()
        HStack(spacing: 16) {
            statTile(icon: "ruler", label: String(localized: "Distance", bundle: LanguageManager.appBundle), value: distanceText)
            statTile(icon: "clock", label: String(localized: "Duration", bundle: LanguageManager.appBundle), value: durationText)
            statTile(icon: "point.bottomleft.forward.to.point.topright.scurvepath", label: String(localized: "Points", bundle: LanguageManager.appBundle), value: "\(payload.track.count)")
        }
    }

    func statTile(icon: String, label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.caption).accessibilityHidden(true)
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(AppTheme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.1)))
    }

    @ViewBuilder
    var fileInfo: some View {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: payload.url.path)[.size] as? Int64) ?? 0
        let sizeStr = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        VStack(alignment: .leading, spacing: 4) {
            Text(payload.url.lastPathComponent)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(String(localized: "\(sizeStr) · GPX format · compatible with Strava, Garmin Connect, WorkOutDoors", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Wraps MKMapView to render the GPX track polyline. Fits the camera to
/// the route once per track, so a parent re-render does not undo the
/// user's pan or zoom. Pure UIKit-bridge so we get the same map
/// rendering Apple/Strava users expect.
struct GPXPreviewMap: UIViewRepresentable {
    let track: [CLLocation]

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.pointOfInterestFilter = .excludingAll
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        guard !context.coordinator.isShowing(track) else { return }
        context.coordinator.renderedTrack = track
        map.removeOverlays(map.overlays)
        guard !track.isEmpty else { return }
        let coords = track.map(\.coordinate)
        let polyline = MKPolyline(coordinates: coords, count: coords.count)
        map.addOverlay(polyline)
        map.setVisibleMapRect(Self.fittedRect(for: polyline), animated: false)
    }

    /// The route's bounds padded by 15 % of the longer side, and by at least
    /// 250 m: a one-point track has a zero-size rect that would otherwise zoom
    /// to the maximum.
    static func fittedRect(for polyline: MKPolyline) -> MKMapRect {
        let rect = polyline.boundingMapRect
        let minimumPadding = MKMapPointsPerMeterAtLatitude(polyline.coordinate.latitude) * 250
        let padding = max(max(rect.size.width, rect.size.height) * 0.15, minimumPadding)
        return rect.insetBy(dx: -padding, dy: -padding)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MKMapViewDelegate {
        /// The track last drawn, so updates for the same track leave the map alone.
        var renderedTrack: [CLLocation]?

        func isShowing(_ track: [CLLocation]) -> Bool {
            guard let renderedTrack else { return false }
            return renderedTrack.elementsEqual(track) { $0 === $1 }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 4
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
