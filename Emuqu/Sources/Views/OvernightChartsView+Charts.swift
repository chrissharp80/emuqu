import SwiftUI

// MARK: - Stat Card

struct OvernightStatCard: View {
    let title: String
    let value: String
    let unit: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)

            valueAndUnit

            Text(subtitle)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(AppTheme.sectionTint)
        .cornerRadius(AppTheme.smallCornerRadius)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)\(unit.isEmpty ? "" : " \(unit)"), \(subtitle)")
    }

    private var valueAndUnit: some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(.title2, design: .rounded).bold())
                .foregroundColor(color)
            Text(unit)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
    }
}

// MARK: - Interactive Chart Tooltip

struct ChartTooltip: View {
    let value: String
    let unit: String
    let time: String
    let color: Color

    @ViewBuilder
    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.headline, design: .rounded).bold())
                    .foregroundColor(color)
                Text(unit)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textSecondary)
            }
            Text(time)
                .font(.caption2.bold())
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        )
    }
}

// MARK: - HR Chart Canvas

struct OvernightHRChartCanvas: View {
    let session: HRVSession
    let result: HRVAnalysisResult
    let stats: OvernightStats
    var healthKitSleep: SleepData?

    @State private var touchLocation: CGPoint?
    @State private var isDragging = false

    // Reserve space for X-axis labels
    private let xAxisHeight: CGFloat = 20

    // Pre-computed render constants. Allocating these
    // inside the Canvas closure on every redraw (orientation
    // change, drag tooltip update, scroll-into-view), which on a chart
    // that already iterates thousands of HR points per frame multiplied
    // the cost. Hoisting them to instance-level lets means the Gradient
    // and Color instances persist for the view's lifetime.
    private let hkAreaGradient = Gradient(colors: [
        AppTheme.terracotta.opacity(0.15),
        AppTheme.terracotta.opacity(0.02)
    ])
    private let hkStrokeColor = AppTheme.terracotta.opacity(0.4)
    private let hrAreaGradient = Gradient(colors: [
        AppTheme.terracotta.opacity(0.3),
        AppTheme.terracotta.opacity(0.05)
    ])

    var body: some View {
        GeometryReader { geo in
            let chartHeight = geo.size.height - xAxisHeight
            ZStack {
                chartStack(chartHeight: chartHeight, width: geo.size.width)
                touchOverlay(touch: touchLocation, chartHeight: chartHeight, geo: geo)
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture)
        }
    }

