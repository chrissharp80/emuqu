import Charts
import SwiftUI

// Charts, beat-to-beat consistency, the engine room and banners, split out of
// `HRVDetailV2View.swift`. What stays behind is the hero, the 4-up
// strip, autonomic capacity and trend analysis — the summary half of the
// screen.

extension HRVDetailV2View {
    // MARK: - Charts

    @ViewBuilder
    var hrvWaveformChart: some View {
        ChartCard(title: String(localized: "HRV waveform (RR intervals)", bundle: LanguageManager.appBundle), unitLabel: "ms") {
            rrWaveformContent
        }
    }

    @ViewBuilder
    private var rrWaveformContent: some View {
        let points = buildRRPoints()
        if points.isEmpty {
            rrWaveformPlaceholder
        } else {
            rrWaveformPlot(points)
        }
    }

    /// Loading state vs truly-empty
    /// distinction, keyed off `rrLoadCompleted` explicitly so legacy sessions
    /// that *load successfully but have no rrSeries on disk* show informative
    /// copy instead of an infinite spinner.
    @ViewBuilder
    private var rrWaveformPlaceholder: some View {
        if !rrLoadCompleted {
            HStack(spacing: 12) {
                ProgressView()
                Text(String(localized: "Loading overnight beats…", bundle: LanguageManager.appBundle))
                    .font(.system(size: dt13))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        } else {
            EmptyState(
                glyph: "waveform.path.ecg",
                headline: String(localized: "No RR series", bundle: LanguageManager.appBundle),
                message: String(localized: "The strap's beat-by-beat data isn't available for this session.", bundle: LanguageManager.appBundle)
            )
        }
    }

    private func rrWaveformPlot(_ points: [RRPlotPoint]) -> some View {
        Chart {
            ForEach(points) { p in
                LineMark(
                    x: .value("Time", p.elapsedSec),
                    y: .value("RR", p.rrMs)
                )
                .foregroundStyle(AppTheme.wongOptimal)
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .accessibilityChartDescriptor(
            AudioGraphDescriptor.numericLine(
                title: String(localized: "HRV waveform", bundle: LanguageManager.appBundle),
                xLabel: String(localized: "Time (s)", bundle: LanguageManager.appBundle),
                yLabel: String(localized: "RR interval (ms)", bundle: LanguageManager.appBundle),
                points: points.map { (x: $0.elapsedSec, y: Double($0.rrMs)) }
            )
        )
    }

    struct RRPlotPoint: Identifiable {
        let id = UUID()
        let elapsedSec: Double
        let rrMs: Int
    }

    func buildRRPoints() -> [RRPlotPoint] {
        guard let series = effectiveRRSeries, !series.points.isEmpty else { return [] }
        // Sample every 4th beat for chart performance.
        var out: [RRPlotPoint] = []
        for (i, p) in series.points.enumerated() where i % 4 == 0 {
            out.append(RRPlotPoint(elapsedSec: Double(p.t_ms) / 1000, rrMs: p.rr_ms))
        }
        return out
    }

    var poincareChart: some View {
        ChartCard(title: String(localized: "Poincaré plot", bundle: LanguageManager.appBundle), unitLabel: "ms") {
            poincareContent
        }
    }

    @ViewBuilder
    private var poincareContent: some View {
        let pairs = buildPoincarePairs()
        if pairs.isEmpty {
            poincarePlaceholder
        } else {
            poincarePlot(pairs)
        }
    }

    /// Use the explicit
    /// `rrLoadCompleted` flag rather than nil-checks on the optional series,
    /// which spin forever on legacy sessions that load successfully but have no
    /// rrSeries.
    @ViewBuilder
    private var poincarePlaceholder: some View {
        if !rrLoadCompleted {
            HStack(spacing: 12) {
                ProgressView()
                Text(String(localized: "Loading raw RR samples…", bundle: LanguageManager.appBundle))
                    .font(.system(size: dt13))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        } else {
            EmptyState(
                glyph: "scope",
                headline: String(localized: "Poincaré plot unavailable", bundle: LanguageManager.appBundle),
                message: String(localized: "This session was saved without raw RR data — older recordings only kept summary stats.", bundle: LanguageManager.appBundle)
            )
        }
    }

    /// Scatter with SD1/SD2 ellipse overlay. SD1 = the
    /// perpendicular spread (short-term variability), SD2 = the along-axis
    /// spread (long-term variability), centred on (mean RR, mean RR) and rotated
    /// 45° because the line of identity is x = y. Drawn beneath the scatter
    /// points so individual beats stay visible.
    /// The ellipse is rendered as ~64 polyline segments: each point is connected
    /// to the next by a LineMark so Charts treats it as a closed outline rather
    /// than a polygon (there is no fill API on arbitrary marks).
    @ChartContentBuilder
    private func ellipseOutline(_ stats: PoincareStats?) -> some ChartContent {
        if let s = stats {
            ForEach(ellipsePoints(stats: s)) { pt in
                LineMark(
                    x: .value("RR_n", pt.x),
                    y: .value("RR_n+1", pt.y),
                    series: .value("Series", "ellipse")
                )
                .foregroundStyle(AppTheme.primary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
    }

    private func beatScatter(_ pairs: [PoincarePair]) -> some ChartContent {
        ForEach(pairs) { pair in
            PointMark(
                x: .value("RR_n", pair.x),
                y: .value("RR_n+1", pair.y)
            )
            .symbolSize(8)
            .foregroundStyle(AppTheme.wongGood.opacity(0.45))
        }
    }

    private func poincarePlot(_ pairs: [PoincarePair]) -> some View {
        let stats = computePoincareStats(pairs: pairs)
        return Chart {
            ellipseOutline(stats)
            beatScatter(pairs)
        }
        .chartYAxis { AxisMarks(position: .leading) }
    }

    struct PoincareEllipsePoint: Identifiable {
        let id: Int
        let x: Double
        let y: Double
    }

    struct PoincareStats {
        let centerX: Double
        let centerY: Double
        let sd1: Double
        let sd2: Double
    }

    /// Compute (cx, cy, sd1, sd2) for the Poincaré ellipse overlay.
    /// SD1 measures perpendicular spread to the line of identity
    /// (short-term variability ≈ RMSSD/√2). SD2 measures along-axis
    /// spread (long-term variability ≈ √(2·SDNN² − RMSSD²/2)).
    func computePoincareStats(pairs: [PoincarePair]) -> PoincareStats? {
        guard pairs.count >= 4 else { return nil }
        let xs = pairs.map { Double($0.x) }
        let ys = pairs.map { Double($0.y) }
        let n = Double(pairs.count)
        let cx = xs.reduce(0, +) / n
        let cy = ys.reduce(0, +) / n
        let spread = Self.rotatedSpread(xs: xs, ys: ys, cx: cx, cy: cy)
        return PoincareStats(centerX: cx, centerY: cy, sd1: spread.sd1, sd2: spread.sd2)
    }

    /// Rotate each point by -45° so the ellipse axes align with x/y, then take
    /// the SD along each axis. SD1 → "y" axis after rotation, SD2 → "x" axis
    /// after rotation. Standard Poincaré analysis; Brennan et al. 2001.
    private static func rotatedSpread(xs: [Double], ys: [Double], cx: Double, cy: Double) -> (sd1: Double, sd2: Double) {
        var sumU2 = 0.0, sumV2 = 0.0
        for i in xs.indices {
            let dx = xs[i] - cx
            let dy = ys[i] - cy
            // u = along the line of identity (x = y); v = perpendicular to it.
            let u = (dx + dy) / sqrt(2)
            let v = (dy - dx) / sqrt(2)
            sumU2 += u * u
            sumV2 += v * v
        }
        let n = Double(xs.count)
        return (sqrt(sumV2 / n), sqrt(sumU2 / n))
    }

    /// 64-point polyline tracing the rotated SD1/SD2 ellipse, centered
    /// on (cx, cy), major axis along the line of identity.
    func ellipsePoints(stats: PoincareStats) -> [PoincareEllipsePoint] {
        let segments = 64
        let pi = Double.pi
        let cosA = cos(pi / 4)
        let sinA = sin(pi / 4)
        return (0...segments).map { i in
            let theta = Double(i) / Double(segments) * 2 * pi
            // Ellipse in axis-aligned space (sd2 along x, sd1 along y)
            let x0 = stats.sd2 * cos(theta)
            let y0 = stats.sd1 * sin(theta)
            // Rotate +45° back into RR_n vs RR_n+1 space
            let xr = x0 * cosA - y0 * sinA
            let yr = x0 * sinA + y0 * cosA
            return PoincareEllipsePoint(id: i, x: stats.centerX + xr, y: stats.centerY + yr)
        }
    }

    struct PoincarePair: Identifiable {
        /// Stable identity derived from the source beat
        /// index. A `UUID()` id mints a fresh id for every pair
        /// on every body evaluation, so Charts' ForEach sees all ~600
        /// points as removed + inserted each render instead of
        /// unchanged. Index-based ids make diffing a no-op.
        let id: Int
        let x: Int
        let y: Int
    }

    func buildPoincarePairs() -> [PoincarePair] {
        guard let series = effectiveRRSeries, series.points.count >= 2 else { return [] }
        let pts = series.points
        var out: [PoincarePair] = []
        // Cap to 600 pairs for chart perf.
        let stride = max(1, pts.count / 600)
        for i in Swift.stride(from: 0, to: pts.count - 1, by: stride) {
            out.append(PoincarePair(id: i, x: pts[i].rr_ms, y: pts[i + 1].rr_ms))
        }
        return out
    }

    // MARK: - Beat-to-Beat Consistency
    //
    // The card shows the night's feature medians, the calibrating-state
    // countdown, and a score once enough prior overnight nights are in the
    // baseline. The prior nights' features come from
    // `BeatConsistencyPriorsCache`, which computes each night once and
    // persists it.

    var beatConsistencyResult: BeatConsistency.NightlyResult? {
        // A pure state read. The priors walk and the full-night
        // `BeatConsistency.score` pass (too heavy for a body eval) run in
        // `loadBeatConsistencyBaseline`, from the view's `.task`.
        beatConsistencyComputed
    }

    var beatConsistencySection: some View {
        ChartCard(title: String(localized: "Beat consistency", bundle: LanguageManager.appBundle), unitLabel: String(localized: "deviation from your baseline", bundle: LanguageManager.appBundle)) {
            beatConsistencyContent
        }
    }

    @ViewBuilder
    var beatConsistencyContent: some View {
        // Show a real "Computing baseline…" state while the
        // priors walk is in flight, instead of misleadingly rendering
        // the `.calibrating(0, 14)` math state. The score is computed
        // from an empty `priorBaselineFeatures` until the .task finishes
        // (~5-10 s cold, instant warm via BeatConsistencyPriorsCache),
        // and during that window the user otherwise sees "0 of 14
        // nights" which they reasonably read as "stuck broken" rather
        // than "still loading."
        if !baselineLoadCompleted {
            computingBaselineRow
        } else if let bc = beatConsistencyResult {
            VStack(alignment: .leading, spacing: 12) {
                beatConsistencyHeader(bc)
                beatConsistencyFeatures(bc)
                beatConsistencyExplainer(bc)
            }
        } else {
            noBeatConsistencyState
        }
    }

    private var noBeatConsistencyState: some View {
        EmptyState(
            glyph: "waveform.path.ecg",
            headline: String(localized: "Not enough RR data", bundle: LanguageManager.appBundle),
            message: String(localized: "Beat consistency needs the raw RR stream from an overnight session.", bundle: LanguageManager.appBundle)
        )
    }

    private var computingBaselineRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(String(localized: "Computing baseline from recent overnight sessions…", bundle: LanguageManager.appBundle))
                .font(.system(size: dt13))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    func beatConsistencyHeader(_ bc: BeatConsistency.NightlyResult) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            beatConsistencyHeadline(bc)
            Spacer()
        }
    }

    /// A scored night shows the number and its band; an unscored one explains
    /// which state it's in instead.
    @ViewBuilder
    private func beatConsistencyHeadline(_ bc: BeatConsistency.NightlyResult) -> some View {
        if let score = bc.score {
            Text(verbatim: "\(score)")
                .font(.system(size: dt36, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            beatConsistencyBandText(bc.band)
        } else {
            Text(beatConsistencyStateLabel(bc.state))
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
        }
    }

    @ViewBuilder
    private func beatConsistencyBandText(_ band: BeatConsistency.Band?) -> some View {
        if let band {
            Text(beatConsistencyBandLabel(band))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(beatConsistencyBandTint(band))
        }
    }

    func beatConsistencyBandLabel(_ band: BeatConsistency.Band) -> String {
        switch band {
        case .consistent: String(localized: "Consistent", bundle: LanguageManager.appBundle)
        case .somewhatVariable: String(localized: "Somewhat variable", bundle: LanguageManager.appBundle)
        case .notablyVariable: String(localized: "Notably variable", bundle: LanguageManager.appBundle)
        }
    }

    func beatConsistencyBandTint(_ band: BeatConsistency.Band) -> Color {
        switch band {
        case .consistent: AppTheme.wongGood
        case .somewhatVariable: AppTheme.wongCaution
        case .notablyVariable: .orange
        }
    }

    func beatConsistencyStateLabel(_ state: BeatConsistency.State) -> String {
        switch state {
        case let .calibrating(collected, needed):
            return String(localized: "Calibrating — \(collected) of \(needed) nights", bundle: LanguageManager.appBundle)
        case let .lowConfidence(collected):
            return String(localized: "Low confidence — \(collected) nights collected", bundle: LanguageManager.appBundle)
        case .normal:
            return String(localized: "Score unavailable", bundle: LanguageManager.appBundle)
        case let .insufficientData(count):
            return String(localized: "Not enough valid windows (\(count))", bundle: LanguageManager.appBundle)
        }
    }

    @ViewBuilder
    func beatConsistencyFeatures(_ bc: BeatConsistency.NightlyResult) -> some View {
        let medians = bc.nightlyFeatureMedians
        HStack(spacing: 16) {
            // pNN50 is already computed in percent units in
            // BeatConsistency.computeFeatures
            // (`pNN50 = 100.0 * count / (n-1)`); multiplying by 100 again
            // here produces values like 2307.7% for
            // what is actually ~23%. CV(RR) IS a 0–1 ratio (stddev/mean)
            // so the * 100 conversion applies to that one only.
            beatConsistencyMetric(label: "pNN50", value: String(format: "%.1f%%", locale: LanguageManager.appLocale, medians.pNN50))
            beatConsistencyMetric(label: "CV(RR)", value: String(format: "%.1f%%", locale: LanguageManager.appLocale, medians.cvRR * 100))
            beatConsistencyMetric(label: "Δ-ratio", value: String(format: "%.2f", locale: LanguageManager.appLocale, medians.ratio))
        }
    }

    func beatConsistencyMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: dt16, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    func beatConsistencyExplainer(_ bc: BeatConsistency.NightlyResult) -> some View {
        let lineCount = bc.scoringWindowCount
        // Copy perimeter: 'diagnosis' is prohibited
        // outside the allowlisted disclaimer surfaces;
        // observation/range language instead.
        Text(String(localized: "Built from \(lineCount) thirty-second windows during sleep. An observation of deviation from YOUR own range — not a medical assessment. A user whose baseline already carries chronic irregularity will score Consistent because that irregularity has been absorbed into the baseline.", bundle: LanguageManager.appBundle))
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Engine Room

    private var engineRoomBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Never disabled: on a short reading the Frequency tab explains
            // why it's empty, and the other tabs must stay reachable.
            tabPicker
                .pickerStyle(.segmented)
            engineRoomGrid
        }
    }

    @ViewBuilder
    private var engineRoomGrid: some View {
        switch engineRoomTab {
        case .timeDomain: timeDomainGrid
        case .frequency: frequencyDomainGrid
        case .nonlinear: nonlinearGrid
        case .ans: ansGrid
        case .quality: qualityGrid
        }
    }

    var engineRoomSection: some View {
        EngineRoomDisclosure(
            title: String(localized: "Advanced metrics", bundle: LanguageManager.appBundle),
            memoryKey: "engineRoom.hrvDetail.\(session.id.uuidString)"
        ) {
            engineRoomBody
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(AppTheme.sectionTint)
            )
        }
    }

    private var tabPicker: some View {
        Picker(String(localized: "Tab", bundle: LanguageManager.appBundle), selection: $engineRoomTab) {
            ForEach(EngineTab.allCases, id: \.self) { tab in
                Text(tab.localizedName).tag(tab)
            }
        }
    }

    var timeDomainGrid: some View {
        let td = result.timeDomain
        return metricGrid([
            ("Mean RR", String(format: "%.0f ms", locale: LanguageManager.appLocale, td.meanRR)),
            ("SDNN", String(format: "%.1f ms", locale: LanguageManager.appLocale, td.sdnn)),
            ("RMSSD", String(format: "%.1f ms", locale: LanguageManager.appLocale, td.rmssd)),
            ("pNN50", String(format: "%.1f%%", locale: LanguageManager.appLocale, td.pnn50)),
            ("SDSD", String(format: "%.1f ms", locale: LanguageManager.appLocale, td.sdsd)),
            ("HR range", String(localized: "\(Int(td.minHR.rounded()))–\(Int(td.maxHR.rounded())) bpm", bundle: LanguageManager.appBundle)),
            ("Mean HR", String(localized: "\(Int(td.meanHR.rounded())) bpm", bundle: LanguageManager.appBundle)),
            ("SD HR", String(format: "%.1f bpm", locale: LanguageManager.appLocale, td.sdHR)),
            ("HRV TI", td.triangularIndex.map { String(format: "%.1f", locale: LanguageManager.appLocale, $0) } ?? "—")
        ])
    }

    @ViewBuilder
    var frequencyDomainGrid: some View {
        if let fd = result.frequencyDomain {
            metricGrid([
                ("LF", String(format: "%.0f ms²", locale: LanguageManager.appLocale, fd.lf)),
                ("HF", String(format: "%.0f ms²", locale: LanguageManager.appLocale, fd.hf)),
                ("Total power", String(format: "%.0f ms²", locale: LanguageManager.appLocale, fd.totalPower)),
                ("LF n.u.", fd.lfNu.map { String(format: "%.0f", locale: LanguageManager.appLocale, $0) } ?? "—"),
                ("HF n.u.", fd.hfNu.map { String(format: "%.0f", locale: LanguageManager.appLocale, $0) } ?? "—"),
                ("LF/HF", fd.lfHfRatio.map { String(format: "%.2f", locale: LanguageManager.appLocale, $0) } ?? "—")
            ])
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Frequency analysis unavailable", bundle: LanguageManager.appBundle))
                    .font(.system(size: dt14, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(String(localized: "Reading too short — Frequency analysis needs ≥256 clean beats. The Time Domain tab still has the standard HRV metrics.", bundle: LanguageManager.appBundle))
                    .font(.system(size: dt12))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var nonlinearGrid: some View {
        let nl = result.nonlinear
        return metricGrid([
            ("SD1", String(format: "%.1f ms", locale: LanguageManager.appLocale, nl.sd1)),
            ("SD2", String(format: "%.1f ms", locale: LanguageManager.appLocale, nl.sd2)),
            ("SD1/SD2", String(format: "%.2f", locale: LanguageManager.appLocale, nl.sd1Sd2Ratio)),
            ("DFA α1", nl.dfaAlpha1.map { String(format: "%.2f", locale: LanguageManager.appLocale, $0) } ?? "—"),
            ("DFA α2", nl.dfaAlpha2.map { String(format: "%.2f", locale: LanguageManager.appLocale, $0) } ?? "—"),
            ("α1 R²", nl.dfaAlpha1R2.map { String(format: "%.2f", locale: LanguageManager.appLocale, $0) } ?? "—"),
            ("SampEn", nl.sampleEntropy.map { String(format: "%.2f", locale: LanguageManager.appLocale, $0) } ?? "—"),
            ("ApEn", nl.approxEntropy.map { String(format: "%.2f", locale: LanguageManager.appLocale, $0) } ?? "—")
        ])
    }

    @ViewBuilder
    var ansGrid: some View {
        if let ans = result.ansMetrics {
            metricGrid([
                ("Stress", ans.stressIndex.map { String(format: "%.0f", locale: LanguageManager.appLocale, $0) } ?? "—"),
                ("PNS", ans.pnsIndex.map { String(format: "%+.2f", locale: LanguageManager.appLocale, $0) } ?? "—"),
                ("SNS", ans.snsIndex.map { String(format: "%+.2f", locale: LanguageManager.appLocale, $0) } ?? "—"),
                ("Resp rate", ans.respirationRate.map { String(format: "%.1f br/min", locale: LanguageManager.appLocale, $0) } ?? "—"),
                ("Readiness", ans.readinessScore.map { String(format: "%.1f", locale: LanguageManager.appLocale, $0) } ?? "—"),
                ("Nocturnal HR dip", ans.nocturnalHRDip.map { String(format: "%.0f%%", locale: LanguageManager.appLocale, $0) } ?? "—")
            ])
        } else {
            Text(String(localized: "ANS indexes unavailable for this reading.", bundle: LanguageManager.appBundle))
                .font(.system(size: dt13))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    /// The stored window-selection reason is an English diagnostic string
    /// (it lands in the log and the AI context), so it isn't shown here; its
    /// numbers are the RMSSD / α1 already in the grid.
    var qualityGrid: some View {
        metricGrid([
            ("Window beats", "\(result.cleanBeatCount)"),
            ("Artifacts", String(format: "%.1f%%", locale: LanguageManager.appLocale, result.artifactPercentage)),
            ("Window classification", result.displayWindowClassification ?? "—")
        ])
    }

    /// On-screen names for the grid's English metric keys. The English key
    /// still drives the info sheet and the compare sheet; abbreviations
    /// (RMSSD, SDNN, LF…) are the same in every language.
    static func localizedMetricName(_ key: String) -> String {
        let bundle = LanguageManager.appBundle
        switch key {
        case "Mean RR": return String(localized: "Mean RR", bundle: bundle)
        case "HR range": return String(localized: "HR range", bundle: bundle)
        case "Mean HR": return String(localized: "Mean HR", bundle: bundle)
        case "SD HR": return String(localized: "SD HR", bundle: bundle)
        case "Total power": return String(localized: "Total Power", bundle: bundle)
        case "Stress": return String(localized: "Stress", bundle: bundle)
        case "Resp rate": return String(localized: "Respiratory rate", bundle: bundle)
        case "Readiness": return String(localized: "Readiness", bundle: bundle)
        case "Nocturnal HR dip": return String(localized: "Nocturnal HR dip", bundle: bundle)
        case "Window beats": return String(localized: "Window beats", bundle: bundle)
        case "Artifacts": return String(localized: "Artifacts", bundle: bundle)
        case "Window classification": return String(localized: "Window classification", bundle: bundle)
        default: return key
        }
    }

    /// Every metric row carries a tappable
    /// ⓘ that opens the Metric Guide article in a sheet, AND a
    /// long-press → "Compare to history" sheet that plots the metric's
    /// trend against the user's recent baseline.
    func metricGrid(_ entries: [(String, String)]) -> some View {
        let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: cols, spacing: 8) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                metricCell(name: entry.0, value: entry.1)
            }
        }
    }

    /// Long-press opens "Compare to history"; VoiceOver users get the same
    /// sheet as a named custom action.
    private func metricCell(name: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: Self.localizedMetricName(name))
                .font(.system(size: dt12))
                .foregroundStyle(AppTheme.textTertiary)
            metricInfoButton(name: name)
            Spacer(minLength: 4)
            Text(verbatim: value)
                .font(.system(size: dt13, weight: .medium).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.cardBackground))
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.5) { compareSheetMetric = name }
        .accessibilityAction(named: Text(String(localized: "Compare to history", bundle: LanguageManager.appBundle))) {
            compareSheetMetric = name
        }
    }

    private func metricInfoButton(name: String) -> some View {
        Button {
            infoSheetMetric = name
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: dt11))
                .foregroundStyle(AppTheme.textTertiary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 44 pt tap target that lays out at the glyph's size, so the grid
        // cells don't grow.
        .padding(-14)
        .accessibilityLabel(Text(String(localized: "About \(Self.localizedMetricName(name))", bundle: LanguageManager.appBundle)))
    }

    // MARK: - Banners

    var artifactBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.wongCaution)
            Text(String(localized: "Signal quality was limited — \(Int(result.artifactPercentage.rounded()))% artifacts in the selected window. We searched the full night and this was the cleanest stretch we could find. Numbers are still informative but carry more uncertainty than usual.", bundle: LanguageManager.appBundle))
                .font(.system(size: dt13))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.wongCaution.opacity(0.12))
        )
    }

    func sectionHeading(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: dt13, weight: .semibold))
            .detailSectionHeadingStyle()
    }
}
