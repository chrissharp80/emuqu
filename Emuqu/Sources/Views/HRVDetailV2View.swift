import Charts
import SwiftUI

/// Build plan §4.2 D3 — HRV detail. Kubios-grade depth organised so the
/// first-time tapper sees a clean hero + interpretation, while the power
/// user can drill into Time/Frequency/Nonlinear/ANS/Quality grids inside
/// the EngineRoomDisclosure.
///
/// Layout (top to bottom):
///   1. Title "HRV"
///   2. Hero — RMSSD value, verdict pill, one-sentence interpretation
///   3. Min/Avg/Max/SDNN strip (4-up)
///   4. Autonomic Capacity card — peak RMSSD/SDNN/window HR
///   5. Trend Analysis — 4 rows current vs avg vs baseline
///   6. HRV waveform chart (RR intervals, scrubbable)
///   7. Poincaré plot
///   8. EngineRoomDisclosure with five tabbed metric grids
///
/// Edge cases:
///   - Reading too short for Frequency Domain (< 256 beats) → tab grayed
///   - High artifact rate (> 10%) → caution banner
struct HRVDetailV2View: View {
    @Environment(\.dependencies) var dependencies
    // MARK: - Dynamic Type
    //
    // These replace hard-coded `.font(.system(size: N))`
    // literals, which do not respond to the user's text-size setting at all.
    // The app's semantic styles (`.body`, `.caption`, …) DO scale, so at AX5 the
    // surrounding text grows while literals stay put — breaking layout and
    // leaving the largest figures on screen at their smallest size for exactly
    // the users who enlarged their text.
    //
    // `@ScaledMetric(relativeTo:)` is the mechanism SwiftUI provides: there is no
    // `Font.system(size:relativeTo:)` overload. Each literal is bound to the text
    // style whose default size is nearest, so the default-setting appearance is
    // unchanged. Same pattern as DashboardV2View.
    @ScaledMetric(relativeTo: .caption2) var dt11: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) var dt12: CGFloat = 12
    @ScaledMetric(relativeTo: .footnote) var dt13: CGFloat = 13
    @ScaledMetric(relativeTo: .footnote) var dt14: CGFloat = 14
    @ScaledMetric(relativeTo: .callout) var dt16: CGFloat = 16
    @ScaledMetric(relativeTo: .body) var dt18: CGFloat = 18
    @ScaledMetric(relativeTo: .title3) var dt20: CGFloat = 20
    @ScaledMetric(relativeTo: .largeTitle) var dt36: CGFloat = 36
    @ScaledMetric(relativeTo: .largeTitle) var dt56: CGFloat = 56

    let session: HRVSession
    let result: HRVAnalysisResult
    let recentSessions: [HRVSession]
    let baselineStats: BaselineTracker.RecoveryBaselineStats?

    @Environment(RRCollector.self) private var collector
    @State var engineRoomTab: EngineTab = .timeDomain
    /// BP §D3 line 634 — info sheet keyed on the metric label that
    /// was tapped (RMSSD, SDNN, pNN50, etc.). Looks up the matching
    /// glossary entry and renders the explanation.
    @State var infoSheetMetric: String?
    /// BP §D3 line 636 — Compare to history sheet, fired on long-press
    /// of any metric tile. Renders a 30-day series of that metric
    /// with the user's recent baseline overlaid.
    @State var compareSheetMetric: String?
    /// Full RR series re-loaded from disk on appear. Dashboard pushes a
    /// lightweight session whose `rrSeries` is stripped (the
    /// `retrieveLightweightOrLog` skip flag) — without this re-load the
    /// HRV waveform + Poincaré charts can never render.
    /// Same approach as RecoveryScoreDetailView.
    @State private var fullRRSeries: RRSeries?
    /// Explicit "load is complete" flag so
    /// the Poincaré / HRV-waveform empty-state copy can distinguish
    /// "still loading" from "loaded, but the session has no rrSeries".
    /// Using `fullRRSeries == nil && session.rrSeries == nil`
    /// as the loading proxy spins forever on legacy sessions where
    /// the load completed but found nothing on disk.
    @State var rrLoadCompleted: Bool = false

    /// Async-loaded Beat Consistency baseline. The
    /// dashboard pushes lightweight sessions (rrSeries == nil) into
    /// `recentSessions`, so the calibration math has no nights to feed
    /// the baseline and the counter is stuck at 0 / 14 forever. A
    /// synchronous `archive.retrieve` inside a computed property runs 28
    /// full session decodes on the main thread on every body recompute and
    /// freezes the screen, so the baseline is loaded ONCE, off the main
    /// thread, in `.task` (alongside the rrSeries load), and stashed in
    /// @State. The body just reads from the array.
    @State private var priorBaselineFeatures: [BeatConsistency.Features] = []
    @State var baselineLoadCompleted: Bool = false

    /// The scored Beat Consistency result, computed once
    /// per session-view-open in the `.task(id: session.id)` block (right
    /// after the priors resolve) and stored here. A computed property
    /// would re-run `BeatConsistency.score`
    /// over the FULL night of RR data on every body evaluation — every
    /// scrub tick, sheet present/dismiss, and tab switch repeating the
    /// whole windowed feature pass. Stored, body evals are a plain state
    /// read. Same inputs (effectiveRRSeries / artifactFlags / sleep
    /// bounds / priors baseline) → identical NightlyResult.
    @State var beatConsistencyComputed: BeatConsistency.NightlyResult?

    var effectiveRRSeries: RRSeries? {
        fullRRSeries ?? session.rrSeries
    }

    enum EngineTab: String, CaseIterable {
        case timeDomain = "Time"
        case frequency = "Frequency"
        case nonlinear = "Nonlinear"
        case ans = "ANS"
        case quality = "Quality"
    }

    private var rmssd: Double { result.timeDomain.rmssd }
    private var verdict: HRVVerdict { HRVVerdict.from(rmssd: rmssd, mean: baselineStats?.lnRmssdMean, sd: baselineStats?.lnRmssdSD) }

    enum HRVVerdict {
        case excellent, good, fair, low

        var word: String {
            switch self {
            case .excellent: String(localized: "Excellent", bundle: LanguageManager.appBundle)
            case .good: String(localized: "Good", bundle: LanguageManager.appBundle)
            case .fair: String(localized: "Fair", bundle: LanguageManager.appBundle)
            case .low: String(localized: "Low", bundle: LanguageManager.appBundle)
            }
        }

        @MainActor var color: Color {
            switch self {
            case .excellent: AppTheme.wongOptimal
            case .good: AppTheme.wongGood
            case .fair: AppTheme.wongCaution
            case .low: AppTheme.wongAttention
            }
        }

        /// A proper z-score on
        /// ln(RMSSD) against the personal baseline mean+SD — not
        /// `((lnRmssd - lnMean)/lnMean)*100`, a percentage of a LOGARITHM
        /// (dimensionally meaningless; it shrinks real deviations, worse for
        /// higher-HRV users). The SAME
        /// methodology the recovery score uses, honouring the "z-score against
        /// your baseline" promise. Deadband: |z| ≤ 0.5 = no meaningful change
        /// (Smallest-Worthwhile-Change), so a night at baseline reads "good".
        static func from(rmssd: Double, mean: Double?, sd: Double?) -> HRVVerdict {
            if let mean, let sd, sd > 0 {
                let z = (log(max(1, rmssd)) - mean) / sd
                if z >= 0.5 { return .excellent }
                if z >= -0.5 { return .good }
                if z >= -1.5 { return .fair }
                return .low
            }
            // No baseline SD yet — absolute-RMSSD fallback (unchanged).
            if rmssd >= 60 { return .excellent }
            if rmssd >= 45 { return .good }
            if rmssd >= 30 { return .fair }
            return .low
        }
    }

    var body: some View {
        ScrollView {
            detailStack
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(Text(String(localized: "HRV", bundle: LanguageManager.appBundle)))
        .navigationBarTitleDisplayMode(.inline)
        // BP §D3 line 634 — metric ⓘ → Metric Guide article sheet.
        .sheet(isPresented: infoSheetBinding) { metricInfoSheet }
        // BP §D3 line 636 — long-press metric → Compare to history sheet.
        .sheet(isPresented: compareSheetBinding) { metricCompareSheet }
        .task(id: session.id) { await loadDetail() }
    }

    private var detailStack: some View {
        VStack(alignment: .leading, spacing: 22) {
            artifactBannerIfNeeded
            heroSection
            minAvgMaxStrip
            autonomicCapacityCard
            trendAnalysisSection
            hrvWaveformChart
            poincareChart
            beatConsistencySectionIfEnabled
            engineRoomSection
        }
    }

    /// The banner only fires when the analyzer had to fall
    /// back past the strict 10% literature-backed cutoff (Plews 2013, Lipponen
    /// 2019, Citi 2012). Below 10% the result is reliable and shouldn't be
    /// flagged; between 10–15% it's the fallback path — analysis still ran, but
    /// the user should know quality was limited.
    @ViewBuilder
    private var artifactBannerIfNeeded: some View {
        if result.artifactPercentage > 10 { artifactBanner }
    }

    /// App Store 1.4.1 posture: a rhythm-adjacent surface behind a
    /// kill switch (default ON); see FeatureFlags.Key.
    @ViewBuilder
    private var beatConsistencySectionIfEnabled: some View {
        if dependencies.app.featureFlags.value(for: .beatConsistencyCardEnabled) {
            beatConsistencySection
        }
    }

    private var infoSheetBinding: Binding<Bool> {
        Binding(
            get: { infoSheetMetric != nil },
            set: { if !$0 { infoSheetMetric = nil } }
        )
    }

    @ViewBuilder
    private var metricInfoSheet: some View {
        if let label = infoSheetMetric {
            MetricInfoSheet(metricLabel: label)
        }
    }

    private var compareSheetBinding: Binding<Bool> {
        Binding(
            get: { compareSheetMetric != nil },
            set: { if !$0 { compareSheetMetric = nil } }
        )
    }

    @ViewBuilder
    private var metricCompareSheet: some View {
        if let label = compareSheetMetric {
            MetricCompareToHistorySheet(
                metricLabel: label,
                archive: collector.archive
            )
        }
    }

    /// Reset on session change — switching sessions in-place would otherwise
    /// keep the old session's "completed" flag.
    private func loadDetail() async {
        rrLoadCompleted = false
        baselineLoadCompleted = false
        priorBaselineFeatures = []
        beatConsistencyComputed = nil
        await loadRRSeries()
        // Honor cancellation — if the user backed out, don't spend seconds
        // walking 17 priors for a dead view.
        if Task.isCancelled { return }
        await loadBeatConsistencyBaseline()
    }

    /// Serial, not parallel, on purpose.
    /// An `async let rrSeriesLoad` + concurrent Task.detached
    /// priors had both contending for the SessionArchive lock
    /// simultaneously: 18 full retrieves (1 for current session
    /// + 17 priors) × SHA256 + decrypt + JSON decode each. When
    /// the user backed out and re-entered mid-load, a SECOND
    /// `.task` fired and added ANOTHER 18 retrieves to the
    /// contention pile. Log evidence (hrv_debug_log_1779845765
    /// / _1779845842): "candidate count=17" fired twice 30 s
    /// apart, the `accepted=...` summary never fired = the
    /// Task.detached was stuck. Result: BOTH spinners hang
    /// forever ("Loading overnight beats..." / "Loading raw
    /// RR samples...").
    ///
    /// Back to serial. The rrSeries chart loads first (one
    /// archive read), THEN priors walk in a regular Task (not
    /// detached) so SwiftUI's `.task` cancellation actually
    /// tears it down when the user backs out. `Task.isCancelled`
    /// checks inside the priors loop bail early instead of
    /// running all 17 retrieves for a view that's gone.
    ///
    /// Trade-off: total latency goes back to sum (rrSeries +
    /// Trade-off: total latency goes back to sum (rrSeries + priors) instead of
    /// max. A few hundred ms slower in the best case, but it actually FINISHES.
    private func loadRRSeries() async {
        if let full = await collector.retrieveFullSessionAsync(session.id),
           let series = full.rrSeries, !series.points.isEmpty {
            fullRRSeries = series
        }
        // Set BEFORE the priors walk so the rrSeries chart's empty-state copy can
        // flip even if the priors work is still running (chart and Beat
        // Consistency are independent surfaces).
        rrLoadCompleted = true
    }

    /// The walk lives in the cache singleton, not here. Owning it
    /// there makes it (a) deduped — only ONE walk runs, so re-entrant opens can't
    /// deadlock concurrent archive reads, (b) persisted incrementally — each
    /// night is written to disk the moment it is computed, and (c)
    /// lifecycle-independent — it finishes even if THIS view is torn down
    /// mid-CloudKit-sync. The prior in-view `withTaskCancellationHandler` design
    /// killed the walk on every teardown before it could store (user log:
    /// cancelled=true, accepted=1, cache hits=0 on repeat — it never finished).
    private func loadBeatConsistencyBaseline() async {
        let archive = collector.archive
        let priorIds = overnightPriorIds(archive: archive)
        var cache: BeatConsistencyPriorsCache { dependencies.analysis.beatConsistencyPriorsCache }
        cache.startWarm(priorIds, archive: archive)
        let resolved = await waitForPriors(priorIds, cache: cache)
        guard !Task.isCancelled else { return }
        priorBaselineFeatures = resolved
        beatConsistencyComputed = await scoreNight(priors: resolved)
        baselineLoadCompleted = true
    }

    /// Pull priors from the FULL archive index (overnight only), NOT
    /// the dashboard's mixed 35-recent slice. A workout-heavy user's recent list
    /// can hold < 14 overnight nights, which pegs the baseline at "Calibrating"
    /// forever. The in-memory index carries sessionType + date for every session.
    ///
    /// `entries` (a lock-safe snapshot, already sorted newest-first),
    /// not the raw `index` array. Reading `index` unlocked from this background
    /// task races the deferred migrations that rewrite it under the lock (launch
    /// +4 s and after every CloudKit pull) — a concurrent read during mutation of
    /// a CoW array is undefined behaviour.
    private func overnightPriorIds(archive: SessionArchive) -> [UUID] {
        Array(
            archive.entries
                .filter { $0.sessionType == .overnight && $0.sessionId != session.id }
                .prefix(28)
                .map(\.sessionId)
        )
    }

    /// Poll until enough nights are cached to score (14), or the walk finishes,
    /// or ~20 s elapse — then render whatever we have. We never block
    /// indefinitely: the card ALWAYS resolves (to a score if ≥14 nights are
    /// ready, else the honest "Calibrating — N of 14"). The walk keeps filling
    /// the rest in the background and persists it, so the next open reads
    /// straight from disk and is instant.
    private func waitForPriors(
        _ priorIds: [UUID],
        cache: BeatConsistencyPriorsCache
    ) async -> [BeatConsistency.Features] {
        let needed = min(BeatConsistency.Config.default.minNightsForLowConfidence, priorIds.count)
        var cachedCount = priorIds.reduce(0) { $0 + (cache.features(for: $1) != nil ? 1 : 0) }
        var waitedTicks = 0
        while cachedCount < needed, cache.isWarming, waitedTicks < 40 {
            await sleepQuietly(500_000_000, context: "waitedTicks")
            if Task.isCancelled { break }
            cachedCount = priorIds.reduce(0) { $0 + (cache.features(for: $1) != nil ? 1 : 0) }
            waitedTicks += 1
        }
        let resolved: [BeatConsistency.Features] = priorIds.compactMap { cache.features(for: $0) }
        debugLog("[BeatConsistency.priors] candidate=\(priorIds.count) cached=\(resolved.count) needed=\(needed) waitedTicks=\(waitedTicks) stillWarming=\(cache.isWarming)")
        return resolved
    }

    /// instead of inside the `beatConsistencyResult` computed
    /// property (which re-ran the full-night pass per body eval).
    /// Stored BEFORE `baselineLoadCompleted` flips so the card
    /// goes spinner → result with no empty-state flash in
    /// between — same visible sequence as before, where the flag
    /// flip triggered the (synchronous) property compute.
    /// if let series = effectiveRRSeries, !series.points.isEmpty {
    private func scoreNight(priors: [BeatConsistency.Features]) async -> BeatConsistency.NightlyResult? {
        guard let series = effectiveRRSeries, !series.points.isEmpty else { return nil }
        let rr = series.points
        let bcFlags = session.artifactFlags ?? []
        let sleepStart = session.sleepStartMs ?? 0
        let sleepEnd = session.sleepEndMs ?? Int64(series.durationMs)
        return await Task.detached(priority: .userInitiated) {
            let baseline = BeatConsistency.buildBaseline(priorNights: priors)
            return BeatConsistency.score(
                rr: rr,
                flags: bcFlags,
                sleepStartMs: sleepStart,
                sleepEndMs: sleepEnd,
                baseline: baseline
            )
        }.value
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            heroHeadlineRow
            Text(verbatim: heroSubtitle)
                .font(.system(size: dt14))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppTheme.cardBackground)
        )
    }

    private var heroHeadlineRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(Int(rmssd.rounded()))")
                .font(.system(size: dt56, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: "ms")
                .font(.system(size: dt18, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            verdictPill
        }
    }

    private var verdictPill: some View {
        Text(verbatim: verdict.word)
            .font(.system(size: dt12, weight: .semibold))
            .foregroundStyle(verdict.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(verdict.color.opacity(0.15)))
    }

    private var heroSubtitle: String {
        guard let mean = baselineStats?.lnRmssdMean, mean > 0 else {
            return String(localized: "Today's RMSSD. Higher values reflect parasympathetic dominance.", bundle: LanguageManager.appBundle)
        }
        // True fractional deviation from the geometric baseline exp(lnMean).
        // (Was `((lnRmssd - lnMean)/lnMean)*100` — a % of a logarithm, which
        // is dimensionless nonsense and understated the real gap.)
        let baselineRmssd = exp(mean)
        let pct = ((rmssd - baselineRmssd) / baselineRmssd) * 100
        let absPct = Int(abs(pct).rounded())
        switch verdict {
        case .excellent:
            return String(localized: "\(absPct)% above your baseline — strong parasympathetic tone.", bundle: LanguageManager.appBundle)
        case .good:
            return String(localized: "Within your usual range — stable nervous-system state.", bundle: LanguageManager.appBundle)
        case .fair:
            return String(localized: "\(absPct)% below your baseline — recovery is reduced today.", bundle: LanguageManager.appBundle)
        case .low:
            return String(localized: "Well below your baseline — body is asking for rest.", bundle: LanguageManager.appBundle)
        }
    }

    // MARK: - 4-up strip

    private var minAvgMaxStrip: some View {
        HStack(spacing: 8) {
            stripCell(label: String(localized: "Min HR", bundle: LanguageManager.appBundle), value: String(Int(result.timeDomain.minHR.rounded())), unit: "bpm")
            stripCell(label: String(localized: "Avg HR", bundle: LanguageManager.appBundle), value: String(Int(result.timeDomain.meanHR.rounded())), unit: "bpm")
            stripCell(label: String(localized: "Max HR", bundle: LanguageManager.appBundle), value: String(Int(result.timeDomain.maxHR.rounded())), unit: "bpm")
            stripCell(label: "SDNN", value: String(Int(result.timeDomain.sdnn.rounded())), unit: "ms")
        }
    }

    private func stripCell(label: String, value: String, unit: String) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: label)
                .font(.system(size: dt11, weight: .medium))
                .foregroundStyle(AppTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            stripValue(value: value, unit: unit)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.cardBackground)
        )
    }

    private func stripValue(value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(verbatim: value)
                .font(.system(size: dt20, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: unit)
                .font(.system(size: dt11))
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    // MARK: - Autonomic Capacity

    @ViewBuilder
    private var autonomicCapacityCard: some View {
        if let peak = result.peakCapacity {
            autonomicCapacityBody(peak)
        }
    }

    private func autonomicCapacityBody(_ peak: PeakCapacity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(String(localized: "Autonomic capacity", bundle: LanguageManager.appBundle))
            capacityStatRow(peak)
            windowHRRow(peak)
            Text(String(
                localized: "Highest sustained HRV during sleep — your physiological ceiling, separate from readiness. Peak total power is the full ANS bandwidth; it tends to fall with accumulated load, short sleep, alcohol or stress, and sometimes illness.",
                bundle: LanguageManager.appBundle
            ))
                .font(.system(size: dt12))
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private func capacityStatRow(_ peak: PeakCapacity) -> some View {
        HStack(spacing: 10) {
            capacityStat(label: String(localized: "Peak RMSSD", bundle: LanguageManager.appBundle), value: String(Int(peak.peakRMSSD.rounded())), unit: "ms")
            capacityStat(label: String(localized: "Peak SDNN", bundle: LanguageManager.appBundle), value: String(Int(peak.peakSDNN.rounded())), unit: "ms")
            thirdCapacityStat(peak)
        }
    }

    /// Peak total spectral power is computed by
    /// the analyzer and stored on `PeakCapacity`, and must be displayed:
    /// total power tracks the full ANS bandwidth (LF + HF + VLF) and falls early
    /// when the user is heading toward overtraining or illness — a useful
    /// early-warning signal. Surfaced alongside
    /// RMSSD / SDNN as the third capacity number, with window HR as the fallback
    /// when the spectral figure isn't available.
    @ViewBuilder
    private func thirdCapacityStat(_ peak: PeakCapacity) -> some View {
        if let totalPower = peak.peakTotalPower {
            capacityStat(
                label: String(localized: "Peak total power", bundle: LanguageManager.appBundle),
                value: String(Int(totalPower.rounded())),
                unit: "ms²"
            )
        } else if let hr = peak.windowMeanHR {
            capacityStat(label: String(localized: "Window HR", bundle: LanguageManager.appBundle), value: String(Int(hr.rounded())), unit: "bpm")
        }
    }

    /// A second row only when total power took the third slot above, so window
    /// HR still gets shown.
    @ViewBuilder
    private func windowHRRow(_ peak: PeakCapacity) -> some View {
        if peak.peakTotalPower != nil, let hr = peak.windowMeanHR {
            HStack(spacing: 10) {
                capacityStat(label: String(localized: "Window HR", bundle: LanguageManager.appBundle), value: String(Int(hr.rounded())), unit: "bpm")
                Spacer().frame(maxWidth: .infinity)
                Spacer().frame(maxWidth: .infinity)
            }
        }
    }

    private func capacityStat(label: String, value: String, unit: String) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: label)
                .font(.system(size: dt11))
                .foregroundStyle(AppTheme.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: value)
                    .font(.system(size: dt18, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(verbatim: unit)
                    .font(.system(size: dt11))
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.cardBackground)
        )
    }

    // MARK: - Trend Analysis

    private var trendAnalysisSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(String(localized: "Trend analysis", bundle: LanguageManager.appBundle))
            trendAnalysisRows
        }
    }

    private var trendAnalysisRows: some View {
        VStack(spacing: 8) {
            coreTrendRows
            stressTrendRow
        }
    }

    @ViewBuilder
    private var coreTrendRows: some View {
        variabilityTrendRows
        trendRow(
            metric: String(localized: "Mean HR", bundle: LanguageManager.appBundle),
            today: result.timeDomain.meanHR,
            avg: trendAverage(for: \.timeDomain.meanHR),
            baseline: baselineStats?.meanHRBaseline,
            unit: "bpm",
            higherIsBetter: false
        )
    }

    @ViewBuilder
    private var variabilityTrendRows: some View {
        trendRow(
            metric: "RMSSD",
            today: result.timeDomain.rmssd,
            avg: trendAverage(for: \.timeDomain.rmssd),
            baseline: (baselineStats?.lnRmssdMean).map { exp($0) },
            unit: "ms",
            higherIsBetter: true
        )
        trendRow(
            metric: "SDNN",
            today: result.timeDomain.sdnn,
            avg: trendAverage(for: \.timeDomain.sdnn),
            baseline: nil,
            unit: "ms",
            higherIsBetter: true
        )
    }

    @ViewBuilder
    private var stressTrendRow: some View {
        if let stress = result.ansMetrics?.stressIndex {
            trendRow(
                metric: String(localized: "Stress index", bundle: LanguageManager.appBundle),
                today: stress,
                avg: trendAverageOptional(for: \.ansMetrics?.stressIndex),
                baseline: nil,
                unit: "",
                higherIsBetter: false
            )
        }
    }

    /// Trend average uses the **30-day baseline** to match the hero
    /// subtitle's framing ("above your 30-day baseline"). A 7-day
    /// window produces
    /// psychologically unstable percentages when the denominator is
    /// small — e.g. RMSSD +167% read as "you're peaking massively"
    /// when it actually meant "your 7-day average is unusually low
    /// and today is normal-ish." Reserving 7-day comparisons for the
    /// trajectory surface where week-over-week change is the point.
    private func trendAverage(for keyPath: KeyPath<HRVAnalysisResult, Double>) -> Double? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let values = recentSessions.compactMap { s -> Double? in
            // MUST filter to overnight sessions. `recentSessions`
            // is mixed-type (overnight + workout + quick), and averaging in
            // workouts/daytime readings wrecks the "vs 30-day avg" deltas:
            // workouts crush RMSSD and spike HR/stress, so an overnight night
            // reads as "+86% RMSSD / −42% HR / −95% stress" against a polluted
            // average. The hero card uses only overnight
            // (latestOvernightComplete); these trend rows must match.
            guard s.sessionType == .overnight,
                  s.id != session.id,
                  s.startDate >= cutoff,
                  let r = s.analysisResult else { return nil }
            return r[keyPath: keyPath]
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func trendAverageOptional(for keyPath: KeyPath<HRVAnalysisResult, Double?>) -> Double? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let values = recentSessions.compactMap { s -> Double? in
            // MUST filter to overnight sessions. `recentSessions`
            // is mixed-type (overnight + workout + quick), and averaging in
            // workouts/daytime readings wrecks the "vs 30-day avg" deltas:
            // workouts crush RMSSD and spike HR/stress, so an overnight night
            // reads as "+86% RMSSD / −42% HR / −95% stress" against a polluted
            // average. The hero card uses only overnight
            // (latestOvernightComplete); these trend rows must match.
            guard s.sessionType == .overnight,
                  s.id != session.id,
                  s.startDate >= cutoff,
                  let r = s.analysisResult else { return nil }
            return r[keyPath: keyPath]
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func trendRow(metric: String, today: Double, avg: Double?, baseline: Double?, unit: String, higherIsBetter: Bool) -> some View {
        HStack {
            Text(verbatim: metric)
                .font(.system(size: dt14, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            trendRowValues(today: today, avg: avg, unit: unit, higherIsBetter: higherIsBetter)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppTheme.cardBackground))
    }

    @ViewBuilder
    private func trendRowValues(today: Double, avg: Double?, unit: String, higherIsBetter: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(verbatim: "\(formatValue(today)) \(unit)")
                .font(.system(size: dt14, weight: .semibold).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
            if let avg {
                trendDeltaText(today: today, avg: avg, higherIsBetter: higherIsBetter)
            }
        }
    }

    /// Render the "+12% vs 7-day avg" delta line. Pulled out of the
    /// `trendRow` ViewBuilder so the if/else colour decision can use
    /// regular Swift control flow without tripping the result builder
    /// (assignments evaluate to `()` which doesn't conform to `View`).
    private func trendDeltaText(today: Double, avg: Double, higherIsBetter: Bool) -> some View {
        let delta = today - avg
        let pct = avg > 0 ? (delta / avg) * 100 : 0
        let directionUp = pct >= 0
        let color: Color
        if abs(pct) < 5 {
            color = AppTheme.textTertiary
        } else if (directionUp && higherIsBetter) || (!directionUp && !higherIsBetter) {
            color = AppTheme.wongOptimal
        } else {
            color = AppTheme.wongCaution
        }
        return Text(String(localized: "\(directionUp ? "+" : "")\(Int(pct.rounded()))% vs 30-day avg", bundle: LanguageManager.appBundle))
            .font(.system(size: dt11))
            .foregroundStyle(color)
    }

    private func formatValue(_ v: Double) -> String {
        v < 10 ? String(format: "%.1f", locale: .current, v) : String(Int(v.rounded()))
    }
}
