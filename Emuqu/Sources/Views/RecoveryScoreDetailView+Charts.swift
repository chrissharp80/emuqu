import Charts
import SwiftUI

// Split out from RecoveryScoreDetailView.swift to keep the primary file
// under the 1500-line tech-debt budget. Holds the chart helpers and the
// inline Pick Window slider; the window picker and engine room live in
// +Panels. The members this extension calls on the view are internal, not
// private, for that reason.

extension RecoveryScoreCharts {

    // MARK: - HRV Overnight chart

    var hrvOvernightChart: some View {
        ChartCard(title: String(localized: "HRV overnight (rolling RMSSD)", bundle: LanguageManager.appBundle), unitLabel: String(localized: "ms", bundle: LanguageManager.appBundle)) {
            hrvChart
        }
    }

    // Reads the cached series (computed once per
    // session load in `rebuildChartSeries()`) instead of calling
    // `buildRMSSDSeries()` here; a builder here runs on every
    // body evaluation — including every hover tick, because
    // `hrvHoverDate` is @State — re-walking the full beat stream
    // per scrub frame.
    @ViewBuilder
    var hrvChart: some View {
        let series = rmssdChartSeries
        if series.isEmpty {
            hrvChartPlaceholder
        } else {
            hrvChartContent(series)
        }
    }

    // Until the background full-RR
    // reload completes, lightweight sessions have no series
    // even though the data is on disk. Show a spinner —
    // an EmptyState flashing for a beat before the reload
    // lands is what "charts not populating reliably"
    // looks like to the user.
    @ViewBuilder
    private var hrvChartPlaceholder: some View {
        if !didCompleteInitialLoad {
            hrvChartLoading
        } else {
            hrvChartEmptyState
        }
    }

