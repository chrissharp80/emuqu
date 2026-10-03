import Charts
import SwiftUI

/// Load & Trajectory (Surface 2). Forward-looking
/// training arc. TRIMP-based. Calm planner voice. Never red anywhere.
///
/// Entry points:
///   1. Tap Load chip on Dashboard → push here
///   2. Fitness tab → "Trajectory" link near top → push here
///
/// It is **not** a top-level tab. Most users will visit weekly, not daily.
///
/// Layout (top to bottom):
///   1. NavigationHeader
///   2. Verdict line + 1-sentence narrative
///   3. Fitness/Fatigue/Form chart (CTL line, ATL line, TSB area)
///   4. Three stat cards: TRIMP / CTL / TSB
///   5. Ramp rate row
///   6. Monotony flag (only when triggered)
///   7. Recent workouts list
///   8. Modes section (Comeback / Peaking / Intentional overreach)
///
/// Verdict mapping uses TrajectoryVerdict / FormDescriptor / RampBand
/// data models — never red, never "danger zone" / "advisory zone."
struct LoadTrajectoryView: View {
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
    @ScaledMetric(relativeTo: .caption2) private var dt10: CGFloat = 10
    @ScaledMetric(relativeTo: .caption2) private var dt11: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var dt12: CGFloat = 12
    @ScaledMetric(relativeTo: .footnote) private var dt13: CGFloat = 13
    @ScaledMetric(relativeTo: .footnote) private var dt14: CGFloat = 14
    @ScaledMetric(relativeTo: .subheadline) private var dt15: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var dt18: CGFloat = 18
    @ScaledMetric(relativeTo: .title2) private var dt22: CGFloat = 22

    /// Per-day fitness/fatigue/form sample for the chart.
    struct DailySample: Identifiable {
        let id: Date
        let date: Date
        let ctl: Double  // chronic — fitness
        let atl: Double  // acute — fatigue
        let tsb: Double  // CTL - ATL — form
        let trimp: Double  // raw daily training load (or 0 for rest)
    }

    /// Recent-workouts row entry — sport icon + duration + TRIMP + date.
    /// A row opens the workout only when `onWorkoutTap` is set.
    struct RecentWorkout: Identifiable {
        let id: UUID
        let sportSymbolName: String
        let sportLabel: String
        let date: Date
        let durationMinutes: Int
        let trimp: Double?
        /// Source of `trimp` so the row labels it correctly ("LOAD" for
        /// power/HR/METs TSS, "TRIMP" only for the Banister fallback).
        let loadSource: WorkoutMetadata.TrainingLoadSource?
    }

    let samples: [DailySample]
    let weeklyTrimp: Double
    let weeklyTrimpDelta: Double
    let rampRate: Double  // TSS/d/wk
    let comebackActive: Bool
    let peakingDetected: Bool
    let overreachActive: Bool
    let monotonyFlagged: Bool
    let recentWorkouts: [RecentWorkout]
    let onComebackTap: () -> Void
    let onPeakingTap: () -> Void
    let onOverreachTap: () -> Void
    var onWorkoutTap: ((UUID) -> Void)?
    /// Long-press a chart point → "What was happening"
    /// sheet showing workouts that contributed on that day. Loader resolves
    /// the date to the matching workouts from the archive.
    var onChartLongPress: ((Date) -> Void)?
    /// The Peaking setting itself, shown separately from whether a taper is
    /// currently detected.
    var peakingDetectionEnabled = true

    /// Modes whose switch-on waits for the user to confirm.
    enum ConfirmableMode: Identifiable {
        case comeback, overreach
        var id: Self { self }
    }

    @State private var scrubbedSample: DailySample?
    @State private var pendingMode: ConfirmableMode?

    private var current: DailySample? { samples.last }

