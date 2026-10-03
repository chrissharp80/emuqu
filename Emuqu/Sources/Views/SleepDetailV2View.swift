import Charts
import SwiftUI

/// Sleep detail. ScoreRing-driven hero, hypnogram,
/// stage breakdown, trends, sleep structure, age-group comparison.
struct SleepDetailV2View: View {
    // MARK: - Dynamic Type
    //
    // Hard-coded `.font(.system(size: N))`
    // literals do not respond to the user's text-size setting at all.
    // The app's semantic styles (`.body`, `.caption`, …) DO scale, so at AX5 the
    // surrounding text grows while such numbers stay put — breaking layout and
    // leaving the largest figures on screen at their smallest size for exactly
    // the users who enlarged their text.
    //
    // `@ScaledMetric(relativeTo:)` is the mechanism SwiftUI provides: there is no
    // `Font.system(size:relativeTo:)` overload. Each literal is bound to the text
    // style whose default size is nearest, so the default-setting appearance is
    // unchanged. Same pattern as DashboardV2View.
    @ScaledMetric(relativeTo: .caption2) var dt9: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) var dt10: CGFloat = 10
    @ScaledMetric(relativeTo: .caption2) var dt11: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) var dt12: CGFloat = 12
    @ScaledMetric(relativeTo: .footnote) var dt13: CGFloat = 13
    @ScaledMetric(relativeTo: .footnote) var dt14: CGFloat = 14
    @ScaledMetric(relativeTo: .subheadline) var dt15: CGFloat = 15
    @ScaledMetric(relativeTo: .callout) var dt16: CGFloat = 16
    @ScaledMetric(relativeTo: .body) var dt17: CGFloat = 17
    @ScaledMetric(relativeTo: .title2) var dt22: CGFloat = 22

    let session: HRVSession
    let sleepData: SleepData?
    let recoveryVitals: RecoveryVitals?
    let recentSessions: [HRVSession]
    let temperatureUnit: TemperatureUnit
    let typicalSleepHours: Double
    let userAge: Int?
    var onRefresh: (() async -> Void)?
    var onAdjust: ((SleepData) -> Void)?

    @Environment(RRCollector.self) private var collector
    @State var expandedStage: SleepStageKind?

    /// Stable, non-localized identity for a sleep stage. Explanation
    /// dispatch and the tap-toggle key switch on this enum instead of the
    /// raw English label, so localizing the *display* label never breaks
    /// the switch. Display text is localized at render only.
    enum SleepStageKind: Hashable {
        case deep, rem, light, awake

        /// Localized label shown on the pill.
        var displayLabel: String {
            switch self {
            case .deep: return String(localized: "Deep", bundle: LanguageManager.appBundle)
            case .rem: return String(localized: "REM", bundle: LanguageManager.appBundle)
            case .light: return String(localized: "Light", bundle: LanguageManager.appBundle)
            case .awake: return String(localized: "Awake", bundle: LanguageManager.appBundle)
            }
        }
    }
    /// Hypnogram interactive scrubber state.
    @State private var hypnogramScrubbedAt: Date?
    @State private var editorSleepData: SleepDataIdentified?
    /// Late-arriving HealthKit vitals (Apple writes RR/SpO₂/temp
    /// minutes-to-hours after sleep ends). Refreshed on appear and
    /// merged with the passed-in `recoveryVitals`.
    @State private var refreshedVitals: RecoveryVitals?
    /// Cached 15-night trend. `buildTrend()` runs
    /// `calculateSleepScore` once per recent night; executed
    /// inside `recentTrendsSection` on EVERY body evaluation, every
    /// hypnogram scrub tick would re-score the whole fortnight. It runs
    /// once per input change (see the `.task(id: trendInputsKey)`
    /// modifier on `body`), off the main thread, and the section just
    /// reads this array. Same math, same ordering → identical bars.
    @State var trendNights: [TrendNight] = []

    /// Per-field merge with strap-meanHR override for sleep HR.
    /// See `VitalsDetailV2View.effectiveVitals` for rationale — this
    /// view applies the same fix so the Sleep HR stat row reads the
    /// strap's nocturnal analysis-window mean instead of Apple's
    /// daytime RHR sample even on sessions accepted before the
    /// strap-override path existed.
    private var effectiveVitals: RecoveryVitals? {
        let stored = recoveryVitals
        let fresh = refreshedVitals
        let strapHR = session.analysisResult?.timeDomain.meanHR
        let mergedRHR = strapHR ?? stored?.restingHeartRate ?? fresh?.restingHeartRate
        if fresh == nil, stored == nil { return heartRateOnlyVitals(mergedRHR) }
        return RecoveryVitals(
            respiratoryRate: fresh?.respiratoryRate ?? stored?.respiratoryRate,
            respiratoryRateBaseline: fresh?.respiratoryRateBaseline ?? stored?.respiratoryRateBaseline,
            oxygenSaturation: fresh?.oxygenSaturation ?? stored?.oxygenSaturation,
            oxygenSaturationMin: fresh?.oxygenSaturationMin ?? stored?.oxygenSaturationMin,
            wristTemperature: fresh?.wristTemperature ?? stored?.wristTemperature,
            wristTemperatureBaseline: fresh?.wristTemperatureBaseline ?? stored?.wristTemperatureBaseline,
            restingHeartRate: mergedRHR
        )
    }

    /// With neither a stored nor a fresh reading, the strap-derived resting
    /// heart rate is the only vital there is — and nil if even that is absent.
    private func heartRateOnlyVitals(_ mergedRHR: Double?) -> RecoveryVitals? {
        return mergedRHR.map {
            RecoveryVitals(
                respiratoryRate: nil, respiratoryRateBaseline: nil,
                oxygenSaturation: nil, oxygenSaturationMin: nil,
                wristTemperature: nil, wristTemperatureBaseline: nil,
                restingHeartRate: $0
            )
        }
    }

    /// Wrapper so SleepData becomes Identifiable for `.sheet(item:)`.
    struct SleepDataIdentified: Identifiable {
        let id = UUID()
        let data: SleepData
    }

    private var sleepScore: Double {
        RecoveryScoreCalculator.calculateSleepScore(
            sleepData: sleepData,
            typicalSleepHours: typicalSleepHours,
            userAge: userAge
        ) ?? 0
    }

    private var verdict: ScoreVerdict { ScoreVerdict(score: sleepScore) }

    var body: some View {
        withSleepEditor(sleepStack)
    }

    @ViewBuilder
    private var sleepStack: some View {
        ScrollView {
            sleepCards
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(Text(String(localized: "Sleep", bundle: LanguageManager.appBundle)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { menuButton } }
        .task(id: session.id) {
            await refreshVitals()
        }
    }

    private var sleepCards: some View {
        VStack(alignment: .leading, spacing: 22) {
            heroSection
            quickStatsRow
            vitalsRow
            sleepWindowCard
            hypnogramCard
            stageBreakdownSection
            scoreBreakdownSection
            sleepInsightsSection
            recentTrendsSection
            sleepStructureCard
            ageGroupCard
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    /// The editor gets a refresh callback so it can re-pull from
    /// HealthKit. That returns nil on failure (auth not granted, no sleep data
    /// for the window) and the editor surfaces a clear error rather than
    /// silently no-op-ing.
    ///
    /// The trend is recomputed whenever its inputs change (and on
    /// first appear), keyed on a fingerprint because `[HRVSession]` is not
    /// Equatable. Any night added or removed, or a sleep-snapshot edit,
    /// produces a new key and re-runs the detached compute; body evals between
    /// input changes read the `trendNights` @State for free.
    private func withSleepEditor(_ content: some View) -> some View {
        content
            .sheet(item: $editorSleepData) { wrapped in
                sleepEditor(wrapped)
            }
            .task(id: trendInputsKey) {
                let sessions = recentSessions
                let hours = typicalSleepHours
                let age = userAge
                trendNights = await Task.detached(priority: .userInitiated) {
                    Self.buildTrend(
                        recentSessions: sessions,
                        typicalSleepHours: hours,
                        userAge: age
                    )
                }.value
            }
    }

    /// Pass a Refresh callback so the editor can
    /// re-pull from HealthKit. Returns nil on failure (auth
    /// not granted, no sleep data for the window) — the
    /// editor surfaces a clear error in that case rather
    /// than silently no-op.
    private func sleepEditor(_ wrapped: SleepDataIdentified) -> some View {
        SleepTimelineEditorView(
            sleepData: wrapped.data,
            onSave: { adjusted in
                onAdjust?(adjusted)
                editorSleepData = nil
            },
            onRefreshFromHealthKit: { [weak collector, session] in
                guard let collector else { return nil }
                let recordingStart = session.startDate
                let recordingEnd = session.endDate ?? session.startDate.addingTimeInterval(8 * 3600)
                return try? await collector.healthKit.fetchSleepData(
                    for: recordingStart,
                    recordingEnd: recordingEnd
                )
            }
        )
    }

    /// Fingerprint of every input that feeds `buildTrend()`. Cheap —
    /// string assembly over the recent-session list, no scoring math.
    /// Covers the fields the sleep score reads (duration, efficiency,
    /// deep/REM/awake minutes, stage-interval count) so a sleep edit
    /// that changes any of them re-keys the trend task.
    private var trendInputsKey: String {
        let nights = recentSessions.map { s -> String in
            guard let snap = s.sleepSnapshot else { return s.id.uuidString }
            return "\(s.id)#\(snap.nightSleepMinutes)#\(snap.sleepEfficiency)#\(snap.deepSleepMinutes ?? -1)#\(snap.remSleepMinutes ?? -1)#\(snap.awakeMinutes)#\(snap.stageIntervals.count)"
        }
        return "\(typicalSleepHours)|\(userAge ?? -1)|" + nights.joined(separator: ",")
    }

    /// Re-pull vitals from HealthKit on appear so late-arriving fields
    /// (resp rate / SpO₂ / wrist temp) show up without forcing a
    /// session re-acceptance pass.
    @MainActor
    private func refreshVitals() async {
        let referenceDate = session.endDate ?? session.startDate
        let strapHR = session.analysisResult?.timeDomain.meanHR
        let fresh = await collector.healthKit
            .fetchRecoveryVitals(relativeTo: referenceDate)
            .withStrapNocturnalRHR(strapHR)
        if !fresh.isEmpty {
            refreshedVitals = fresh
        }
    }

    private var menuButton: some View {
        Menu {
            refreshSleepMenuItem
            editSleepMenuItem
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: dt16, weight: .semibold))
        }
        .accessibilityLabel(String(localized: "Sleep options", bundle: LanguageManager.appBundle))
    }

    private var refreshSleepLabel: some View {
        Label(String(localized: "Refresh sleep data", bundle: LanguageManager.appBundle), systemImage: "arrow.clockwise")
    }

    @ViewBuilder
    private var editSleepMenuItem: some View {
        if let sleepData, onAdjust != nil {
            Button {
                editorSleepData = SleepDataIdentified(data: sleepData)
            } label: { Label(String(localized: "Edit sleep", bundle: LanguageManager.appBundle), systemImage: "pencil") }
        }
    }

    @ViewBuilder
    private var refreshSleepMenuItem: some View {
        if let onRefresh {
            refreshSleepButton(onRefresh)
        }
    }

    private func refreshSleepButton(_ refresh: @escaping () async -> Void) -> some View {
        Button(action: { Task { await refresh() } }, label: { refreshSleepLabel })
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroSection: some View {
        HStack(alignment: .center, spacing: 16) {
            // No sleep data → the ring's empty state, not a 0 rated "Very low".
            ScoreRing(
                state: sleepData == nil ? .noData : .default(score: Int(sleepScore.rounded()), verdict: verdict),
                size: .card
            )
            .frame(width: 90, height: 90)
            noSleepDataSection
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppTheme.cardBackground)
        )
    }

    private var noSleepDataSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let sleep = sleepData {
                Text(verbatim: verdict.localizedWord)
                    .font(.system(size: dt17, weight: .semibold))
                    .foregroundStyle(verdict.textColor)
                // Hero shows the 24h total the score is graded on (night +
                // any qualifying nap). With no nap this is just the night, so
                // nap-free readings are unchanged. The night alone is still
                // shown by the Sleep Window card, the stage breakdown, and the
                // In-bed/Nap stats below.
                Text(verbatim: sleep.totalSleepFormatted)
                    .font(.system(size: dt22, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(AppTheme.textPrimary)
                goalProgressBar(sleep: sleep)
            } else {
                Text(String(localized: "No sleep data", bundle: LanguageManager.appBundle))
                    .font(.system(size: dt14))
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    private func goalProgressBar(sleep: SleepData) -> some View {
        let target = typicalSleepHours * 60
        // Include any qualifying nap so the goal bar matches what the score
        // grades (24h sleep), not the night alone.
        let actual = Double(sleep.totalSleepIncludingNapMinutes)
        let pct = min(actual / target, 1.2)
        let color = pct >= 1.0 ? AppTheme.wongOptimal : (pct >= 0.85 ? AppTheme.wongGood : AppTheme.wongCaution)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(AppTheme.textTertiary.opacity(0.18))
                    .frame(height: 4)
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: geo.size.width * min(pct, 1.0), height: 4)
            }
        }
        .frame(height: 4)
        .frame(maxWidth: 180)
    }

    // MARK: - Quick stats

    @ViewBuilder
    private var quickStatsRow: some View {
        if let sleep = sleepData {
            VStack(alignment: .leading, spacing: 6) {
                quickStatCells(sleep)
                latencyHint(sleep)
            }
        }
    }

    @ViewBuilder
    private func latencyHint(_ sleep: SleepData) -> some View {
        if sleep.sleepLatencyMinutes == nil {
            // Latency requires either an Apple "in-bed" segment
            // (Sleep Schedule wind-down) or a strap recording started
            // before sleep onset. Tell the user what to do — empty
            // dashes with no explanation make the app look broken.
            Text(String(localized: "Latency needs Sleep Schedule wind-down or starting the strap before bed.", bundle: LanguageManager.appBundle))
                .font(.system(size: dt11))
                .foregroundStyle(AppTheme.textTertiary)
                .padding(.top, 2)
        }
    }

    private func quickStatCells(_ sleep: SleepData) -> some View {
        HStack(spacing: 8) {
            stat(label: String(localized: "Efficiency", bundle: LanguageManager.appBundle), value: String(format: "%.0f%%", locale: LanguageManager.appLocale, sleep.sleepEfficiency))
            if let napFmt = sleep.napSleepFormatted {
                stat(label: String(localized: "Nap", bundle: LanguageManager.appBundle), value: napFmt)
            }
            stat(label: String(localized: "In bed", bundle: LanguageManager.appBundle), value: formatMinutes(sleep.inBedMinutes))
            stat(label: String(localized: "Awake", bundle: LanguageManager.appBundle), value: formatMinutes(sleep.awakeMinutes))
            stat(label: String(localized: "Latency", bundle: LanguageManager.appBundle), value: sleep.sleepLatencyMinutes.map { LocalizedDuration.minutes($0) } ?? "—")
        }
    }

    @ViewBuilder
    private var vitalsRow: some View {
        if let v = effectiveVitals, !v.isEmpty {
            vitalCells(v)
        }
    }

    private func vitalCells(_ v: RecoveryVitals) -> some View {
        HStack(spacing: 8) {
            stat(label: String(localized: "Resp", bundle: LanguageManager.appBundle), value: v.respiratoryRate.map { String(format: "%.1f", locale: LanguageManager.appLocale, $0) } ?? "—", unit: String(localized: "br/min", bundle: LanguageManager.appBundle))
            stat(label: String(localized: "SpO₂", bundle: LanguageManager.appBundle), value: v.oxygenSaturation.map { String(Int($0.rounded())) } ?? "—", unit: "%")
            stat(label: String(localized: "Temp", bundle: LanguageManager.appBundle), value: tempDisplay(v.wristTemperatureDeviation))
            stat(label: String(localized: "Sleep HR", bundle: LanguageManager.appBundle), value: v.restingHeartRate.map { String(Int($0.rounded())) } ?? "—", unit: String(localized: "bpm", bundle: LanguageManager.appBundle))
        }
    }

    private func tempDisplay(_ celsius: Double?) -> String {
        guard let c = celsius else { return "—" }
        switch temperatureUnit {
        case .celsius: return String(format: "%+.1f°C", locale: LanguageManager.appLocale, c)
        case .fahrenheit: return String(format: "%+.1f°F", locale: LanguageManager.appLocale, c * 9 / 5)
        }
    }

    private func stat(label: String, value: String, unit: String? = nil) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: label)
                .font(.system(size: dt11, weight: .medium))
                .foregroundStyle(AppTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            statValue(value: value, unit: unit)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.cardBackground)
        )
    }

    private func statValue(value: String, unit: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(verbatim: value)
                .font(.system(size: dt17, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
            if let unit {
                Text(verbatim: unit)
                    .font(.system(size: dt10))
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    func formatMinutes(_ minutes: Int) -> String {
        LocalizedDuration.hoursMinutes(minutes: minutes)
    }

    // MARK: - Sleep window

    @ViewBuilder
    private var sleepWindowCard: some View {
        if let sleep = sleepData,
           let start = sleep.sleepStart, let end = sleep.sleepEnd {
            HStack(alignment: .center) {
                sleepWindowText(sleep, start: start, end: end)
                Spacer()
                adjustSleepButton(sleep)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(AppTheme.cardBackground)
            )
        }
    }

    @ViewBuilder
    private func adjustSleepButton(_ sleep: SleepData) -> some View {
        if onAdjust != nil {
            Button {
                editorSleepData = SleepDataIdentified(data: sleep)
            } label: {
                Text(String(localized: "Adjust", bundle: LanguageManager.appBundle))
                    .font(.system(size: dt13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(AppTheme.primary.opacity(0.15)))
                    .foregroundStyle(AppTheme.primary)
            }
            .buttonStyle(.plain)
        }
    }

    private func sleepWindowText(_ sleep: SleepData, start: Date, end: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Sleep window", bundle: LanguageManager.appBundle))
                .font(.system(size: dt13, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(verbatim: "\(formatTime(start)) – \(formatTime(end))")
                .font(.system(size: dt15, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: sleep.totalSleepFormatted)
                .font(.system(size: dt13))
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private func formatTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = LanguageManager.appLocale
        f.timeStyle = .short
        return f.string(from: d)
    }

    // MARK: - Hypnogram

    @ViewBuilder
    private var hypnogramCard: some View {
        ChartCard(title: String(localized: "Hypnogram", bundle: LanguageManager.appBundle), aspectRatio: 16.0 / 7.0) {
            if let sleep = sleepData, !sleep.stageIntervals.isEmpty {
                hypnogramChart(intervals: sleep.stageIntervals)
            } else {
                EmptyState(
                    glyph: "bed.double",
                    headline: String(localized: "No stage data", bundle: LanguageManager.appBundle),
                    message: String(localized: "Sleep stages need an Apple Watch overnight, or HRV-based classification from the strap.", bundle: LanguageManager.appBundle)
                )
            }
        }
    }

    /// Interactive scrubber. Drag across the
    /// hypnogram and a value pill appears showing the time + stage at
    /// the cursor. Reuses the same `chartXSelection(value:)` pattern
    /// the recovery + HRV charts use, so the gesture model is
    /// consistent across the app.
    private func hypnogramChart(intervals: [HealthKitManager.SleepStageInterval]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                stageBarMarks(intervals: intervals)
                hypnogramScrubMarks(intervals: intervals)
            }
            .chartXSelection(value: $hypnogramScrubbedAt)
            .chartYScale(domain: 0...4)
            .chartYAxis { hypnogramStageAxis }
            .chartXAxis { hypnogramTimeAxis }
            hypnogramScrubPill(intervals: intervals)
        }
    }

    /// Hour ticks. Without this the default axis printed the DATE on a chart
    /// that spans one night — "Sep 2 a…", "Sep 3 a…".
    private var hypnogramTimeAxis: some AxisContent {
        AxisMarks(values: .stride(by: .hour)) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.hour())
        }
    }

    /// Four stage rows, labelled by name rather than the numeric position the
    /// chart actually plots against.
    private var hypnogramStageAxis: some AxisContent {
        AxisMarks(position: .leading, values: [0, 1, 2, 3]) { v in
            AxisValueLabel { hypnogramStageLabel(v.as(Int.self)) }
        }
    }

    @ViewBuilder
    private func hypnogramStageLabel(_ numeric: Int?) -> some View {
        if let numeric { Text(verbatim: stageLabel(numeric: numeric)) }
    }

    private func stageBarMarks(intervals: [HealthKitManager.SleepStageInterval]) -> some ChartContent {
        ForEach(intervals) { interval in
            BarMark(
                xStart: .value("Start", interval.start),
                xEnd: .value("End", interval.end),
                y: .value("Stage", stageNumeric(interval.stage)),
                height: 12
            )
            .foregroundStyle(stageColor(interval.stage))
        }
    }

    @ChartContentBuilder
    private func hypnogramScrubMarks(intervals: [HealthKitManager.SleepStageInterval]) -> some ChartContent {
        if let scrubbed = hypnogramScrubbedAt, let interval = stageAt(scrubbed, in: intervals) {
            RuleMark(x: .value("Scrubbed", scrubbed))
                .foregroundStyle(AppTheme.textPrimary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            PointMark(
                x: .value("Date", scrubbed),
                y: .value("Stage", stageNumeric(interval.stage))
            )
            .symbolSize(80)
            .foregroundStyle(stageColor(interval.stage))
        }
    }

    @ViewBuilder
    private func hypnogramScrubPill(intervals: [HealthKitManager.SleepStageInterval]) -> some View {
        if let scrubbed = hypnogramScrubbedAt, let interval = stageAt(scrubbed, in: intervals) {
            let timeFmt: Date.FormatStyle = .dateTime.hour().minute()
            HStack(spacing: 8) {
                Circle()
                    .fill(stageColor(interval.stage))
                    .frame(width: 8, height: 8)
                Text(verbatim: scrubbed.formatted(timeFmt))
                    .font(.system(size: dt13, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(verbatim: stageLabel(numeric: stageNumericInt(interval.stage)))
                    .font(.system(size: dt13, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(AppTheme.cardBackground))
        }
    }

    /// Find the stage interval covering `date` (or nil if the cursor
    /// landed in a gap). Linear scan — N is O(stage transitions),
    /// typically 50–200, well under the per-frame budget.
    private func stageAt(_ date: Date, in intervals: [HealthKitManager.SleepStageInterval]) -> HealthKitManager.SleepStageInterval? {
        intervals.first { $0.start <= date && date <= $0.end }
    }

    private func stageNumericInt(_ stage: HealthKitManager.SleepStage) -> Int {
        Int(stageNumeric(stage))
    }

    private func stageNumeric(_ stage: HealthKitManager.SleepStage) -> Double {
        switch stage {
        case .awake: 3
        case .rem: 2
        case .core: 1
        case .deep: 0
        case .unspecified: 1
        }
    }

    private func stageLabel(numeric: Int) -> String {
        switch numeric {
        case 0: String(localized: "Deep", bundle: LanguageManager.appBundle)
        case 1: String(localized: "Light", bundle: LanguageManager.appBundle)
        case 2: String(localized: "REM", bundle: LanguageManager.appBundle)
        case 3: String(localized: "Awake", bundle: LanguageManager.appBundle)
        default: ""
        }
    }

    private func stageColor(_ stage: HealthKitManager.SleepStage) -> Color {
        switch stage {
        case .deep: AppTheme.primaryDark
        case .core: AppTheme.primary
        case .rem: AppTheme.wongCaution
        case .awake: AppTheme.wongAttention.opacity(0.7)
        case .unspecified: AppTheme.textTertiary
        }
    }
}
