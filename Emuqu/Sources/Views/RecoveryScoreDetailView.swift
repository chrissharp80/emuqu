import Charts
import SwiftUI

/// Recovery Score detail. The depth that used to
/// clutter Dashboard, on its own surface. Pushes from the v2 Dashboard's
/// hero ring tap or "View full report" footer link.
///
/// Layout (top to bottom):
///   1. NavigationHeader — title "Recovery", share button trailing, ConfidencePip
///   2. Hero recap — 140pt ring + delta line
///   3. What this means — NarrativeCard (1-2 sentences)
///   4. Most Likely Explanations — 3 numbered cards
///   5. Score Breakdown — three rows tappable-to-expand (HRV 60% / Sleep 25% / Vitals 15%)
///   6. SpO2 penalty badge (when triggered)
///   7. Key Findings — capped at 4 bullets, blue dot
///   8. What To Do — capped at 3 bullets, green arrow
///   9. HRV Overnight chart (Swift Charts)
///   10. Heart Rate Overnight chart (Swift Charts)
///   11. Analysis Window picker — segmented control (Best / Pick / Last 5min)
///   12. EngineRoomDisclosure — Recording details
///
/// **No training-load content.** No ACWR, no ATL/CTL/TSB. That lives on D6.
struct RecoveryScoreDetailView: View {
    @Environment(\.dependencies) var dependencies
    // MARK: - Dynamic Type
    //
    // These replace hard-coded `.font(.system(size: N))`
    // literals, which do not respond to the user's text-size setting at all.
    // The app's semantic styles (`.body`, `.caption`, …) DO scale, so at AX5 the
    // surrounding text grew while these numbers stayed put — breaking layout and
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
    @ScaledMetric(relativeTo: .subheadline) var dt15: CGFloat = 15
    @ScaledMetric(relativeTo: .body) var dt17: CGFloat = 17
    @ScaledMetric(relativeTo: .title2) var dt22: CGFloat = 22

    let session: HRVSession
    let result: HRVAnalysisResult
    let recentSessions: [HRVSession]
    let baselineStats: BaselineTracker.RecoveryBaselineStats?
    let totalSessionCount: Int
    /// Optional Re-analyze hook. When supplied the Analysis Window picker
    /// becomes interactive; nil hides the picker (e.g. for read-only
    /// History views).
    var onReanalyze: ((WindowSelectionMethod) async -> Void)?
    /// Optional positional Re-analyze hook (Pick Window / Last 5 min).
    /// `targetMs` is the window-midpoint timestamp relative to session start.
    var onReanalyzeAt: ((Int64) async -> Void)?

    @Environment(RRCollector.self) var collector
    var settingsManager: SettingsManager { dependencies.app.settingsManager }
    @State var expandedFactor: String?
    @State var selectedWindowSegment: AnalysisWindowSegment = .bestRecovery
    /// Until set, the "Window method" row describes the stored session.
    @State var windowChangedHere = false
    /// Pick Window's Cancel restores this without re-running an analysis.
    @State var segmentBeforePick: AnalysisWindowSegment = .bestRecovery
    @State var restoringSegment = false
    @State var isReanalyzing = false
    @State var isShowingPickWindowSheet = false