    /// Routes through the canonical helper so the dashboard chip and this full
    /// surface can never disagree.
    ///
    /// The CTL passed in is today's continuous projection (`current`); the
    /// week-ago CTL (`samples[count - 8]`) is only the fallback the verdict uses
    /// when it has no ramp rate. The verdict's direction comes from `rampRate`,
    /// the same regression slope the ramp-rate card shows.
    ///
    /// `makeSamples` overrides today's bucket with the continuous projection, so
    /// today's TRIMP of 0 does not drag the CTL down.
    private var verdict: TrajectoryVerdict {
        let weekAgo: Double? = samples.count >= 8
            ? samples[samples.count - 8].ctl
            : nil
        return TrajectoryVerdict.compute(.init(
            currentCTL: current?.ctl ?? 0,
            ctlOneWeekAgo: weekAgo,
            sampleCount: samples.count,
            comebackActive: comebackActive,
            overreachActive: overreachActive,
            peakingDetected: peakingDetected,
            rampRate: rampRate,
            currentTSB: current?.tsb
        ))
    }

    private var form: FormDescriptor? {
        current.map { FormDescriptor(tsb: $0.tsb) }
    }

    private var rampBand: RampBand { RampBand(tssPerDayPerWeek: rampRate) }

    var body: some View {
        ScrollView {
            trajectoryStack
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(Text(String(localized: "Load & Trajectory", bundle: LanguageManager.appBundle)))
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(
            pendingMode.map(confirmTitle) ?? "",
            isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }),
            titleVisibility: .visible,
            presenting: pendingMode
        ) { mode in
            Button(String(localized: "Turn On", bundle: LanguageManager.appBundle)) { confirm(mode) }
            Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
        } message: { mode in
            Text(confirmMessage(mode))
        }
    }

    private var trajectoryStack: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !hasAnyLoad {
                noTrainingDataState
            } else {
                trajectoryCards
            }
            modesSection
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    /// The loader fills every day of the window, rest days at zero, so an
    /// account with no workouts still had samples and was told "Maintaining —
    /// you're holding fitness" over a chart of zeros.
    private var hasAnyLoad: Bool {
        samples.contains { $0.trimp > 0 || $0.ctl > 0 || $0.atl > 0 }
    }

    @ViewBuilder
    private var noTrainingDataState: some View {
        EmptyState(
            glyph: "chart.bar.xaxis",
            headline: String(localized: "No training data yet", bundle: LanguageManager.appBundle),
            message: String(localized: "Load & Trajectory needs at least one workout from Apple Health. Once your first workout is logged the curves and TRIMP/CTL/TSB stats appear here.", bundle: LanguageManager.appBundle)
        )
    }

    @ViewBuilder
    private var trajectoryCards: some View {
        verdictHeader
        fitnessChart
        statTriplet
        rampRow
        if monotonyFlagged { monotonyCard }
        if !recentWorkouts.isEmpty { recentWorkoutsSection }
    }

    // MARK: - Verdict header

    private var verdictHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: verdict.localizedChipLabel)
                .font(.system(size: dt22, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: verdict.localizedNarrative)
                .font(.system(size: dt15))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Fitness chart

    private var fitnessChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            chartLegend
            loadChart
        }
    }

    private var chartLegend: some View {
        HStack(spacing: 12) {
            legendDot(color: AppTheme.wongGood, label: String(localized: "CTL — fitness", bundle: LanguageManager.appBundle))
            legendDot(color: AppTheme.wongCaution, label: String(localized: "ATL — fatigue", bundle: LanguageManager.appBundle))
            legendDot(color: AppTheme.wongOptimal, label: String(localized: "TSB — form", bundle: LanguageManager.appBundle))
        }
        .font(.system(size: dt11))
        .foregroundStyle(AppTheme.textSecondary)
    }

    private var loadChart: some View {
        trajectoryChart
            // 240 pt, not 200: ATL and CTL need visible vertical separation when they
            // are numerically close, which is most days. At 200 pt a 4-point delta
            // between ATL=28 and CTL=24 on a 0–50 Y range was ~16 pt — inside the
            // stroke width itself.
            .frame(height: 240)
            .chartOverlay { proxy in longPressCapture(proxy) }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(AppTheme.cardBackground)
            )
            .overlay(alignment: .topTrailing) { currentValueChips }
    }

    @ViewBuilder
    private var trajectoryChart: some View {
        Chart(samples) { sample in
            tsbArea(sample)
            atlLine(sample)
            ctlLine(sample)
        }
        .chartForegroundStyleScale([
            "CTL — fitness": AppTheme.wongGood,
            "ATL — fatigue": AppTheme.wongCaution
        ])
        .chartYAxis { AxisMarks(position: .leading) }
        .accessibilityChartDescriptor(
            AudioGraphDescriptor.line(
                title: String(localized: "Fitness, fatigue, form", bundle: LanguageManager.appBundle),
                xLabel: String(localized: "Date", bundle: LanguageManager.appBundle),
                yLabel: String(localized: "CTL (fitness)", bundle: LanguageManager.appBundle),
                points: samples.map { (date: $0.date, value: $0.ctl) }
            )
        )
    }

    /// TSB area shaded green where positive, neutral grey
    /// where slightly negative, NEVER red anywhere.
    private func tsbArea(_ sample: DailySample) -> some ChartContent {
        AreaMark(
            x: .value("Date", sample.date),
            yStart: .value("Zero", 0),
            yEnd: .value("TSB", sample.tsb)
        )
        .foregroundStyle(
            sample.tsb >= 0
                ? AppTheme.wongOptimal.opacity(0.18)   // green when positive
                : AppTheme.textTertiary.opacity(0.12) // neutral grey when negative
        )
    }

    /// ATL renders FIRST (drawn under CTL) so on overlap the
    /// solid CTL line dominates for the "where is fitness today" reading. The
    /// ATL line is solid amber at a higher stroke weight so it stays visible
    /// even where it tracks CTL exactly; a dashed amber disappears
    /// into the solid blue on rest days, where ATL ≈ CTL.
    private func atlLine(_ sample: DailySample) -> some ChartContent {
        LineMark(
            x: .value("Date", sample.date),
            y: .value("ATL", sample.atl),
            series: .value("Series", "ATL")
        )
        .foregroundStyle(AppTheme.wongCaution)
        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        .interpolationMethod(.monotone)
    }

    private func ctlLine(_ sample: DailySample) -> some ChartContent {
        LineMark(
            x: .value("Date", sample.date),
            y: .value("CTL", sample.ctl),
            series: .value("Series", "CTL")
        )
        .foregroundStyle(AppTheme.wongGood)
        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        .interpolationMethod(.monotone)
    }

    /// Current-value chips at the right edge of the chart. Even
    /// when the ATL line is occluded by CTL its number stays visible here.
    /// Solves the "I see a key for ATL but cannot find the data" complaint at
    /// source: the data is labelled, not just plotted.
    @ViewBuilder
    private var currentValueChips: some View {
        if let last = samples.last {
            VStack(alignment: .trailing, spacing: 4) {
                valueChip(label: "CTL", value: last.ctl, color: AppTheme.wongGood)
                valueChip(label: "ATL", value: last.atl, color: AppTheme.wongCaution)
            }
            .padding(.top, 24) // clear the legend row
            .padding(.trailing, 8)
            .allowsHitTesting(false)
        }
    }

    /// Long-press, THEN a zero-distance drag, so the touch location can be
    /// read (a bare `.onLongPressGesture` exposes none). The x-coord maps
    /// through the chart proxy to a date and snaps to the nearest sample, so
    /// long-pressing a historical point opens THAT day rather than
    /// `samples.last` (confidently-wrong data).
    @ViewBuilder
    private func longPressCapture(_ proxy: ChartProxy) -> some View {
        if onChartLongPress != nil {
            longPressSurface(proxy)
        }
    }

    private func longPressSurface(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            longPressTarget(proxy, geo: geo)
        }
    }

    private func longPressTarget(_ proxy: ChartProxy, geo: GeometryProxy) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.4)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onEnded { value in
                        guard case let .second(true, drag?) = value else { return }
                        onChartLongPress?(resolveLongPressDate(drag.location, proxy: proxy, geo: geo))
                    }
            )
    }

    /// Map a long-press location inside the chart to the nearest sample's
    /// date. Falls back to the most recent sample when the proxy can't
    /// resolve the point (press outside the plot area, or no date scale).
    private func resolveLongPressDate(_ location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Date {
        guard let plotAnchor = proxy.plotFrame else { return samples.last?.date ?? Date() }
        let plotOrigin = geo[plotAnchor].origin
        let relativeX = location.x - plotOrigin.x
        guard let pressed: Date = proxy.value(atX: relativeX),
              let nearest = samples.min(by: {
                  abs($0.date.timeIntervalSince(pressed)) < abs($1.date.timeIntervalSince(pressed))
              })
        else {
            return samples.last?.date ?? Date()
        }
        return nearest.date
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(verbatim: label)
        }
    }

    /// Right-edge chip showing the most recent CTL / ATL
    /// numerical value. Renders even when the two lines overlap so the
    /// user always sees both numbers, not just the colour they happen
    /// to be looking at.
    private func valueChip(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(verbatim: "\(label) \(String(format: "%.1f", locale: LanguageManager.appLocale, value))")
                .font(.system(size: dt11, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(AppTheme.cardBackground.opacity(0.9))
        )
        .overlay(
            Capsule().stroke(color.opacity(0.4), lineWidth: 0.5)
        )
    }

    // MARK: - Stat quad
    //
    // A 4-card row (TRIMP, ATL, CTL, TSB), not a triplet without ATL. User
    // report: "ATL is a metric the app doesn't seem to surface.
    // There's a key for it in the load and trajectory but i see zero
    // sign of it on the graph or in the displayed data." The chart
    // legend mentions ATL but the line overlaps CTL when fatigue is
    // low (the only condition under which most users see it), so a
    // numeric callout is needed.
    // The ATL card is keyed off the chart's own samples.last so the
    // displayed number tracks the chart series exactly.

    private var loadStatCard: some View {
        statCard(
            title: Self.loadLabel,
            value: String(Int(weeklyTrimp.rounded())),
            subline: weeklyTrimpDeltaSubline
        )
    }

    /// The first card sums the per-day `effectiveLoad`
    /// (power/HR TSS-preferred), the same metric the workout LOAD tile shows, so
    /// it is labelled "LOAD" and not "TRIMP" (which is the Banister-only scale).
    /// Reserving "TRIMP" for the Banister value keeps one workout from reading
    /// as two different numbers under one label.
    private var statTriplet: some View {
        HStack(spacing: 8) {
            loadStatCard
            statCard(
                title: "CTL",
                value: current.map { String(format: "%.1f", locale: LanguageManager.appLocale, $0.ctl) } ?? "—",
                subline: rampBand.localizedWord
            )
            statCard(
                title: "ATL",
                value: current.map { String(format: "%.1f", locale: LanguageManager.appLocale, $0.atl) } ?? "—",
                subline: atlSubline
            )
            statCard(
                title: "TSB",
                value: current.map { String(format: "%+.1f", locale: LanguageManager.appLocale, $0.tsb) } ?? "—",
                subline: form?.localizedWord ?? "—"
            )
        }
    }

    /// Short subline for the ATL card — describes the fatigue load
    /// relative to chronic fitness so the number isn't context-free.
    /// "above CTL" / "near CTL" / "below CTL" maps directly to TSB
    /// sign without re-deriving it.
    private var atlSubline: String {
        guard let s = current else { return "—" }
        let delta = s.atl - s.ctl
        if abs(delta) < 1 { return String(localized: "near CTL", bundle: LanguageManager.appBundle) }
        return delta > 0
            ? String(localized: "above CTL", bundle: LanguageManager.appBundle)
            : String(localized: "below CTL", bundle: LanguageManager.appBundle)
    }

    private var weeklyTrimpDeltaSubline: String {
        let signed = weeklyTrimpDelta >= 0 ? "+\(Int(weeklyTrimpDelta.rounded()))" : "\(Int(weeklyTrimpDelta.rounded()))"
        return String(format: NSLocalizedString("%@ vs last", bundle: LanguageManager.appBundle, comment: ""), signed)
    }

    private func statCard(title: String, value: String, subline: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(.system(size: dt11, weight: .semibold))
                .foregroundStyle(AppTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(verbatim: value)
                .font(.system(size: dt22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
            statCardSubline(subline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.cardBackground)
        )
    }

    /// Two lines max, shrinking a touch rather than truncating so a long
    /// locale-formatted subline still reads.
    private func statCardSubline(_ subline: String) -> some View {
        Text(verbatim: subline)
            .font(.system(size: dt12))
            .foregroundStyle(AppTheme.textSecondary)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Ramp row

    @ViewBuilder
    private var rampRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: dt18, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 28, height: 28)
            rampRateSection
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.cardBackground)
        )
    }

    private var rampRateSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Ramp rate", bundle: LanguageManager.appBundle))
                .font(.system(size: dt13, weight: .semibold))
                .foregroundStyle(AppTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.4)
            Text(verbatim: rampSentence)
                .font(.system(size: dt14))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rampSentence: String {
        // Neutral "Ramp: %@" prefix — the sign lives in the number and the
        // verb now lives in rampBand.localizedSentence, which branches on sign. The
        // old "You're building at %@" hard-coded "building" even for a
        // NEGATIVE ramp ("building at -0.5 … building gradually").
        let pace = String(format: "%+.1f", locale: LanguageManager.appLocale, rampRate)
        return String(format: NSLocalizedString("Ramp: %@ TSS/day/week. %@", bundle: LanguageManager.appBundle, comment: ""), pace, rampBand.localizedSentence)
    }

    // MARK: - Monotony card

    @ViewBuilder
    private var monotonyCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform.path")
                .font(.system(size: dt18, weight: .semibold))
                .foregroundStyle(AppTheme.wongCaution)
                .frame(width: 28, height: 28)
            // Localizable prose, not Text(verbatim:).
            Text(String(localized: "Your training has been unusually similar day-to-day this week. Consider varying intensity.", bundle: LanguageManager.appBundle))
                .font(.system(size: dt14))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(AppTheme.wongCaution.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Recent workouts list

    private var recentWorkoutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Recent workouts", bundle: LanguageManager.appBundle))
                .font(.system(size: dt13, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            recentWorkoutRows
        }
    }

    private var recentWorkoutRows: some View {
        VStack(spacing: 6) {
            ForEach(recentWorkouts.prefix(8)) { row in
                recentWorkoutRow(row)
            }
        }
    }

    private func recentWorkoutRow(_ row: RecentWorkout) -> some View {
        Button {
            onWorkoutTap?(row.id)
        } label: {
            HStack(spacing: 12) {
                sportBadge(row)
                workoutRowCaption(row)
                Spacer()
                workoutRowMetrics(row)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(AppTheme.cardBackground)
            )
        }
        .buttonStyle(.plain)
        .disabled(onWorkoutTap == nil)
    }

    private func sportBadge(_ row: RecentWorkout) -> some View {
        Image(systemName: row.sportSymbolName)
            .font(.system(size: dt15, weight: .semibold))
            .foregroundStyle(AppTheme.primary)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(AppTheme.primary.opacity(0.12))
            )
    }

    private func workoutRowCaption(_ row: RecentWorkout) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: row.sportLabel)
                .font(.system(size: dt14, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: relativeWorkoutDate(row.date))
                .font(.system(size: dt11))
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    /// Label the load by source (LOAD for power/HR/METs
    /// TSS, TRIMP only for the Banister fallback) so this row agrees with the
    /// workout summary's LOAD tile instead of calling a power TSS "TRIMP".
    /// Rounded to match the summary tile.
    private func workoutRowMetrics(_ row: RecentWorkout) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            // Locale-aware "min" abbreviation.
            Text(verbatim: LocalizedDuration.minutes(row.durationMinutes))
                .font(.system(size: dt13, weight: .medium).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
            if let trimp = row.trimp {
                Text(verbatim: "\(Int(trimp.rounded())) \(loadUnitLabel(row.loadSource))")
                    .font(.system(size: dt10).monospacedDigit())
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    private static var loadLabel: String {
        String(localized: "LOAD", bundle: LanguageManager.appBundle)
    }

    /// "TRIMP" (an acronym, not translated) for the Banister scale, the
    /// localized "LOAD" for every TSS-based source.
    private func loadUnitLabel(_ source: WorkoutMetadata.TrainingLoadSource?) -> String {
        switch source {
        case .banister, .routeHistory: "TRIMP"
        case .power, .hr, .mets, nil: Self.loadLabel
        }
    }

    private func relativeWorkoutDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LanguageManager.appLocale
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Modes section

extension LoadTrajectoryView {
    private var modesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Modes", bundle: LanguageManager.appBundle))
                .font(.system(size: dt13, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            comebackModeCard
            peakingModeCard
            overreachModeCard
        }
    }

    private var overreachModeCard: some View {
        ModeToggleCard(
            icon: "scope",
            title: String(localized: "Intentional overreach", bundle: LanguageManager.appBundle),
            status: overreachActive ? .on : .off,
            footerCopy: String(localized: "Use this when you're deliberately doing a hard training block (camp, race build, peak overload week). Suppresses 'rapid increase' / 'high load' messaging. Metrics still display.", bundle: LanguageManager.appBundle),
            onTap: { overreachActive ? onOverreachTap() : (pendingMode = .overreach) }
        )
    }

    private var peakingModeCard: some View {
        ModeToggleCard(
            icon: "triangle.fill",
            title: String(localized: "Peaking detection", bundle: LanguageManager.appBundle),
            status: peakingStatus,
            footerCopy: String(localized: "When ATL drops below CTL by 10% for 4+ days, Emuqu recognises you're tapering and labels it 'Peaking' on the Trajectory screen. Suppresses 'detraining' messaging.", bundle: LanguageManager.appBundle),
            onTap: onPeakingTap
        )
    }

    private var comebackModeCard: some View {
        ModeToggleCard(
            icon: "arrow.uturn.up.circle.fill",
            title: String(localized: "Comeback mode", bundle: LanguageManager.appBundle),
            status: comebackActive ? .on : .off,
            footerCopy: String(localized: "Use this when returning from illness, injury, or a long break. For 21 days, your recovery score weights HRV more heavily and ignores noisy vitals so a slow autonomic comeback isn't double-penalised.", bundle: LanguageManager.appBundle),
            onTap: { comebackActive ? onComebackTap() : (pendingMode = .comeback) }
        )
    }

    /// "Auto" while a taper is detected, otherwise the setting itself.
    private var peakingStatus: ModeToggleCard.ModeStatus {
        if peakingDetected { return .autoDetected }
        return peakingDetectionEnabled ? .on : .off
    }

    // MARK: - Mode confirmation

    private func confirmTitle(_ mode: ConfirmableMode) -> String {
        switch mode {
        case .comeback: String(localized: "Turn on Comeback mode?", bundle: LanguageManager.appBundle)
        case .overreach: String(localized: "Turn on Intentional overreach?", bundle: LanguageManager.appBundle)
        }
    }

    private func confirmMessage(_ mode: ConfirmableMode) -> String {
        switch mode {
        case .comeback:
            String(localized: "For the next 21 days your recovery score weights HRV more heavily and ignores noisy vitals.", bundle: LanguageManager.appBundle)
        case .overreach:
            String(localized: "Rapid-increase and high-load warnings will be hidden until you turn this off.", bundle: LanguageManager.appBundle)
        }
    }

    private func confirm(_ mode: ConfirmableMode) {
        switch mode {
        case .comeback: onComebackTap()
        case .overreach: onOverreachTap()
        }
    }
}
