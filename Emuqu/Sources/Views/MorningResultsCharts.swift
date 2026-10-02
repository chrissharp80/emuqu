import SwiftUI

/// Where the Poincaré square sits inside the canvas, and the RR range its axes
/// cover. The plot is square by construction so both axes share one scale.
private struct PoincareGeometry {
    let plotMin: Double
    let plotMax: Double
    let plotSize: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat

    init(pairs: [(Double, Double)], size: CGSize) {
        let allRR = pairs.flatMap { [$0.0, $0.1] }
        let minRR = allRR.min() ?? 600
        let maxRR = allRR.max() ?? 1200
        let padding = max(maxRR - minRR, 100) * 0.15
        plotMin = minRR - padding
        plotMax = maxRR + padding
        plotSize = min(size.width, size.height)
        offsetX = (size.width - plotSize) / 2
        offsetY = (size.height - plotSize) / 2
    }

    func scale(_ value: Double) -> CGFloat {
        CGFloat((value - plotMin) / (plotMax - plotMin)) * plotSize
    }

    func point(_ rr1: Double, _ rr2: Double) -> CGPoint {
        CGPoint(x: offsetX + scale(rr1), y: offsetY + plotSize - scale(rr2))
    }
}

// MARK: - Poincaré Plot View

struct PoincarePlotView: View {
    let session: HRVSession
    let result: HRVAnalysisResult