    /// Fresh vitals fetched from HealthKit on appear. Apple writes RR /
    /// SpO2 / wrist-temp some minutes AFTER the recording session ends,
    /// so the snapshot frozen at acceptance frequently has those fields
    /// nil. The detail view re-fetches and applies the strap-RHR
    /// override so older sessions that predate the override fix also
    /// see the right physiology.
    @State var refreshedVitals: RecoveryVitals?
    /// Fresh HR samples from HealthKit covering the session's sleep
    /// window — used by the HR-overnight chart when `session.rrSeries`
    /// has been pruned post-acceptance.
    @State var fallbackHRSamples: [(date: Date, hr: Double)] = []
    /// Full RR series re-loaded from disk on appear. The dashboard
    /// path passes a lightweight session with `rrSeries == nil` (the
    /// archive's `retrieveLightweight` skip flag). Without re-pulling
    /// the full session here the HRV-overnight chart can never render
    /// — it needs the beat-by-beat stream to compute rolling RMSSD.
    @State var fullRRSeries: RRSeries?
    /// True once `refreshVitalsAndCharts` has finished its
    /// first pass, regardless of whether it found a full RR series.
    /// Drives the chart's loading-vs-empty-state branch so a session
    /// loaded lightweight (no rrSeries) shows a spinner until the
    /// background reload completes — rather than briefly flashing
    /// "No overnight HRV trace" before the data arrives. Was the
    /// "charts flaky / sometimes empty" report.
    @State var didCompleteInitialLoad: Bool = false
    /// Preview window the user is dragging in the inline
    /// Pick Window slider. Drawn as a lighter dashed band on the HRV
    /// chart so the user sees in real time which slice of the night
    /// they're about to analyze. Cleared on Apply (real window from
    /// `result` takes over) or Cancel.
    @State var previewWindowMs: Int64?
    /// Organized-recovery zones cached at view-load time
    /// from `result.organizedRecoveryZones`. When the field is nil
    /// (older sessions archived before the field existed), we
    /// recompute from the rrSeries via `OrganizedZonesCache` so the
    /// green overlay still appears. Stored on @State so the chart
    /// rebuild after reanalysis picks up freshly-attached zones.
    @State var organizedZoneRanges: [HRVAnalysisResult.TimeRange] = []
    /// Hover/scrub time on the HRV-overnight chart (iOS 17 .chartXSelection).
    /// Drives the floating value-pill annotation that shows RMSSD at the
    /// selected time, matching the granular hover values of the legacy
    /// MorningResults chart.
    @State var hrvHoverDate: Date?
    /// Hover/scrub time on the HR-overnight chart.
    @State var hrHoverDate: Date?
    /// Overnight chart series cached off the render path. Running
    /// `buildRMSSDSeries` / `buildHRSeries` inside the chart
    /// @ViewBuilders would run them on EVERY body evaluation — including every hover
    /// tick (`hrvHoverDate` / `hrHoverDate` are @State above), so a
    /// scrub gesture re-walks the full overnight beat stream per frame.
    /// Both series are computed by `rebuildChartSeries()` inside the
    /// `.task(id: session.id)` load pass (off-main, alongside the
    /// full-RR reload) and the chart bodies just read these arrays.
    /// Same inputs, same math → identical rendered series.
    @State var rmssdChartSeries: [RecoveryScoreCharts.RMSSDPoint] = []
    @State var hrChartSeries: [RecoveryScoreCharts.HRPoint] = []

    init(
        session: HRVSession,
        result: HRVAnalysisResult,
        recentSessions: [HRVSession],
        baselineStats: BaselineTracker.RecoveryBaselineStats?,
        totalSessionCount: Int,
        onReanalyze: ((WindowSelectionMethod) async -> Void)? = nil,
        onReanalyzeAt: ((Int64) async -> Void)? = nil
    ) {
        self.session = session
        self.result = result
        self.recentSessions = recentSessions
        self.baselineStats = baselineStats
        self.totalSessionCount = totalSessionCount
        self.onReanalyze = onReanalyze
        self.onReanalyzeAt = onReanalyzeAt
    }

    // MARK: - Computed score / breakdown

    /// 0-100 composite. Reads the frozen score when available so the
    /// detail view never disagrees with the dashboard.
    var compositeScore: Double {
        if let frozen = session.recoveryScore { return frozen * 10.0 }
        return breakdown.compositeScore
    }

    var verdict: ScoreVerdict { ScoreVerdict(score: compositeScore) }