    private var hrvChartLoading: some View {
        VStack(spacing: 12) {
            ProgressView().tint(AppTheme.primary)
            Text(String(localized: "Loading HRV trace…", bundle: LanguageManager.appBundle))
                .scaledFont(size: 12)
                .foregroundStyle(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var hrvChartEmptyState: some View {
        EmptyState(
            glyph: "waveform.path.ecg",
            headline: String(localized: "No overnight HRV trace", bundle: LanguageManager.appBundle),
            message: String(localized: "Raw RR data isn't available for this session — the per-window RMSSD chart needs the strap recording's beat stream.", bundle: LanguageManager.appBundle)
        )
    }

    @ViewBuilder
    private func hrvChartContent(_ series: [RMSSDPoint]) -> some View {
        hrvChartCanvas(series, selected: nearestRMSSDPoint(to: hrvHoverDate, in: series))
        hrvPickWindowSlot
    }

    private func hrvChartCanvas(_ series: [RMSSDPoint], selected: RMSSDPoint?) -> some View {
        Chart {
            hrvZoneBands
            hrvWindowMarks
            hrvPreviewMarks
            hrvLineMarks(series)
            hrvSelectionMarks(selected)
        }
        .chartYAxis { AxisMarks(position: .leading) }
        // The X domain is the full session window so the user can SEE that
        // data exists past the last RMSSD point (the rolling-RMSSD trace may
        // end early when the artifact gate fails on late windows — typically
        // because the user started moving around 3-4 AM). The HR chart below
        // uses the same axis so the two stay visually aligned.
        .modifier(OvernightTimeAxis(domain: sessionXScaleDomain()))
        .chartXSelection(value: $hrvHoverDate)
        .chartOverlay { proxy in hrvHoverPill(proxy: proxy, selected: selected) }
        .accessibilityChartDescriptor(hrvAudioDescriptor(series))
    }

    // Organized-recovery zones — the green tint that lets
    // the user SEE where parasympathetic recovery happened.
    // Per FLOWCHART.md §green-zone-overlay and the
    // architecture spec, these are non-negotiable for the
    // overnight chart. Drawn first so the analysis-window
    // band sits on top and stays visually dominant.
    private var hrvZoneBands: some ChartContent {
        ForEach(Array(organizedZoneDateRanges.enumerated()), id: \.offset) { _, range in
            RectangleMark(
                xStart: .value("Zone start", range.start),
                xEnd: .value("Zone end", range.end)
            )
            .foregroundStyle(AppTheme.wongGood.opacity(0.18))
        }
    }

    // Selected analysis window (commits after reanalysis).
    @ChartContentBuilder
    private var hrvWindowMarks: some ChartContent {
        if let windowRange = analysisWindowDateRange {
            RectangleMark(
                xStart: .value("Window start", windowRange.start),
                xEnd: .value("Window end", windowRange.end)
            )
            .foregroundStyle(AppTheme.wongOptimal.opacity(0.32))
            hrvHeadlineRule
        }
    }

    private var hrvHeadlineRule: some ChartContent {
        RuleMark(y: .value("Headline RMSSD", result.timeDomain.rmssd))
            .foregroundStyle(AppTheme.wongOptimal.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            // The rule spans the whole plot, so a trailing annotation would
            // start past the plot's right edge; fitting it to the chart keeps
            // the label inside at every width and text size.
            .annotation(
                position: .topTrailing,
                alignment: .trailing,
                overflowResolution: AnnotationOverflowResolution(x: .fit(to: .chart), y: .fit(to: .chart))
            ) {
                hrvHeadlineAnnotation
            }
    }

    private var hrvHeadlineAnnotation: some View {
        Text(String(localized: "Window: \(Int(result.timeDomain.rmssd.rounded())) ms", bundle: LanguageManager.appBundle))
            .scaledFont(size: 10, weight: .semibold, monospacedDigit: true)
            .foregroundStyle(AppTheme.wongOptimalText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppTheme.cardBackground.opacity(0.9))
            )
    }

    // Live preview window — drawn while the user drags the
    // Pick Window slider beneath the chart. Dashed border +
    // lighter fill so it reads as "tentative" vs the
    // committed analysis window.
    @ChartContentBuilder
    private var hrvPreviewMarks: some ChartContent {
        if let previewRange = previewWindowDateRange, previewWindowMs != nil {
            RectangleMark(
                xStart: .value("Preview start", previewRange.start),
                xEnd: .value("Preview end", previewRange.end)
            )
            .foregroundStyle(AppTheme.primary.opacity(0.22))
            RuleMark(x: .value("Preview center", previewRange.center))
                .foregroundStyle(AppTheme.primary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
        }
    }

    @ViewBuilder
    private func hrvHoverPill(proxy: ChartProxy, selected: RMSSDPoint?) -> some View {
        if let selected {
            valuePill(
                text: String(localized: "\(Int(selected.rmssd.rounded())) ms", bundle: LanguageManager.appBundle),
                sub: shortTimeFormatter.string(from: selected.time),
                proxy: proxy,
                date: selected.time
            )
        }
    }

    // Inline Pick Window slider beneath the chart.
    // When the user picks "Pick Window" in the segmented
    // control above, this slot expands. Drag → updates
    // `previewWindowMs` → green preview band moves on the
    // chart in real time. Apply commits to reanalysis.
    @ViewBuilder
    private var hrvPickWindowSlot: some View {
        if selectedWindowSegment == .pickWindow,
           let startMs = recordingStartMs,
           let endMs = recordingEndMs,
           endMs > startMs {
            inlinePickWindowControl(startMs: startMs, endMs: endMs)
                .padding(.top, 8)
        }
    }

    /// Preview-window date range derived from the slider
    /// state. 5-minute window centered on `previewWindowMs`. Returns
    /// nil when no preview is active.
    var previewWindowDateRange: (start: Date, end: Date, center: Date)? {
        guard let centerMs = previewWindowMs else { return nil }
        let halfMs: Int64 = 150_000  // 2.5 minutes
        let start = session.startDate.addingTimeInterval(Double(centerMs - halfMs) / 1000)
        let end = session.startDate.addingTimeInterval(Double(centerMs + halfMs) / 1000)
        let center = session.startDate.addingTimeInterval(Double(centerMs) / 1000)
        return (start, end, center)
    }

    /// Convert `result.organizedRecoveryZones` (or the on-demand fallback)
    /// to chart-friendly `(Date, Date)` pairs.
    var organizedZoneDateRanges: [(start: Date, end: Date)] {
        organizedZoneRanges.map { range in
            (
                start: session.startDate.addingTimeInterval(Double(range.startMs) / 1000),
                end: session.startDate.addingTimeInterval(Double(range.endMs) / 1000)
            )
        }
    }

    /// Clock-time string for the inline Pick Window label. Extracted
    /// so the @ViewBuilder above doesn't need to construct a
    /// DateFormatter inline (Swift's view builder forbids non-view
    /// statements like `f.dateStyle = .none` between `let` bindings).
    func pickWindowClockText(forMs ms: Int64) -> String {
        let date = session.startDate.addingTimeInterval(Double(ms) / 1000)
        return LocalizedDateFormat.string(from: date, template: "jmm")
    }

    /// Inline replacement for the modal Pick Window sheet: a slider
    /// glued to the chart above. As the user drags, `previewWindowMs`
    /// moves and the chart redraws the preview band live, so the
    /// "line in the chart matches the slider" — the user's exact ask.
    @ViewBuilder
    func inlinePickWindowControl(startMs: Int64, endMs: Int64) -> some View {
        let mid = startMs + (endMs - startMs) / 2
        let currentMs = previewWindowMs ?? mid
        VStack(alignment: .leading, spacing: 8) {
            pickWindowReadout(startMs: startMs, currentMs: currentMs)
            Slider(
                value: Binding(
                    get: { Double(previewWindowMs ?? mid) },
                    set: { previewWindowMs = Int64($0) }
                ),
                in: Double(max(startMs, 0))...Double(max(endMs, startMs + 1)),
                step: 60_000
            )
            .disabled(isReanalyzing)
            pickWindowButtons
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.sectionTint)
        )
    }

    private func pickWindowReadout(startMs: Int64, currentMs: Int64) -> some View {
        let durationMin = Int(((Double(currentMs) - Double(startMs)) / 60_000).rounded())
        return HStack(alignment: .firstTextBaseline) {
            Text(verbatim: pickWindowClockText(forMs: currentMs))
                .scaledFont(size: 22, weight: .semibold, design: .rounded, monospacedDigit: true)
            Spacer()
            Text(String(localized: "\(durationMin) min in", bundle: LanguageManager.appBundle))
                .scaledFont(size: 12)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private var pickWindowButtons: some View {
        HStack {
            Button(role: .cancel) {
                // Back to the previous segment without re-running its analysis,
                // so Cancel never replaces the window the session already has.
                previewWindowMs = nil
                restoringSegment = true
                selectedWindowSegment = segmentBeforePick == .pickWindow ? .bestRecovery : segmentBeforePick
            } label: {
                Text(String(localized: "Cancel", bundle: LanguageManager.appBundle)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button {
                runInlineReanalysis()
            } label: {
                Text(String(localized: "Analyze here", bundle: LanguageManager.appBundle)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isReanalyzing)
        }
    }

    private func runInlineReanalysis() {
        guard let onReanalyzeAt, let target = previewWindowMs else { return }
        windowChangedHere = true
        Task {
            isReanalyzing = true
            await onReanalyzeAt(target)
            previewWindowMs = nil
            isReanalyzing = false
        }
    }

    /// Find the chart point closest to a hover Date. Returns nil when
    /// hover hasn't started yet or the series is empty.
    func nearestRMSSDPoint(to date: Date?, in series: [RMSSDPoint]) -> RMSSDPoint? {
        guard let date, !series.isEmpty else { return nil }
        return series.min(by: { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) })
    }

    func nearestHRPoint(to date: Date?, in series: [HRPoint]) -> HRPoint? {
        guard let date, !series.isEmpty else { return nil }
        return series.min(by: { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) })
    }

    // Read on every chartOverlay render, so it comes from the shared cache
    // (one formatter per app language) rather than a fresh DateFormatter.
    var shortTimeFormatter: DateFormatter { LocalizedDateFormat.formatter(template: "jmm") }

    /// Floating value pill anchored above a selected x-position. Rendered
    /// in a chartOverlay so it positions correctly on top of the chart
    /// area — the proxy maps the Date to plot-area coordinates.
    @ViewBuilder
    func valuePill(text: String, sub: String, proxy: ChartProxy, date: Date) -> some View {
        if let xPos = proxy.position(forX: date) {
            VStack(spacing: 2) {
                Text(verbatim: text)
                    .scaledFont(size: 13, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(AppTheme.textPrimary)
                Text(verbatim: sub)
                    .scaledFont(size: 10)
                    .foregroundStyle(AppTheme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(AppTheme.cardBackground)
                    .shadow(color: .black.opacity(0.15), radius: 3)
            )
            .position(x: max(40, min(xPos, proxy.plotSize.width - 40)), y: 14)
        }
    }

    struct RMSSDPoint: Identifiable {
        let id = UUID()
        let time: Date
        let rmssd: Double
    }

    /// Compute a rolling RMSSD trace from the session's RR series.
    /// 5-minute windows, stepped every minute. Skips successive-difference
    /// pairs where either beat is flagged as an artifact so movement spikes
    /// and ectopic beats don't inflate the line out of proportion with the
    /// analyzer's headline RMSSD (which already excludes those beats).
    /// Empty when `rrSeries` is nil.
    ///
    /// Two design points:
    ///   1. Off the render path: called only from
    ///      `rebuildChartSeries()` (the `.task(id: session.id)` load
    ///      pass); the chart body reads `rmssdChartSeries` @State.
    ///      Static + explicit inputs so the walk runs on a detached
    ///      task without capturing the view.
    ///   2. The per-window index collection does not re-scan `points`
    ///      from index 0 for every 1-minute window step —
    ///      O(windows × beats), quadratic over a full night. It is
    ///      a single forward two-pointer pass: `t_ms` is cumulative
    ///      beat time (monotonically non-decreasing), so each window's
    ///      contents are the contiguous run points[lo..<hi] and both
    ///      bounds only ever advance. Same windows, same flag-gated
    ///      successive-difference pairs, same RMSSD per window.
    ///
    /// `lo` is the first index with t_ms >= startMs and `hi` the first with
    /// t_ms >= windowEnd, so the window's beats are points[lo..<hi] and
    /// artifactFlags is consulted by the same indices (it is a parallel array
    /// to series.points).
    nonisolated static func buildRMSSDSeries(
        series: RRSeries?,
        flags: [ArtifactFlags]?,
        sessionStartDate: Date
    ) -> [RMSSDPoint] {
        guard let series, !series.points.isEmpty,
              let firstT = series.points.first?.t_ms, let lastT = series.points.last?.t_ms
        else { return [] }
        let points = series.points
        let windowMs: Int64 = 5 * 60 * 1000
        var out: [RMSSDPoint] = []
        var startMs = firstT
        var lo = 0
        var hi = 0
        while startMs <= lastT - windowMs {
            while lo < points.count, points[lo].t_ms < startMs { lo += 1 }
            if hi < lo { hi = lo }
            while hi < points.count, points[hi].t_ms < startMs + windowMs { hi += 1 }
            if let rmssd = windowRMSSD(points: points, flags: flags, lo: lo, hi: hi) {
                let time = sessionStartDate.addingTimeInterval(Double(startMs) / 1000)
                out.append(RMSSDPoint(time: time, rmssd: rmssd))
            }
            startMs += 60 * 1000
        }
        return out
    }

    /// Shared estimator; see `TimeDomainAnalyzer.rmssd(points:range:isValid:)`.
    /// This chart, the live stats card and the peak scan use the same
    /// artifact-skipping arithmetic, so it is not inlined here. A pair split
    /// by a recording break is not a successive difference and is skipped.
    ///
    /// Nil unless the window holds at least 30 beats and 20 artifact-free
    /// successive pairs — below that the estimate is noise, not a data point.
    nonisolated private static func windowRMSSD(points: [RRPoint], flags: [ArtifactFlags]?, lo: Int, hi: Int) -> Double? {
        guard hi - lo >= 30 else { return nil }
        let isValid: (Int) -> Bool = { offset in
            guard let flags else { return true }
            let absolute = lo + offset
            guard absolute < flags.count else { return true }
            return !flags[absolute].isArtifact
        }
        let breaks = TimeDomainAnalyzer.beatsAfterRecordingBreak(in: points, range: lo ..< hi)
        let validPairs = (1 ..< hi - lo).count { isValid($0) && isValid($0 - 1) && !breaks.contains(lo + $0) }
        guard validPairs >= 20 else { return nil }
        return TimeDomainAnalyzer.rmssd(points: points, range: lo ..< hi, isValid: isValid)
    }

    /// Shared X-axis domain for the HRV and HR overnight
    /// charts. Returns the full session window (startDate..endDate) so
    /// both charts visually align even when one of them (HRV) has a
    /// data series that ends earlier — typically because the rolling-
    /// RMSSD artifact gate rejects late-night windows when the user
    /// starts moving around 3-4 AM. Without this, the HRV chart would
    /// auto-scale to end where its data ends, making it look like the
    /// recording stopped early.
    func sessionXScaleDomain() -> ClosedRange<Date> {
        let start = session.startDate
        let end = session.endDate ?? Date()
        guard end > start else { return start...start.addingTimeInterval(60) }
        return start...end
    }

    // MARK: - HR Overnight chart

    var heartRateOvernightChart: some View {
        ChartCard(title: String(localized: "Heart rate overnight", bundle: LanguageManager.appBundle), unitLabel: String(localized: "bpm", bundle: LanguageManager.appBundle)) {
            hrChart
        }
    }

    // Cached series, same hoist as `hrvChart` above: calling
    // `buildHRSeries()` here would re-run it on every body evaluation
    // (every `hrHoverDate` scrub tick included).
    @ViewBuilder
    var hrChart: some View {
        let series = hrChartSeries
        if series.isEmpty {
            hrChartPlaceholder
        } else {
            hrChartCanvas(series)
        }
    }

    // Same flakiness fix as the HRV chart — show a spinner
    // while the background full-RR reload + HK gap-fill is
    // still running. EmptyState only after we've actually
    // finished trying to load.
    @ViewBuilder
    private var hrChartPlaceholder: some View {
        if !didCompleteInitialLoad {
            hrChartLoading
        } else {
            hrChartEmptyState
        }
    }

    private var hrChartLoading: some View {
        VStack(spacing: 12) {
            ProgressView().tint(AppTheme.primary)
            Text(String(localized: "Loading HR trace…", bundle: LanguageManager.appBundle))
                .scaledFont(size: 12)
                .foregroundStyle(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private var hrChartEmptyState: some View {
        EmptyState(
            glyph: "heart.fill",
            headline: String(localized: "No overnight HR trace", bundle: LanguageManager.appBundle),
            message: String(localized: "The strap's beat-by-beat recording isn't in this session's stored data. (Older sessions sometimes have the analysis result without the raw stream.)", bundle: LanguageManager.appBundle)
        )
    }

    private func hrChartCanvas(_ series: [HRPoint]) -> some View {
        let minHR = series.map(\.hr).min() ?? 0
        let maxHR = series.map(\.hr).max() ?? 100
        let selected = nearestHRPoint(to: hrHoverDate, in: series)
        return Chart {
            hrLineMarks(series)
            hrSelectionMarks(selected)
        }
        .chartYScale(domain: max(0, minHR - 5)...maxHR + 5)
        .chartYAxis { AxisMarks(position: .leading) }
        .modifier(OvernightTimeAxis(domain: sessionXScaleDomain()))
        .chartXSelection(value: $hrHoverDate)
        .chartOverlay { proxy in hrHoverPill(proxy: proxy, selected: selected) }
        .accessibilityChartDescriptor(hrAudioDescriptor(series))
    }

    @ViewBuilder
    private func hrHoverPill(proxy: ChartProxy, selected: HRPoint?) -> some View {
        if let selected {
            valuePill(
                text: String(localized: "\(Int(selected.hr.rounded())) bpm", bundle: LanguageManager.appBundle),
                sub: shortTimeFormatter.string(from: selected.time),
                proxy: proxy,
                date: selected.time
            )
        }
    }

    struct HRPoint: Identifiable {
        let id = UUID()
        let time: Date
        let hr: Double
    }

    /// HR sampled every 15s from the strap's beat stream. When the
    /// strap RR series isn't available (older sessions whose raw beat
    /// stream was pruned post-acceptance), fall back to HealthKit HR
    /// samples covering the same sleep window.
    ///
    /// Off the render path alongside
    /// `buildRMSSDSeries` (called from `rebuildChartSeries()` only;
    /// the chart body reads `hrChartSeries` @State). A single
    /// forward pass.
    nonisolated static func buildHRSeries(
        series: RRSeries?,
        flags: [ArtifactFlags]?,
        sessionStartDate: Date,
        fallbackHRSamples: [(date: Date, hr: Double)]
    ) -> [HRPoint] {
        guard let series, !series.points.isEmpty else {
            // Fallback path — HealthKit HR samples for the sleep window.
            return fallbackHRSamples.map { HRPoint(time: $0.date, hr: $0.hr) }
        }
        let stepMs: Int64 = 15 * 1000
        var out: [HRPoint] = []
        var nextEmitMs: Int64 = series.points.first?.t_ms ?? 0
        for (idx, p) in series.points.enumerated() {
            guard let hr = strapHR(p, idx: idx, flags: flags), p.t_ms >= nextEmitMs else { continue }
            out.append(HRPoint(time: sessionStartDate.addingTimeInterval(Double(p.t_ms) / 1000), hr: hr))
            nextEmitMs = p.t_ms + stepMs
        }
        return out
    }

    /// Prefer the device-reported HR when present; otherwise derive from the RR
    /// interval (60_000 / rr_ms).
    ///
    /// Apply the same artifact gate the HRV chart uses
    /// (`buildRMSSDSeries`). Without this, a single bad RR interval (~320 ms
    /// ectopic / dropout) computes to 187 bpm and surfaces as a tall spike on
    /// the overnight HR chart. A user saw spikes to ~190 on a screenshot of a
    /// sleep session; their actual nocturnal HR was 50–60. Skipping
    /// artifact-flagged beats matches what the HRV chart does and drops the
    /// bogus spikes.
    nonisolated private static func strapHR(_ p: RRPoint, idx: Int, flags: [ArtifactFlags]?) -> Double? {
        if let flags, idx < flags.count, flags[idx].isArtifact { return nil }
        if let devHR = p.hr { return Double(devHR) }
        guard p.rr_ms > 0 else { return nil }
        return 60_000.0 / Double(p.rr_ms)
    }
}

// MARK: - Overnight time axis

/// The time axis both overnight charts share.
///
/// Labels are forced to hour-of-day: Swift Charts' automatic format picks
/// date labels like "May 16 / May 17" when a night crosses midnight, which
/// reads as broken on a single-night chart.
///
/// The plot is inset on both sides by half a label's width so an hour label
/// centred on a tick at either end of the night stays inside the chart. The
/// inset is a scaled metric, so it grows with Dynamic Type along with the
/// labels.
struct OvernightTimeAxis: ViewModifier {
    let domain: ClosedRange<Date>
    @ScaledMetric(relativeTo: .caption2) private var edgeInset: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .chartXAxis {
                AxisMarks(values: .automatic) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartXScale(domain: domain, range: .plotDimension(startPadding: edgeInset, endPadding: edgeInset))
    }
}

// MARK: - File-scope helpers
//
// Kept outside RecoveryScoreDetailView: each names no member of the
// type and calls nothing inside it, so none needs to be a member.
// `private` at file scope is fileprivate, so every call site in this
// file resolves the same way.

private func hrvLineMarks(_ series: [RecoveryScoreCharts.RMSSDPoint]) -> some ChartContent {
    ForEach(series) { p in
        LineMark(
            x: .value("Time", p.time),
            y: .value("RMSSD", p.rmssd)
        )
        .foregroundStyle(AppTheme.wongOptimal)
    }
}

@ChartContentBuilder
@MainActor
private func hrvSelectionMarks(_ selected: RecoveryScoreCharts.RMSSDPoint?) -> some ChartContent {
    if let selected {
        RuleMark(x: .value("Time", selected.time))
            .foregroundStyle(AppTheme.textTertiary.opacity(0.4))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
        PointMark(
            x: .value("Time", selected.time),
            y: .value("RMSSD", selected.rmssd)
        )
        .foregroundStyle(AppTheme.wongOptimal)
        .symbolSize(80)
    }
}

private func hrvAudioDescriptor(_ series: [RecoveryScoreCharts.RMSSDPoint]) -> some AXChartDescriptorRepresentable {
    AudioGraphDescriptor.line(
        title: String(localized: "HRV overnight", bundle: LanguageManager.appBundle),
        xLabel: String(localized: "Time", bundle: LanguageManager.appBundle),
        yLabel: String(localized: "RMSSD (ms)", bundle: LanguageManager.appBundle),
        points: series.map { (date: $0.time, value: $0.rmssd) }
    )
}

private func hrLineMarks(_ series: [RecoveryScoreCharts.HRPoint]) -> some ChartContent {
    ForEach(series) { p in
        LineMark(
            x: .value("Time", p.time),
            y: .value("HR", p.hr)
        )
        .foregroundStyle(AppTheme.wongAttention.opacity(0.7))
    }
}

@ChartContentBuilder
@MainActor
private func hrSelectionMarks(_ selected: RecoveryScoreCharts.HRPoint?) -> some ChartContent {
    if let selected {
        RuleMark(x: .value("Time", selected.time))
            .foregroundStyle(AppTheme.textTertiary.opacity(0.4))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
        PointMark(
            x: .value("Time", selected.time),
            y: .value("HR", selected.hr)
        )
        .foregroundStyle(AppTheme.wongAttention)
        .symbolSize(80)
    }
}

private func hrAudioDescriptor(_ series: [RecoveryScoreCharts.HRPoint]) -> some AXChartDescriptorRepresentable {
    AudioGraphDescriptor.line(
        title: String(localized: "Heart rate overnight", bundle: LanguageManager.appBundle),
        xLabel: String(localized: "Time", bundle: LanguageManager.appBundle),
        yLabel: String(localized: "Heart rate (bpm)", bundle: LanguageManager.appBundle),
        points: series.map { (date: $0.time, value: $0.hr) }
    )
}
