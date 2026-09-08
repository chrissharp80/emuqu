import CoreLocation
import Foundation
import MapKit
import UIKit

// MARK: - Workout PDF charts and map
//
// The alpha-1 timeline, the HR trace with its zone bands, and the route
// snapshot with its alpha-1-coloured polyline. Kept apart from
// WorkoutPDFReport+Pages.swift: with these in it, that file passes the
// 1000-line limit, and the charts are a self-contained half of it.
//
// Members are internal rather than private because Swift's `private` does
// not reach across files; same convention as PDFReportGenerator+Sections.

extension WorkoutPDFRenderer {
    /// Axis domain plus the two projection closures for the α1 chart. A struct
    /// rather than a 4-tuple — SwiftLint caps tuples at three, and these are
    /// read by name anyway.
    struct Alpha1ChartScales {
        let minY: Double
        let maxY: Double
        let px: (Double) -> CGFloat
        let py: (Double) -> CGFloat
    }

    func drawHRChart(in rect: CGRect, samples: [WorkoutSample]) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        fillChartFrame(rect)
        let raw: [(Double, Double)] = samples.compactMap { s in
            guard let hr = s.heartRate else { return nil }
            return (Double(s.offsetSec), Double(hr))
        }
        let points = Self.downsample(raw, target: Self.maxPDFPoints)
        guard points.count >= 2 else { return }

        let minY = max(40.0, (points.map(\.1).min() ?? 60) - 10)
        let maxY = min(Double(report.userMaxHR) + 10, (points.map(\.1).max() ?? 150) + 10)
        let minX = 0.0
        let maxX = points.map(\.0).max() ?? 1.0