    var body: some View {
        GeometryReader { _ in
            Canvas { context, size in
                drawPoincarePlot(&context, size: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Poincaré plot showing beat-to-beat heart rate variability. SD1: \(String(format: "%.1f", locale: .current, result.nonlinear.sd1)) milliseconds, SD2: \(String(format: "%.1f", locale: .current, result.nonlinear.sd2)) milliseconds", bundle: LanguageManager.appBundle))
    }

    private func drawPoincarePlot(_ context: inout GraphicsContext, size: CGSize) {
        let pairs = beatPairs()
        guard !pairs.isEmpty else { return }
        let plot = PoincareGeometry(pairs: pairs, size: size)
        drawPlotBackground(&context, plot)
        drawIdentityLine(&context, plot)
        drawDispersionEllipse(&context, plot, pairs: pairs)
        drawBeatPoints(&context, plot, pairs: pairs)
    }

    /// Consecutive RR pairs inside the analysis window, artifact beats excluded.
    ///
    /// Guard the range. A short/empty rrSeries (a 5-min quick
    /// reading) or a degenerate window makes `windowEnd` small, so
    /// `windowStart ..< (windowEnd - 1)` becomes e.g. `0 ..< -1` → "Range
    /// requires lowerBound <= upperBound" trap. Sibling views (Tachogram / HR
    /// axis) already guard this; the Poincaré loop didn't.
    private func beatPairs() -> [(Double, Double)] {
        guard let series = session.rrSeries else { return [] }
        let flags = session.artifactFlags ?? []
        let windowStart = result.windowStart
        let windowEnd = min(result.windowEnd, series.points.count)
        guard windowStart >= 0, windowEnd > windowStart + 1 else { return [] }
        return (windowStart ..< (windowEnd - 1)).compactMap { i in
            let isArtifact1 = i < flags.count ? flags[i].isArtifact : false
            let isArtifact2 = (i + 1) < flags.count ? flags[i + 1].isArtifact : false
            guard !isArtifact1, !isArtifact2 else { return nil }
            return (Double(series.points[i].rr_ms), Double(series.points[i + 1].rr_ms))
        }
    }

    private func drawPlotBackground(_ context: inout GraphicsContext, _ plot: PoincareGeometry) {
        let bgRect = CGRect(x: plot.offsetX, y: plot.offsetY, width: plot.plotSize, height: plot.plotSize)
        context.fill(Path(bgRect), with: .color(Color(.tertiarySystemGroupedBackground)))
    }

    private func drawIdentityLine(_ context: inout GraphicsContext, _ plot: PoincareGeometry) {
        var linePath = Path()
        linePath.move(to: CGPoint(x: plot.offsetX, y: plot.offsetY + plot.plotSize))
        linePath.addLine(to: CGPoint(x: plot.offsetX + plot.plotSize, y: plot.offsetY))
        context.stroke(linePath, with: .color(.gray.opacity(0.3)), lineWidth: 1)
    }

    /// The SD1 / SD2 ellipse, centred on the mean RR and rotated onto the
    /// identity line.
    private func drawDispersionEllipse(
        _ context: inout GraphicsContext,
        _ plot: PoincareGeometry,
        pairs: [(Double, Double)]
    ) {
        let allRR = pairs.flatMap { [$0.0, $0.1] }
        let meanRR = allRR.reduce(0, +) / Double(allRR.count)
        let center = plot.point(meanRR, meanRR)
        let span = CGFloat(plot.plotMax - plot.plotMin)
        let sd1Px = CGFloat(result.nonlinear.sd1) * plot.plotSize / span
        let sd2Px = CGFloat(result.nonlinear.sd2) * plot.plotSize / span
        let transform = CGAffineTransform.identity
            .translatedBy(x: center.x, y: center.y)
            .rotated(by: -.pi / 4)
        let rect = CGRect(x: -sd2Px, y: -sd1Px, width: sd2Px * 2, height: sd1Px * 2)
        let ellipse = Path(ellipseIn: rect).applying(transform)
        context.fill(ellipse, with: .color(AppTheme.primary.opacity(0.15)))
        context.stroke(ellipse, with: .color(AppTheme.primary.opacity(0.5)), lineWidth: 2)
    }

    /// At most 300 dots — beyond that the plot is a solid blob and the draw
    /// cost stops being free.
    private func drawBeatPoints(
        _ context: inout GraphicsContext,
        _ plot: PoincareGeometry,
        pairs: [(Double, Double)]
    ) {
        let step = max(1, pairs.count / 300)
        for i in stride(from: 0, to: pairs.count, by: step) {
            let (rr1, rr2) = pairs[i]
            let p = plot.point(rr1, rr2)
            let dot = Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
            context.fill(dot, with: .color(AppTheme.primary.opacity(0.6)))
        }
    }
}

// MARK: - Tachogram View

struct TachogramView: View {
    let session: HRVSession
    let result: HRVAnalysisResult

    @State private var touchLocation: CGPoint?
    @State private var isDragging = false

    private let xAxisHeight: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            chartStack(geo)
                .contentShape(Rectangle())
                .gesture(touchGesture)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Tachogram showing RR interval variability over time. RMSSD: \(String(format: "%.1f", locale: .current, result.timeDomain.rmssd)) milliseconds, mean heart rate: \(String(format: "%.0f", locale: .current, result.timeDomain.meanHR)) beats per minute", bundle: LanguageManager.appBundle))
    }

    private func chartStack(_ geo: GeometryProxy) -> some View {
        let chartHeight = geo.size.height - xAxisHeight
        return ZStack {
            VStack(spacing: 0) {
                chartCanvas(size: CGSize(width: geo.size.width, height: chartHeight))
                    .frame(height: chartHeight)

                xAxisLabels(width: geo.size.width)
                    .frame(height: xAxisHeight)
            }
            touchOverlay(geo, chartHeight: chartHeight)
        }
    }

    /// Crosshair and readout under the user's finger while dragging.
    @ViewBuilder
    private func touchOverlay(_ geo: GeometryProxy, chartHeight: CGFloat) -> some View {
        if let touch = touchLocation, isDragging {
            Rectangle()
                .fill(Color.white.opacity(0.8))
                .frame(width: 1, height: chartHeight)
                .position(x: touch.x, y: chartHeight / 2)

            if let (rr, time) = rrAtLocation(touch.x, size: CGSize(width: geo.size.width, height: chartHeight)) {
                TachogramTooltip(value: String(format: "%.0f", locale: .current, rr), unit: "ms", time: time, color: AppTheme.primary)
                    .position(x: tooltipX(touch.x, width: geo.size.width), y: 30)
            }
        }
    }

    private var touchGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                touchLocation = value.location
                isDragging = true
            }
            .onEnded { _ in
                isDragging = false
                touchLocation = nil
            }
    }

