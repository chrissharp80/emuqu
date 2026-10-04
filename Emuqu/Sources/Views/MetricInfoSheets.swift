import Charts
import SwiftUI

/// Every metric in Engine Room has a tappable ⓘ that opens the Metric Guide
/// article for that metric in a sheet.
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
            Text(verbatim: HRVDetailV2View.localizedMetricName(metricLabel))
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
    /// metric. A label missing here falls back to the Morning Results popover's
    /// copy for the same metric, so the two glossaries never disagree and every
    /// grid metric has an entry. The values are factories rather than `Entry` values so the
    /// localized strings resolve at read time — caching the built `Entry` would
    /// freeze the copy in whichever language happened to be active the first
    /// time this table was touched.
    private static let entryFactories: [String: @MainActor () -> Entry] = [
        "RMSSD": rmssdEntry,
        "SDNN": sdnnEntry,
        "pNN50": pnn50Entry,
        "Mean RR": meanRREntry,
        "Mean HR": meanHREntry,
        "DFA α1": dfaAlpha1Entry,
        "SD1": sd1Entry,
        "SD2": sd2Entry,
        "LF": lfPowerEntry,
        "HF": hfPowerEntry,
        "LF/HF": lfhfRatioEntry,
        "Total Power": totalPowerEntry,
        "Total power": totalPowerEntry,
        "Stress": stressIndexEntry,
        "Stress index": stressIndexEntry,
        "Stress Index": stressIndexEntry,
        "Baevsky SI": stressIndexEntry,
        "Readiness": readinessEntry,
        "Readiness score": readinessEntry,
        "Artifacts": artifactsEntry,
        "Nocturnal HR dip": nocturnalDipEntry,
        "Window classification": windowClassificationEntry
    ]

    @MainActor
    static func entry(for label: String) -> Entry {
        if let factory = entryFactories[label] { return factory() }
        if let info = MetricExplanationPopover.info(forKey: label) {
            return Entry(short: info.fullName, body: info.description, typicalRange: info.interpretation)
        }
        return unknownEntry()
    }

    private static func rmssdEntry() -> Entry {
        Entry(
            short: String(localized: "Root Mean Square of Successive Differences — the headline parasympathetic indicator.", bundle: LanguageManager.appBundle),
            body: String(localized: "RMSSD is the root mean square of the differences between consecutive beat-to-beat gaps, so it measures how much each gap changes from the one before. It's the cleanest read of the vagal nerve's brake on heart rate. Higher = more recovered. Lower = more sympathetic / fatigued. Personal baselines matter way more than population norms — your trend over 7–28 days is the signal.", bundle: LanguageManager.appBundle),
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

    private static func meanRREntry() -> Entry {
        Entry(
            short: String(localized: "Average time between heartbeats across the analysis window.", bundle: LanguageManager.appBundle),
            body: String(localized: "Mean RR is the average gap between consecutive beats, in milliseconds. It is the inverse of mean heart rate: 1,000 ms equals 60 bpm. Longer gaps mean a slower heart, which during sleep usually goes with good recovery.", bundle: LanguageManager.appBundle),
            typicalRange: String(localized: "Awake at rest: about 750–1,000 ms (60–80 bpm). Asleep: about 900–1,300 ms (45–65 bpm).", bundle: LanguageManager.appBundle)
        )
    }

    private static func meanHREntry() -> Entry {
        Entry(
            short: String(localized: "Average heartbeat rate across the analysis window.", bundle: LanguageManager.appBundle),
            body: String(localized: "The slowest your heart beats during deep sleep tracks fitness and recovery: a lower value (within reason) usually goes with higher aerobic fitness and good recovery. Big day-over-day jumps in sleeping heart rate are worth noticing: they most often follow hard training, short sleep, alcohol, heat or stress, and sometimes come with the start of an illness.", bundle: LanguageManager.appBundle),
            typicalRange: String(localized: "Awake at rest: about 60–80 bpm for adults. Asleep: about 45–65 bpm. Lower in endurance athletes.", bundle: LanguageManager.appBundle)
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
            body: String(localized: "Mostly reflects baroreflex activity, with both sympathetic and parasympathetic input. It is not a sympathetic index on its own, and neither is LF/HF (Billman 2013). Read it alongside HF and against your own baseline.", bundle: LanguageManager.appBundle),
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
            short: String(localized: "LF/HF Ratio", bundle: LanguageManager.appBundle),
            body: String(localized: "The ratio of low-frequency to high-frequency power. Long used as a sympathovagal balance index, an interpretation the evidence does not support (Billman 2013) — LF is not a sympathetic signal.", bundle: LanguageManager.appBundle),
            typicalRange: String(localized: "Usual resting range 0.5-2.0. Read it as a position in that range, not as autonomic balance. Breathing rate moves it as much as anything else — slow paced breathing pushes it up sharply.", bundle: LanguageManager.appBundle)
        )
    }

    private static func totalPowerEntry() -> Entry {
        Entry(
            short: String(localized: "Sum of VLF + LF + HF power — the full autonomic spectrum.", bundle: LanguageManager.appBundle),
            body: String(localized: "Most useful as a trend against your own baseline: a sharp drop usually tracks accumulated training load, short sleep, alcohol or stress, and sometimes illness. It describes last night; it is not a forecast. Flo reads the total power of the night's peak window.", bundle: LanguageManager.appBundle),
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
            typicalRange: String(localized: "7–10: Ready. 4.5–7: Moderate. 2–4.5: Fatigued. Below 2: Rest.", bundle: LanguageManager.appBundle)
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

    private static func nocturnalDipEntry() -> Entry {
        Entry(
            short: String(localized: "How far your sleeping heart rate fell below your daytime resting heart rate.", bundle: LanguageManager.appBundle),
            body: [
                String(localized: "The percentage drop from your daytime resting heart rate to the median heart rate of the night's clean beats.", bundle: LanguageManager.appBundle),
                String(localized: "A clear overnight dip is the usual pattern; a small one can follow late training, alcohol, a warm room or the start of an illness. Read it against your own nights rather than a fixed number.", bundle: LanguageManager.appBundle)
            ].joined(separator: " "),
            typicalRange: nil
        )
    }

    private static func windowClassificationEntry() -> Entry {
        Entry(
            short: String(localized: "How the analysis window was chosen.", bundle: LanguageManager.appBundle),
            body: [
                String(localized: "A label for the window selection, not a statement about your nervous system. Organized Recovery: DFA α1 sat in the app's resting reference range (about 0.75–1.0) with a steady heart rate.", bundle: LanguageManager.appBundle),
                String(localized: "Flexible / Unconsolidated: α1 a little below that range. High Variability: α1 outside both. Peak Capacity: the window was picked for its highest HRV. Insufficient Data: too few clean beats to classify.", bundle: LanguageManager.appBundle)
            ].joined(separator: " "),
            typicalRange: nil
        )
    }

    private static func unknownEntry() -> Entry {
        Entry(
            short: String(localized: "Engine Room metric — see Settings → Metric Guide for the full glossary.", bundle: LanguageManager.appBundle),
            body: String(localized: "This metric isn't yet covered in the per-metric guide. Settings → Metric Guide has the full reference.", bundle: LanguageManager.appBundle),
            typicalRange: nil
        )
    }
}

/// Long-press any metric to open the 'Compare to history' sheet.
///
/// Plots the selected metric across the user's last 30 reliable overnight
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

    // Memoized via @State + .task. Building the points
    // inline in the view body means
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
            Text(verbatim: HRVDetailV2View.localizedMetricName(metricLabel))
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

    /// Labels with no numeric value to plot. The Engine Room hides the
    /// "Compare to history" action for them.
    static func canCompare(_ label: String) -> Bool {
        label != "Window classification"
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

    nonisolated private static func computePoints(metricLabel: String, archive: SessionArchive) -> [Point] {
        // Static / nonisolated so the work can run on Task.detached
        // without capturing `self`. `fastValueStatic` and `analysisValueStatic`
        // below are also static nonisolated — they only branch on
        // the label, no instance state required.
        return computePointsImpl(metricLabel: metricLabel, archive: archive)
    }

    /// Walks the whole archive, newest first, and keeps the most recent 30
    /// reliable overnight readings that carry the metric. Workout, Quick and
    /// Breathe readings are left out so they cannot widen the ±1 SD band.
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

    /// Reliable overnight entries only. Fast path first: the four metrics
    /// cached on the index entry. Otherwise fall back to a lightweight
    /// session read.
    nonisolated private static func pointValue(metricLabel: String, entry: SessionArchiveEntry, archive: SessionArchive) -> Point? {
        guard entry.sessionType == .overnight, entry.isReliableForHRVAggregates else { return nil }
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
        case "Mean HR": return entry.meanHR
        case "SDNN": return entry.meanSDNN
        case "Stress", "Stress index", "Stress Index", "Baevsky SI": return entry.stressIndex
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

    /// Labels match the Engine Room grid (`HRVDetailV2View+Charts.swift`) and
    /// the longer forms other screens use.
    nonisolated private static func timeDomainValue(for label: String, result: HRVAnalysisResult) -> Double? {
        let td = result.timeDomain
        switch label {
        case "RMSSD": return td.rmssd
        case "SDNN": return td.sdnn
        case "SDSD": return td.sdsd
        case "Mean RR": return td.meanRR
        case "Mean HR": return td.meanHR
        case "HR range": return td.maxHR - td.minHR
        case "SD HR": return td.sdHR
        case "Min HR": return td.minHR
        case "Max HR": return td.maxHR
        case "pNN50": return td.pnn50
        case "HRV TI", "Triangular Index", "TINN": return td.triangularIndex
        default: return nil
        }
    }

    nonisolated private static func frequencyValue(for label: String, result: HRVAnalysisResult) -> Double? {
        switch label {
        case "LF": return result.frequencyDomain?.lf
        case "HF": return result.frequencyDomain?.hf
        case "LF/HF", "Balance": return result.frequencyDomain?.lfHfRatio
        case "Total Power", "Total power": return result.frequencyDomain?.totalPower
        case "LF n.u.": return result.frequencyDomain?.lfNu
        case "HF n.u.": return result.frequencyDomain?.hfNu
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
        case "α1 R²": return result.nonlinear.dfaAlpha1R2
        case "SampEn", "Sample entropy": return result.nonlinear.sampleEntropy
        case "ApEn", "Approx entropy": return result.nonlinear.approxEntropy
        default: return nil
        }
    }

    nonisolated private static func ansValue(for label: String, result: HRVAnalysisResult) -> Double? {
        switch label {
        case "Stress", "Stress index", "Stress Index", "Baevsky SI": return result.ansMetrics?.stressIndex
        case "PNS", "PNS Index": return result.ansMetrics?.pnsIndex
        case "SNS", "SNS Index": return result.ansMetrics?.snsIndex
        case "Readiness", "Readiness score": return result.ansMetrics?.readinessScore
        case "Resp rate", "Respiration rate": return result.ansMetrics?.respirationRate
        case "Nocturnal HR dip": return result.ansMetrics?.nocturnalHRDip
        default: return nil
        }
    }

    nonisolated private static func qualityValue(for label: String, result: HRVAnalysisResult) -> Double? {
        switch label {
        case "Artifacts", "Artifact %": return result.artifactPercentage
        case "Window beats": return Double(result.cleanBeatCount)
        default: return nil
        }
    }

}