        let plot = rect.insetBy(dx: 30, dy: 10)
        func px(_ x: Double) -> CGFloat { plot.minX + CGFloat((x - minX) / max(1, maxX - minX)) * plot.width }
        func py(_ y: Double) -> CGFloat { plot.maxY - CGFloat((y - minY) / max(1, maxY - minY)) * plot.height }
        drawHRZoneBands(plot: plot, minY: minY, maxY: maxY, py: py)
        drawHRCurve(ctx: ctx, points: points, px: px, py: py)
        drawHRYAxisTicks(plot: plot, minY: minY, maxY: maxY, py: py)
    }
    /// Karvonen-style bands behind the trace, so a reader can see which zone the
    /// line is sitting in without reading the axis.
    func drawHRZoneBands(plot: CGRect, minY: Double, maxY: Double, py: (Double) -> CGFloat) {
        // Zone bands
        let zones: [(lo: Double, hi: Double, color: UIColor)] = [
            (Double(report.userMaxHR) * 0.50, Double(report.userMaxHR) * 0.60, UIColor(red: 0.40, green: 0.80, blue: 0.55, alpha: 0.10)),
            (Double(report.userMaxHR) * 0.60, Double(report.userMaxHR) * 0.70, UIColor(red: 0.55, green: 0.85, blue: 0.45, alpha: 0.12)),
            (Double(report.userMaxHR) * 0.70, Double(report.userMaxHR) * 0.80, UIColor(red: 0.95, green: 0.80, blue: 0.30, alpha: 0.14)),
            (Double(report.userMaxHR) * 0.80, Double(report.userMaxHR) * 0.90, UIColor(red: 0.95, green: 0.55, blue: 0.25, alpha: 0.16)),
            (Double(report.userMaxHR) * 0.90, Double(report.userMaxHR) + 10, UIColor(red: 0.90, green: 0.35, blue: 0.35, alpha: 0.18))
        ]
        for z in zones {
            let yLo = py(max(minY, z.lo))
            let yHi = py(min(maxY, z.hi))
            let bandRect = CGRect(x: plot.minX, y: yHi, width: plot.width, height: yLo - yHi)
            z.color.setFill()
            UIBezierPath(rect: bandRect).fill()
        }
    }
    func drawHRCurve(ctx: CGContext, points: [(Double, Double)], px: (Double) -> CGFloat, py: (Double) -> CGFloat) {
        // HR curve
        ctx.setStrokeColor(report.config.primary.cgColor)
        ctx.setLineWidth(2.0)
        let path = UIBezierPath()
        for (i, pt) in points.enumerated() {
            let cgp = CGPoint(x: px(pt.0), y: py(pt.1))
            if i == 0 { path.move(to: cgp) } else { path.addLine(to: cgp) }
        }
        path.stroke()
    }
    func drawHRYAxisTicks(plot: CGRect, minY: Double, maxY: Double, py: (Double) -> CGFloat) {
        // Y axis ticks
        let ticks = stride(from: Double(Int(minY / 25.0) * 25), through: maxY, by: 25.0)
        for t in ticks {
            drawText("\(Int(t))", at: CGPoint(x: plot.minX - 22, y: py(t) - 5), font: report.config.captionFont, color: report.config.textTertiary)
        }
    }
    /// Panel background plus its hairline border — the same frame every chart
    /// on these pages draws before plotting anything.
    func fillChartFrame(_ rect: CGRect) {
        UIColor(white: 0.98, alpha: 1.0).setFill()
        UIBezierPath(rect: rect).fill()
        report.config.divider.setStroke()
        UIBezierPath(rect: rect).stroke()
    }
    /// α1 timeline drawn directly into the PDF context. Downsamples the
    /// raw ~1 Hz series to at most `maxPDFPoints` samples — a 63-min walk
    /// generates ~3 700 α1 readings, but on a printed A4/US-Letter chart
    /// no reader can distinguish more than ~400 points. Bucket-averaging
    /// down from 3 700 → 400 is ~9× faster to draw and indistinguishable
    /// visually.
    func drawAlpha1Chart(in rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let points = alpha1ChartPoints()
        guard points.count >= 2 else {
            drawText(String(localized: "No α1 data available.", bundle: LanguageManager.appBundle), at: rect.origin, font: report.config.captionFont, color: report.config.textTertiary)
            return
        }
        fillChartFrame(rect)
        let plot = rect.insetBy(dx: 40, dy: 24)
        let scales = alpha1ChartScales(points: points, plot: plot)
        let (minY, maxY, px, py) = (scales.minY, scales.maxY, scales.px, scales.py)
        drawAlpha1Grid(ctx: ctx, plot: plot, minY: minY, maxY: maxY, py: py)
        drawAlpha1Thresholds(ctx: ctx, plot: plot, py: py)
        strokeAlpha1Curve(ctx: ctx, points: points, px: px, py: py)
        drawText(String(localized: "Seconds from start", bundle: LanguageManager.appBundle), at: CGPoint(x: plot.midX - 40, y: plot.maxY + 6), font: report.config.captionFont, color: report.config.textTertiary)
    }
    /// α1 series, bucket-averaged down to at most `maxPDFPoints`.
    func alpha1ChartPoints() -> [(Double, Double)] {
        let samples = report.session.workoutMetadata?.samples ?? []
        let raw: [(x: Double, y: Double)] = samples.compactMap { s in
            guard let a = s.alpha1 else { return nil }
            return (Double(s.offsetSec), a)
        }
        return Self.downsample(raw, target: Self.maxPDFPoints)
    }
    /// Axis domain and the two projection closures. α1 is clamped to a
    /// 0.3–1.3 minimum window so a flat report.session still shows the thresholds.
    func alpha1ChartScales(
        points: [(Double, Double)],
        plot: CGRect
    ) -> Alpha1ChartScales {
        let minX = 0.0
        let maxX = points.map(\.0).max() ?? 1.0
        let minY = min(0.3, (points.map(\.1).min() ?? 0.5) - 0.1)
        let maxY = max(1.3, (points.map(\.1).max() ?? 1.0) + 0.15)
        let xRange = max(1, maxX - minX)
        let yRange = max(0.1, maxY - minY)
        return Alpha1ChartScales(
            minY: minY, maxY: maxY,
            px: { plot.minX + CGFloat(($0 - minX) / xRange) * plot.width },
            py: { plot.maxY - CGFloat(($0 - minY) / yRange) * plot.height }
        )
    }
    /// Horizontal grid at the α1 values a reader actually looks for.
    func drawAlpha1Grid(ctx: CGContext, plot: CGRect, minY: Double, maxY: Double, py: (Double) -> CGFloat) {
        // Y-axis grid lines at 0.5 / 0.75 / 1.0 / 1.5
        let gridYs: [Double] = [0.5, 0.75, 1.0, 1.5].filter { $0 >= minY && $0 <= maxY }
        for gy in gridYs {
            ctx.setStrokeColor(report.config.divider.cgColor)
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: plot.minX, y: py(gy)))
            ctx.addLine(to: CGPoint(x: plot.maxX, y: py(gy)))
            ctx.strokePath()
            drawText(String(format: "%.2f", locale: .current, gy), at: CGPoint(x: plot.minX - 32, y: py(gy) - 5), font: report.config.captionFont, color: report.config.textTertiary)
        }
    }
    /// The AT1 and AT2 dashed reference lines, with their labels.
    func drawAlpha1Thresholds(ctx: CGContext, plot: CGRect, py: (Double) -> CGFloat) {
        // AT1 line
        ctx.setStrokeColor(report.config.sage.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.move(to: CGPoint(x: plot.minX, y: py(0.75)))
        ctx.addLine(to: CGPoint(x: plot.maxX, y: py(0.75)))
        ctx.strokePath()
        drawText(String(localized: "AT1 · aerobic threshold", bundle: LanguageManager.appBundle), at: CGPoint(x: plot.minX + 4, y: py(0.75) - 12), font: report.config.captionFont, color: report.config.sage)

        // AT2 line
        ctx.setStrokeColor(UIColor.orange.cgColor)
        ctx.move(to: CGPoint(x: plot.minX, y: py(0.5)))
        ctx.addLine(to: CGPoint(x: plot.maxX, y: py(0.5)))
        ctx.strokePath()
        drawText(String(localized: "AT2 · anaerobic threshold", bundle: LanguageManager.appBundle), at: CGPoint(x: plot.minX + 4, y: py(0.5) - 12), font: report.config.captionFont, color: .orange)
        ctx.setLineDash(phase: 0, lengths: [])
    }
    func strokeAlpha1Curve(ctx: CGContext, points: [(Double, Double)], px: (Double) -> CGFloat, py: (Double) -> CGFloat) {
        // α1 curve
        ctx.setStrokeColor(report.config.dustyRose.cgColor)
        ctx.setLineWidth(2.0)
        let path = UIBezierPath()
        for (i, pt) in points.enumerated() {
            let cgp = CGPoint(x: px(pt.0), y: py(pt.1))
            if i == 0 { path.move(to: cgp) } else { path.addLine(to: cgp) }
        }
        path.stroke()

    }
    /// Overlay the GPS polyline onto the map image rect, segment-coloured by
    /// α1 band. Draws in the current graphics context (caller has already
    /// placed the mapImage into `rect`).
    func drawColouredPolyline(in rect: CGRect) {
        guard report.track.count >= 2, let point = trackProjection(in: rect) else { return }
        let band = alphaBandLookup()
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        cg.setLineWidth(3.0)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        for i in 1 ..< report.track.count {
            let a = report.track[i - 1], b = report.track[i]
            let offset = Int(b.timestamp.timeIntervalSince(report.session.startDate).rounded())
            cg.setStrokeColor(band(offset).withAlphaComponent(0.95).cgColor)
            cg.move(to: point(a.coordinate))
            cg.addLine(to: point(b.coordinate))
            cg.strokePath()
        }
    }
    /// Maps a coordinate into `rect`, using the same region padding as
    /// `mapSnapshotOptions` so the line lands on the tiles it was drawn for.
    func trackProjection(in rect: CGRect) -> ((CLLocationCoordinate2D) -> CGPoint)? {
        let coords = report.track.map(\.coordinate)
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return nil }
        let padLat = max((maxLat - minLat) * 0.2, 0.003 * 0.5)
        let padLon = max((maxLon - minLon) * 0.2, 0.003 * 0.5)
        let dispMinLat = minLat - padLat, dispMaxLat = maxLat + padLat
        let dispMinLon = minLon - padLon, dispMaxLon = maxLon + padLon
        let latRange = max(1e-6, dispMaxLat - dispMinLat)
        let lonRange = max(1e-6, dispMaxLon - dispMinLon)
        return { c in
            let nx = (c.longitude - dispMinLon) / lonRange
            let ny = 1.0 - (c.latitude - dispMinLat) / latRange
            return CGPoint(x: rect.minX + CGFloat(nx) * rect.width, y: rect.minY + CGFloat(ny) * rect.height)
        }
    }
    /// Nearest-preceding α1 sample for a given offset, mapped to its band
    /// colour. Grey when no sample precedes the point.
    func alphaBandLookup() -> (Int) -> UIColor {
        // α1 lookup keyed by sample offset.
        let samples = report.session.workoutMetadata?.samples ?? []
        let alphaByOffset: [Int: Double] = samples.reduce(into: [:]) { acc, s in
            if let a = s.alpha1 { acc[s.offsetSec] = a }
        }
        let sortedOffsets = alphaByOffset.keys.sorted()
        let fallback = report.config.textTertiary
        let sage = report.config.sage
        return { offsetSec in
            guard let a = Self.nearestPreceding(offsetSec, in: sortedOffsets, values: alphaByOffset) else {
                return fallback
            }
            return Self.bandColor(a, sage: sage)
        }
    }

    private static func nearestPreceding(_ offsetSec: Int, in sortedOffsets: [Int], values: [Int: Double]) -> Double? {
        var nearest: Double?
        for off in sortedOffsets {
            guard off <= offsetSec else { break }
            nearest = values[off]
        }
        return nearest
    }

    /// ≥0.75 aerobic (sage), ≥0.50 threshold (yellow), below that anaerobic.
    private static func bandColor(_ alpha1: Double, sage: UIColor) -> UIColor {
        if alpha1 >= 0.75 { return sage }
        if alpha1 >= 0.50 { return .systemYellow }
        return .orange
    }
    /// Render an MKMapSnapshot for the report.track area. Returns nil when there's
    /// no report.track to snapshot.
    ///
    /// Scale dropped from 2.0 → 1.0 and dimensions halved: at the PDF's
    /// print density these pixels get resampled anyway, and the tile
    /// rendering was the dominant latency in the generator (~1.5 s at
    /// scale 2.0). Halving both dimensions × halving scale cut snapshot
    /// time to under ~300 ms on a typical walk's bounding box — a
    /// roughly 5× speedup with no visible quality loss in the printed
    /// output.
    func renderMapSnapshot() async -> UIImage? {
        guard let options = mapSnapshotOptions() else { return nil }
        let snapshotter = MKMapSnapshotter(options: options)
        return await withCheckedContinuation { cont in
            snapshotter.start { snapshot, _ in
                cont.resume(returning: snapshot?.image)
            }
        }
    }
    /// Region and raster size for the snapshot; nil when there is no report.track.
    func mapSnapshotOptions() -> MKMapSnapshotter.Options? {
        guard !report.track.isEmpty else { return nil }
        let coords = report.track.map(\.coordinate)
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return nil }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let latDelta = max((maxLat - minLat) * 1.4, 0.003)
        let lonDelta = max((maxLon - minLon) * 1.4, 0.003)
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
        options.size = CGSize(width: 540, height: 420)
        options.scale = 1.0
        options.mapType = .standard
        return options
    }
}
