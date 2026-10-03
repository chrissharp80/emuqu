import CoreLocation
import MapKit
import SwiftUI

/// The 9:16 social-shareable artifact for workouts and
/// recovery scores. Long-press the score ring → "Share recovery card."
/// Workout summary has "Share Recap Card" in the share sheet.
///
/// Critical: designed to be beautiful out-of-the-box without filters. This
/// is the screenshot-worthy moment that gets the app on Instagram. It is
/// the primary growth vector.
///
/// Two variants:
///   • `.recovery(score, verdict, date)`   — recovery score reveal
///   • `.workout(distance, duration, pace, polyline, verdict, summary, date)` — post-workout
///
/// Render with `ImageRenderer` at scale 1 to get a 1080×1920 PNG for the
/// share sheet's image target.
struct RecapCard: View {
    // The hard-coded `.font(.system(size: N))` literals in
    // this file are DELIBERATE and are exempt from the Dynamic
    // Type migration that put the on-screen detail views on `@ScaledMetric`.
    //
    // `RecapCard` is not on-screen UI: it renders offscreen to a fixed
    // 1080×1920 PNG for the share sheet. A shared image must look identical
    // regardless of the sharer's text-size setting, so scaling these would make
    // the exported artwork reflow unpredictably — the layout is pinned to the
    // pixel canvas, not to the reader's preferences.

    enum Variant {
        case recovery(score: Int, verdict: ScoreVerdict, date: Date)
        case workout(
            distance: String,
            duration: String,
            pace: String,
            verdict: String,
            summary: String,
            date: Date,
            /// Optional pre-rendered route map snapshot (build via
            /// `RecapCard.renderRouteMap(_:)`). When nil, the workout
            /// variant falls back to a gradient strip.
            routeMap: UIImage? = nil
        )
    }

    let variant: Variant

    /// The card is laid out on a 360×640 pt canvas (the point sizes below are
    /// designed for it). `renderImage()` draws it at ×3, so the PNG is a full
    /// 1080×1920 on any device.
    static let layoutSize = CGSize(width: 360, height: 640)
    static let exportSize = CGSize(width: 1080, height: 1920)

    var body: some View {
        cardContent
            .frame(width: Self.layoutSize.width, height: Self.layoutSize.height)
    }

    @ViewBuilder
    private var cardContent: some View {
        switch variant {
        case let .recovery(score, verdict, date):
            recoveryCard(score: score, verdict: verdict, date: date)
        case let .workout(distance, duration, pace, verdict, summary, date, routeMap):
            workoutCard(
                distance: distance,
                duration: duration,
                pace: pace,
                verdict: verdict,
                summary: summary,
                date: date,
                routeMap: routeMap
            )
        }
    }

    /// Static, no-state-animation score ring used by the
    /// recap card capture path. ScoreRing in the live dashboard
    /// animates `displayedScore` from 0 to the target; ImageRenderer
    /// captures before the animation lands. This version renders both
    /// the filled stroke AND the numeric label at their final values
    /// on the first frame, suitable for instant snapshot.
    @ViewBuilder
    private func staticScoreRing(score: Int, verdict: ScoreVerdict) -> some View {
        let fraction = max(0, min(1, Double(score) / 100.0))
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 14)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(verdict.color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text(verbatim: "\(score)")
                    .font(.system(size: 96, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                Text(verbatim: verdict.localizedWord)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(verdict.color)
                    .textCase(.uppercase)
                    .tracking(1.5)
            }
        }
    }

    // MARK: - Recovery variant

