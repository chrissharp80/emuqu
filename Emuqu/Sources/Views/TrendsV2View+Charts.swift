import Charts
import SwiftUI

// The metric charts and their supporting series builders. Members are internal
// rather than `private` because Swift's `private` does not reach across files.

extension TrendsV2View {
    // MARK: - Metric chart

    var metricChartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            metricPicker

            ChartCard(title: selectedMetric.localizedName) {
                metricChartContent
            }
        }
    }

    @ViewBuilder
    private var metricChartContent: some View {
        let pts = derived.points
        if pts.isEmpty {
            EmptyState(
                glyph: "chart.line.uptrend.xyaxis",
                headline: String(localized: "No overnight readings in this window", bundle: LanguageManager.appBundle),
                message: String(localized: "Quick spot-checks, post-workout HRV, and naps don't feed Trends — record overnight to see a trend.", bundle: LanguageManager.appBundle)
            )
        } else {
            chartContent(points: pts)
        }
    }

    private var metricPicker: some View {
        Picker(String(localized: "Metric", bundle: LanguageManager.appBundle), selection: $selectedMetric) {
            ForEach(Metric.allCases, id: \.self) { m in
                Text(verbatim: m.localizedName).tag(m)
            }
        }
        .pickerStyle(.segmented)
    }

    /// Chart layers:
    ///   1. Daily dots (raw rMSSD / current metric)
    ///   2. 7-day rolling baseline line
    ///   3. **Shaded normal-range band: mean ±1 SD over 60 days**
    ///   4. Color-coded out-of-band dots
    /// Plus chartXSelection so a drag pins a value pill to the dot
    /// nearest the gesture ("Scrubbable").
    /// Building-baseline overlay (fewer than 4 overnight readings in the last
    /// 60 days, `BaselineStats.hasData`) is drawn on top with the readings so
    /// far visible behind it.
    @ViewBuilder
    func chartContent(points pts: [MetricPoint]) -> some View {
        let band = derived.chartBand
        ZStack {
            metricChart(points: pts, band: band)
            // Too few readings for a band → "Building baseline" overlay over
            // the readings so far.
            if !band.hasData {
                buildingBaselineOverlay
            }
        }
        if let pt = scrubbedDate.flatMap({ nearestPoint(to: $0, in: Self.chartVisiblePoints(pts)) }) {
            scrubPill(point: pt, band: band)
        }
    }

    /// The newest readings the chart draws, capped for performance on "All".
    /// The baseline line, scrubbing and the audio graph use the same set so
    /// they line up with the dots.
    static func chartVisiblePoints(_ pts: [MetricPoint]) -> [MetricPoint] {
        Array(pts.suffix(120))
    }

    func metricChart(points pts: [MetricPoint], band: BaselineStats) -> some View {
        let bandLow = band.hasData ? band.mean - band.sd : nil
        let bandHigh = band.hasData ? band.mean + band.sd : nil
        let visiblePoints = Self.chartVisiblePoints(pts)
        return Chart {
            normalRangeBand(band: band, points: visiblePoints)
            dailyDots(visiblePoints, bandLow: bandLow, bandHigh: bandHigh)
            baselineLine(from: visiblePoints.first?.date)
            scrubMarks(points: visiblePoints)
        }
        .chartXSelection(value: $scrubbedDate)
        .accessibilityChartDescriptor(
            AudioGraphDescriptor.line(
                title: String(localized: "\(selectedMetric.localizedName) trend", bundle: LanguageManager.appBundle),
                xLabel: String(localized: "Date", bundle: LanguageManager.appBundle),
                yLabel: selectedMetric.localizedName,
                points: visiblePoints.map { (date: $0.date, value: $0.value) }
            )
        )
    }

    /// Shaded normal-range band — 60-day mean ±1 SD — plus its dashed mean line.
    @ChartContentBuilder
    func normalRangeBand(band: BaselineStats, points: [MetricPoint]) -> some ChartContent {
        if band.hasData {
            RectangleMark(
                xStart: .value("Start", points.first?.date ?? Date()),
                xEnd: .value("End", points.last?.date ?? Date()),
                yStart: .value("Lower", band.mean - band.sd),
                yEnd: .value("Upper", band.mean + band.sd)
            )
            .foregroundStyle(AppTheme.primary.opacity(0.08))
            RuleMark(y: .value("Baseline", band.mean))
                .foregroundStyle(AppTheme.textTertiary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    /// One dot per reading, tinted when it falls outside the normal range.
    func dailyDots(_ points: [MetricPoint], bandLow: Double?, bandHigh: Double?) -> some ChartContent {
        ForEach(points) { p in
            let outOfBand = (bandLow.map { p.value < $0 } ?? false) || (bandHigh.map { p.value > $0 } ?? false)
            PointMark(
                x: .value("Date", p.date),
                y: .value(selectedMetric.localizedName, p.value)
            )
            .symbolSize(30)
            .foregroundStyle(outOfBand ? AppTheme.wongCaution : AppTheme.primary.opacity(0.7))
        }
    }

    func baselineLine(from start: Date?) -> some ChartContent {
        ForEach(derived.rollingBaseline.filter { $0.date >= (start ?? .distantPast) }) { p in
            LineMark(
                x: .value("Date", p.date),
                y: .value("Baseline", p.value)
            )
            .foregroundStyle(AppTheme.primary)
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
    }

    /// Crosshair + emphasised dot at whatever the drag is nearest to.
    @ChartContentBuilder
    func scrubMarks(points pts: [MetricPoint]) -> some ChartContent {
        if let pinned = scrubbedDate, let pt = nearestPoint(to: pinned, in: pts) {
            RuleMark(x: .value("Scrubbed", pt.date))
                .foregroundStyle(AppTheme.textPrimary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            PointMark(
                x: .value("Date", pt.date),
                y: .value(selectedMetric.localizedName, pt.value)
            )
            .symbolSize(80)
            .foregroundStyle(AppTheme.textPrimary)
        }
    }

    func scrubPill(point pt: MetricPoint, band: BaselineStats) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: pt.date.formatted(.dateTime.month(.abbreviated).day()))
                .font(.system(size: dt12, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
            Text(verbatim: formatMetricValue(pt.value))
                .font(.system(size: dt13, weight: .semibold).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
            if let delta = band.deltaPercent(pt.value) {
                Text(verbatim: deltaLabel(delta))
                    .font(.system(size: dt11, weight: .medium))
                    .foregroundStyle(deltaColor(delta))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(AppTheme.cardBackground))
    }

    var buildingBaselineOverlay: some View {
        VStack(spacing: 4) {
            Text(String(localized: "Building baseline", bundle: LanguageManager.appBundle))
                .font(.system(size: dt13, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(String(localized: "The ±1 SD band appears once there are 4 overnight readings in the last 60 days. Keep recording — what you have so far is showing through.", bundle: LanguageManager.appBundle))
                .font(.system(size: dt11))
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(AdaptiveMaterial.ultraThin(reduceTransparency))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(AppTheme.primary.opacity(0.25), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }

    func nearestPoint(to date: Date, in pts: [MetricPoint]) -> MetricPoint? {
        pts.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
    }

    func formatMetricValue(_ v: Double) -> String {
        let unit = selectedMetric.displayUnit
        switch selectedMetric {
        case .recoveryScore, .rmssd, .sdnn, .meanHR, .stress:
            return unit.isEmpty ? "\(Int(v.rounded()))" : "\(Int(v.rounded())) \(unit)"
        case .balance:
            return String(format: "%.2f", locale: LanguageManager.appLocale, v)
        case .hfPower:
            return "\(Int(v.rounded())) \(unit)"
        }
    }

    func deltaLabel(_ pct: Double) -> String {
        let sign = pct >= 0 ? "+" : ""
        return String(localized: "\(sign)\(Int(pct.rounded()))% vs baseline", bundle: LanguageManager.appBundle)
    }

    /// Text colour for the delta. Stress and Mean HR: higher = worse.
    /// Recovery, RMSSD, SDNN, HF Power: higher = better. Balance (LF/HF) has
    /// no better direction, so its delta stays neutral, as `balanceColor`
    /// does.
    @MainActor func deltaColor(_ pct: Double) -> Color {
        if abs(pct) < 5 || selectedMetric == .balance { return AppTheme.textSecondary }
        let isInverted = selectedMetric == .stress || selectedMetric == .meanHR
        let goodDirection = isInverted ? pct < 0 : pct > 0
        return goodDirection ? AppTheme.wongOptimalText : AppTheme.wongCautionText
    }

    struct MetricPoint: Identifiable {
        let id: Date
        let date: Date
        let value: Double

        func outOfBand(mean: Double, sd: Double) -> Bool {
            value < mean - sd || value > mean + sd
        }
    }

    /// Map sessions → metric points for the requested metric. Recovery
    /// score is stored as 0–10 on `HRVSession.recoveryScore`; we scale
    /// to the 0–100 dashboard convention so the y-axis matches what
    /// the user sees on the score gauge.
    /// Metrics that aren't computed for every session (Balance / HF /
    /// Stress / DFA) compactMap-skip — sample counts in the stats grid
    /// reflect coverage so the user can sanity-check.
    func buildMetricPoints(from scoped: [HRVSession], metric: Metric) -> [MetricPoint] {
        scoped.compactMap { s -> MetricPoint? in
            guard let value = Self.metricValue(metric, in: s) else { return nil }
            return MetricPoint(id: s.startDate, date: s.startDate, value: value)
        }
    }

    static func metricValue(_ metric: Metric, in s: HRVSession) -> Double? {
        switch metric {
        case .recoveryScore: return s.recoveryScore.map { $0 * 10 }
        case .rmssd: return s.analysisResult?.timeDomain.rmssd
        case .sdnn: return s.analysisResult?.timeDomain.sdnn
        case .meanHR: return s.analysisResult?.timeDomain.meanHR
        case .balance: return s.analysisResult?.frequencyDomain?.lfHfRatio
        case .hfPower: return s.analysisResult?.frequencyDomain?.hf
        case .stress: return s.analysisResult?.ansMetrics?.stressIndex
        }
    }

    static func rollingBaseline(_ pts: [MetricPoint], window: Int) -> [MetricPoint] {
        guard pts.count >= window else { return [] }
        var out: [MetricPoint] = []
        for i in (window - 1)..<pts.count {
            let slice = pts[(i - window + 1)...i]
            let mean = slice.map(\.value).reduce(0, +) / Double(slice.count)
            out.append(MetricPoint(id: pts[i].date, date: pts[i].date, value: mean))
        }
        return out
    }

    // MARK: - Stats grid

    var statsGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 8) {
            ForEach(Array(derived.stats.enumerated()), id: \.offset) { _, cell in
                statCell(cell)
            }
        }
    }

    private func statCell(_ cell: GridCell) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: cell.label)
                .font(.system(size: dt11, weight: .medium))
                .foregroundStyle(AppTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(verbatim: cell.value)
                .font(.system(size: dt22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
            deltaText(cell)
            Text(verbatim: cell.subline)
                .font(.system(size: dt11))
                .foregroundStyle(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.cardBackground)
        )
    }

    @ViewBuilder
    private func deltaText(_ cell: GridCell) -> some View {
        if let delta = cell.delta {
            Text(verbatim: delta)
                .font(.system(size: dt11, weight: .medium))
                .foregroundStyle(deltaColor(pct: cell.deltaPercent, higherIsBetter: cell.higherIsBetter))
        }
    }

    /// Color the stats-grid delta line. Direction is encoded on the
    /// cell via `higherIsBetter`; the numeric percent is carried on the
    /// cell (`deltaPercent`) so we never re-parse the localized label —
    /// a `.contains("+")` / `split("%")` parse breaks the moment the
    /// string is translated. Below ±5% reads as neutral (within noise).
    func deltaColor(pct: Double?, higherIsBetter: Bool?) -> Color {
        guard let direction = higherIsBetter, let pct else { return AppTheme.textSecondary }
        if abs(pct) < 5 { return AppTheme.textSecondary }
        let goodDirection = direction ? pct > 0 : pct < 0
        return goodDirection ? AppTheme.wongOptimal : AppTheme.wongCaution
    }

    struct GridCell {
        let label: String
        let value: String
        let subline: String
        /// Pre-formatted "+12% vs baseline" delta. nil when no baseline.
        let delta: String?
        /// Numeric delta vs baseline (%), carried alongside the formatted
        /// `delta` string so the color logic never has to re-parse the
        /// localized text. nil when no baseline.
        let deltaPercent: Double?
        /// nil → tinted neutral. Otherwise drives delta color: + with
        /// `higherIsBetter == true` → optimal, otherwise caution.
        let higherIsBetter: Bool?
    }

    /// Stats grid is overnight-only — same population as the chart.
    /// Each cell shows: avg, sample count, **vs-baseline %**.
    /// Baseline = 60-day rolling, computed once in `rebuildDerived()`
    /// and passed in.
    /// Cell selection (the design lists 7 metrics; we have 4 cells):
    ///   - Recovery avg (the headline number)
    ///   - RMSSD avg (the most-used HRV value)
    ///   - Heart Complexity / DFA α1 (the gold-standard nonlinear metric)
    ///   - Stress Index (Baevsky autonomic balance)
    /// SDNN, Mean HR, Balance and HF Power are reachable via the chart
    /// picker.
    static func computeStats(_ scoped: [HRVSession], baselines: [Metric: BaselineStats]) -> [GridCell] {
        guard !scoped.isEmpty else { return [] }
        return [
            recoveryStatsCell(scoped, baselines: baselines),
            rmssdStatsCell(scoped, baselines: baselines),
            complexityStatsCell(scoped),
            stressStatsCell(scoped, baselines: baselines)
        ]
    }

    static func recoveryStatsCell(_ scoped: [HRVSession], baselines: [Metric: BaselineStats]) -> GridCell {
        statsCell(
            label: String(localized: "Recovery avg", bundle: LanguageManager.appBundle),
            values: scoped.compactMap { $0.recoveryScore.map { $0 * 10 } },
            format: { "\(Int($0.rounded()))" },
            sublineSuffix: String(localized: "of \(scoped.count) overnights", bundle: LanguageManager.appBundle),
            baseline: baselines[.recoveryScore],
            higherIsBetter: true
        )
    }

    static func rmssdStatsCell(_ scoped: [HRVSession], baselines: [Metric: BaselineStats]) -> GridCell {
        statsCell(
            label: String(localized: "RMSSD avg", bundle: LanguageManager.appBundle),
            values: scoped.compactMap(\.analysisResult).map(\.timeDomain.rmssd),
            format: { "\(Int($0.rounded())) ms" },
            sublineSuffix: String(localized: "readings", bundle: LanguageManager.appBundle),
            baseline: baselines[.rmssd],
            higherIsBetter: true
        )
    }

    /// No baseline pulled — DFA varies and 0.75–1.0 is the target band, not a
    /// delta question.
    static func complexityStatsCell(_ scoped: [HRVSession]) -> GridCell {
        statsCell(
            label: String(localized: "Heart Complexity", bundle: LanguageManager.appBundle),
            values: scoped.compactMap { $0.analysisResult?.nonlinear.dfaAlpha1 },
            format: { String(format: "%.2f", locale: LanguageManager.appLocale, $0) },
            sublineSuffix: "DFA α1",
            baseline: nil,
            higherIsBetter: true
        )
    }

    static func stressStatsCell(_ scoped: [HRVSession], baselines: [Metric: BaselineStats]) -> GridCell {
        statsCell(
            label: String(localized: "Stress avg", bundle: LanguageManager.appBundle),
            values: scoped.compactMap { $0.analysisResult?.ansMetrics?.stressIndex },
            format: { "\(Int($0.rounded()))" },
            sublineSuffix: String(localized: "Baevsky SI", bundle: LanguageManager.appBundle),
            baseline: baselines[.stress],
            higherIsBetter: false
        )
    }

    static func statsCell(
        label: String,
        values: [Double],
        format: (Double) -> String,
        sublineSuffix: String,
        baseline: BaselineStats?,
        higherIsBetter: Bool
    ) -> GridCell {
        let count = values.count
        guard count > 0 else {
            return GridCell(label: label, value: "—", subline: String(localized: "0 \(sublineSuffix)", bundle: LanguageManager.appBundle), delta: nil, deltaPercent: nil, higherIsBetter: nil)
        }
        let mean = values.reduce(0, +) / Double(count)
        let valueStr = format(mean)
        let subline = String(localized: "\(count) \(sublineSuffix)", bundle: LanguageManager.appBundle)
        let deltaPct: Double? = {
            guard let b = baseline, let pct = b.deltaPercent(mean), abs(pct) >= 1 else { return nil }
            return pct
        }()
        let delta: String? = deltaPct.map { pct in
            let sign = pct >= 0 ? "+" : ""
            return String(localized: "\(sign)\(Int(pct.rounded()))% vs baseline", bundle: LanguageManager.appBundle)
        }
        return GridCell(label: label, value: valueStr, subline: subline, delta: delta, deltaPercent: deltaPct, higherIsBetter: higherIsBetter)
    }

    // MARK: - Insights

    var insightsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(String(localized: "Insights", bundle: LanguageManager.appBundle))
            insightsCard
        }
    }

    private var insightsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(derived.insights, id: \.self) { insight in
                insightRow(insight)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.cardBackground)
        )
    }

    private func insightRow(_ insight: String) -> some View {
        InsightBulletRow(text: insight, fontSize: dt14)
    }

    static func buildInsights(metric: Metric, points pts: [MetricPoint], days: Int?, totalDays: Int) -> [String] {
        guard pts.count >= 3 else {
            // Counts readings in the current range and tag filter, not days.
            return [String(localized: "Trends need at least 3 readings in this view. Readings so far: \(pts.count).", bundle: LanguageManager.appBundle)]
        }
        let directionInfo = computeDirection(rmssd: pts.map(\.value))
        var out = [directionSentence(name: metric.localizedName, glyph: directionInfo.glyph, days: days)]
        let spread = variationStats(metric: metric, points: pts)
        if spread.cv > 0 {
            out.append(variationSentence(metric: metric, cv: spread.cv))
        }
        if spread.outliers > 0 {
            out.append(String(localized: "Readings well outside your typical range: \(spread.outliers) — worth scrolling back to check them.", bundle: LanguageManager.appBundle))
        }
        return out
    }

    /// One whole sentence per direction and period. It was built from
    /// pieces, "Your \(name) is \(label) over the last \(range)", which read
    /// "Your mean hr is building trend over the last all time." and could not
    /// follow another language's word order.
    static func directionSentence(name: String, glyph: String, days: Int?) -> String {
        let b = LanguageManager.appBundle
        switch (glyph, days) {
        case let ("arrow.up.right", days?): return String(localized: "\(name): rising over the last \(days) days.", bundle: b)
        case ("arrow.up.right", nil): return String(localized: "\(name): rising across all your readings.", bundle: b)
        case let ("arrow.down.right", days?): return String(localized: "\(name): falling over the last \(days) days.", bundle: b)
        case ("arrow.down.right", nil): return String(localized: "\(name): falling across all your readings.", bundle: b)
        case let ("arrow.right", days?): return String(localized: "\(name): stable over the last \(days) days.", bundle: b)
        case ("arrow.right", nil): return String(localized: "\(name): stable across all your readings.", bundle: b)
        default: return String(localized: "\(name): not enough readings yet to call a trend.", bundle: b)
        }
    }

    /// #19 — RMSSD/SDNN are log-normal; a raw mean±SD band flags ~70%
    /// of readings as "outliers" and calls normal weeks "51% high". For those
    /// metrics compute the CV and outlier band in LOG space (mean ± 2 SD ≈ 95%
    /// coverage). Other metrics keep the raw path.
    static func variationStats(metric: Metric, points pts: [MetricPoint]) -> (cv: Double, outliers: Int) {
        guard isLogNormal(metric) else { return rawVariationStats(points: pts) }
        let lnValues = pts.map(\.value).filter { $0 > 0 }.map { log($0) }
        guard lnValues.count > 1 else { return rawVariationStats(points: pts) }
        let lnMean = lnValues.reduce(0, +) / Double(lnValues.count)
        let lnSD = sqrt(lnValues.map { pow($0 - lnMean, 2) }.reduce(0, +) / Double(lnValues.count - 1))
        guard lnSD > 0 else { return (0, 0) }
        return (
            sqrt(exp(lnSD * lnSD) - 1) * 100,
            pts.filter { $0.value > 0 && abs(log($0.value) - lnMean) > 2 * lnSD }.count
        )
    }

    static func rawVariationStats(points pts: [MetricPoint]) -> (cv: Double, outliers: Int) {
        let mean = pts.map(\.value).reduce(0, +) / Double(pts.count)
        let variance = pts.map { pow($0.value - mean, 2) }.reduce(0, +) / Double(pts.count)
        return (
            mean > 0 ? sqrt(variance) / mean * 100 : 0,
            pts.filter { abs($0.value - mean) > mean * 0.25 }.count
        )
    }

    static func isLogNormal(_ metric: Metric) -> Bool {
        metric == .rmssd || metric == .sdnn
    }

    /// Log-normal metrics spread wider, so they get a wider "normal" band.
    static func variationSentence(metric: Metric, cv: Double) -> String {
        let lowT = isLogNormal(metric) ? 15.0 : 8.0
        let highT = isLogNormal(metric) ? 30.0 : 15.0
        let cvLabel = cv < lowT
            ? String(localized: "low", bundle: LanguageManager.appBundle)
            : cv < highT
            ? String(localized: "normal", bundle: LanguageManager.appBundle)
            : String(localized: "high", bundle: LanguageManager.appBundle)
        return String(localized: "Day-to-day variation is \(String(format: "%.0f", locale: LanguageManager.appLocale, cv))% — \(cvLabel).", bundle: LanguageManager.appBundle)
    }

    // MARK: -

    func sectionHeading(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: dt13, weight: .semibold))
            .detailSectionHeadingStyle()
    }
}
