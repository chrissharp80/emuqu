import Charts
import SwiftUI

/// BP §D3 line 634 — "Each metric in Engine Room has tappable ⓘ that
/// opens the Metric Guide article for that metric in a sheet."
///
/// Self-contained glossary sheet keyed on the metric label. The
/// existing app already has a `MetricGuideView` (Help Center → Metric
/// Guide) but it's an everything-at-once index; this sheet is the
/// per-metric drill-in, opened from the Engine Room grid taps.
struct MetricInfoSheet: View {
    let metricLabel: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                metricInfoStack
            }
            .background(AppTheme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { doneToolbarItem }
        }
    }

    @ToolbarContentBuilder
    private var doneToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { dismiss() }
        }
    }

    private var metricInfoStack: some View {
        VStack(alignment: .leading, spacing: 14) {
            metricHeadline
            whatItMeansSection
            typicalRangeCallout
        }
        .padding(20)
    }

    private var metricHeadline: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: metricLabel)
                .scaledFont(size: 28, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: Self.entry(for: metricLabel).short)
                .scaledFont(size: 17)
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var whatItMeansSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Localizable prose, not Text(verbatim:), which opts
            // out of translation.
            Text(String(localized: "What it means", bundle: LanguageManager.appBundle))
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(.uppercase)
                .padding(.top, 8)
            Text(verbatim: Self.entry(for: metricLabel).body)
                .scaledFont(size: 15)
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var typicalRangeCallout: some View {
        if let typical = Self.entry(for: metricLabel).typicalRange {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Typical range", bundle: LanguageManager.appBundle))
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(AppTheme.textSecondary)
                    .textCase(.uppercase)
                Text(verbatim: typical)
                    .scaledFont(size: 15)
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        }
    }

    /// Glossary entries keyed by the verbatim labels used in the
    /// Engine Room metric grids. Each entry: a one-line short, a
    /// fuller body, and an optional typical range. Adding a new
    /// metric to the grid requires adding it here too — that's
    /// intentional, so the AI's "where does this number come from"
    /// lives next to the number itself.
    struct Entry {
        let short: String
        let body: String
        let typicalRange: String?
    }

    /// Per-metric copy, keyed by every label the Engine Room uses for that
    /// metric. The values are factories rather than `Entry` values so the
    /// localized strings resolve at read time — caching the built `Entry` would
    /// freeze the copy in whichever language happened to be active the first
    /// time this table was touched.
    private static let entryFactories: [String: @MainActor () -> Entry] = [
        "RMSSD": rmssdEntry,
        "SDNN": sdnnEntry,
        "pNN50": pnn50Entry,
        "Mean RR": meanHREntry,
        "Mean HR": meanHREntry,
        "DFA α1": dfaAlpha1Entry,
        "SD1": sd1Entry,
        "SD2": sd2Entry,
        "LF": lfPowerEntry,
        "HF": hfPowerEntry,
        "LF/HF": lfhfRatioEntry,
        "Total Power": totalPowerEntry,
        "Stress index": stressIndexEntry,
        "Stress Index": stressIndexEntry,
        "Baevsky SI": stressIndexEntry,
        "Readiness": readinessEntry,
        "Readiness score": readinessEntry,
        "Artifacts": artifactsEntry
    ]

    @MainActor
    static func entry(for label: String) -> Entry {
        (entryFactories[label] ?? unknownEntry)()
    }

    private static func rmssdEntry() -> Entry {
        Entry(
            short: String(localized: "Root Mean Square of Successive Differences — the headline parasympathetic indicator.", bundle: LanguageManager.appBundle),
            body: String(localized: "RMSSD is the standard deviation of the gaps BETWEEN consecutive heartbeats, not the beats themselves. It's the cleanest read of the vagal nerve's brake on heart rate. Higher = more recovered. Lower = more sympathetic / fatigued. Personal baselines matter way more than population norms — your trend over 7–28 days is the signal.", bundle: LanguageManager.appBundle),
            typicalRange: String(localized: "Adults: 20–80 ms (huge person-to-person variability). Athletes often 60–120 ms.", bundle: LanguageManager.appBundle)
        )
    }

    private static func sdnnEntry() -> Entry {
        Entry(
            short: String(localized: "Standard deviation of all RR intervals — total variability.", bundle: LanguageManager.appBundle),
            body: String(localized: "SDNN captures both the slow (sympathetic / breathing-driven) and the fast (vagal) variations in heart rate. Useful for total autonomic-tone snapshots, but RMSSD is cleaner for vagal tone alone.", bundle: LanguageManager.appBundle),
            typicalRange: String(localized: "Resting: 30–120 ms. Sleep windows usually 50–150 ms.", bundle: LanguageManager.appBundle)
        )
    }

    private static func pnn50Entry() -> Entry {
        Entry(
            short: String(localized: "% of consecutive RR pairs that differ by > 50 ms — a coarse vagal-tone proxy.", bundle: LanguageManager.appBundle),
            body: String(localized: "Easy to compute, easy to read: high pNN50 ⇒ heart rate is jumping around beat-to-beat ⇒ strong parasympathetic input. RMSSD is more sensitive but pNN50 is sometimes more readable on short windows.", bundle: LanguageManager.appBundle),
            typicalRange: String(localized: "Resting: 5–40%. Higher in young / fit subjects.", bundle: LanguageManager.appBundle)
        )
    }

    private static func meanHREntry() -> Entry {
        Entry(
            short: String(localized: "Average heartbeat rate across the analysis window.", bundle: LanguageManager.appBundle),
            body: String(localized: "The slowest your heart beats during deep sleep is a clean fitness + recovery proxy: lower (within reason) means a stronger heart and better autonomic control. Big day-over-day jumps in sleeping heart rate are worth noticing: they most often follow hard training, short sleep, alcohol, heat or stress, and sometimes come with the start of an illness.", bundle: LanguageManager.appBundle),
            typicalRange: String(localized: "Sleep HR: 45–65 bpm typical, lower for endurance athletes.", bundle: LanguageManager.appBundle)
        )
    }

    private static func dfaAlpha1Entry() -> Entry {
        Entry(
            short: String(localized: "Detrended Fluctuation Analysis short-scale exponent — describes the pattern of your beat-to-beat variation, not its size.", bundle: LanguageManager.appBundle),
            body: String(localized: "α1 in 0.75–1.0 is the app's resting reference range, where most resting adult recordings sit. Above 1.0 = more correlated, seen with stress and with slow breathing. Below 0.75 → 0.5 during exercise tracks rising intensity (LT1/VT1 around 0.75). Below 0.5 = hard exercise.", bundle: LanguageManager.appBundle),
            typicalRange: String(localized: "Resting reference range: 0.75–1.0. Hard exercise: < 0.50.", bundle: LanguageManager.appBundle)
        )
    }

    private static func sd1Entry() -> Entry {
        Entry(
            short: String(localized: "Poincaré short-axis spread (perpendicular to identity line) — beat-to-beat variability.", bundle: LanguageManager.appBundle),
            body: String(localized: "Equivalent to RMSSD/√2. Visualizes the same parasympathetic signal as RMSSD on the Poincaré plot.", bundle: LanguageManager.appBundle),
            typicalRange: String(localized: "Mirrors RMSSD.", bundle: LanguageManager.appBundle)
        )
    }

    private static func sd2Entry() -> Entry {
        Entry(
            short: String(localized: "Poincaré long-axis spread — overall variability across the recording.", bundle: LanguageManager.appBundle),
            body: String(localized: "Mathematically related to both RMSSD and SDNN; mostly useful as a sanity check on the Poincaré ellipse shape (SD2/SD1 ratio).", bundle: LanguageManager.appBundle),
            typicalRange: String(localized: "Resting: 50–150 ms.", bundle: LanguageManager.appBundle)
        )
    }

    private static func lfPowerEntry() -> Entry {
        Entry(
            short: String(localized: "Low-frequency band power (0.04–0.15 Hz) — sympathetic + parasympathetic mix.", bundle: LanguageManager.appBundle),
            body: String(localized: "Often interpreted as a sympathetic indicator but contains parasympathetic input too. More reliable as a ratio (LF/HF) or in combination with HF, not in isolation.", bundle: LanguageManager.appBundle),
            typicalRange: String(localized: "Resting: 200–2,000 ms².", bundle: LanguageManager.appBundle)
        )
    }

    private static func hfPowerEntry() -> Entry {
        Entry(
            short: String(localized: "High-frequency band power (0.15–0.4 Hz) — almost pure parasympathetic.", bundle: LanguageManager.appBundle),
            body: String(localized: "Tracks respiratory sinus arrhythmia. Rises when you're calm and breathing slowly; collapses under stress. Pairs well with RMSSD for vagal-tone reads.", bundle: LanguageManager.appBundle),
            typicalRange: String(localized: "Resting: 100–1,500 ms².", bundle: LanguageManager.appBundle)
        )
    }

    private static func lfhfRatioEntry() -> Entry {
        Entry(
            short: String(localized: "Sympathovagal balance ratio.", bundle: LanguageManager.appBundle),
            body: String(localized: "Conventionally interpreted as sympathetic-to-parasympathetic balance, but LF carries parasympathetic input too — read it as a SHIFT signal (today vs your baseline) more than an absolute number.", bundle: LanguageManager.appBundle),
            typicalRange: String(localized: "Resting: 0.5–2.5. Stress states push higher.", bundle: LanguageManager.appBundle)
        )
    }

    private static func totalPowerEntry() -> Entry {
        Entry(
            short: String(localized: "Sum of VLF + LF + HF power — the full autonomic spectrum.", bundle: LanguageManager.appBundle),
            body: String(localized: "Most useful as a trend against your own baseline (Plews 2013): a sharp drop usually tracks accumulated training load, short sleep, alcohol or stress, and sometimes illness. It describes last night; it is not a forecast. The peak nightly version (peak window's total power) is what feeds the AI's `hrv.peak.total_power_ms2` fact.", bundle: LanguageManager.appBundle),
            typicalRange: String(localized: "Highly individual; track relative drops > 30%.", bundle: LanguageManager.appBundle)
        )
    }

    private static func stressIndexEntry() -> Entry {
        Entry(
            short: String(localized: "Baevsky's stress index — a Russian-physiology integral measure.", bundle: LanguageManager.appBundle),
            body: String(localized: "Combines mode, mode amplitude, and variation range into a single number that rises with sympathetic load and drops with parasympathetic dominance. Useful in trend, less so as an isolated value.", bundle: LanguageManager.appBundle),
            typicalRange: String(localized: "Resting: 50–150. Stressed: 200+.", bundle: LanguageManager.appBundle)
        )
    }

    private static func readinessEntry() -> Entry {
        Entry(
            short: String(localized: "Composite 1–10 readiness from the HRV pipeline.", bundle: LanguageManager.appBundle),
            body: String(localized: "Built from RMSSD plus DFA α1 banding and autonomic balance, scaled to your aerobic capacity. It reads CAPACITY — how much your system can handle — so it can sit high even on a day your Recovery score is low. Recovery answers a different question: today vs YOUR recent baseline. When the two diverge, trust Recovery for whether to go hard today, and Readiness for your underlying fitness ceiling.", bundle: LanguageManager.appBundle),
            typicalRange: String(localized: "5 = baseline. 7+ = well recovered. < 4 = depleted.", bundle: LanguageManager.appBundle)
        )
    }

    private static func artifactsEntry() -> Entry {
        Entry(
            short: String(localized: "Percentage of beats the cleaner had to interpolate or drop.", bundle: LanguageManager.appBundle),
            body: String(
                localized: "Above 10% means signal quality was limited (loose strap, motion, electrode dryness). The metrics still compute but the headline numbers carry more noise — a reading at 15% artifacts is informative but not as precise as a clean reading at 2%.",
                bundle: LanguageManager.appBundle
            ),
            typicalRange: String(localized: "< 5% great. < 10% fine. > 15% reconsider.", bundle: LanguageManager.appBundle)
        )
    }

    private static func unknownEntry() -> Entry {
        Entry(
            short: String(localized: "Engine Room metric — see the Help Center → Metric Guide for the full glossary.", bundle: LanguageManager.appBundle),
            body: String(localized: "This metric isn't yet covered in the per-metric guide. The Metric Guide in Settings → Help Center has the full reference.", bundle: LanguageManager.appBundle),
            typicalRange: nil
        )
    }
}