    private func recoveryCard(score: Int, verdict: ScoreVerdict, date: Date) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.06, blue: 0.10),
                    verdict.color.opacity(0.40)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            recoveryCardStack(score: score, verdict: verdict, date: date)
        }
    }

    /// The live ScoreRing would render "0" in the captured PNG because
    /// `ImageRenderer` snapshots the view before ScoreRing's `@State
    /// displayedScore` finishes its animation from 0 → target. The ring is
    /// `@State`-animated by design (the live dashboard wants the reveal); a
    /// static screenshot needs the final state immediately. Inline a
    /// non-animated equivalent here instead of fighting ScoreRing's lifecycle.
    private func recoveryCardStack(score: Int, verdict: ScoreVerdict, date: Date) -> some View {
        VStack(spacing: 28) {
            Spacer()
            Text(verbatim: "EMUQU")
                .font(.system(size: 14, weight: .semibold))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.65))
            staticScoreRing(score: score, verdict: verdict)
                .frame(width: 280, height: 280)
            recoveryVerdictText(verdict)
            Spacer()
            Text(verbatim: dateFormatted(date))
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 40)
        }
    }

    private func recoveryVerdictText(_ verdict: ScoreVerdict) -> some View {
        VStack(spacing: 20) {
            Text(verbatim: verdict.localizedWord)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white)
            Text(verbatim: verdict.localizedSubverdict)
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Workout variant

    private func workoutCard(distance: String, duration: String, pace: String, verdict: String, summary: String, date: Date, routeMap: UIImage?) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.06, blue: 0.10), Color(red: 0.10, green: 0.14, blue: 0.18)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 0) {
                routePanel(routeMap: routeMap)
                headlinePanel(distance: distance, duration: duration, pace: pace, verdict: verdict)
                summaryPanel(summary: summary, date: date)
            }
        }
    }

    /// Each of the three stacked panels gets exactly one third of the card.
    private var panelHeight: CGFloat { Self.layoutSize.height / 3 }

    /// Top 1/3 — route polyline on satellite map when available, fallback
    /// gradient otherwise.
    @ViewBuilder
    private func routePanel(routeMap: UIImage?) -> some View {
        if let routeMap {
            Image(uiImage: routeMap)
                .resizable()
                .scaledToFill()
                .clipped()
                .overlay(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.45)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(height: panelHeight)
        } else {
            Rectangle()
                .fill(LinearGradient(
                    colors: [AppTheme.primary.opacity(0.7), AppTheme.primary.opacity(0.3)],
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(height: panelHeight)
        }
    }

    /// Middle 1/3 — distance huge, then duration / pace, then verdict pill.
    private func headlinePanel(distance: String, duration: String, pace: String, verdict: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Text(verbatim: distance)
                .font(.system(size: 96, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 20)
                .foregroundStyle(.white)
            HStack(spacing: 24) {
                statColumn(value: duration, caption: String(localized: "Time", bundle: LanguageManager.appBundle))
                statColumn(value: pace, caption: String(localized: "Pace", bundle: LanguageManager.appBundle))
            }
            verdictPill(verdict)
            Spacer()
        }
        .frame(height: panelHeight)
    }

    private func statColumn(value: String, caption: String) -> some View {
        VStack {
            Text(verbatim: value).font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
            Text(caption).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        }
    }

    private func verdictPill(_ verdict: String) -> some View {
        Text(verbatim: verdict)
            .font(.system(size: 13, weight: .semibold))
            .tracking(2)
            .foregroundStyle(AppTheme.wongOptimal)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(Capsule().strokeBorder(AppTheme.wongOptimal.opacity(0.5), lineWidth: 1))
    }

    /// Bottom 1/3 — AI Coach summary + attribution.
    private func summaryPanel(summary: String, date: Date) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Text(verbatim: summary)
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .lineLimit(4)
            Spacer()
            attributionRow(date: date)
        }
        .frame(height: panelHeight)
    }

    private func attributionRow(date: Date) -> some View {
        HStack {
            Text(verbatim: "EMUQU")
                .font(.system(size: 12, weight: .semibold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(verbatim: dateFormatted(date))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
    }

    private func dateFormatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }
}

// MARK: - Render-to-PNG helper

@MainActor
extension RecapCard {
    /// Render the card to a 1080×1920 PNG suitable for a share sheet's
    /// image target.
    func renderImage() -> UIImage? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = Self.exportSize.width / Self.layoutSize.width
        return renderer.uiImage
    }

    /// Render a satellite-style map snapshot with a sport-coloured
    /// polyline overlay, sized to the workout-recap top third
    /// (1080 wide × 640 tall). Pass the resulting image into
    /// `Variant.workout(routeMap:)`.
    ///
    /// The polyline is drawn as a 6pt stroke in the supplied tint with
    /// a subtle outer glow so it stays legible against busy satellite
    /// imagery.
    static func renderRouteMap(
        coordinates: [CLLocationCoordinate2D],
        tint: UIColor
    ) async -> UIImage? {
        guard !coordinates.isEmpty, let options = snapshotOptions(for: coordinates) else { return nil }
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        return overlayRoute(coordinates, on: snapshot, tint: tint)
    }

    private static func overlayRoute(
        _ coordinates: [CLLocationCoordinate2D],
        on snapshot: MKMapSnapshotter.Snapshot,
        tint: UIColor
    ) -> UIImage {
        let image = snapshot.image
        return UIGraphicsImageRenderer(size: image.size).image { ctx in
            image.draw(at: .zero)
            drawRoute(coordinates.map { snapshot.point(for: $0) }, in: ctx.cgContext, tint: tint)
        }
    }

    /// Bounding region with a 12% padding margin so the polyline doesn't touch
    /// the edges.
    private static func snapshotOptions(for coordinates: [CLLocationCoordinate2D]) -> MKMapSnapshotter.Options? {
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return nil }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.001, (maxLat - minLat) * 1.24),
            longitudeDelta: max(0.001, (maxLon - minLon) * 1.24)
        )
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, span: span)
        options.size = CGSize(width: 1080, height: 640)
        options.scale = 1.0
        options.mapType = .satelliteFlyover
        options.showsBuildings = false
        return options
    }

    /// Black outer glow for legibility on satellite imagery, then the
    /// sport-coloured inner stroke on top.
    private static func drawRoute(_ points: [CGPoint], in cg: CGContext, tint: UIColor) {
        guard let first = points.first else { return }
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        for (width, color) in [(CGFloat(12), UIColor.black.withAlphaComponent(0.45)), (CGFloat(6), tint)] {
            cg.setLineWidth(width)
            cg.setStrokeColor(color.cgColor)
            cg.move(to: first)
            for p in points.dropFirst() { cg.addLine(to: p) }
            cg.strokePath()
        }
    }
}
