import SwiftUI

/// Shared formatters for OvernightChartsView — avoids static stored property
/// limitation in generic types.
enum OvernightChartFormatters {
    static let clockTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    /// Update locale on cached formatters after an in-app language change.
    static func updateLocale(_ locale: Locale) {
        clockTimeFormatter.locale = locale
    }
}

/// The viewport members the shared drawing helpers need. The HR and HRV
/// canvases each keep their own geometry struct; both expose these.
protocol OvernightChartViewport {
    var size: CGSize { get }
    var totalDurationMs: Int64 { get }
    func x(forMs ms: Int64) -> CGFloat
}

/// Drawing the HR and HRV overnight canvases share: axis labels, tooltip
/// clamping, sleep-segment shading, and the horizontal grid.
@MainActor
enum OvernightChartDrawing {
    /// X-axis labels showing clock times across the chart viewport.
    /// When HealthKit sleep extends beyond the recording, labels span the full
    /// viewport.
    static func xAxisLabels(session: HRVSession, stats: OvernightStats, width: CGFloat) -> some View {
        let labels = clockTimeLabels(session: session, stats: stats, width: width)
        return ZStack {
            ForEach(0 ..< labels.count, id: \.self) { i in
                Text(labels[i].text)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
                    .position(x: labels[i].x, y: 10)
            }
        }
    }

    /// Five evenly-spaced clock times across the viewport, anchored to the
    /// chart's wall-clock start.
    ///
    /// Reuses the cached formatter — these run per scrub frame,
    /// and allocating a DateFormatter each time was tooltip jank.
    static func clockTimeLabels(session: HRVSession, stats: OvernightStats, width: CGFloat) -> [(text: String, x: CGFloat)] {
        guard let series = session.rrSeries, !series.points.isEmpty else { return [] }
        let chartDurationMs = stats.chartEndMs - stats.chartStartMs
        guard chartDurationMs > 0 else { return [] }
        let chartStartDate = session.startDate.addingTimeInterval(Double(stats.chartStartMs) / 1000.0)
        let formatter = OvernightChartFormatters.clockTimeFormatter
        let labelCount = 5
        let totalDuration = Double(chartDurationMs) / 1000.0
        return (0 ..< labelCount).map { i in
            let fraction = CGFloat(i) / CGFloat(labelCount - 1)
            let actualTime = chartStartDate.addingTimeInterval(totalDuration * Double(fraction))
            return (formatter.string(from: actualTime), fraction * width)
        }
    }

    /// Keeps the tooltip inside the canvas: 50 pt of padding either side.
    static func tooltipX(_ x: CGFloat, size: CGSize) -> CGFloat {
        let padding: CGFloat = 50
        if x < padding {
            return padding
        } else if x > size.width - padding {
            return size.width - padding
        }
        return x
    }

    /// Subtle background shading marking the individual sleep periods. Only
    /// meaningful when the night was split into more than one.
    static func drawSleepSegments(_ context: inout GraphicsContext, _ geo: some OvernightChartViewport, stats: OvernightStats) {
        guard stats.sleepSegmentRanges.count > 1, geo.totalDurationMs > 0 else { return }
        for segRange in stats.sleepSegmentRanges {
            let segX = max(0, geo.x(forMs: segRange.startMs))
            let segW = min(geo.size.width, geo.x(forMs: segRange.endMs)) - segX
            guard segW > 0 else { continue }
            let segRect = CGRect(x: segX, y: 0, width: segW, height: geo.size.height)
            context.fill(Path(segRect), with: .color(AppTheme.mist.opacity(0.08)))
        }
    }

    static func drawGrid(_ context: inout GraphicsContext, _ geo: some OvernightChartViewport) {
        let gridColor = Color.gray.opacity(0.2)
        for i in 0 ... 4 {
            let y = geo.size.height * CGFloat(i) / 4
            var gridPath = Path()
            gridPath.move(to: CGPoint(x: 0, y: y))
            gridPath.addLine(to: CGPoint(x: geo.size.width, y: y))
            context.stroke(gridPath, with: .color(gridColor), lineWidth: 0.5)
        }
    }
}