    /// The canvas with its x-axis time labels beneath.
    private func chartStack(chartHeight: CGFloat, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            chartCanvas(size: CGSize(width: width, height: chartHeight))
                .frame(height: chartHeight)

            OvernightChartDrawing.xAxisLabels(session: session, stats: stats, width: width)
                .frame(height: xAxisHeight)
        }
    }

    @ViewBuilder
    private func touchOverlay(touch: CGPoint?, chartHeight: CGFloat, geo: GeometryProxy) -> some View {
        if let touch, isDragging {
            // Vertical indicator line
            Rectangle()
                .fill(Color.white.opacity(0.8))
                .frame(width: 1, height: chartHeight)
                .position(x: touch.x, y: chartHeight / 2)

            // Tooltip
            if let (hr, time) = hrAtLocation(touch.x, size: CGSize(width: geo.size.width, height: chartHeight)) {
                ChartTooltip(
                    value: String(format: "%.0f", locale: LanguageManager.appLocale, hr),
                    unit: String(localized: "bpm", bundle: LanguageManager.appBundle),
                    time: time,
                    color: AppTheme.terracotta
                )
                .position(x: OvernightChartDrawing.tooltipX(touch.x, size: geo.size), y: 30)
            }
        }
    }

    /// Time runs left to right, so the scrub follows horizontal drags and
    /// ignores mostly-vertical ones, which belong to the page scroll (the
    /// same rule as the HRV chart).
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(value.translation.height) <= abs(value.translation.width) * 2 else { return }
                touchLocation = value.location
                isDragging = true
            }
            .onEnded { _ in
                isDragging = false
                touchLocation = nil
            }
    }

    /// The HR sample nearest the scrub position, from whichever source is
    /// closer in time, with its wall-clock label.
    ///
    /// Reuses the cached formatter — this runs per scrub frame,
    /// and allocating a DateFormatter each time was tooltip jank.
    private func hrAtLocation(_ x: CGFloat, size: CGSize) -> (Double, String)? {
        let firstMs = stats.chartStartMs
        let totalDurationMs = stats.chartEndMs - firstMs
        guard totalDurationMs > 0 else { return nil }
        let targetMs = firstMs + Int64(Double(totalDurationMs) * Double(x / size.width))
        let formatter = OvernightChartFormatters.clockTimeFormatter
        let polar = nearestPolarSample(toMs: targetMs)
        let hk = nearestHealthKitSample(toMs: targetMs)
        switch (polar, hk) {
        case let (p?, h?):
            return p.dist <= h.dist
                ? (p.hr, formatter.string(from: p.time))
                : (h.hr, formatter.string(from: h.time))
        case let (p?, nil):
            return (p.hr, formatter.string(from: p.time))
        case let (nil, h?):
            return (h.hr, formatter.string(from: h.time))
        case (nil, nil):
            return nil
        }
    }

    /// Closest Polar RR-derived HR sample by timestamp.
    private func nearestPolarSample(toMs targetMs: Int64) -> (hr: Double, dist: Int64, time: Date)? {
        guard let series = session.rrSeries else { return nil }
        let points = series.points
        let touchHR = stats.allHrValues.isEmpty ? stats.hrValues : stats.allHrValues
        var closest: (hr: Double, dist: Int64, time: Date)?
        for (index, hr) in touchHR {
            guard index < points.count else { continue }
            let dist = abs(points[index].t_ms - targetMs)
            guard closest.map({ dist < $0.dist }) ?? true else { continue }
            closest = (hr, dist, series.absoluteTimeWallClock(at: index) ?? series.startDate)
        }
        return closest
    }

    /// Closest HealthKit HR sample by timestamp.
    private func nearestHealthKitSample(toMs targetMs: Int64) -> (hr: Double, dist: Int64, time: Date)? {
        var closest: (hr: Double, dist: Int64, time: Date)?
        for sample in stats.healthKitHR {
            let dist = abs(sample.timeMs - targetMs)
            guard closest.map({ dist < $0.dist }) ?? true else { continue }
            let time = session.startDate.addingTimeInterval(Double(sample.timeMs) / 1000.0)
            closest = (sample.hr, dist, time)
        }
        return closest
    }

    /// A chart is a sequence of draw passes over one shared geometry, so the
    /// passes are named functions and the geometry is a value computed once
    /// per frame.
    private func chartCanvas(size: CGSize) -> some View {
        Canvas { context, size in
            guard let geo = HRChartGeometry(
                size: size,
                stats: stats,
                points: session.rrSeries?.points ?? []
            ) else { return }
            drawWindowHighlight(&context, geo)
            OvernightChartDrawing.drawSleepSegments(&context, geo, stats: stats)
            OvernightChartDrawing.drawGrid(&context, geo)
            drawHealthKitHR(&context, geo)
            drawPolarHR(&context, geo)
            drawNadirMarker(&context, geo)
            drawAxisLabels(&context, geo)
        }
    }

    /// Everything the HR draw passes share. Nil when there's nothing to plot.
    ///
    /// This must not bail whenever the Polar RR series is
    /// missing/empty. For overnight-crashed sessions the RR series is
    /// sometimes empty (the recovery path reconstructs sleep + HK HR but
    /// can't always rebuild RR), so the user saw a totally blank HR chart even
    /// though HK HR data WAS available via the gap-fill in
    /// OvernightChartsView. Now it bails only when BOTH sources are empty; the
    /// Polar pass is gated on `points` being non-empty on its own.
    private struct HRChartGeometry: OvernightChartViewport {
        let size: CGSize
        let points: [RRPoint]
        /// Full-recording HR for plotting — no gaps from sleep-boundary filtering.
        let plotHR: [(Int, Double)]
        let healthKitHR: [(timeMs: Int64, hr: Double)]
        /// Chart viewport: the extended range covering the HealthKit sleep envelope.
        let firstMs: Int64
        let totalDurationMs: Int64
        let minY: Double
        let maxY: Double
        let yRange: Double
        let windowStartX: CGFloat
        let windowEndX: CGFloat
        /// True when the window covers essentially the whole recording, or
        /// when there's no window to draw at all.
        let windowIsFullRecording: Bool

        init?(size: CGSize, stats: OvernightStats, points: [RRPoint]) {
            let plotHR = stats.allHrValues.isEmpty ? stats.hrValues : stats.allHrValues
            guard !plotHR.isEmpty || !stats.healthKitHR.isEmpty else { return nil }
            guard let range = Self.yRange(plotHR: plotHR, healthKitHR: stats.healthKitHR) else { return nil }
            self.size = size
            self.points = points
            self.plotHR = plotHR
            healthKitHR = stats.healthKitHR
            minY = range.min
            maxY = range.max
            yRange = range.max - range.min
            firstMs = stats.chartStartMs
            totalDurationMs = stats.chartEndMs - stats.chartStartMs
            let window = Self.windowBounds(stats: stats, size: size, totalPoints: points.count, firstMs: firstMs, totalDurationMs: totalDurationMs)
            windowStartX = window.startX
            windowEndX = window.endX
            windowIsFullRecording = window.isFull
        }

        /// Y-axis range combining both data sources, padded by 5 bpm. Nil when
        /// both came up empty or degenerate — bail rather than divide by zero.
        private static func yRange(
            plotHR: [(Int, Double)],
            healthKitHR: [(timeMs: Int64, hr: Double)]
        ) -> (min: Double, max: Double)? {
            var lo = plotHR.min(by: { $0.1 < $1.1 })?.1 ?? .infinity
            var hi = plotHR.max(by: { $0.1 < $1.1 })?.1 ?? -.infinity
            if !healthKitHR.isEmpty {
                lo = min(lo, healthKitHR.min(by: { $0.hr < $1.hr })?.hr ?? lo)
                hi = max(hi, healthKitHR.max(by: { $0.hr < $1.hr })?.hr ?? hi)
            }
            guard lo.isFinite, hi.isFinite, hi > lo else { return nil }
            return (lo - 5, hi + 5)
        }

        /// The analysis window's horizontal bounds, preferring wall-clock
        /// positioning and falling back to point indices. A crash-recovered
        /// HK-only session has neither, so the highlight is skipped entirely.
        private static func windowBounds(
            stats: OvernightStats,
            size: CGSize,
            totalPoints: Int,
            firstMs: Int64,
            totalDurationMs: Int64
        ) -> (startX: CGFloat, endX: CGFloat, isFull: Bool) {
            if totalDurationMs > 0, stats.windowStartMs != stats.windowEndMs {
                let startFraction = CGFloat(stats.windowStartMs - firstMs) / CGFloat(totalDurationMs)
                let endFraction = CGFloat(stats.windowEndMs - firstMs) / CGFloat(totalDurationMs)
                return (
                    max(0, startFraction) * size.width,
                    min(1, endFraction) * size.width,
                    (endFraction - startFraction) > 0.8
                )
            }
            guard totalPoints > 0 else { return (0, 0, true) }
            let indexFraction = CGFloat(stats.windowEndIndex - stats.windowStartIndex) / CGFloat(totalPoints)
            return (
                CGFloat(stats.windowStartIndex) / CGFloat(totalPoints) * size.width,
                CGFloat(stats.windowEndIndex) / CGFloat(totalPoints) * size.width,
                indexFraction > 0.8
            )
        }

        /// Horizontal position of a wall-clock offset.
        func x(forMs ms: Int64) -> CGFloat {
            guard totalDurationMs > 0 else { return 0 }
            return CGFloat(ms - firstMs) / CGFloat(totalDurationMs) * size.width
        }

        /// Vertical position of a heart rate.
        func y(forHR hr: Double) -> CGFloat {
            size.height - CGFloat((hr - minY) / yRange) * size.height
        }
    }

    /// The analysis window, drawn only when it's meaningfully smaller than the
    /// full recording.
    private func drawWindowHighlight(_ context: inout GraphicsContext, _ geo: HRChartGeometry) {
        guard !geo.windowIsFullRecording else { return }
        let windowRect = CGRect(
            x: geo.windowStartX, y: 0,
            width: geo.windowEndX - geo.windowStartX, height: geo.size.height
        )
        context.fill(Path(windowRect), with: .color(AppTheme.primary.opacity(0.2)))
        for x in [geo.windowStartX, geo.windowEndX] {
            context.stroke(
                verticalLine(atX: x, height: geo.size.height),
                with: .color(AppTheme.primary.opacity(0.8)),
                lineWidth: 2
            )
        }
        drawWindowLabel(&context, geo)
    }

    /// The pill showing the window's clock range.
    private func drawWindowLabel(_ context: inout GraphicsContext, _ geo: HRChartGeometry) {
        guard !stats.windowStartTimeFormatted.isEmpty || !stats.windowEndTimeFormatted.isEmpty else { return }
        let timeRangeText = Text("\(stats.windowStartTimeFormatted) - \(stats.windowEndTimeFormatted)")
            .font(.caption.weight(.bold))
            .foregroundColor(.white)
        OvernightChartDrawing.drawPill(
            &context, text: timeRangeText, centerX: (geo.windowStartX + geo.windowEndX) / 2,
            top: 4, canvasWidth: geo.size.width, color: AppTheme.primary.opacity(0.9)
        )
    }

    /// Apple Watch HR for the segments Polar didn't cover — lighter, dashed.
    /// A 10-minute gap threshold, since Watch samples are sparser.
    private func drawHealthKitHR(_ context: inout GraphicsContext, _ geo: HRChartGeometry) {
        guard !geo.healthKitHR.isEmpty, geo.totalDurationMs > 0 else { return }
        let segments = splitIntoSegments(
            geo.healthKitHR.map { (ms: $0.timeMs, hr: $0.hr) },
            gapThresholdMs: 600_000,
            geo: geo
        )
        for seg in segments where seg.count >= 2 {
            let (linePath, fillPath) = areaPaths(seg, height: geo.size.height)
            context.fill(
                fillPath,
                with: .linearGradient(hkAreaGradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: geo.size.height))
            )
            context.stroke(linePath, with: .color(hkStrokeColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    /// The Polar HR trace, gap-aware so a split night doesn't get a line drawn
    /// across the hours the strap was off.
    ///
    /// `hrAreaGradient` is hoisted to instance scope — otherwise it
    /// is a fresh Gradient per Canvas redraw.
    private func drawPolarHR(_ context: inout GraphicsContext, _ geo: HRChartGeometry) {
        let samples: [(ms: Int64, hr: Double)] = geo.plotHR.compactMap { index, hr in
            guard index >= 0, index < geo.points.count, geo.totalDurationMs > 0 else { return nil }
            return (geo.points[index].t_ms, hr)
        }
        for seg in splitIntoSegments(samples, gapThresholdMs: 300_000, geo: geo) where seg.count >= 2 {
            let (linePath, fillPath) = areaPaths(seg, height: geo.size.height)
            context.fill(
                fillPath,
                with: .linearGradient(hrAreaGradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: geo.size.height))
            )
            context.stroke(linePath, with: .color(AppTheme.terracotta), lineWidth: 1.5)
        }
    }

    /// Project timestamped HR samples into chart points, breaking the run
    /// wherever more than `gapThresholdMs` passed between samples.
    private func splitIntoSegments(
        _ samples: [(ms: Int64, hr: Double)],
        gapThresholdMs: Int64,
        geo: HRChartGeometry
    ) -> [[CGPoint]] {
        var segments: [[CGPoint]] = [[]]
        var lastMs: Int64 = -1
        for sample in samples {
            if lastMs >= 0, sample.ms - lastMs > gapThresholdMs { segments.append([]) }
            segments[segments.count - 1].append(
                CGPoint(x: geo.x(forMs: sample.ms), y: geo.y(forHR: sample.hr))
            )
            lastMs = sample.ms
        }
        return segments
    }

    /// The stroked line and the closed fill beneath it for one segment.
    private func areaPaths(_ seg: [CGPoint], height: CGFloat) -> (line: Path, fill: Path) {
        // Both current callers filter `where seg.count >= 2`, but `seg[0]`
        // below would crash if a third appeared without it. Empty paths draw
        // nothing, which is the right answer for an empty segment.
        guard seg.count > 1 else { return (Path(), Path()) }

        var linePath = Path()
        linePath.move(to: seg[0])
        for i in 1 ..< seg.count { linePath.addLine(to: seg[i]) }
        var fillPath = linePath
        fillPath.addLine(to: CGPoint(x: (seg.last ?? seg[0]).x, y: height))
        fillPath.addLine(to: CGPoint(x: seg[0].x, y: height))
        fillPath.closeSubpath()
        return (linePath, fillPath)
    }

    /// Dashed vertical line, circle, and value label at the night's HR nadir.
    private func drawNadirMarker(_ context: inout GraphicsContext, _ geo: HRChartGeometry) {
        let nadirX = geo.x(forMs: stats.nadirTimeMs)
        let nadirY = geo.y(forHR: stats.nadirHR)
        context.stroke(
            verticalLine(atX: nadirX, height: geo.size.height),
            with: .color(AppTheme.mist.opacity(0.5)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
        )
        let nadirCircle = Path(ellipseIn: CGRect(x: nadirX - 6, y: nadirY - 6, width: 12, height: 12))
        context.fill(nadirCircle, with: .color(AppTheme.mist))
        context.stroke(nadirCircle, with: .color(.white), lineWidth: 2)
        let nadirText = Text("\(Int(stats.nadirHR))")
            .font(.caption.bold())
            .foregroundColor(AppTheme.mist)
        context.draw(nadirText, at: CGPoint(x: nadirX, y: nadirY - 16))
    }

    private func drawAxisLabels(_ context: inout GraphicsContext, _ geo: HRChartGeometry) {
        context.draw(
            Text("\(Int(geo.maxY))").font(.caption2).foregroundColor(.gray),
            at: CGPoint(x: 15, y: 8)
        )
        context.draw(
            Text("\(Int(geo.minY))").font(.caption2).foregroundColor(.gray),
            at: CGPoint(x: 15, y: geo.size.height - 22)
        )
    }

    /// A full-height vertical line at `x`.
    private func verticalLine(atX x: CGFloat, height: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: height))
        return path
    }
}