    private func xAxisLabels(width: CGFloat) -> some View {
        ChartXAxisLabels(session: session, result: result, width: width)
    }

    private func tooltipX(_ x: CGFloat, width: CGFloat) -> CGFloat {
        let padding: CGFloat = 50
        if x < padding { return padding }
        if x > width - padding { return width - padding }
        return x
    }

    private func rrAtLocation(_ x: CGFloat, size: CGSize) -> (Double, String)? {
        guard let hit = beatAtLocation(x, size: size, session: session, result: result) else { return nil }
        return (Double(hit.point.rr_ms), hit.timeString)
    }

    private func chartCanvas(size: CGSize) -> some View {
        Canvas { context, size in
            guard let rrValues = tachogramValues() else { return }
            drawTachogram(context, size: size, rrValues: rrValues)
        }
    }

    /// Nil when there's nothing drawable. Two points are the minimum: a
    /// single-beat window (windowEnd == windowStart + 1) would make
    /// `count - 1 == 0` and the xScale divide by zero → ∞ into CoreGraphics.
    private func tachogramValues() -> [Double]? {
        guard let series = session.rrSeries,
              let window = clampedAnalysisWindow(series: series, result: result)
        else { return nil }
        let rrValues = window.map { Double(series.points[$0].rr_ms) }
        return rrValues.count > 1 ? rrValues : nil
    }

    private func drawTachogram(_ context: GraphicsContext, size: CGSize, rrValues: [Double]) {
        let minRR = rrValues.min() ?? 600
        let range = max((rrValues.max() ?? 1200) - minRR, 50)
        let xScale = size.width / CGFloat(rrValues.count - 1)
        strokeHorizontalGrid(context, ys: (0 ... 4).map { size.height * CGFloat($0) / 4 }, width: size.width)
        let points = rrValues.enumerated().map { i, rr -> CGPoint in
            let normalized = (rr - minRR) / range
            let y = size.height - CGFloat(normalized) * size.height * 0.85 - size.height * 0.075
            return CGPoint(x: CGFloat(i) * xScale, y: y)
        }
        let paths = tracePaths(points: points, height: size.height, closingX: size.width)
        let gradient = Gradient(colors: [AppTheme.primary.opacity(0.3), AppTheme.primary.opacity(0.05)])
        context.fill(paths.fill, with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        context.stroke(paths.line, with: .color(AppTheme.primary), lineWidth: 1.5)
    }
}

struct TachogramTooltip: View {
    let value: String
    let unit: String
    let time: String
    let color: Color

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

// MARK: - Frequency Bands View

struct FrequencyBandsView: View {
    let frequencyDomain: FrequencyDomainMetrics

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 8) {
                stackedBar(width: geo.size.width)
                legend
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Frequency analysis: Low frequency \(String(format: "%.0f", locale: .current, frequencyDomain.lf)) milliseconds squared, High frequency \(String(format: "%.0f", locale: .current, frequencyDomain.hf)) milliseconds squared, LF/HF ratio \(String(format: "%.2f", locale: .current, frequencyDomain.lfHfRatio ?? 0))", bundle: LanguageManager.appBundle))
        }
    }