/// Overnight visualization showing full-night HR and HRV with nadir marked
/// Welltory-style overnight graphs
struct OvernightChartsView<InterChartContent: View>: View {
    let session: HRVSession
    let result: HRVAnalysisResult
    var healthKitSleep: SleepData?
    /// Optional callback for manual window reanalysis (timestamp in ms from session start)
    var onReanalyzeAt: ((Int64) -> Void)?
    /// Whether the user is in manual window selection mode
    var isManualWindowMode: Bool = false
    /// The manual analysis result (if any) to show its window on the chart
    var manualResult: HRVAnalysisResult?
    /// When true, suppresses the sleep metrics row (caller shows its own sleep card)
    var hideSleepRow: Bool = false
    /// Optional content inserted between overnight summary and charts (e.g., window selector controls)
    var interChartContent: InterChartContent

    @ViewBuilder
    var body: some View {
        VStack(spacing: 20) {
            if cachedOvernightStats == nil {
                chartsPlaceholder
            } else {
                chartSections
            }
        }
        /// Task identity: session.id + the analysis window quantised to the
        /// nearest minute. HealthKit can nudge sleep boundaries by a few
        /// seconds after the fact; without quantisation, each tiny bump
        /// invalidates the task and re-runs the full (cached-or-scanned)
        /// stats pipeline. A 1-minute resolution is way finer than the
        /// recovery-window differences the user can perceive.
        .task(id: "\(session.id)-\(result.windowStart / 60_000)-\(result.windowEnd / 60_000)") {
            await loadOvernightStats()
        }
    }

