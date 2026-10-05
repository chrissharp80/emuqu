import Charts
import SwiftUI

// The HRV chart canvas. The stat card, tooltip and HR canvas live in
// `OvernightChartsView+Charts.swift`.

// MARK: - HRV Chart Canvas

struct OvernightHRVChartCanvas: View {
    let session: HRVSession
    let result: HRVAnalysisResult
    let stats: OvernightStats
    var healthKitSleep: SleepData?
    var onReanalyzeAt: ((Int64) -> Void)?
    var isManualWindowMode: Bool = false
    var manualResult: HRVAnalysisResult?

    @State private var touchLocation: CGPoint?
    @State private var isDragging = false
    @State private var selectedTimestampMs: Int64?
    // Pinned location: persists after finger lifts so the "Analyze Here" button stays tappable
    @State private var pinnedLocation: CGPoint?

    // Reserve space for X-axis labels
    private let xAxisHeight: CGFloat = 20

    // Hoisted from the Canvas closure; otherwise allocated
    // per redraw alongside hundreds of point-rendering iterations.
    private let rmssdAreaGradient = Gradient(colors: [
        AppTheme.sage.opacity(0.3),
        AppTheme.sage.opacity(0.05)
    ])

    // Auto-selected window indices
    private var effectiveWindowStartIndex: Int {
        stats.windowStartIndex
    }

    private var effectiveWindowEndIndex: Int {
        stats.windowEndIndex
    }

    // Manual window indices (if a manual result exists)
    private var manualWindowStartIndex: Int? {
        manualResult?.windowStart
    }

    private var manualWindowEndIndex: Int? {
        manualResult?.windowEnd
    }

    var body: some View {
        GeometryReader { geo in
            let chartHeight = geo.size.height - xAxisHeight
            let chartSize = CGSize(width: geo.size.width, height: chartHeight)
            // The active display location: the live touch while dragging, else the
            // pinned location left behind by the last drag.
            let displayLocation: CGPoint? = isDragging ? touchLocation : pinnedLocation
            ZStack {
                chartStack(chartSize: chartSize, chartHeight: chartHeight, width: geo.size.width)
                manualModeHint(displayLocation, size: chartSize)
                indicatorLine(displayLocation, chartHeight: chartHeight)
                tooltipOverlay(displayLocation, chartSize: chartSize, geoSize: geo.size)
            }
        }
    }