    /// VLF / LF / HF as one stacked bar, each band sized by its share of total
    /// power. VLF is dropped below 1% — at that width it is a rendering artifact
    /// rather than a reading.
    private func stackedBar(width: CGFloat) -> some View {
        let total = frequencyDomain.totalPower
        let lfPct = total > 0 ? frequencyDomain.lf / total : 0
        let hfPct = total > 0 ? frequencyDomain.hf / total : 0
        let vlfPct = total > 0 ? (frequencyDomain.vlf ?? 0) / total : 0
        return HStack(spacing: 2) {
            if vlfPct > 0.01 {
                Rectangle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: width * CGFloat(vlfPct))
            }
            Rectangle()
                .fill(AppTheme.primary)
                .frame(width: width * CGFloat(lfPct))
            Rectangle()
                .fill(AppTheme.secondary)
                .frame(width: width * CGFloat(hfPct))
        }
        .frame(height: 24)
        .cornerRadius(4)
    }

    private var legend: some View {
        HStack(spacing: 20) {
            if frequencyDomain.vlf != nil {
                LegendItem(color: .gray.opacity(0.5), label: "VLF", value: String(format: "%.0f ms²", locale: .current, frequencyDomain.vlf ?? 0))
            }
            LegendItem(color: AppTheme.primary, label: "LF", value: String(format: "%.0f ms²", locale: .current, frequencyDomain.lf))
            LegendItem(color: AppTheme.secondary, label: "HF", value: String(format: "%.0f ms²", locale: .current, frequencyDomain.hf))
        }
    }
}

struct LegendItem: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.caption2.bold())
                    .foregroundColor(AppTheme.textPrimary)
                Text(value)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Heart Rate Chart View

struct HeartRateChartView: View {
    let session: HRVSession
    let result: HRVAnalysisResult

    @State private var touchLocation: CGPoint?
    @State private var isDragging = false