    private var chartsPlaceholder: some View {
        // Show placeholder while computing stats on background thread
        VStack(spacing: 12) {
            ProgressView()
                .tint(AppTheme.primary)
            Text(String(localized: "Preparing charts...", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
    }

    @ViewBuilder
    private var chartSections: some View {
        // Overnight stats summary
        overnightStatsSection

        // Optional content between summary and charts (e.g., window selector controls)
        interChartContent

        // Full night HRV (rolling RMSSD) graph - with reanalysis support (primary interaction chart)
        overnightHRVSection

        // Full night HR graph
        overnightHRSection
    }

    /// Runs the expensive stats computation off the main thread so scrolling
    /// stays responsive; the view shows a spinner until it completes.
    ///
    /// The zone-cache state is snapshotted BEFORE the compute so
    /// the disk backfill keeps the exact trigger condition:
    /// persisted zones absent AND memory-cache miss, i.e. the
    /// on-demand WindowSelector scan is about to actually run. The archive
    /// WRITE lives at this task boundary, not in `computeOrganizedZonesOnDemand`
    /// (stats math), so the side effect fires once per task id.
    private func loadOvernightStats() async {
        // Run expensive stats computation off the main thread so scrolling
        // stays responsive. The view shows a spinner until this completes.
        let computer = OvernightStatsComputer(session: session, result: result, healthKitSleep: healthKitSleep)
        let zonesNeedDiskBackfill = result.organizedRecoveryZones == nil
            && AppDependencies.current.app.organizedZonesCache.get(session.id) == nil
        var stats = await Task.detached(priority: .userInitiated) {
            computer.computeOvernightStats()
        }.value

        if zonesNeedDiskBackfill, let computedZones = AppDependencies.current.app.organizedZonesCache.get(session.id) {
            OvernightStatsComputer.backfillZonesToArchive(sessionId: session.id, zones: computedZones)
        }

        stats = await withHealthKitGapFill(stats)

        cachedOvernightStats = stats
    }

    /// HealthKit HR fills the gaps when the recording does not cover the whole
    /// sleep: split nights with segments that have no Polar data, short
    /// recordings where the strap disconnected, and crash-truncated recordings
    /// where the frozen sleep snapshot is truncated too. That last case is
    /// caught by comparing recording duration to the typical sleep target
    /// rather than to the snapshot ("HR chart still empty after
    /// crash", where the crash truncated BOTH recording and sleep).
    private func withHealthKitGapFill(_ input: OvernightStats) async -> OvernightStats {
        var stats = input
        guard needsGapFill(stats) else { return stats }
        guard let hkSleep = healthKitSleep else { return stats }
        debugLog("[ChartGate] gate PASSED — fetching HK HR for \(hkSleep.effectiveSegments.count) segments")
        let hkHR = await fetchHealthKitHRForUncoveredSegments(
            segments: hkSleep.effectiveSegments,
            recordingStartMs: session.rrSeries?.points.first?.t_ms ?? 0,
            recordingEndMs: session.rrSeries?.points.last?.endMs ?? 0
        )
        debugLog("[ChartGate] fetch returned \(hkHR.count) HK HR samples")
        stats = Self.extendedStats(stats, hkHR: hkHR, hkSleep: hkSleep, session: session)
        return stats
    }

    /// True when the recording does not cover the whole sleep, so HealthKit HR
    /// has to fill the gaps:
    /// - Split nights: segments without Polar data.
    /// - Short recordings: strap disconnected, sleep extends well beyond it.
    /// - Crash-truncated recordings: even when the frozen sleep snapshot is
    ///   truncated too (e.g. 81 min recording = 81 min sleep), the user
    ///   actually slept longer. Detect this by comparing recording duration to
    ///   the user's typical sleep target — if recording < half of target,
    ///   gap-fill regardless of what the snapshot says. (Fixes
    ///   "HR chart still empty after crash", where the crash truncated BOTH
    ///   the recording AND the sleep.)
    private func needsGapFill(_ stats: OvernightStats) -> Bool {
        let recordingStartMs = session.rrSeries?.points.first?.t_ms ?? 0
        let recordingEndMs = session.rrSeries?.points.last?.endMs ?? 0
        let recordingDurationMs = recordingEndMs - recordingStartMs
        let sleepDurationMs: Int64 = {
            guard let hk = healthKitSleep, let s = hk.sleepStart, let e = hk.sleepEnd else { return 0 }
            return MillisecondOffset.between(e, and: s, fallback: 0)
        }()
        let recordingCoversLessThanHalfOfSleep = sleepDurationMs > 0 && recordingDurationMs < sleepDurationMs / 2
        let typicalSleepMs: Int64 = Int64(AppDependencies.current.app.settingsManager.settings.typicalSleepHours * 3600 * 1000)
        let recordingCoversLessThanHalfOfTarget = recordingDurationMs < typicalSleepMs / 2

        debugLog("[ChartGate] recDuration=\(recordingDurationMs / 60000)min sleepDuration=\(sleepDurationMs / 60000)min typicalSleep=\(typicalSleepMs / 60000)min hkSleep=\(healthKitSleep != nil ? "yes" : "nil") segments=\(stats.sleepSegmentRanges.count) coversLessThanHalfOfSleep=\(recordingCoversLessThanHalfOfSleep) coversLessThanHalfOfTarget=\(recordingCoversLessThanHalfOfTarget)")

        return stats.sleepSegmentRanges.count > 1
            || recordingCoversLessThanHalfOfSleep
            || recordingCoversLessThanHalfOfTarget
    }

    /// Widen the chart viewport to whatever the HealthKit samples cover —
    /// split-night segment bounds and the full HealthKit sleep window — then
    /// fold in the samples that land inside it.
    private static func extendedStats(
        _ stats: OvernightStats,
        hkHR: [(timeMs: Int64, hr: Double)],
        hkSleep: SleepData,
        session: HRVSession
    ) -> OvernightStats {
        var stats = stats
        let dataStartMs = session.rrSeries?.points.first?.t_ms ?? stats.chartStartMs
        debugLog("[ChartExtension] BEFORE: chartStart=\(stats.chartStartMs) chartEnd=\(stats.chartEndMs) dataStartMs=\(dataStartMs) hkHR.count=\(hkHR.count)")
        let bounds = viewportBounds(stats, hkSleep: hkSleep, session: session, dataStartMs: dataStartMs)
        let extendedStart = bounds.start
        let extendedEnd = bounds.end
        debugLog("[ChartExtension] AFTER: chartStart=\(extendedStart) chartEnd=\(extendedEnd)")

        let viewportHR = hkHR.filter {
            $0.timeMs >= extendedStart && $0.timeMs <= extendedEnd
        }
        if !viewportHR.isEmpty {
            stats = stats.withHealthKitHR(
                viewportHR,
                chartStartMs: extendedStart,
                chartEndMs: extendedEnd
            )
        }
        return stats
    }

    /// Split-night segment boundaries, as the viewport would have to widen for
    /// them. A start before the recording's own data is ignored, exactly as the
    /// inline version did.
    private static func segmentBounds(
        _ stats: OvernightStats,
        dataStartMs: Int64
    ) -> (start: Int64, end: Int64) {
        let starts = stats.sleepSegmentRanges.map(\.startMs).min()
        let ends = stats.sleepSegmentRanges.map(\.endMs).max()
        return (
            starts.flatMap { $0 >= dataStartMs ? $0 : nil } ?? .max,
            ends ?? .min
        )
    }

    private static func viewportBounds(
        _ stats: OvernightStats,
        hkSleep: SleepData,
        session: HRVSession,
        dataStartMs: Int64
    ) -> (start: Int64, end: Int64) {
        let (segStartMs, segEndMs) = segmentBounds(stats, dataStartMs: dataStartMs)
        var extendedStart = min(stats.chartStartMs, segStartMs)
        var extendedEnd = max(stats.chartEndMs, segEndMs)
        // Full HealthKit sleep window (short recording + long sleep)
        if let hkStart = hkSleep.sleepStart, let hkEnd = hkSleep.sleepEnd {
            let hkStartMs = MillisecondOffset.between(hkStart, and: session.startDate, fallback: 0)
            let hkEndMs = MillisecondOffset.between(hkEnd, and: session.startDate, fallback: 0)
            debugLog("[ChartExtension] hkSleep: startMs=\(hkStartMs) endMs=\(hkEndMs) (hkStart=\(hkStart) hkEnd=\(hkEnd) sessionStart=\(session.startDate))")
            if hkStartMs >= dataStartMs {
                extendedStart = min(extendedStart, hkStartMs)
            } else {
                debugLog("[ChartExtension] SKIPPED extending start: hkStartMs=\(hkStartMs) < dataStartMs=\(dataStartMs)")
            }
            extendedEnd = max(extendedEnd, hkEndMs)
        }
        return (extendedStart, extendedEnd)
    }

    // MARK: - Overnight Stats (cached — not recomputed on every render)

    @State private var cachedOvernightStats: OvernightStats?

    private var overnightStats: OvernightStats {
        cachedOvernightStats ?? .empty
    }

    private var overnightStatsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            overnightSummaryHeader
            coreMetricsRow
            sleepMetricsRow
        }
        .zenCard()
    }

    private var overnightSummaryHeader: some View {
        HStack {
            Image(systemName: "moon.stars.fill")
                .foregroundColor(AppTheme.primary)
            Text(healthKitSleep != nil ? String(localized: "Overnight Summary", bundle: LanguageManager.appBundle) : String(localized: "Session Summary", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)
        }
    }

    /// Row 1: core metrics.
    private var coreMetricsRow: some View {
        HStack(spacing: 12) {
            hrNadirCard

            peakHRVCard

            avgHRCard
        }
    }

    private var avgHRCard: some View {
        OvernightStatCard(
            title: String(localized: "Avg HR", bundle: LanguageManager.appBundle),
            value: String(format: "%.0f", locale: .current, overnightStats.avgHR),
            unit: "bpm",
            subtitle: String(localized: "overnight", bundle: LanguageManager.appBundle),
            color: AppTheme.terracotta
        )
    }

    private var peakHRVCard: some View {
        OvernightStatCard(
            title: String(localized: "Peak HRV", bundle: LanguageManager.appBundle),
            value: String(format: "%.0f", locale: .current, overnightStats.peakRMSSD),
            unit: "ms",
            subtitle: overnightStats.peakHRVTimeFormatted,
            color: AppTheme.sage
        )
    }

    private var hrNadirCard: some View {
        OvernightStatCard(
            // Row 1: Core metrics
            title: String(localized: "HR Nadir", bundle: LanguageManager.appBundle),
            value: String(format: "%.0f", locale: .current, overnightStats.nadirHR),
            unit: "bpm",
            subtitle: overnightStats.nadirTimeFormatted,
            color: AppTheme.mist
        )
    }

    /// Row 2: sleep metrics, from HealthKit when available and otherwise
    /// estimated from HR. Hidden when the parent view already shows a
    /// dedicated sleep card.
    @ViewBuilder
    private var sleepMetricsRow: some View {
        // Row 2: Sleep metrics (from HealthKit when available, otherwise estimated from HR patterns)
        // Hidden when the parent view already shows a dedicated sleep card
        if !hideSleepRow, overnightStats.estimatedSleepDurationMinutes > 0 {
            sleepStatCards

            // Sleep quality note
            Text(sleepQualityNote)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .padding(.top, 4)
        }
    }

    private var sleepStatCards: some View {
        HStack(spacing: 12) {
            timeAsleepCard

            deepSleepCard

            awakeningsCard
        }
    }

    private var awakeningsCard: some View {
        OvernightStatCard(
            title: String(localized: "Awakenings", bundle: LanguageManager.appBundle),
            value: "\(overnightStats.awakeningsCount)",
            unit: "",
            subtitle: overnightStats.isHealthKitData ? String(localized: "from sleep data", bundle: LanguageManager.appBundle) : String(localized: "HR spikes", bundle: LanguageManager.appBundle),
            color: overnightStats.awakeningsCount > 3 ? AppTheme.terracotta : AppTheme.sage
        )
    }

    private var deepSleepCard: some View {
        OvernightStatCard(
            title: overnightStats.isHealthKitData ? String(localized: "Deep Sleep", bundle: LanguageManager.appBundle) : String(localized: "Est. Deep", bundle: LanguageManager.appBundle),
            // Locale-aware h/m abbreviations.
            value: LocalizedDuration.hoursMinutes(minutes: overnightStats.deepSleepMinutes),
            unit: "",
            subtitle: overnightStats.isHealthKitData ? String(localized: "Apple Watch", bundle: LanguageManager.appBundle) : String(localized: "lowest HR quartile", bundle: LanguageManager.appBundle),
            color: AppTheme.mist
        )
    }

    private var timeAsleepCard: some View {
        OvernightStatCard(
            title: overnightStats.isHealthKitData ? String(localized: "Time Asleep", bundle: LanguageManager.appBundle) : String(localized: "Est. Sleep", bundle: LanguageManager.appBundle),
            value: overnightStats.estimatedSleepDurationFormatted,
            unit: "",
            subtitle: overnightStats.isHealthKitData
                ? String(localized: "from Apple Health", bundle: LanguageManager.appBundle)
                : String(format: NSLocalizedString("%.0f%% efficiency", bundle: LanguageManager.appBundle, comment: ""), overnightStats.sleepEfficiency),
            color: AppTheme.primary
        )
    }

    private var sleepQualityNote: String {
        let stats = overnightStats
        let notes = durationNotes(stats) + deepSleepNotes(stats) + awakeningNotes(stats)
        return notes.isEmpty ? String(localized: "Sleep metrics estimated from HR patterns", bundle: LanguageManager.appBundle) : notes.joined(separator: " • ").capitalized
    }

    private func durationNotes(_ stats: OvernightStats) -> [String] {
        var notes: [String] = []
        // Sleep duration assessment
        if stats.estimatedSleepDurationMinutes < 300 { // < 5 hours
            notes.append(String(localized: "Short sleep detected", bundle: LanguageManager.appBundle))
        } else if stats.estimatedSleepDurationMinutes >= 420 { // >= 7 hours
            notes.append(String(localized: "Good sleep duration", bundle: LanguageManager.appBundle))
        }
        return notes
    }

    private func deepSleepNotes(_ stats: OvernightStats) -> [String] {
        var notes: [String] = []

        // Deep sleep assessment
        let deepSleepPercent = stats.estimatedSleepDurationMinutes > 0 ?
            Double(stats.deepSleepMinutes) / Double(stats.estimatedSleepDurationMinutes) * 100 : 0
        if deepSleepPercent < 15 {
            notes.append(String(localized: "low deep sleep", bundle: LanguageManager.appBundle))
        } else if deepSleepPercent > 25 {
            notes.append(String(localized: "excellent deep sleep", bundle: LanguageManager.appBundle))
        }
        return notes
    }

    private func awakeningNotes(_ stats: OvernightStats) -> [String] {
        var notes: [String] = []

        // Awakenings assessment
        if stats.awakeningsCount > 5 {
            notes.append(String(localized: "fragmented sleep", bundle: LanguageManager.appBundle))
        } else if stats.awakeningsCount <= 1 {
            notes.append(String(localized: "uninterrupted sleep", bundle: LanguageManager.appBundle))
        }

        return notes
    }

    // MARK: - Overnight HR Graph

    private var overnightHRSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            hrSectionHeader

            OvernightHRChartCanvas(
                session: session,
                result: result,
                stats: overnightStats,
                healthKitSleep: healthKitSleep
            )
            .frame(height: 180)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Heart rate chart. Range \(Int(overnightStats.minHR)) to \(Int(overnightStats.maxHR)) bpm. Nadir \(Int(overnightStats.nadirHR)) bpm at \(overnightStats.nadirTimeFormatted). Average \(Int(overnightStats.avgHR)) bpm.", bundle: LanguageManager.appBundle))

            // Legend
            hrChartLegend
        }
        .zenCard()
    }