/// BP §D3 line 636 — "Long-press any metric → 'Compare to history' sheet."
///
/// Plots the selected metric across the user's last 30 overnight
/// readings, with mean ±1 SD shown as a baseline band so the user can
/// see today's value in context. Reads from the lightweight session
/// archive so opening the sheet is fast (no rrSeries decode).
struct MetricCompareToHistorySheet: View {
    let metricLabel: String
    let archive: SessionArchive
    @Environment(\.dismiss) private var dismiss

    private struct Point: Identifiable {
        let id: Date
        let date: Date
        let value: Double
    }

    // Memoized via @State + .task. Calling
    // `buildPoints()` inline in the view body means
    // every body recompute (sheet present, gesture, state change)
    // re-walks the archive and re-decodes up to 30 sessions via
    // `archive.retrieveLightweight`. Each lightweight retrieve is
    // ~5-20 ms; iterating until 30 valid points = 100-500 ms per
    // recompute, on main, blocking the sheet's responsiveness.
    @State private var pointsLoadCompleted = false
    @State private var pts: [Point] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                historyStack
                    .padding(20)
            }
            .background(AppTheme.background)
            .navigationTitle(Text(String(localized: "Compare to history", bundle: LanguageManager.appBundle)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { historyDoneToolbarItem }
            .task(id: metricLabel) { await loadPoints() }
        }
    }

    private var historyStack: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: metricLabel)
                .scaledFont(size: 22, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            Text(String(localized: "Last 30 readings", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            historyChartSection
        }
    }

    /// The if-let unwraps satisfy the count >= 4 branch without a force unwrap
    /// (count < 4 paths take the first branch, leaving the chart branch with at
    /// least 4 readings — first and last are always present at that point).
    @ViewBuilder
    private var historyChartSection: some View {
        if !pointsLoadCompleted {
            historyLoadingRow
        } else if pts.count < 4 || pts.first == nil || pts.last == nil {
            // Localizable prose, not Text(verbatim:).
            Text(String(localized: "Need at least 4 readings with this metric to plot a comparison. Keep recording — the chart fills in as your archive grows.", bundle: LanguageManager.appBundle))
                .scaledFont(size: 14)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(20)
        } else if let firstPt = pts.first, let lastPt = pts.last {
            historyChart(firstPt: firstPt, lastPt: lastPt)
            // Localizable prose, not Text(verbatim:).
            Text(String(localized: "Shaded band = mean ±1 SD across these readings. Dots outside the band are the days worth a closer look.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var historyLoadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(String(localized: "Loading history…", bundle: LanguageManager.appBundle))
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(20)
    }

    /// Every reading as a dot, over a mean ±1 SD band — dots outside the band
    /// are the days worth a closer look.
    private func historyChart(firstPt: Point, lastPt: Point) -> some View {
        let mean = pts.map(\.value).reduce(0, +) / Double(pts.count)
        let sd = sqrt(pts.map { pow($0.value - mean, 2) }.reduce(0, +) / Double(pts.count))
        return Chart {
            spreadBand(firstPt: firstPt, lastPt: lastPt, mean: mean, sd: sd)
            RuleMark(y: .value("Mean", mean))
                .foregroundStyle(AppTheme.textTertiary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            readingMarks(mean: mean, sd: sd)
        }
        .frame(height: 240)
    }

    private func spreadBand(firstPt: Point, lastPt: Point, mean: Double, sd: Double) -> some ChartContent {
        RectangleMark(
            xStart: .value("Start", firstPt.date),
            xEnd: .value("End", lastPt.date),
            yStart: .value("Lower", mean - sd),
            yEnd: .value("Upper", mean + sd)
        )
        .foregroundStyle(AppTheme.primary.opacity(0.08))
    }

    private func readingMarks(mean: Double, sd: Double) -> some ChartContent {
        ForEach(pts) { p in
            PointMark(
                x: .value("Date", p.date),
                y: .value(metricLabel, p.value)
            )
            .symbolSize(40)
            .foregroundStyle(p.value < mean - sd || p.value > mean + sd ? AppTheme.wongCaution : AppTheme.primary)
        }
    }

    @ToolbarContentBuilder
    private var historyDoneToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { dismiss() }
        }
    }

    /// Off-main load on sheet present (and on metric-label change). Archive walk
    /// + lightweight session decodes happen on the cooperative pool; the result
    /// is published once, on main.
    private func loadPoints() async {
        let archiveCapture = archive
        let labelCapture = metricLabel
        let loaded: [Point] = await Task.detached(priority: .userInitiated) {
            Self.buildPointsStatic(metricLabel: labelCapture, archive: archiveCapture)
        }.value
        if Task.isCancelled { return }
        pts = loaded
        pointsLoadCompleted = true
    }

    /// Static, archive-injected variant of `buildPoints` so it can run
    /// from a `Task.detached` without capturing `self`.
    nonisolated private static func buildPointsStatic(metricLabel: String, archive: SessionArchive) -> [Point] {
        return computePoints(metricLabel: metricLabel, archive: archive)
    }

    private func buildPoints() -> [Point] {
        return Self.computePoints(metricLabel: metricLabel, archive: archive)
    }

    nonisolated private static func computePoints(metricLabel: String, archive: SessionArchive) -> [Point] {
        // Static / nonisolated so the work can run on Task.detached
        // without capturing `self`. `fastValue` and `analysisValue`
        // below are also static nonisolated — they only branch on
        // the label, no instance state required.
        return computePointsImpl(metricLabel: metricLabel, archive: archive)
    }

    /// The candidate pool is ALL sessions, not the LAST 30 of any type. For
    /// metrics that are
    /// only meaningful for overnight recordings (Total power / VLF / DFA α2 /
    /// nocturnal HR dip), a user who records mostly Quick/Breathe sessions would
    /// otherwise see the "need 4 readings" message even with dozens of
    /// overnights archived. Each metric has a different "is this session relevant?" gate;
    /// we widen the candidate pool to ALL sessions, run the metric resolver
    /// against each, and keep the most-recent 30 SUCCESSFUL extractions. That
    /// way every metric — universal (RMSSD) or overnight-only (Total power) —
    /// sees the right number of points.
    nonisolated private static func computePointsImpl(metricLabel: String, archive: SessionArchive) -> [Point] {
        let allEntries = archive.entries.sorted { $0.date > $1.date }
        var collected: [Point] = []
        for entry in allEntries {
            if let point = pointValue(metricLabel: metricLabel, entry: entry, archive: archive) {
                collected.append(point)
            }
            if collected.count >= 30 { break }
        }
        return collected.reversed()
    }

    /// Fast path first: the four metrics cached on the index entry. Otherwise
    /// fall back to a lightweight session read.
    nonisolated private static func pointValue(metricLabel: String, entry: SessionArchiveEntry, archive: SessionArchive) -> Point? {
        if let v = fastValueStatic(for: metricLabel, entry: entry) {
            return Point(id: entry.date, date: entry.date, value: v)
        }
        guard let session = try? archive.retrieveLightweight(entry.sessionId),
              let result = session.analysisResult,
              let v = Self.analysisValueStatic(for: metricLabel, result: result)
        else { return nil }
        return Point(id: entry.date, date: entry.date, value: v)
    }

    nonisolated private static func fastValueStatic(for label: String, entry: SessionArchiveEntry) -> Double? {
        switch label {
        case "RMSSD": return entry.meanRMSSD
        case "Mean HR", "Mean RR": return entry.meanHR
        case "SDNN": return entry.meanSDNN
        case "Stress index", "Stress Index", "Baevsky SI": return entry.stressIndex
        default: return nil
        }
    }

    nonisolated private static func analysisValueStatic(for label: String, result: HRVAnalysisResult) -> Double? {
        timeDomainValue(for: label, result: result)
            ?? frequencyValue(for: label, result: result)
            ?? nonlinearValue(for: label, result: result)
            ?? ansValue(for: label, result: result)
            ?? qualityValue(for: label, result: result)
    }

    nonisolated private static func timeDomainValue(for label: String, result: HRVAnalysisResult) -> Double? {
        switch label {
        case "RMSSD": return result.timeDomain.rmssd
        case "SDNN": return result.timeDomain.sdnn
        case "Mean HR", "Mean RR": return result.timeDomain.meanHR
        case "Min HR": return result.timeDomain.minHR
        case "Max HR": return result.timeDomain.maxHR
        case "pNN50": return result.timeDomain.pnn50
        case "Triangular Index", "TINN": return result.timeDomain.triangularIndex
        default: return nil
        }
    }

    nonisolated private static func frequencyValue(for label: String, result: HRVAnalysisResult) -> Double? {
        switch label {
        case "LF": return result.frequencyDomain?.lf
        case "HF": return result.frequencyDomain?.hf
        case "LF/HF", "Balance": return result.frequencyDomain?.lfHfRatio
        case "Total Power": return result.frequencyDomain?.totalPower
        case "VLF": return result.frequencyDomain?.vlf
        default: return nil
        }
    }

    nonisolated private static func nonlinearValue(for label: String, result: HRVAnalysisResult) -> Double? {
        switch label {
        case "SD1": return result.nonlinear.sd1
        case "SD2": return result.nonlinear.sd2
        case "SD1/SD2": return result.nonlinear.sd1Sd2Ratio
        case "DFA α1", "DFA α₁", "DFA alpha1": return result.nonlinear.dfaAlpha1
        case "DFA α2", "DFA α₂", "DFA alpha2": return result.nonlinear.dfaAlpha2
        case "Sample entropy": return result.nonlinear.sampleEntropy
        case "Approx entropy": return result.nonlinear.approxEntropy
        default: return nil
        }
    }

    nonisolated private static func ansValue(for label: String, result: HRVAnalysisResult) -> Double? {
        switch label {
        case "Stress index", "Stress Index", "Baevsky SI": return result.ansMetrics?.stressIndex
        case "PNS Index": return result.ansMetrics?.pnsIndex
        case "SNS Index": return result.ansMetrics?.snsIndex
        case "Readiness", "Readiness score": return result.ansMetrics?.readinessScore
        case "Respiration rate": return result.ansMetrics?.respirationRate
        default: return nil
        }
    }

    nonisolated private static func qualityValue(for label: String, result: HRVAnalysisResult) -> Double? {
        switch label {
        case "Artifacts", "Artifact %": return result.artifactPercentage
        default: return nil
        }
    }

}
