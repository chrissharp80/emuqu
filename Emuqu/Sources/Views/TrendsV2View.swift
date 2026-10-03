import Charts
import SwiftUI

/// Trends home (v2). Long-term pattern view.
///
/// Layout (top to bottom):
///   1. Filter row (Tags + time-range chips)
///   2. Overall Trend card
///   3. Main HRV chart with shaded normal-range band
///   4. Stats grid 2×2
///   5. Insights bullets (data-window-aware)
///   6. History calendar — consolidated month grid carrying both the
///      day's training load (cell fill) and morning feeling (corner dot).
struct TrendsV2View: View {
    @Environment(\.dependencies) var dependencies
    /// Materials go opaque when the user asks for reduced transparency —
    /// iOS does not substitute for you. See `AdaptiveMaterial`.
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency

    // MARK: - Dynamic Type
    //
    // These replace hard-coded `.font(.system(size: N))`
    // literals, which do not respond to the user's text-size setting at all.
    // The app's semantic styles (`.body`, `.caption`, …) DO scale, so at AX5 the
    // surrounding text grows while such numbers stay put — breaking layout and
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
    @ScaledMetric(relativeTo: .body) private var dt17: CGFloat = 17
    @ScaledMetric(relativeTo: .title2) var dt22: CGFloat = 22
    @ScaledMetric(relativeTo: .title2) private var dt24: CGFloat = 24

    @Environment(RRCollector.self) var collector
    @Environment(ArchiveSignal.self) private var archiveSignal

    @State private var selectedRange: TimeRange = .thirty
    /// Default metric is **Recovery Score**. Showing
    /// RMSSD by default would invite the same averaging trap users hit
    /// before the .overnight filter landed: the recovery score is the
    /// number users already see on the dashboard, the one they want to
    /// see trending. RMSSD / SDNN / HR / Stress remain in the picker.
    @State var selectedMetric: Metric = .recoveryScore
    /// Filter by Tags chips (single row, horizontal
    /// scroll, never-wrapping). nil = "All". Selecting any tag filters
    /// `sessions` to readings carrying that tag. Single-select for
    /// now; the v1 plan calls for single-select chip semantics.
    @State private var selectedTagId: UUID?
    /// An `@State` populated once via
    /// `recentSessionsAsync(limit: nil)` (lightweight loader, no
    /// rrSeries deserialization), refreshed on selectedRange change
    /// and archive-version bump. Body reads from this without
    /// touching disk. A computed property calling
    /// `collector.recentSessions(limit: nil)` synchronously on every
    /// body re-evaluation decodes the entire archive on the main
    /// thread (~250ms freeze for 50+ sessions, multiple times per
    /// nav transition) — the "More tab → Trends" stall.
    @State private var allSessions: [HRVSession] = []
    @State private var isLoadingSessions = false

    /// Memoized derived state. Body re-evaluations
    /// (range change, tag chip tap, metric switch, archive bump, view
    /// re-layout) would otherwise recompute `buildMetricPoints` × 4 surfaces
    /// (chart, stats grid, insights, overall direction), each iterating
    /// all sessions plus their analysis results. Built once per
    /// input change and cached here. Tracks an input-fingerprint so
    /// `.task(id:)` only rebuilds when something actually changed.
    @State var derived: Derived = .empty
    @State private var fingerprint: Int = 0
    /// Chart scrubbing state — `chartXSelection(value:)` writes a Date
    /// here as the user drags. Nearest-point lookup pins a value pill
    /// + delta-vs-baseline % beneath the chart.
    @State var scrubbedDate: Date?