    private var hrChartLegend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Circle().fill(AppTheme.terracotta).frame(width: 8, height: 8)
                Text(String(localized: "HR", bundle: LanguageManager.appBundle)).font(.caption2).foregroundColor(AppTheme.textTertiary)
            }
            appleWatchLegendItem
            HStack(spacing: 4) {
                Circle().fill(AppTheme.mist).frame(width: 8, height: 8)
                Text(String(localized: "Nadir", bundle: LanguageManager.appBundle)).font(.caption2).foregroundColor(AppTheme.textTertiary)
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(AppTheme.primary.opacity(0.3))
                    .frame(width: 12, height: 8)
                Text(String(localized: "Analysis Window", bundle: LanguageManager.appBundle)).font(.caption2).foregroundColor(AppTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var appleWatchLegendItem: some View {
        if !overnightStats.healthKitHR.isEmpty {
            HStack(spacing: 4) {
                Circle().fill(AppTheme.terracotta.opacity(0.4)).frame(width: 8, height: 8)
                Text(String(localized: "Apple Watch", bundle: LanguageManager.appBundle)).font(.caption2).foregroundColor(AppTheme.textTertiary)
            }
        }
    }

    private var hrSectionHeader: some View {
        HStack {
            Text(healthKitSleep != nil ? String(localized: "Heart Rate Overnight", bundle: LanguageManager.appBundle) : String(localized: "Heart Rate", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)
            Spacer()
            Text(String(localized: "\(Int(overnightStats.minHR))-\(Int(overnightStats.maxHR)) bpm", bundle: LanguageManager.appBundle))
                .font(.caption.bold())
                .foregroundColor(AppTheme.terracotta)
        }
    }

    // MARK: - Overnight HRV Graph

    private var overnightHRVSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            hrvSectionHeader

            OvernightHRVChartCanvas(
                session: session,
                result: result,
                stats: overnightStats,
                healthKitSleep: healthKitSleep,
                onReanalyzeAt: onReanalyzeAt,
                isManualWindowMode: isManualWindowMode,
                manualResult: manualResult
            )
            .frame(height: 180)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "HRV chart. Peak RMSSD \(Int(overnightStats.peakRMSSD)) milliseconds at \(overnightStats.peakHRVTimeFormatted). Analysis window \(overnightStats.windowStartTimeFormatted) to \(overnightStats.windowEndTimeFormatted).", bundle: LanguageManager.appBundle))

            // Legend
            hrvChartLegend
        }
        .zenCard()
    }

    private var hrvChartLegend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Circle().fill(AppTheme.sage).frame(width: 8, height: 8)
                Text(String(localized: "RMSSD", bundle: LanguageManager.appBundle)).font(.caption2).foregroundColor(AppTheme.textTertiary)
            }
            HStack(spacing: 4) {
                Circle().fill(AppTheme.primary).frame(width: 8, height: 8)
                Text(String(localized: "Peak HRV", bundle: LanguageManager.appBundle)).font(.caption2).foregroundColor(AppTheme.textTertiary)
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(AppTheme.primary.opacity(0.3))
                    .frame(width: 12, height: 8)
                Text(String(localized: "Analysis Window", bundle: LanguageManager.appBundle)).font(.caption2).foregroundColor(AppTheme.textTertiary)
            }
        }
    }

    private var hrvSectionHeader: some View {
        HStack {
            Text(healthKitSleep != nil ? String(localized: "HRV Overnight (Rolling RMSSD)", bundle: LanguageManager.appBundle) : String(localized: "HRV (Rolling RMSSD)", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)
            Spacer()
            Text(String(localized: "Peak: \(Int(overnightStats.peakRMSSD)) ms", bundle: LanguageManager.appBundle))
                .font(.caption.bold())
                .foregroundColor(AppTheme.sage)
        }
    }

    // MARK: - Compute Stats
}