    private func chartStack(chartSize: CGSize, chartHeight: CGFloat, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Main chart canvas
            chartCanvas(size: chartSize)
                .frame(height: chartHeight)

            // X-axis time labels
            OvernightChartDrawing.xAxisLabels(session: session, stats: stats, width: width)
                .frame(height: xAxisHeight)
        }
        .contentShape(Rectangle())
        .gesture(scrubGesture)
    }

    /// Must NOT reject any drag where |width| > |height|, i.e. ALL
    /// horizontal motion. That makes horizontal scrubbing (the natural way to
    /// pick a position on a time-series chart) impossible — "the
    /// slider doesn't show values as it moves." In manual-window mode the user
    /// is explicitly picking a horizontal position, so always honour the drag; in
    /// normal mode keep the guard light so it doesn't fight outer vertical
    /// scrolls, but still allow horizontal scrubbing.
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { scrub($0) }
            .onEnded { pin($0) }
    }

    private func scrub(_ value: DragGesture.Value) {
        // Allow the drag if either axis dominates; only reject pure-vertical
        // jitters that belong to the page scroll.
        if !isManualWindowMode {
            let isMostlyVertical = abs(value.translation.height) > abs(value.translation.width) * 2
            if isMostlyVertical { return }
        }
        touchLocation = value.location
        isDragging = true
    }

    /// Pin the location so the tooltip + button stay visible after the lift.
    private func pin(_ value: DragGesture.Value) {
        pinnedLocation = value.location
        isDragging = false
        touchLocation = nil
    }

    /// Shown while manual mode is active, nothing is pinned, and no result has
    /// come back yet.
    @ViewBuilder
    private func manualModeHint(_ displayLocation: CGPoint?, size: CGSize) -> some View {
        if isManualWindowMode, displayLocation == nil, manualResult == nil {
            VStack(spacing: 4) {
                Image(systemName: "hand.draw.fill")
                    .font(.title3)
                    .foregroundColor(AppTheme.sage.opacity(0.6))
                Text(String(localized: "Drag across the chart to analyze that window", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
            .position(x: size.width / 2, y: size.height / 2)
            .allowsHitTesting(false)
        }
    }

    /// Shown while dragging, and after release at the pinned position.
    @ViewBuilder
    private func indicatorLine(_ displayLocation: CGPoint?, chartHeight: CGFloat) -> some View {
        if let loc = displayLocation {
            let lineColor = isManualWindowMode ? AppTheme.sage : Color.white
            Rectangle()
                .fill(lineColor.opacity(0.8))
                .frame(width: isManualWindowMode ? 2 : 1, height: chartHeight)
                .position(x: loc.x, y: chartHeight / 2)
                .allowsHitTesting(false)
        }
    }

    /// Lives outside the gesture scope so its buttons receive taps.
    @ViewBuilder
    private func tooltipOverlay(_ displayLocation: CGPoint?, chartSize: CGSize, geoSize: CGSize) -> some View {
        if let loc = displayLocation,
           let (rmssd, time) = rmssdAtLocation(loc.x, size: chartSize) {
            VStack(spacing: 4) {
                tooltipRow(rmssd: rmssd, time: time)
                analyzeHereButton(loc, chartSize: chartSize)
            }
            .position(x: OvernightChartDrawing.tooltipX(loc.x, size: geoSize), y: 45)
        }
    }

    private func tooltipRow(rmssd: Double, time: String) -> some View {
        HStack(spacing: 6) {
            ChartTooltip(
                value: String(format: "%.0f", locale: LanguageManager.appLocale, rmssd),
                unit: String(localized: "ms", bundle: LanguageManager.appBundle),
                time: time,
                color: AppTheme.sage
            )
            dismissButton
        }
    }

    /// Stays visible after the finger lifts, so the pin can be acted on.
    @ViewBuilder
    private func analyzeHereButton(_ loc: CGPoint, chartSize: CGSize) -> some View {
        if onReanalyzeAt != nil, let tsMs = timestampAtLocation(loc.x, size: chartSize) {
            Button {
                onReanalyzeAt?(tsMs)
                // Dismiss the pin after analyzing
                pinnedLocation = nil
            } label: {
                analyzeHereLabel
            }
            .buttonStyle(.plain)
        }
    }

    private var analyzeHereLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: isManualWindowMode ? "hand.draw.fill" : "scope")
                .font(.caption2)
            Text(String(localized: "Analyze Here", bundle: LanguageManager.appBundle))
                .font(.caption2.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isManualWindowMode ? AppTheme.sage : AppTheme.primary)
        .foregroundColor(.white)
        .cornerRadius(8)
    }

    private var dismissButton: some View {
        // Dismiss button
        Button {
            pinnedLocation = nil
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "Dismiss", bundle: LanguageManager.appBundle))
    }

    /// Get timestamp in ms from session start for a given x position
    private func timestampAtLocation(_ x: CGFloat, size: CGSize) -> Int64? {
        let startMs = stats.chartStartMs
        let endMs = stats.chartEndMs
        let durationMs = endMs - startMs
        guard durationMs > 0 else { return nil }

        let normalizedX = max(0, min(1, x / size.width))
        return startMs + Int64(Double(durationMs) * normalizedX)
    }

    /// The rolling-RMSSD sample nearest the scrub position, with its
    /// wall-clock time.
    ///
    /// Reuses the cached formatter — this runs per scrub frame,
    /// and allocating a DateFormatter each time is tooltip jank.
    private func rmssdAtLocation(_ x: CGFloat, size: CGSize) -> (Double, String)? {
        let points = session.rrSeries?.points ?? []
        guard !points.isEmpty, !stats.rollingRMSSD.isEmpty else { return nil }
        let firstMs = stats.chartStartMs
        let totalDurationMs = stats.chartEndMs - firstMs
        guard totalDurationMs > 0 else { return nil }
        let targetMs = firstMs + Int64(Double(totalDurationMs) * Double(x / size.width))
        guard let rmssdPoint = nearestRollingSample(toMs: targetMs, points: points),
              let series = session.rrSeries else { return nil }
        // Wall-clock timestamp from the actual RR point, for an accurate time.
        let actualTime = series.absoluteTimeWallClock(at: rmssdPoint.index) ?? series.startDate
        return (rmssdPoint.rmssd, OvernightChartFormatters.clockTimeFormatter.string(from: actualTime))
    }

    /// Closest rolling-RMSSD entry by timestamp.
    private func nearestRollingSample(toMs targetMs: Int64, points: [RRPoint]) -> (index: Int, rmssd: Double)? {
        var closest: (index: Int, rmssd: Double)?
        var minDist = Int64.max
        for (index, rmssd) in stats.rollingRMSSD {
            guard index < points.count else { continue }
            let dist = abs(points[index].t_ms - targetMs)
            if dist < minDist {
                minDist = dist
                closest = (index, rmssd)
            }
        }
        return closest
    }

    /// Long by construction (a chart is a sequence of draw passes over one
    /// shared geometry), so the passes are named functions and the geometry
    /// they share is a value computed once per frame.
    private func chartCanvas(size: CGSize) -> some View {
        Canvas { context, size in
            guard let geo = ChartGeometry(
                size: size,
                stats: stats,
                points: session.rrSeries?.points ?? [],
                effectiveWindowStartIndex: effectiveWindowStartIndex,
                effectiveWindowEndIndex: effectiveWindowEndIndex,
                hasManualWindow: manualWindowStartIndex != nil && manualWindowEndIndex != nil
            ) else { return }
            drawOrganizedRecoveryZones(&context, geo)
            drawAutoWindow(&context, geo)
            drawManualWindow(&context, geo)
            OvernightChartDrawing.drawSleepSegments(&context, geo, stats: stats)
            OvernightChartDrawing.drawGrid(&context, geo)
            drawSleepBandMarkers(&context, geo)
            drawHRVLine(&context, geo)
            drawPeakMarker(&context, geo)
            drawAxisLabels(&context, geo)
        }
    }

    /// Everything the draw passes share, computed once per frame. Nil when
    /// there's nothing to plot.
    private struct ChartGeometry: OvernightChartViewport {
        let size: CGSize
        let points: [RRPoint]
        let totalPoints: Int
        /// Chart viewport: the extended range that covers the HealthKit sleep
        /// envelope, not just the recording.
        let firstMs: Int64
        let totalDurationMs: Int64
        let minY: Double
        let maxY: Double
        let yRange: Double
        let windowStartX: CGFloat
        let windowEndX: CGFloat
        /// True when the auto window is within 80% of the whole recording —
        /// highlighting it then tells the user nothing.
        let windowIsFullRecording: Bool
        let hasManualWindow: Bool

        init?(
            size: CGSize,
            stats: OvernightStats,
            points: [RRPoint],
            effectiveWindowStartIndex: Int,
            effectiveWindowEndIndex: Int,
            hasManualWindow: Bool
        ) {
            guard !stats.rollingRMSSD.isEmpty, !points.isEmpty else { return nil }
            self.size = size
            self.points = points
            totalPoints = points.count
            self.hasManualWindow = hasManualWindow
            minY = 0
            maxY = max(stats.peakRMSSD * 1.2, 100)
            yRange = maxY - minY
            firstMs = stats.chartStartMs
            totalDurationMs = stats.chartEndMs - stats.chartStartMs
            // Prefer wall-clock window bounds; fall back to sample indices when
            // the stats carry no distinct window.
            let bounds = Self.windowBounds(
                stats: stats, size: size, totalPoints: totalPoints,
                startIndex: effectiveWindowStartIndex, endIndex: effectiveWindowEndIndex
            )
            windowStartX = bounds.startX
            windowEndX = bounds.endX
            windowIsFullRecording = bounds.isFullRecording
        }

        private static func windowBounds(
            stats: OvernightStats, size: CGSize, totalPoints: Int, startIndex: Int, endIndex: Int
        ) -> (startX: CGFloat, endX: CGFloat, isFullRecording: Bool) {
            let firstMs = stats.chartStartMs
            let totalDurationMs = stats.chartEndMs - stats.chartStartMs
            if totalDurationMs > 0, stats.windowStartMs != stats.windowEndMs {
                let startFraction = CGFloat(stats.windowStartMs - firstMs) / CGFloat(totalDurationMs)
                let endFraction = CGFloat(stats.windowEndMs - firstMs) / CGFloat(totalDurationMs)
                return (max(0, startFraction) * size.width,
                        min(1, endFraction) * size.width,
                        (endFraction - startFraction) > 0.8)
            }
            let indexFraction = CGFloat(endIndex - startIndex) / CGFloat(totalPoints)
            return (CGFloat(startIndex) / CGFloat(totalPoints) * size.width,
                    CGFloat(endIndex) / CGFloat(totalPoints) * size.width,
                    indexFraction > 0.8)
        }

        /// Horizontal position of a wall-clock offset, clamped to the viewport.
        func x(forMs ms: Int64) -> CGFloat {
            guard totalDurationMs > 0 else { return 0 }
            return CGFloat(ms - firstMs) / CGFloat(totalDurationMs) * size.width
        }

        /// Vertical position of an RMSSD value.
        func y(forRMSSD value: Double) -> CGFloat {
            size.height - CGFloat((value - minY) / yRange) * size.height
        }
    }

    /// Faint green bands where DFA α1 ∈ [0.75–1.0], so the user can see where
    /// recovery lives without trial-and-error.
    private func drawOrganizedRecoveryZones(_ context: inout GraphicsContext, _ geo: ChartGeometry) {
        guard geo.totalDurationMs > 0 else { return }
        for zone in stats.organizedRecoveryZones {
            let zx = max(0, geo.x(forMs: zone.startMs))
            let zw = min(geo.size.width, geo.x(forMs: zone.endMs)) - zx
            guard zw > 0 else { continue }
            let zoneRect = CGRect(x: zx, y: 0, width: zw, height: geo.size.height)
            context.fill(Path(zoneRect), with: .color(AppTheme.sage.opacity(0.12)))
        }
    }

    /// The auto-selected window, dimmed when a manual window is also active.
    /// Skipped entirely when it covers essentially the whole recording.
    private func drawAutoWindow(_ context: inout GraphicsContext, _ geo: ChartGeometry) {
        guard !geo.windowIsFullRecording else { return }
        let fillOpacity: Double = geo.hasManualWindow ? 0.08 : 0.2
        let borderOpacity: Double = geo.hasManualWindow ? 0.3 : 0.8
        let borderWidth: CGFloat = geo.hasManualWindow ? 1 : 2
        let windowRect = CGRect(
            x: geo.windowStartX, y: 0,
            width: geo.windowEndX - geo.windowStartX, height: geo.size.height
        )
        context.fill(Path(windowRect), with: .color(AppTheme.primary.opacity(fillOpacity)))
        for x in [geo.windowStartX, geo.windowEndX] {
            context.stroke(
                verticalLine(atX: x, height: geo.size.height),
                with: .color(AppTheme.primary.opacity(borderOpacity)),
                lineWidth: borderWidth
            )
        }
        drawAutoWindowLabel(&context, geo)
    }

    /// The pill showing the auto window's clock range, tagged "Auto" when a
    /// manual window is competing with it.
    private func drawAutoWindowLabel(_ context: inout GraphicsContext, _ geo: ChartGeometry) {
        guard !stats.windowStartTimeFormatted.isEmpty || !stats.windowEndTimeFormatted.isEmpty else { return }
        let timeRangeText = Text("\(stats.windowStartTimeFormatted) - \(stats.windowEndTimeFormatted)")
            .font(.caption.weight(.bold))
            .foregroundColor(.white)
        let pillY: CGFloat = 4
        let centerX = OvernightChartDrawing.drawPill(
            &context, text: timeRangeText, centerX: (geo.windowStartX + geo.windowEndX) / 2,
            top: pillY, canvasWidth: geo.size.width, color: AppTheme.primary.opacity(geo.hasManualWindow ? 0.5 : 0.9)
        )
        guard geo.hasManualWindow else { return }
        let autoLabel = Text(String(localized: "Auto", bundle: LanguageManager.appBundle))
            .font(.caption2.weight(.bold))
            .foregroundColor(AppTheme.primary.opacity(0.6))
        context.draw(autoLabel, at: CGPoint(x: centerX, y: pillY + 28), anchor: .center)
    }

    /// The user's own window, in sage green. Positioned by wall-clock ms when
    /// the manual result carries them, else by point index.
    private func drawManualWindow(_ context: inout GraphicsContext, _ geo: ChartGeometry) {
        guard let mStart = manualWindowStartIndex, let mEnd = manualWindowEndIndex else { return }
        let startX: CGFloat
        let endX: CGFloat
        if geo.totalDurationMs > 0, let mStartMs = manualResult?.windowStartMs, let mEndMs = manualResult?.windowEndMs {
            startX = max(0, geo.x(forMs: mStartMs))
            endX = min(geo.size.width, geo.x(forMs: mEndMs))
        } else {
            startX = CGFloat(mStart) / CGFloat(geo.totalPoints) * geo.size.width
            endX = CGFloat(mEnd) / CGFloat(geo.totalPoints) * geo.size.width
        }
        let manualRect = CGRect(x: startX, y: 0, width: endX - startX, height: geo.size.height)
        context.fill(Path(manualRect), with: .color(AppTheme.sage.opacity(0.2)))
        for x in [startX, endX] {
            context.stroke(
                verticalLine(atX: x, height: geo.size.height),
                with: .color(AppTheme.sage.opacity(0.8)),
                lineWidth: 2
            )
        }
        drawManualWindowLabel(&context, geo, startX: startX, endX: endX, mStart: mStart, mEnd: mEnd)
    }

    /// The manual window's pill, using wall-clock time for accuracy.
    private func drawManualWindowLabel(
        _ context: inout GraphicsContext,
        _ geo: ChartGeometry,
        startX: CGFloat,
        endX: CGFloat,
        mStart: Int,
        mEnd: Int
    ) {
        guard let series = session.rrSeries, !series.points.isEmpty else { return }
        let (mStartMs, mEndMs) = manualWindowSpanMs(series.points, mStart: mStart, mEnd: mEnd)
        let fmt = OvernightChartFormatters.clockTimeFormatter
        let startLabel = fmt.string(from: series.wallClockTime(forTMs: mStartMs))
        let endLabel = fmt.string(from: series.wallClockTime(forTMs: mEndMs))
        let manualTimeText = Text("\(startLabel) - \(endLabel)")
            .font(.caption.weight(.bold))
            .foregroundColor(.white)
        let centerX = OvernightChartDrawing.drawPill(
            &context, text: manualTimeText, centerX: (startX + endX) / 2,
            top: geo.size.height - 36, canvasWidth: geo.size.width, color: AppTheme.sage.opacity(0.9)
        )
        let yoursLabel = Text(String(localized: "Yours", bundle: LanguageManager.appBundle))
            .font(.caption2.weight(.bold))
            .foregroundColor(AppTheme.sage.opacity(0.8))
        context.draw(yoursLabel, at: CGPoint(x: centerX, y: geo.size.height - 45), anchor: .center)
    }

    /// The manual window's span in `t_ms`: the result's own bounds, the ones
    /// the rectangle is drawn from, else the point indices. `mEnd` is
    /// exclusive and may equal the point count, so the last beat inside the
    /// window is `mEnd - 1`.
    private func manualWindowSpanMs(_ points: [RRPoint], mStart: Int, mEnd: Int) -> (Int64, Int64) {
        if let startMs = manualResult?.windowStartMs, let endMs = manualResult?.windowEndMs {
            return (startMs, endMs)
        }
        let last = points.count - 1
        let startIndex = min(max(0, mStart), last)
        let endIndex = min(max(startIndex, mEnd - 1), last)
        return (points[startIndex].t_ms, points[endIndex].t_ms)
    }

    /// Dotted lines at 30% / 70% of the session's stored sleep period
    /// (`sleepStartMs` / `sleepEndMs`). Not drawn when none is stored. The
    /// chart's own peak marker searches the same fractions of the HealthKit
    /// sleep span or, without one, of the whole recording, so the two can
    /// differ slightly.
    private func drawSleepBandMarkers(_ context: inout GraphicsContext, _ geo: ChartGeometry) {
        guard let sleepStart = session.sleepStartMs,
              let sleepEnd = session.sleepEndMs,
              geo.totalDurationMs > 0 else { return }
        let sleepSpanMs = sleepEnd - sleepStart
        guard sleepSpanMs > 0 else { return }
        let bandColor = Color.gray.opacity(0.5)
        let dashStyle = StrokeStyle(lineWidth: 1, dash: [4, 4])
        for (fraction, label) in [(0.30, "30%"), (0.70, "70%")] {
            let x = geo.x(forMs: sleepStart + Int64(Double(sleepSpanMs) * fraction))
            context.stroke(verticalLine(atX: x, height: geo.size.height), with: .color(bandColor), style: dashStyle)
            let text = Text(String(localized: String.LocalizationValue(label), bundle: LanguageManager.appBundle))
                .font(.caption2.weight(.medium))
                .foregroundColor(.gray.opacity(0.7))
            context.draw(text, at: CGPoint(x: x + 2, y: geo.size.height - 8), anchor: .leading)
        }
    }

    /// The rolling-RMSSD trace, gap-aware so a split night doesn't get a line
    /// drawn straight across the hours the user was awake.
    private func drawHRVLine(_ context: inout GraphicsContext, _ geo: ChartGeometry) {
        // `rmssdAreaGradient` is the hoisted instance-level gradient.
        let gradient = rmssdAreaGradient
        for seg in hrvSegments(geo) where seg.count >= 2 {
            var linePath = Path()
            linePath.move(to: seg[0])
            for i in 1 ..< seg.count { linePath.addLine(to: seg[i]) }
            var fillPath = linePath
            fillPath.addLine(to: CGPoint(x: (seg.last ?? seg[0]).x, y: geo.size.height))
            fillPath.addLine(to: CGPoint(x: seg[0].x, y: geo.size.height))
            fillPath.closeSubpath()
            context.fill(
                fillPath,
                with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: geo.size.height))
            )
            context.stroke(linePath, with: .color(AppTheme.sage), lineWidth: 1.5)
        }
    }

    /// Split the rolling-RMSSD series into contiguous runs, breaking wherever
    /// more than 5 minutes passed between samples.
    private func hrvSegments(_ geo: ChartGeometry) -> [[CGPoint]] {
        let gapThresholdMs: Int64 = 300_000 // 5 min = segment break
        var segments: [[CGPoint]] = [[]]
        var lastPlotMs: Int64 = -1
        for (index, rmssd) in stats.rollingRMSSD {
            guard index >= 0, index < geo.points.count, geo.totalDurationMs > 0 else { continue }
            let timeMs = geo.points[index].t_ms
            if lastPlotMs >= 0, timeMs - lastPlotMs > gapThresholdMs { segments.append([]) }
            segments[segments.count - 1].append(
                CGPoint(x: geo.x(forMs: timeMs), y: geo.y(forRMSSD: rmssd))
            )
            lastPlotMs = timeMs
        }
        return segments
    }

    /// Dashed vertical line, circle, and value label at the night's peak RMSSD.
    private func drawPeakMarker(_ context: inout GraphicsContext, _ geo: ChartGeometry) {
        let peakX = geo.x(forMs: stats.peakHRVTimeMs)
        let peakY = geo.y(forRMSSD: stats.peakRMSSD)
        context.stroke(
            verticalLine(atX: peakX, height: geo.size.height),
            with: .color(AppTheme.primary.opacity(0.5)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
        )
        let peakCircle = Path(ellipseIn: CGRect(x: peakX - 6, y: peakY - 6, width: 12, height: 12))
        context.fill(peakCircle, with: .color(AppTheme.primary))
        context.stroke(peakCircle, with: .color(.white), lineWidth: 2)
        let peakText = Text("\(Int(stats.peakRMSSD))")
            .font(.caption.bold())
            .foregroundColor(AppTheme.primary)
        context.draw(peakText, at: CGPoint(x: peakX, y: peakY - 16))
    }

    private func drawAxisLabels(_ context: inout GraphicsContext, _ geo: ChartGeometry) {
        context.draw(
            Text("\(Int(geo.maxY))").font(.caption2).foregroundColor(.gray),
            at: CGPoint(x: 15, y: 8)
        )
        context.draw(
            Text(String(localized: "0", bundle: LanguageManager.appBundle)).font(.caption2).foregroundColor(.gray),
            at: CGPoint(x: 10, y: geo.size.height - 22)
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

#Preview {
    OvernightChartsView(
        session: HRVSession(),
        result: HRVAnalysisResult(
            windowStart: 0,
            windowEnd: 100,
            timeDomain: TimeDomainMetrics(
                meanRR: 900,
                sdnn: 50,
                rmssd: 45,
                pnn50: 20,
                sdsd: 35,
                meanHR: 65,
                sdHR: 8,
                minHR: 52,
                maxHR: 78,
                triangularIndex: 12
            ),
            frequencyDomain: nil,
            nonlinear: NonlinearMetrics(
                sd1: 30,
                sd2: 50,
                sd1Sd2Ratio: 0.6,
                sampleEntropy: nil,
                approxEntropy: nil,
                dfaAlpha1: 0.95,
                dfaAlpha2: nil,
                dfaAlpha1R2: nil
            ),
            ansMetrics: nil,
            artifactPercentage: 2,
            cleanBeatCount: 300,
            analysisDate: Date()
        )
    )
}