    private let xAxisHeight: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            chartStack(geo)
                .contentShape(Rectangle())
                .gesture(touchGesture)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Heart rate chart showing rate over time. Mean: \(String(format: "%.0f", locale: .current, result.timeDomain.meanHR)) beats per minute, range: \(String(format: "%.0f", locale: .current, result.timeDomain.minHR)) to \(String(format: "%.0f", locale: .current, result.timeDomain.maxHR))", bundle: LanguageManager.appBundle))
    }

    private func chartStack(_ geo: GeometryProxy) -> some View {
        let chartHeight = geo.size.height - xAxisHeight
        return ZStack {
            VStack(spacing: 0) {
                chartCanvas(size: CGSize(width: geo.size.width, height: chartHeight))
                    .frame(height: chartHeight)

                xAxisLabels(width: geo.size.width)
                    .frame(height: xAxisHeight)
            }
            touchOverlay(geo, chartHeight: chartHeight)
        }
    }

    /// Crosshair and readout under the user's finger while dragging.
    @ViewBuilder
    private func touchOverlay(_ geo: GeometryProxy, chartHeight: CGFloat) -> some View {
        if let touch = touchLocation, isDragging {
            Rectangle()
                .fill(Color.white.opacity(0.8))
                .frame(width: 1, height: chartHeight)
                .position(x: touch.x, y: chartHeight / 2)

            if let (hr, time) = hrAtLocation(touch.x, size: CGSize(width: geo.size.width, height: chartHeight)) {
                HRChartTooltip(value: String(format: "%.0f", locale: .current, hr), unit: "bpm", time: time, color: AppTheme.terracotta)
                    .position(x: tooltipX(touch.x, width: geo.size.width), y: 30)
            }
        }
    }

    private var touchGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                touchLocation = value.location
                isDragging = true
            }
            .onEnded { _ in
                isDragging = false
                touchLocation = nil
            }
    }

    private func xAxisLabels(width: CGFloat) -> some View {
        ChartXAxisLabels(session: session, result: result, width: width)
    }

    private func tooltipX(_ x: CGFloat, width: CGFloat) -> CGFloat {
        let padding: CGFloat = 50
        if x < padding { return padding }
        if x > width - padding { return width - padding }
        return x
    }

    private func hrAtLocation(_ x: CGFloat, size: CGSize) -> (Double, String)? {
        guard let hit = beatAtLocation(x, size: size, session: session, result: result),
              hit.point.rr_ms > 0 else { return nil }
        return (60000.0 / Double(hit.point.rr_ms), hit.timeString)
    }

    private func chartCanvas(size: CGSize) -> some View {
        Canvas { context, size in
            guard let hrValues = artifactFreeHRValues() else { return }
            drawHRTrace(context, size: size, hrValues: hrValues.points, windowCount: hrValues.windowCount)
        }
    }

    /// Artifact beats are dropped outright — an interpolated RR turns
    /// into a fabricated bpm, and this chart is read as measurement.
    /// Nil when fewer than three clean beats survive.
    private func artifactFreeHRValues() -> (points: [(Int, Double)], windowCount: Int)? {
        guard let series = session.rrSeries,
              let window = clampedAnalysisWindow(series: series, result: result)
        else { return nil }
        let flags = session.artifactFlags ?? []
        let hrValues: [(Int, Double)] = window.compactMap { i in
            let isArtifact = i < flags.count ? flags[i].isArtifact : false
            // A zero interval stored by an older build is not a beat either.
            guard !isArtifact, series.points[i].rr_ms > 0 else { return nil }
            return (i - window.lowerBound, 60000.0 / Double(series.points[i].rr_ms))
        }
        return hrValues.count > 2 ? (hrValues, window.count) : nil
    }

    /// Range gets 10% padding top and bottom so the trace never touches an edge.
    private func hrPaddedRange(_ hrValues: [(Int, Double)]) -> (min: Double, span: Double) {
        let minHR = hrValues.map(\.1).min() ?? 50
        let maxHR = hrValues.map(\.1).max() ?? 100
        let range = max(maxHR - minHR, 10)
        let paddedMin = minHR - range * 0.1
        return (paddedMin, (maxHR + range * 0.1) - paddedMin)
    }

    private func drawHRTrace(_ context: GraphicsContext, size: CGSize, hrValues: [(Int, Double)], windowCount: Int) {
        let (paddedMin, paddedRange) = hrPaddedRange(hrValues)
        let yFor: (Double) -> CGFloat = { size.height - CGFloat(($0 - paddedMin) / paddedRange) * size.height }
        strokeHorizontalGrid(context, ys: (0 ... 4).map { yFor(paddedMin + paddedRange * Double($0) / 4) }, width: size.width)
        let xScale = size.width / CGFloat(windowCount - 1)
        let points = hrValues.map { CGPoint(x: CGFloat($0.0) * xScale, y: yFor($0.1)) }
        let closingX = CGFloat(hrValues.last?.0 ?? 0) * xScale
        let paths = tracePaths(points: points, height: size.height, closingX: closingX)
        let gradient = Gradient(colors: [AppTheme.terracotta.opacity(0.3), AppTheme.terracotta.opacity(0.05)])
        context.fill(paths.fill, with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        context.stroke(paths.line, with: .color(AppTheme.terracotta), lineWidth: 2)
        strokeAverageLine(context, size: size, hrValues: hrValues, yFor: yFor)
    }

    /// Dashed mean-HR reference line across the full width.
    private func strokeAverageLine(_ context: GraphicsContext, size: CGSize, hrValues: [(Int, Double)], yFor: (Double) -> CGFloat) {
        let avgHR = hrValues.map(\.1).reduce(0, +) / Double(hrValues.count)
        let avgY = yFor(avgHR)
        var avgPath = Path()
        avgPath.move(to: CGPoint(x: 0, y: avgY))
        avgPath.addLine(to: CGPoint(x: size.width, y: avgY))
        context.stroke(avgPath, with: .color(AppTheme.terracotta.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }
}

struct HRChartTooltip: View {
    let value: String
    let unit: String
    let time: String
    let color: Color

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

// MARK: - Shared window / sampling helpers
//
// The RR tachogram and the HR chart draw the same analysis window from the
// same beat stream; only the y-value transform and the tint differ. These
// helpers hold the parts that were duplicated verbatim between the two.

/// The analysis window, clamped to what the series actually contains.
func clampedAnalysisWindow(series: RRSeries, result: HRVAnalysisResult) -> Range<Int>? {
    let start = result.windowStart
    let end = min(result.windowEnd, series.points.count)
    return end > start ? start ..< end : nil
}

/// The beat under a touch point, plus a formatted wall-clock label that says
/// so when the beat was flagged as an artifact.
func beatAtLocation(_ x: CGFloat, size: CGSize, session: HRVSession, result: HRVAnalysisResult) -> (point: RRPoint, timeString: String)? {
    guard let series = session.rrSeries,
          let window = clampedAnalysisWindow(series: series, result: result)
    else { return nil }
    let targetIndex = window.lowerBound + Int((x / size.width) * CGFloat(window.count))
    guard window.contains(targetIndex) else { return nil }
    let flags = session.artifactFlags ?? []
    let isArtifact = targetIndex < flags.count ? flags[targetIndex].isArtifact : false
    let point = series.points[targetIndex]
    let actualTime = series.wallClockTime(forTMs: point.t_ms)
    let suffix = isArtifact ? " " + String(localized: "(artifact)", bundle: LanguageManager.appBundle) : ""
    return (point, actualTime.formatted(.dateTime.hour().minute().second()) + suffix)
}

/// Evenly spaced wall-clock tick labels across the analysis window.
func windowTimeLabels(session: HRVSession, result: HRVAnalysisResult, width: CGFloat, count: Int = 5) -> [(String, CGFloat)] {
    guard let series = session.rrSeries,
          let window = clampedAnalysisWindow(series: series, result: result)
    else { return [] }
    let startMs = series.points[window.lowerBound].t_ms
    let durationMs = series.points[window.upperBound - 1].t_ms - startMs
    return (0 ..< count).map { i in
        let fraction = CGFloat(i) / CGFloat(count - 1)
        let timeOffsetMs = Int64(Double(durationMs) * Double(fraction))
        let actualTime = series.wallClockTime(forTMs: startMs + timeOffsetMs)
        return (actualTime.formatted(date: .omitted, time: .shortened), fraction * width)
    }
}

/// Horizontal hairlines at the supplied y positions.
func strokeHorizontalGrid(_ context: GraphicsContext, ys: [CGFloat], width: CGFloat) {
    let gridColor = Color.gray.opacity(0.2)
    for y in ys {
        var gridPath = Path()
        gridPath.move(to: CGPoint(x: 0, y: y))
        gridPath.addLine(to: CGPoint(x: width, y: y))
        context.stroke(gridPath, with: .color(gridColor), lineWidth: 0.5)
    }
}

/// Polyline through the supplied points, plus the same path closed down to the
/// baseline for the gradient fill underneath it.
func tracePaths(points: [CGPoint], height: CGFloat, closingX: CGFloat) -> (line: Path, fill: Path) {
    var line = Path()
    for (i, p) in points.enumerated() {
        if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
    }
    var fill = line
    if !points.isEmpty {
        fill.addLine(to: CGPoint(x: closingX, y: height))
        fill.addLine(to: CGPoint(x: 0, y: height))
        fill.closeSubpath()
    }
    return (line, fill)
}

/// The x-axis time labels shared by the tachogram and the heart-rate chart.
///
/// Shared rather than a byte-identical private `xAxisLabels` in each
/// view. Two copies of a layout rule drift the moment one is
/// adjusted, and nothing would have flagged it — both are private, so neither
/// compiler nor linter could see the other. Both views are snapshot-tested, so
/// this consolidation is checked rather than assumed.
private struct ChartXAxisLabels: View {
    let session: HRVSession
    let result: HRVAnalysisResult
    let width: CGFloat

    var body: some View {
        let labels = windowTimeLabels(session: session, result: result, width: width)
        return ZStack {
            ForEach(0 ..< labels.count, id: \.self) { i in
                Text(labels[i].0)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
                    .position(x: labels[i].1, y: 10)
            }
        }
    }
}