    // Prefer the frozen breakdown the scorer wrote at
    // archive time. Without this, every SwiftUI re-render of this
    // view recomputes the breakdown live — and if `session.sleepSnapshot`
    // is nil (e.g. after a session recovery that didn't persist
    // snapshots, or a session imported via CloudKit pull) the live
    // recompute drops to tier 1 and shows different factor scores
    // than the headline frozen score. User saw "Excellent 93" in the
    // ring and a tier-1 factor list contradicting it.
    //
    // Falls through to live recompute only when no frozen breakdown
    // exists — keeps the legacy/pre-breakdown sessions rendering.
    var breakdown: RecoveryScoreCalculator.ScoreBreakdown {
        if let stored = session.scoreBreakdown {
            // #4 — the frozen breakdown may read "RR — no data" because Apple
            // wrote overnight respiratory rate minutes after the recording
            // ended (after the breakdown froze). The Recovery Vitals card
            // re-fetches live, so refresh the frozen Vitals factor from
            // effectiveVitals when it now carries respiration. Composite is preserved.
            return RecoveryScoreCalculator.breakdownRefreshingVitalsFactor(
                stored, freshVitals: effectiveVitals, baselineStats: baselineStats
            )
        }
        return liveBreakdown
    }

    private var liveBreakdown: RecoveryScoreCalculator.ScoreBreakdown {
        RecoveryScoreCalculator.calculateWithBreakdown(
            RecoveryScoreCalculator.ScoreInputs(
                hrvReadiness: result.ansMetrics?.readinessScore, rmssd: result.timeDomain.rmssd,
                meanHR: result.timeDomain.meanHR, dfaAlpha1: result.nonlinear.dfaAlpha1,
                baselineStats: baselineStats, sleepData: session.sleepSnapshot, vitals: effectiveVitals,
                typicalSleepHours: settingsManager.settings.typicalSleepHours
            ),
            trainingContext: session.trainingSnapshot,
            config: RecoveryScoreCalculator.ScoringConfiguration(from: settingsManager.settings),
            ansBalance: ansBalance
        )
    }

    var ansBalance: Double? {
        guard let pns = result.ansMetrics?.pnsIndex,
              let sns = result.ansMetrics?.snsIndex else { return nil }
        return pns - sns
    }

    /// The vitals payload to display. Prefers a fresh HealthKit fetch
    /// over the frozen `session.vitalsSnapshot` so RR / temp / SpO2
    /// values that arrived AFTER session acceptance show up in the
    /// breakdown. Falls back to the snapshot when the refresh is still
    /// in flight or empty. Apple writes some vitals minutes after sleep ends.
    ///
    /// **Sleep-HR override:** ALWAYS prefer the
    /// strap's analysis-window meanHR over both stored and fresh
    /// HealthKit RHR samples — same physiology that
    /// `BaselineTracker.meanHRBaseline` is built from. Sessions
    /// accepted before the strap-override path landed have stored
    /// `restingHeartRate` set to Apple's daytime RHR (often ~10–15
    /// bpm higher than nocturnal mean), so we override at display time
    /// regardless of whether the refresh has loaded.
    var effectiveVitals: RecoveryVitals? {
        let stored = session.vitalsSnapshot
        let fresh = refreshedVitals
        // Strap analysis-window mean wins for Sleep HR. Falls back to
        // stored / fresh only when the analysis didn't run.
        let sleepHR: Double? = result.timeDomain.meanHR > 0
            ? result.timeDomain.meanHR
            : (stored?.restingHeartRate ?? fresh?.restingHeartRate)
        if fresh == nil, stored == nil {
            return sleepHRVitals(sleepHR)
        }
        return mergedVitals(stored: stored, fresh: fresh, sleepHR: sleepHR)
    }

    var deltaText: String? {
        guard let pct = hrvPercentVsBaseline else { return nil }
        let sign = pct >= 0 ? "+" : ""
        return String(localized: "\(sign)\(Int(pct.rounded()))% vs your average", bundle: LanguageManager.appBundle)
    }

    var rmssdText: String { String(localized: "\(Int(result.timeDomain.rmssd.rounded())) ms", bundle: LanguageManager.appBundle) }