    enum TimeRange: Int, CaseIterable, Identifiable {
        case seven = 7, fourteen = 14, thirty = 30, ninety = 90, all = 0
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .seven: "7"
            case .fourteen: "14"
            case .thirty: "30"
            case .ninety: "90"
            case .all: String(localized: "All", bundle: LanguageManager.appBundle)
            }
        }

        /// What VoiceOver reads: "7 days" rather than "7", in the app
        /// language, plural forms included.
        var spokenLabel: String {
            guard let days = dayCount else { return label }
            let formatter = DateComponentsFormatter()
            var calendar = Calendar.current
            calendar.locale = LanguageManager.appLocale
            formatter.calendar = calendar
            formatter.unitsStyle = .full
            formatter.allowedUnits = [.day]
            return formatter.string(from: TimeInterval(days * 86_400)) ?? label
        }

        private var dayCount: Int? {
            switch self {
            case .seven: 7
            case .fourteen: 14
            case .thirty: 30
            case .ninety: 90
            case .all: nil
            }
        }
    }

    enum Metric: String, CaseIterable {
        case recoveryScore = "Recovery"
        case rmssd = "RMSSD"
        case sdnn = "SDNN"
        case meanHR = "Mean HR"
        case balance = "Balance"   // LF/HF ratio — autonomic balance
        case hfPower = "HF Power"  // Vagal tone proxy
        case stress = "Stress"

        /// The name on screen. `rawValue` is English and stays the chart's
        /// data key; shown as-is, the picker and titles were English in every
        /// language.
        var localizedName: String {
            let b = LanguageManager.appBundle
            return switch self {
            case .recoveryScore: String(localized: "Recovery", bundle: b)
            case .rmssd: "RMSSD"
            case .sdnn: "SDNN"
            case .meanHR: String(localized: "Mean HR", bundle: b)
            case .balance: String(localized: "Balance", bundle: b)
            case .hfPower: String(localized: "HF Power", bundle: b)
            case .stress: String(localized: "Stress", bundle: b)
            }
        }

        /// Y-axis caption + insight phrasing.
        var displayUnit: String {
            switch self {
            case .recoveryScore: "/ 100"
            case .rmssd, .sdnn: "ms"
            case .meanHR: "bpm"
            case .balance: ""        // dimensionless ratio
            case .hfPower: "ms²"
            case .stress: ""
            }
        }
    }

    /// Filtered + sorted view of `allSessions` for the current range,
    /// **session type** (overnight only — naps, quick spot-checks,
    /// post-workout HRV captures, and Apple Watch Breathe samples are
    /// physiologically incomparable and would corrupt the trend mean
    /// when averaged together; ARCHITECTURE.md "Trend cap contract"
    /// + the SessionType.overnight comment make this explicit), and
    /// the selected tag filter. Pure in-memory transform.
    private var sessions: [HRVSession] {
        let cutoff: Date = {
            switch selectedRange {
            case .all: return .distantPast
            default: return Calendar.current.date(byAdding: .day, value: -selectedRange.rawValue, to: Date()) ?? .distantPast
            }
        }()
        return allSessions
            .filter { $0.startDate >= cutoff && $0.sessionType == .overnight && $0.analysisResult != nil && $0.isReliableForHRVAggregates }
            .filter { session in
                guard let tagId = selectedTagId else { return true }
                return session.tags.contains { $0.id == tagId }
            }
            .sorted { $0.startDate < $1.startDate }
    }

    /// These are the four primary tags in the filter row.
    /// Single horizontal scroll, never wrapped. "All" = nil selection.
    private static let primaryFilterTags: [ReadingTag] = [
        .morning, .postExercise, .recovery, .evening
    ]

    var body: some View {
        withRefreshHooks(
            ScrollView { stack }
                .background(AppTheme.background.ignoresSafeArea())
                .navigationTitle(Text(String(localized: "Trends", bundle: LanguageManager.appBundle)))
                .navigationBarTitleDisplayMode(.large)
        )
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 22) {
            tagFilterChips
            rangeChips
            overallTrendCard
            metricChartCard
            statsGrid
            insightsSection
            calendar
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    /// Single calendar surface. The Sun–Sat month grid carries
    /// BOTH the day's objective training load (cell fill intensity) AND the
    /// subjective morning-feeling rating (small colored dot in the top-right
    /// corner). User complaint: "Two calendars in Trends. Neither make sense.
    /// One history calendar but it's tiny. The other is a 'how you felt' and
    /// it's huge and you can't click into it." Resolved by consolidating both
    /// signals into the one tappable calendar — load tells you what you DID,
    /// dot tells you how you felt that morning, tap opens the day's session
    /// detail.
    private var calendar: some View {
        HistoryCalendarView(allSessions: allSessions, onDelete: deleteSession)
    }

    private func withRefreshHooks(_ content: some View) -> some View {
        content
            .task {
                await loadSessions()
            }
            // Refresh when a session is added / mutated elsewhere.
            .onChange(of: archiveSignal.version) { _, _ in
                Task { await loadSessions() }
            }
            // Rebuild memoized derived state whenever an input changes.
            // The fingerprint hashes (sessions identity, range, metric, tag)
            // so the same body re-eval doesn't trigger a rebuild.
            .onChange(of: allSessions.count) { _, _ in rebuildDerived() }
            .onChange(of: selectedRange) { _, _ in rebuildDerived() }
            .onChange(of: selectedMetric) { _, _ in rebuildDerived() }
            .onChange(of: selectedTagId) { _, _ in rebuildDerived() }
    }

    @MainActor
    private func loadSessions() async {
        guard !isLoadingSessions else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        // Async loader runs on a background priority queue and uses
        // the lightweight retrieve path (skips rrSeries decode), so
        // the main thread never blocks on disk during nav transition.
        let loaded = await collector.recentSessionsAsync(limit: nil)
        allSessions = loaded
        rebuildDerived()
    }

    /// Soft-delete a session from the calendar's day sheet (moves it to Trash).
    /// Mirrors `MainTabView.deleteSession` so the History list and the calendar
    /// share one delete path. Removing it from `allSessions` immediately keeps
    /// the calendar in sync before the archive signal re-loads.
    private func deleteSession(_ session: HRVSession) {
        do {
            try collector.archive.delete(session.id)
            collector.notifyArchiveChanged()
            allSessions.removeAll { $0.id == session.id }
            rebuildDerived()
            Task { await dependencies.storage.cloudKitSyncManager.uploadDeletion(session.id) }
        } catch {
            debugLog("[TrendsV2View] Failed to delete session \(session.id.uuidString.prefix(8)): \(error)")
        }
    }

    /// Recompute every chart-, grid-, insight-, and heatmap-feeding
    /// array in one pass. Cheap (one filter + one map per surface) but
    /// only runs when an input changed — body re-evals don't trigger
    /// it. Hot path: range/metric/tag changes hit ~5ms for 200 sessions.
    private func rebuildDerived() {
        let scoped = sessions
        let pts = buildMetricPoints(from: scoped, metric: selectedMetric)
        let baselineStats = sixtyDayBaselines()
        derived = Derived(
            sessions: scoped,
            points: pts,
            rollingBaseline: Self.rollingBaseline(pts, window: 7),
            chartBand: baselineStats[selectedMetric] ?? .empty,
            direction: Self.computeDirection(rmssd: scoped.compactMap { $0.analysisResult?.timeDomain.rmssd }),
            stats: Self.computeStats(scoped, baselines: baselineStats),
            insights: Self.buildInsights(metric: selectedMetric, points: pts, days: rangeDays, totalDays: scoped.count)
        )
    }

    /// 60-day rolling baseline (shaded normal-range
    /// band, mean ±1 SD over 60 days). Computed across ALL overnight sessions
    /// in the last 60 days, independent of the visible-window range chip —
    /// that's what makes the band a stable "this is your normal" reference
    /// rather than circular ("the average of the dots, ±1 SD of those same
    /// dots").
    private func sixtyDayBaselines() -> [Metric: BaselineStats] {
        let baselineSet = Self.baselineWindow(allSessions, days: 60)
        return Dictionary(uniqueKeysWithValues:
            Metric.allCases.map { metric in
                let pts = buildMetricPoints(from: baselineSet, metric: metric)
                return (metric, BaselineStats.from(pts.map(\.value)))
            }
        )
    }

    /// 60-day mean + SD for a single metric, used both for the chart's
    /// shaded band AND for the per-cell vs-baseline % in the stats grid.
    /// Independent from the visible-window range so the reference doesn't
    /// shift when the user changes the time chip.
    struct BaselineStats {
        let mean: Double
        let sd: Double
        let sampleCount: Int

        static let empty = BaselineStats(mean: 0, sd: 0, sampleCount: 0)
        var hasData: Bool { sampleCount >= 4 }

        static func from(_ values: [Double]) -> BaselineStats {
            guard values.count >= 4 else { return .empty }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count)
            return BaselineStats(mean: mean, sd: sqrt(variance), sampleCount: values.count)
        }

        /// Percentage delta of `value` vs the baseline mean. Returns nil
        /// when we don't yet have ≥4 data points to anchor against.
        func deltaPercent(_ value: Double) -> Double? {
            guard hasData, mean > 0 else { return nil }
            return ((value - mean) / mean) * 100
        }
    }

    /// Snapshot of every derived view input. Recomputed by
    /// `rebuildDerived()` whenever an input changes; read-only from
    /// the body. Keeps body re-evals O(1).
    struct Derived {
        let sessions: [HRVSession]
        let points: [MetricPoint]
        let rollingBaseline: [MetricPoint]
        /// 60-day baseline stats for the currently-selected chart
        /// metric. Drives the shaded ±1 SD band on the chart
        let chartBand: BaselineStats
        let direction: DirectionInfo
        let stats: [GridCell]
        let insights: [String]

        @MainActor static let empty = Derived(
            sessions: [],
            points: [],
            rollingBaseline: [],
            chartBand: .empty,
            direction: DirectionInfo(label: String(localized: "Building trend", bundle: LanguageManager.appBundle), glyph: "circle.dashed", color: AppTheme.textTertiary),
            stats: [],
            insights: []
        )
    }

    /// Filter `allSessions` to overnight readings within the last
    /// `days` days. Used as the input set for the 60-day baseline.
    private static func baselineWindow(_ all: [HRVSession], days: Int) -> [HRVSession] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        return all.filter {
            $0.startDate >= cutoff && $0.sessionType == .overnight && $0.analysisResult != nil && $0.isReliableForHRVAggregates
        }
    }

    // MARK: - Tag filter chips (single row, horizontal scroll)

    private var tagFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            chipRow
                .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            allTagsChip
            ForEach(Self.primaryFilterTags) { tag in
                filterChip(tag)
            }
        }
    }

    private var allTagsChip: some View {
        tagChip(label: String(localized: "All", bundle: LanguageManager.appBundle), color: AppTheme.primary, isSelected: selectedTagId == nil) {
            selectedTagId = nil
        }
    }

    private func filterChip(_ tag: ReadingTag) -> some View {
        let chipColor = Color(hex: tag.colorHex) ?? AppTheme.primary
        return tagChip(label: tag.displayName, color: chipColor, isSelected: selectedTagId == tag.id) {
            selectedTagId = (selectedTagId == tag.id) ? nil : tag.id
        }
    }

    private func tagChip(label: String, color: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(.system(size: dt13, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isSelected ? color.opacity(0.18) : AppTheme.cardBackground)
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? color : Color.clear, lineWidth: 1.2)
                )
                .foregroundStyle(isSelected ? color : AppTheme.textSecondary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "\(label) filter", bundle: LanguageManager.appBundle))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Range chips

    private var rangeChips: some View {
        HStack(spacing: 6) {
            ForEach(TimeRange.allCases) { range in
                rangeChip(range)
            }
            Spacer()
        }
    }

    /// The range chips are labelled "7", "14", "30", "90",
    /// "All"; a UI test that looks for copy ("1W", "1M", "3M", "All Time")
    /// silently skips when the labels change. Key the
    /// query to the range instead of to the copy.
    private func rangeChip(_ range: TimeRange) -> some View {
        Button {
            selectedRange = range
        } label: {
            rangeChipLabel(range)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(range.spokenLabel)
        .accessibilityAddTraits(selectedRange == range ? .isSelected : [])
        .accessibilityIdentifier("trends.range.\(range.rawValue)")
    }

    private func rangeChipLabel(_ range: TimeRange) -> some View {
        Text(verbatim: range.label)
            .font(.system(size: dt13, weight: .semibold))
            .frame(width: 44, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedRange == range ? AppTheme.primary.opacity(0.15) : AppTheme.cardBackground)
            )
            // 44pt touch target; the visible chip stays 32pt tall.
            .frame(height: 44)
            .contentShape(Rectangle())
            .foregroundStyle(selectedRange == range ? AppTheme.primary : AppTheme.textSecondary)
    }

    // MARK: - Overall trend

    /// Always computed from RMSSD, whichever metric the chart shows, so it
    /// names its metric rather than appearing to contradict the selected
    /// metric's insights below.
    private var overallTrendCard: some View {
        HStack {
            Image(systemName: derived.direction.glyph)
                .foregroundStyle(derived.direction.color)
                .font(.system(size: dt24))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "RMSSD · " + derived.direction.label)
                    .font(.system(size: dt17, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(readingCountLine(derived.sessions.count))
                    .font(.system(size: dt13))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.cardBackground)
        )
    }

    struct DirectionInfo { let label: String; let glyph: String; let color: Color }

    /// Weight RECENT points so a full-window slope can't paint
    /// "Rising" over a fresh reversal (Jun-25 ~85 → mid-50s still read
    /// Rising). Compare the most-recent block vs the block just before it
    /// (each ~a third of the window, min 2 points).
    static func computeDirection(rmssd values: [Double]) -> DirectionInfo {
        guard values.count >= 4 else {
            return DirectionInfo(label: String(localized: "Building trend", bundle: LanguageManager.appBundle), glyph: "circle.dashed", color: AppTheme.textTertiary)
        }
        let block = max(2, values.count / 3)
        let recent = Array(values.suffix(block))
        let prior = Array(values.dropLast(block).suffix(block))
        guard !prior.isEmpty else { return stableDirection() }
        let recentMean = recent.reduce(0, +) / Double(recent.count)
        let priorMean = prior.reduce(0, +) / Double(prior.count)
        guard priorMean > 0 else { return stableDirection() }
        let pct = ((recentMean - priorMean) / priorMean) * 100
        if pct > 5 { return DirectionInfo(label: String(localized: "Rising", bundle: LanguageManager.appBundle), glyph: "arrow.up.right", color: AppTheme.wongOptimal) }
        if pct < -5 { return DirectionInfo(label: String(localized: "Falling", bundle: LanguageManager.appBundle), glyph: "arrow.down.right", color: AppTheme.wongCaution) }
        return stableDirection()
    }

    private static func stableDirection() -> DirectionInfo {
        DirectionInfo(label: String(localized: "Stable", bundle: LanguageManager.appBundle), glyph: "arrow.right", color: AppTheme.wongGood)
    }

    /// Nil for "All".
    private var rangeDays: Int? { selectedRange == .all ? nil : selectedRange.rawValue }

    /// Whole sentences: "over the last \(range)" read "over the last all time".
    private func readingCountLine(_ count: Int) -> String {
        let b = LanguageManager.appBundle
        guard let days = rangeDays else { return String(localized: "Overnight readings, all time: \(count)", bundle: b) }
        return String(localized: "Overnight readings, last \(days) days: \(count)", bundle: b)
    }
}