    /// Active only when the score shown contains the SpO₂ deduction: vitals
    /// re-fetched after scoring can show a low SpO₂ the frozen score never saw.
    var spo2Penalty: (active: Bool, value: Double?, points: Int) {
        let points = Int(RecoveryScoreConstants.Vitals.spo2Penalty)
        guard session.recoveryScore != nil else {
            return (breakdown.spo2PenaltyApplied, effectiveVitals?.oxygenSaturation, points)
        }
        let scored = session.vitalsSnapshot
        let applied = session.scoreBreakdown?.spo2PenaltyApplied ?? (scored?.isSpO2Concerning ?? false)
        return (applied, scored?.oxygenSaturation ?? effectiveVitals?.oxygenSaturation, points)
    }

    // MARK: - Body

    @ViewBuilder
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                bannerAndSections
                engineRoomSection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(Text(String(localized: "Recovery", bundle: LanguageManager.appBundle)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { detailToolbar }
        .task(id: session.id) {
            await refreshVitalsAndCharts()
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            shareButton
        }
        ToolbarItem(placement: .principal) {
            if ScoreAppearancePolicy.showsScore(baselineNights: totalSessionCount) {
                ConfidencePip(daysCollected: totalSessionCount)
            }
        }
    }

    @ViewBuilder
    private var bannerAndSections: some View {
        if isInsufficient {
            insufficientBanner
        }
        mainSections
    }

    @ViewBuilder
    private var mainSections: some View {
        if isBuildingBaseline {
            buildingBaselineBlock
        } else {
            heroSection
            whatThisMeansSection
            mostLikelyExplanationsSection
            scoreBreakdownSection
            if spo2Penalty.active { spo2PenaltyBadge }
            keyFindingsSection
            trendComparisonSection
            whatToDoSection
            hrvOvernightChart
            heartRateOvernightChart
            if onReanalyze != nil || onReanalyzeAt != nil { analysisWindowPicker }
        }
    }

    // MARK: - HealthKit refresh

    /// Re-pull vitals + HR samples on appear so older sessions (whose
    /// frozen snapshot predates Apple's late-arriving RR/temp/SpO2
    /// writes, or predates the strap-RHR override fix) display the
    /// correct physiology without forcing the user to re-accept the
    /// session. Also re-loads the full session from disk so the
    /// HRV-overnight chart can render rolling RMSSD from the beat
    /// stream that the dashboard's lightweight loader had stripped.
    @MainActor
    func refreshVitalsAndCharts() async {
        let referenceDate = session.endDate ?? session.startDate
        await reloadFullSeries()
        await refreshVitals(referenceDate: referenceDate)
        await loadFallbackHRSamples(referenceDate: referenceDate)
        await loadOrganizedZones()
        // Mark initial load complete — the chart's empty-vs-loading branch
        // flips to "real empty state" only after we've finished the
        // lightweight → full reload round trip. Prevents the "No HRV trace"
        // flash users were reporting.
        didCompleteInitialLoad = true
    }

    /// Re-load the full session (with rrSeries) so charts have the strap beat
    /// stream. Cheap when already loaded.
    ///
    /// Then build the cached overnight chart series (see `rmssdChartSeries` /
    /// `hrChartSeries`) — before the slower HealthKit fetches, so the charts
    /// do not wait on them.
    @MainActor
    private func reloadFullSeries() async {
        if let full = await collector.retrieveFullSessionAsync(session.id),
           let series = full.rrSeries, !series.points.isEmpty {
            fullRRSeries = series
        }
        await rebuildChartSeries()
    }

    /// Fresh vitals + strap-RHR override.
    @MainActor
    private func refreshVitals(referenceDate: Date) async {
        let fresh = await collector.healthKit
            .fetchRecoveryVitals(relativeTo: referenceDate)
            .withStrapNocturnalRHR(result.timeDomain.meanHR)
        guard !fresh.isEmpty else { return }
        refreshedVitals = fresh
        persistMergedVitals(fresh)
    }

    /// Persist the merge back so other surfaces (Dashboard, Trends, Coach
    /// context) pick it up too. Only fields the stored snapshot lacks are
    /// filled, and only when that adds something. The archive read-modify-write runs
    /// off the main actor: a full retrieve decrypts and decodes the session.
    @MainActor
    private func persistMergedVitals(_ fresh: RecoveryVitals) {
        let stored = session.vitalsSnapshot
        let merged = Self.mergeVitals(fresh: fresh, stored: stored)
        guard vitalsCount(merged) > vitalsCount(stored) else { return }
        let id = session.id
        let archive = collector.archive
        Task.detached { Self.storeMergedVitals(merged, id: id, archive: archive) }
    }

    nonisolated private static func storeMergedVitals(_ merged: RecoveryVitals, id: UUID, archive: SessionArchive) {
        do {
            try archive.update(id) { $0.vitalsSnapshot = merged }
        } catch {
            debugLog("[RecoveryScoreDetail] Merged vitals not persisted for \(id.uuidString.prefix(8)): \(error.localizedDescription)", level: .warning)
        }
    }

    /// Fills only the fields the stored snapshot lacks. A stored value is
    /// what the score was frozen with at acceptance and is never replaced.
    private static func mergeVitals(fresh: RecoveryVitals, stored: RecoveryVitals?) -> RecoveryVitals {
        RecoveryVitals(
            respiratoryRate: stored?.respiratoryRate ?? fresh.respiratoryRate,
            respiratoryRateBaseline: stored?.respiratoryRateBaseline ?? fresh.respiratoryRateBaseline,
            oxygenSaturation: stored?.oxygenSaturation ?? fresh.oxygenSaturation,
            oxygenSaturationMin: stored?.oxygenSaturationMin ?? fresh.oxygenSaturationMin,
            wristTemperature: stored?.wristTemperature ?? fresh.wristTemperature,
            wristTemperatureBaseline: stored?.wristTemperatureBaseline ?? fresh.wristTemperatureBaseline,
            restingHeartRate: stored?.restingHeartRate ?? fresh.restingHeartRate
        )
    }

    /// Fallback HR samples for the overnight chart when the strap beat stream
    /// is genuinely missing (older session or recovery path that didn't
    /// preserve it). Only fetches when the full-session re-load also came back
    /// empty.
    ///
    /// The HR chart's HealthKit fallback path only populates when the strap
    /// stream is missing — rebuild the cached series so the fallback samples
    /// land on the chart as soon as `fallbackHRSamples` is written.
    @MainActor
    private func loadFallbackHRSamples(referenceDate: Date) async {
        await fetchFallbackHRSamples(referenceDate: referenceDate)
        if !fallbackHRSamples.isEmpty {
            await rebuildChartSeries()
        }
    }

    @MainActor
    private func fetchFallbackHRSamples(referenceDate: Date) async {
        guard fullRRSeries == nil,
              session.rrSeries == nil || session.rrSeries?.points.isEmpty == true
        else { return }
        let sleepStart = session.sleepSnapshot?.sleepStart ?? session.startDate
        let sleepEnd = session.sleepSnapshot?.sleepEnd ?? session.endDate ?? referenceDate
        guard sleepEnd > sleepStart,
              let samples = try? await collector.healthKit.fetchHeartRateSamples(from: sleepStart, to: sleepEnd)
        else { return }
        fallbackHRSamples = samples
    }

    /// Organized-recovery zones (green band overlay on HRV chart). Per the
    /// architecture doc + FLOWCHART.md these are the load-bearing visual that
    /// lets the user see WHERE recovery happened so the Pick Window choice is
    /// meaningful. Three tiers: persisted on result → memory cache → on-demand
    /// recompute from the rrSeries.
    @MainActor
    private func loadOrganizedZones() async {
        if let persisted = result.organizedRecoveryZones, !persisted.isEmpty {
            organizedZoneRanges = persisted
            return
        }
        guard let series = effectiveRRSeries else { return }
        let flags = session.artifactFlags ?? []
        let sleepStartMs = session.sleepStartMs ?? 0
        let sleepEndMs = session.sleepEndMs ?? series.points.last?.t_ms ?? 0
        let sessionId = session.id
        organizedZoneRanges = await Task.detached(priority: .userInitiated) {
            Self.computeOrganizedZonesOnDemand(
                sessionId: sessionId,
                series: series,
                flags: flags,
                sleepStartMs: sleepStartMs,
                sleepEndMs: sleepEndMs
            )
        }.value
    }

    /// Recompute the cached overnight chart series (`rmssdChartSeries` /
    /// `hrChartSeries`) from the current inputs. This is
    /// the off-render-path home for `buildRMSSDSeries` / `buildHRSeries`
    /// (RecoveryScoreDetailView+Charts.swift). Inputs are snapshotted on
    /// the MainActor, the walk runs on a detached task, and the results
    /// land back in @State — the main thread never blocks on a
    /// full-night beat stream.
    @MainActor
    func rebuildChartSeries() async {
        let series = effectiveRRSeries
        let flags = session.artifactFlags
        let startDate = session.startDate
        let fallback = fallbackHRSamples
        let (rmssd, hr) = await Task.detached(priority: .userInitiated) {
            (
                Self.buildRMSSDSeries(series: series, flags: flags, sessionStartDate: startDate),
                Self.buildHRSeries(series: series, flags: flags, sessionStartDate: startDate, fallbackHRSamples: fallback)
            )
        }.value
        rmssdChartSeries = rmssd
        hrChartSeries = hr
    }

    /// Same fallback the legacy OvernightChartsView uses.
    /// Hits an in-memory cache first; recomputes via WindowSelector if
    /// missing. Pure (no I/O), nonisolated so it can run on a
    /// background priority Task.
    nonisolated static func computeOrganizedZonesOnDemand(
        sessionId: UUID,
        series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64,
        sleepEndMs: Int64
    ) -> [HRVAnalysisResult.TimeRange] {
        if let cached = AppDependencies.current.app.organizedZonesCache.get(sessionId) {
            return cached
        }
        let selector = WindowSelector()
        _ = selector.findBestWindow(
            in: series,
            flags: flags,
            sleepStartMs: sleepStartMs,
            wakeTimeMs: sleepEndMs
        )
        let zones = selector.lastOrganizedZones
        AppDependencies.current.app.organizedZonesCache.set(sessionId, zones: zones)
        return zones
    }

    /// Effective RR series for the chart builders. Prefers the freshly
    /// loaded full series, falls back to whatever the lightweight
    /// session carried.
    var effectiveRRSeries: RRSeries? {
        fullRRSeries ?? session.rrSeries
    }

    func vitalsCount(_ v: RecoveryVitals?) -> Int {
        guard let v else { return 0 }
        var n = 0
        if v.respiratoryRate != nil { n += 1 }
        if v.oxygenSaturation != nil { n += 1 }
        if v.wristTemperature != nil { n += 1 }
        if v.restingHeartRate != nil { n += 1 }
        return n
    }
}

// MARK: - File-scope helpers
//
// Kept outside RecoveryScoreDetailView: each names no member of the
// type and calls nothing inside it, so none needs to be a member.
// `private` at file scope is fileprivate, so every call site in this
// file resolves the same way.

private func sleepHRVitals(_ sleepHR: Double?) -> RecoveryVitals? {
    sleepHR.map {
        RecoveryVitals(
            respiratoryRate: nil, respiratoryRateBaseline: nil,
            oxygenSaturation: nil, oxygenSaturationMin: nil,
            wristTemperature: nil, wristTemperatureBaseline: nil,
            restingHeartRate: $0
        )
    }
}

private func mergedVitals(
    stored: RecoveryVitals?,
    fresh: RecoveryVitals?,
    sleepHR: Double?
) -> RecoveryVitals? {
    return RecoveryVitals(
        respiratoryRate: fresh?.respiratoryRate ?? stored?.respiratoryRate,
        respiratoryRateBaseline: fresh?.respiratoryRateBaseline ?? stored?.respiratoryRateBaseline,
        oxygenSaturation: fresh?.oxygenSaturation ?? stored?.oxygenSaturation,
        oxygenSaturationMin: fresh?.oxygenSaturationMin ?? stored?.oxygenSaturationMin,
        wristTemperature: fresh?.wristTemperature ?? stored?.wristTemperature,
        wristTemperatureBaseline: fresh?.wristTemperatureBaseline ?? stored?.wristTemperatureBaseline,
        restingHeartRate: sleepHR
    )
}
