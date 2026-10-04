import SwiftUI

// Stage breakdown, score breakdown and insights, split out of
// `SleepDetailV2View.swift`. The hero, quick stats, sleep window and
// hypnogram stay behind — the top half of the screen.

extension SleepDetailV2View {
    // MARK: - Stage breakdown

    @ViewBuilder
    var stageBreakdownSection: some View {
        if let sleep = sleepData, sleep.nightSleepMinutes > 0 {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading(String(localized: "Stage breakdown", bundle: LanguageManager.appBundle))
                let totalMin = sleep.nightSleepMinutes
                stagePills(sleep, totalMin: totalMin)
                // Tap any stage pill expands an
                // explanation card. Persists until tapped again or
                // a different pill is tapped.
                stageExplanationCard
            }
            .animation(.easeInOut(duration: 0.2), value: expandedStage)
        }
    }

    @ViewBuilder
    private var stageExplanationCard: some View {
        if let key = expandedStage {
            stageExplanation(for: key)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func stagePills(_ sleep: SleepData, totalMin: Int) -> some View {
        HStack(spacing: 8) {
            if let deep = sleep.deepSleepMinutes {
                stagePill(kind: .deep, minutes: deep, totalMin: totalMin, color: AppTheme.primaryDark)
            }
            if let rem = sleep.remSleepMinutes {
                stagePill(kind: .rem, minutes: rem, totalMin: totalMin, color: AppTheme.wongCaution)
            }
            let lightMin = max(0, totalMin - (sleep.deepSleepMinutes ?? 0) - (sleep.remSleepMinutes ?? 0))
            stagePill(kind: .light, minutes: lightMin, totalMin: totalMin, color: AppTheme.primary)
            if sleep.measuredSleepEfficiency != nil {
                stagePill(kind: .awake, minutes: sleep.awakeMinutes, totalMin: sleep.inBedMinutes, color: AppTheme.wongAttention.opacity(0.7))
            }
        }
    }

    /// Tappable stage pill. Wrapped in a Button so
    /// the entire pill area is hit-testable, with a `withAnimation`
    /// toggle on `expandedStage`. Tap-again collapses.
    func stagePill(kind: SleepStageKind, minutes: Int, totalMin: Int, color: Color) -> some View {
        let label = kind.displayLabel
        let isExpanded = expandedStage == kind
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedStage = isExpanded ? nil : kind
            }
        } label: {
            stagePillLabel(kind: kind, minutes: minutes, totalMin: totalMin, color: color, isExpanded: isExpanded)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(String(localized: "Double tap to learn what \(label.lowercased()) sleep is and what's typical.", bundle: LanguageManager.appBundle)))
    }

    private func stagePillLabel(kind: SleepStageKind, minutes: Int, totalMin: Int, color: Color, isExpanded: Bool) -> some View {
        let pct = totalMin > 0 ? Double(minutes) / Double(totalMin) * 100 : 0
        return VStack(spacing: 4) {
            Text(verbatim: kind.displayLabel)
                .font(.system(size: dt11, weight: .medium))
                .foregroundStyle(Self.stageLabelColor(kind))
                .textCase(.uppercase)
                .tracking(0.5)
            Text(verbatim: formatMinutes(minutes))
                .font(.system(size: dt14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: String(format: "%.0f%%", locale: LanguageManager.appLocale, pct))
                .font(.system(size: dt10))
                .foregroundStyle(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .modifier(StagePillChrome(color: color, isExpanded: isExpanded))
    }

    /// The stage name as text: amber and orange-red fills take their
    /// darkened text variants, which clear 4.5:1 on the light theme.
    private static func stageLabelColor(_ kind: SleepStageKind) -> Color {
        switch kind {
        case .deep: AppTheme.primaryDark
        case .rem: AppTheme.wongCautionText
        case .light: AppTheme.primaryText
        case .awake: AppTheme.wongAttentionText
        }
    }

    /// Tint deepens and a hairline border appears while the pill is expanded.
    private struct StagePillChrome: ViewModifier {
        let color: Color
        let isExpanded: Bool

        func body(content: Content) -> some View {
            content
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(color.opacity(isExpanded ? 0.20 : 0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isExpanded ? color.opacity(0.6) : Color.clear, lineWidth: 1.2)
                )
        }
    }

    func stageExplanation(for stage: SleepStageKind) -> some View {
        Text(verbatim: Self.stageExplanationText(stage))
            .font(.system(size: dt13))
            .foregroundStyle(AppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(AppTheme.cardBackground)
            )
    }

    private static func stageExplanationText(_ stage: SleepStageKind) -> String {
        switch stage {
        case .deep:
            return String(localized: "Deep sleep (slow-wave) is when your body repairs muscle, consolidates declarative memory, and clears metabolic waste. Target: 13–23% of total sleep. The first deep block is usually within 90 minutes of falling asleep.", bundle: LanguageManager.appBundle)
        case .rem:
            return String(
                localized: "REM sleep is when most dreaming happens and where emotional / procedural memory is processed. Target: 20–25% of total sleep. REM blocks lengthen across the night — short or fragmented REM often shows up after alcohol or late-night training.",
                bundle: LanguageManager.appBundle
            )
        case .light:
            return String(localized: "Light sleep (N1 + N2) makes up the majority of a healthy night and is the bridge between awake, deep, and REM. Target: 50–60%. Too much usually means deep + REM are short, not that light is the problem.", bundle: LanguageManager.appBundle)
        case .awake:
            return String(localized: "Time spent awake while in bed. Brief awakenings are normal (4–6 per night). Sustained awakenings >5 min, especially in the second half, are what fragment recovery.", bundle: LanguageManager.appBundle)
        }
    }

    // MARK: - Score breakdown

    @ViewBuilder
    var scoreBreakdownSection: some View {
        if let sleep = sleepData, sleep.nightSleepMinutes > 0 {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading(String(localized: "Score breakdown", bundle: LanguageManager.appBundle))
                let breakdowns = computeSleepBreakdowns(sleep: sleep)
                scoreBreakdownRows(breakdowns)
                // The rows mirror `SleepScienceAnalyzer.computeEnhancedScore`, the
                // formula behind the Sleep score shown above, with its weights.
                Text(String(localized: "Each part's share of the Sleep score is on the right. A night well short of your sleep target is capped lower, however well the rest scored. This is separate from how Sleep feeds your Recovery Score.", bundle: LanguageManager.appBundle))
                    .font(.system(size: dt12))
                    .foregroundStyle(AppTheme.textTertiary)
                    .padding(.top, 4)
            }
        }
    }

    private func scoreBreakdownRows(_ breakdowns: [SleepBreakdownEntry]) -> some View {
        VStack(spacing: 8) {
            ForEach(breakdowns, id: \.label) { entry in
                sleepBreakdownRow(label: entry.label, score: entry.score, weight: entry.weight, ok: entry.ok)
            }
        }
    }

    struct SleepBreakdownEntry {
        let label: String
        let score: Double
        let weight: Double
        let ok: Bool
    }

    /// Per-part scores (0–100) of the enhanced Sleep score, weighted by the
    /// analyzer's own point table so the rows can't drift from the formula.
    func computeSleepBreakdowns(sleep: SleepData) -> [SleepBreakdownEntry] {
        guard let analysis = SleepScienceAnalyzer.analyze(
            sleepData: sleep, userAge: userAge, typicalSleepHours: typicalSleepHours
        ) else { return [] }
        typealias Wts = SleepScienceAnalyzer.EnhancedScoreWeights
        let bundle = LanguageManager.appBundle
        let duration = breakdownDurationScore(sleep)
        let efficiency = breakdownEfficiencyScore(sleep, norms: analysis.ageNorms)
        let stages = breakdownStagesScore(sleep, norms: analysis.ageNorms)
        let continuity = max(0, 100 - analysis.fragmentationIndex)
        let cycles = breakdownCyclesScore(sleep, cycleCount: analysis.cycleCount)
        let architecture = analysis.architecture.architectureScore
        return [
            SleepBreakdownEntry(label: String(localized: "Duration", bundle: bundle), score: duration, weight: Wts.durationPoints / 100, ok: duration >= Wts.durationDebtRatioThreshold * 100),
            SleepBreakdownEntry(label: String(localized: "Efficiency", bundle: bundle), score: efficiency, weight: Wts.efficiencyPoints / 100, ok: efficiency >= 90),
            SleepBreakdownEntry(label: String(localized: "Deep & REM", bundle: bundle), score: stages, weight: Wts.stageHalfPoints * 2 / 100, ok: stages >= 70),
            SleepBreakdownEntry(label: String(localized: "Continuity", bundle: bundle), score: continuity, weight: Wts.fragmentationPoints / 100, ok: continuity >= 70),
            SleepBreakdownEntry(label: String(localized: "Cycles", bundle: bundle), score: cycles, weight: Wts.cyclePoints / 100, ok: cycles >= 70),
            SleepBreakdownEntry(label: String(localized: "Architecture", bundle: bundle), score: architecture, weight: Wts.architecturePoints / 100, ok: architecture >= 70)
        ]
    }

    /// Night plus qualifying nap against the sleep target, as the score uses
    /// it. The formula lets the ratio reach `ratioCap` (1.1), so a long night
    /// reads up to 110 here too.
    private func breakdownDurationScore(_ sleep: SleepData) -> Double {
        typealias Wts = SleepScienceAnalyzer.EnhancedScoreWeights
        let target = max(typicalSleepHours, 1.0) * 60
        return min(Double(sleep.totalSleepIncludingNapMinutes) / target, Wts.ratioCap) * 100
    }

    /// Efficiency against the age-expected value when age is known, capped
    /// at `ratioCap` as in the formula. A night whose wake was not measured
    /// gets the formula's neutral half credit.
    private func breakdownEfficiencyScore(_ sleep: SleepData, norms: SleepScienceAnalyzer.AgeAdjustedNorms?) -> Double {
        typealias Wts = SleepScienceAnalyzer.EnhancedScoreWeights
        guard let efficiency = sleep.measuredSleepEfficiency else { return Wts.unmeasuredEfficiencyRatio * 100 }
        let expected = norms?.expectedEfficiency ?? SleepConstants.goodEfficiency
        return min(efficiency / expected, Wts.ratioCap) * 100
    }

    /// Deep and REM adequacy, half each. A stage the night carried no data
    /// for gets neutral half credit for its half, as in the formula, so a
    /// source that staged deep but not REM is not scored as if REM were absent.
    private func breakdownStagesScore(_ sleep: SleepData, norms: SleepScienceAnalyzer.AgeAdjustedNorms?) -> Double {
        typealias Wts = SleepScienceAnalyzer.EnhancedScoreWeights
        let night = Double(sleep.nightSleepMinutes)
        guard night > 0 else { return 50 }
        let deep = sleep.deepSleepMinutes.map { minutes in
            Self.breakdownStageHalf(minutes: minutes, night: night, targetPct: Wts.populationDeepTargetPct,
                                    norm: norms.map { (inRange: $0.isDeepInRange, deviation: $0.deepDeviation) })
        }
        let rem = sleep.remSleepMinutes.map { minutes in
            Self.breakdownStageHalf(minutes: minutes, night: night, targetPct: Wts.populationREMTargetPct,
                                    norm: norms.map { (inRange: $0.isREMInRange, deviation: $0.remDeviation) })
        }
        return (deep ?? 25) + (rem ?? 25)
    }

    /// One recorded stage's half (0–50). Against age norms only a below-range
    /// share loses points; without norms the share of the night is scored
    /// against the population target.
    private static func breakdownStageHalf(
        minutes: Int, night: Double, targetPct: Double,
        norm: (inRange: Bool, deviation: Double)?
    ) -> Double {
        typealias Wts = SleepScienceAnalyzer.EnhancedScoreWeights
        guard let norm else { return min(50, Double(minutes) / night * 100 / targetPct * 50) }
        guard !norm.inRange, norm.deviation <= 0 else { return 50 }
        return max(0, 50 - abs(norm.deviation) * Wts.deviationPenaltySlope * 5)
    }

    private func breakdownCyclesScore(_ sleep: SleepData, cycleCount: Int) -> Double {
        typealias Wts = SleepScienceAnalyzer.EnhancedScoreWeights
        let hours = Double(sleep.nightSleepMinutes) / 60
        let expected = max(Wts.minimumExpectedCycles, Int(hours / Wts.cycleLengthHours))
        return min(Double(cycleCount) / Double(expected), 1.0) * 100
    }

    func sleepBreakdownRow(label: String, score: Double, weight: Double, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? AppTheme.wongOptimal : AppTheme.wongCaution)
            Text(verbatim: label)
                .font(.system(size: dt14, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Text(verbatim: "\(Int(score.rounded()))")
                .font(.system(size: dt15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: "× \(Int((weight * 100).rounded()))%")
                .font(.system(size: dt12))
                .foregroundStyle(AppTheme.textTertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.cardBackground)
        )
    }

    // MARK: - Insights

    @ViewBuilder
    var sleepInsightsSection: some View {
        if let sleep = sleepData {
            let insights = buildInsights(sleep: sleep)
            insightsCard(insights)
        }
    }

    @ViewBuilder
    private func insightsCard(_ insights: [String]) -> some View {
        if !insights.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading(String(localized: "Sleep insights", bundle: LanguageManager.appBundle))
                insightList(insights)
            }
        }
    }

    private func insightList(_ insights: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            insightRows(insights)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.cardBackground)
        )
    }

    private func insightRows(_ insights: [String]) -> some View {
        ForEach(insights, id: \.self) { insight in
            insightRow(insight)
        }
    }

    private func insightRow(_ insight: String) -> some View {
        InsightBulletRow(text: insight, fontSize: dt14)
    }

    func buildInsights(sleep: SleepData) -> [String] {
        var out: [String] = []
        let target = typicalSleepHours
        let actualHours = Double(sleep.totalSleepIncludingNapMinutes) / 60
        if actualHours < target * 0.85 {
            out.append(String(localized: "Your sleep was significantly shorter than your goal. Try to get to bed earlier tonight to recover.", bundle: LanguageManager.appBundle))
        } else if actualHours > target * 1.1 {
            out.append(String(localized: "You slept more than your usual target — likely catching up on accumulated debt.", bundle: LanguageManager.appBundle))
        }
        if let efficiency = sleep.measuredSleepEfficiency, efficiency >= 95 {
            out.append(String(localized: "Excellent sleep efficiency. You're sleeping well for the time spent in bed.", bundle: LanguageManager.appBundle))
        } else if let efficiency = sleep.measuredSleepEfficiency, efficiency < 80 {
            out.append(String(localized: "Sleep efficiency was low — many awakenings or long time-to-fall-asleep. Worth tracking what's interrupting the night.", bundle: LanguageManager.appBundle))
        }
        if let line = deepShareInsight(sleep) { out.append(line) }
        return Array(out.prefix(3))
    }

    /// The deep-sleep share this screen calls typical, matching the 13–23%
    /// in the deep-stage explanation.
    static var typicalDeepShare: ClosedRange<Double> { 0.13 ... 0.23 }

    /// "Typical" only for a typical share of the night.
    private func deepShareInsight(_ sleep: SleepData) -> String? {
        guard let deep = sleep.deepSleepMinutes, sleep.nightSleepMinutes > 0 else { return nil }
        let share = Double(deep) / Double(sleep.nightSleepMinutes)
        let bundle = LanguageManager.appBundle
        if share > Self.typicalDeepShare.upperBound { return String(localized: "Deep sleep made up more of the night than is typical.", bundle: bundle) }
        if share >= Self.typicalDeepShare.lowerBound { return String(localized: "Deep sleep made up a typical share of the night.", bundle: bundle) }
        return nil
    }

    // MARK: - Recent trends

    @ViewBuilder
    var recentTrendsSection: some View {
        // Reads the cached trend (see `trendNights`)
        // instead of calling `buildTrend()` per body evaluation.
        let trend = trendNights
        if !trend.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading(String(localized: "Recent trends (\(trend.count) nights)", bundle: LanguageManager.appBundle))
                trendStrip(trend)
            }
        }
    }

    private func trendStrip(_ trend: [TrendNight]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            trendBars(trend)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.cardBackground)
        )
    }

    private func trendBars(_ trend: [TrendNight]) -> some View {
        HStack(spacing: 8) {
            trendBarList(trend)
        }
        .padding(.horizontal, 4)
    }

    private func trendBarList(_ trend: [TrendNight]) -> some View {
        ForEach(trend) { night in
            trendBar(night)
        }
    }

    private func trendBar(_ night: TrendNight) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: weekday(night.date))
                .font(.system(size: dt10))
                .foregroundStyle(AppTheme.textTertiary)
            Rectangle()
                .fill(barColor(night.score))
                .frame(width: 18, height: max(8, CGFloat(night.score) * 0.6))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(verbatim: LocalizedDuration.hours(Int((Double(night.minutes) / 60).rounded())))
                .font(.system(size: dt9))
                .foregroundStyle(AppTheme.textTertiary)
        }
        .frame(width: 28)
    }

    struct TrendNight: Identifiable {
        /// Stable identity derived from the night's
        /// timestamp. A `UUID()` re-randomizes on every
        /// rebuild and makes ForEach treat every bar as
        /// removed + inserted. Session start dates are unique per
        /// night, so the date is a stable, meaningful id.
        var id: Date { date }
        let date: Date
        let minutes: Int
        let score: Double
    }

    /// Static with explicit inputs so the `.task` keyed on
    /// `trendInputsKey` can run it on a detached task without capturing
    /// the view.
    nonisolated static func buildTrend(
        recentSessions: [HRVSession],
        typicalSleepHours: Double,
        userAge: Int?
    ) -> [TrendNight] {
        recentSessions
            .compactMap { s -> TrendNight? in
                guard let snap = s.sleepSnapshot, snap.nightSleepMinutes > 0 else { return nil }
                let score = RecoveryScoreCalculator.calculateSleepScore(
                    sleepData: snap,
                    typicalSleepHours: typicalSleepHours,
                    userAge: userAge
                ) ?? 0
                return TrendNight(date: s.startDate, minutes: snap.nightSleepMinutes, score: score)
            }
            .prefix(15)
            .sorted { $0.date < $1.date }
            .map { $0 }
    }

    /// Narrow weekday symbol ("M", "T"…) in the app language.
    func weekday(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = LanguageManager.appLocale
        f.setLocalizedDateFormatFromTemplate("EEEEE")
        return f.string(from: d)
    }

    /// The same `ScoreVerdict` ladder as the hero ring above, so one score
    /// reads the same colour everywhere on this screen.
    func barColor(_ score: Double) -> Color {
        ScoreVerdict(score: score).color
    }

    // MARK: - Sleep structure

    @ViewBuilder
    var sleepStructureCard: some View {
        if let sleep = sleepData, sleep.nightSleepMinutes > 0 {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading(String(localized: "Sleep structure", bundle: LanguageManager.appBundle))
                structureCells(sleep)
            }
        }
    }

    /// Cycles, awakenings and continuity come from the same analysis as the
    /// Score breakdown rows, so each reads the same in both places.
    private func structureCells(_ sleep: SleepData) -> some View {
        let analysis = SleepScienceAnalyzer.analyze(
            sleepData: sleep, userAge: userAge, typicalSleepHours: typicalSleepHours
        )
        return HStack(spacing: 8) {
            structureCell(label: String(localized: "Cycles", bundle: LanguageManager.appBundle), value: cyclesDescriptor(sleep, analysis: analysis))
            structureCell(label: String(localized: "Awakenings", bundle: LanguageManager.appBundle), value: awakeningsDescriptor(analysis))
            structureCell(label: String(localized: "Continuity", bundle: LanguageManager.appBundle), value: continuityDescriptor(analysis))
            structureCell(label: String(localized: "Architecture", bundle: LanguageManager.appBundle), value: architectureDescriptor(sleep))
        }
    }

    /// Complete cycles the analyzer detected in the staged night; a night
    /// without stage data has none to count.
    func cyclesDescriptor(_ sleep: SleepData, analysis: SleepScienceAnalyzer.SleepAnalysis?) -> String {
        let staged = sleep.deepSleepMinutes != nil || sleep.remSleepMinutes != nil
        guard staged, let analysis else { return "—" }
        return "\(analysis.cycleCount)"
    }

    func awakeningsDescriptor(_ analysis: SleepScienceAnalyzer.SleepAnalysis?) -> String {
        guard let awakeCount = analysis?.awakeningCount else { return "—" }
        if awakeCount <= 2 { return String(localized: "Minimal", bundle: LanguageManager.appBundle) }
        if awakeCount <= 5 { return String(localized: "Few", bundle: LanguageManager.appBundle) }
        return String(localized: "Many", bundle: LanguageManager.appBundle)
    }

    /// 100 minus the fragmentation index, the same continuity the Score
    /// breakdown row scores; "Low" is where that row shows its warning.
    func continuityDescriptor(_ analysis: SleepScienceAnalyzer.SleepAnalysis?) -> String {
        guard let analysis else { return "—" }
        let continuity = 100 - analysis.fragmentationIndex
        if continuity >= 85 { return String(localized: "High", bundle: LanguageManager.appBundle) }
        if continuity >= 70 { return String(localized: "Normal", bundle: LanguageManager.appBundle) }
        return String(localized: "Low", bundle: LanguageManager.appBundle)
    }

    func architectureDescriptor(_ sleep: SleepData) -> String {
        guard let deep = sleep.deepSleepMinutes, let rem = sleep.remSleepMinutes,
              sleep.nightSleepMinutes > 0 else { return "—" }
        let deepPct = Double(deep) / Double(sleep.nightSleepMinutes)
        let remPct = Double(rem) / Double(sleep.nightSleepMinutes)
        if deepPct >= Self.typicalDeepShare.lowerBound && remPct >= 0.20 { return String(localized: "Typical", bundle: LanguageManager.appBundle) }
        return String(localized: "Atypical", bundle: LanguageManager.appBundle)
    }

    func structureCell(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: label)
                .font(.system(size: dt11))
                .foregroundStyle(AppTheme.textTertiary)
            Text(verbatim: value)
                .font(.system(size: dt14, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.cardBackground)
        )
    }

    // MARK: - Age-group comparison

    /// Stages the app classifies from heart-beat intervals lack the EEG
    /// ground truth a sleep lab provides, and have not been compared with one.
    /// A user seeing 42% deep deserves to know both that it is outside the
    /// typical range AND that its accuracy is unknown — hence the footnote at
    /// the bottom of this card on nights with HRV-classified stages.
    @ViewBuilder
    var ageGroupCard: some View {
        if let age = userAge, let sleep = sleepData, sleep.nightSleepMinutes > 0 {
            ageGroupStack(age: age, sleep: sleep)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(AppTheme.cardBackground)
                )
        }
    }

    private func ageGroupStack(age: Int, sleep: SleepData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(String(localized: "You vs your age group · age \(age)", bundle: LanguageManager.appBundle))
            ageComparisonRows(sleep, norms: ageNorms(age: age, sleep: sleep))
            Text(String(localized: "Based on Ohayon et al. (2004). The range in brackets is typical for your age group.", bundle: LanguageManager.appBundle))
                .font(.system(size: dt11))
                .foregroundStyle(AppTheme.textTertiary)
            if Self.hasHRVClassifiedStages(sleep) {
                Text(String(localized: "Stages estimated from heart-beat intervals have not been compared with a sleep lab, so their accuracy is unknown.", bundle: LanguageManager.appBundle))
                    .font(.system(size: dt11))
                    .foregroundStyle(AppTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    /// Whether any deep, core or REM stretch was inferred from heart rate
    /// rather than staged by Apple Watch.
    private static func hasHRVClassifiedStages(_ sleep: SleepData) -> Bool {
        sleep.stageIntervals.contains { interval in
            interval.provenance == .hrvDerived && [HealthKitManager.SleepStage.deep, .core, .rem].contains(interval.stage)
        }
    }

    private func ageComparisonRows(_ sleep: SleepData, norms: SleepScienceAnalyzer.AgeAdjustedNorms) -> some View {
        VStack(spacing: 8) {
            ageRow(label: String(localized: "Deep sleep", bundle: LanguageManager.appBundle), value: deepPctText(sleep: sleep), rangeText: rangeText(norms.expectedDeepPercent))
            ageRow(label: String(localized: "REM sleep", bundle: LanguageManager.appBundle), value: remPctText(sleep: sleep), rangeText: rangeText(norms.expectedREMPercent))
            ageRow(label: String(localized: "Efficiency", bundle: LanguageManager.appBundle), value: Self.efficiencyText(sleep), rangeText: "(≥\(Int(norms.expectedEfficiency))%)")
        }
    }

    /// The Ohayon 2004 age norms the Sleep score itself grades against.
    func ageNorms(age: Int, sleep: SleepData) -> SleepScienceAnalyzer.AgeAdjustedNorms {
        let night = Double(max(sleep.nightSleepMinutes, 1))
        return SleepScienceAnalyzer.computeAgeNorms(
            age: age,
            deepPercent: Double(sleep.deepSleepMinutes ?? 0) / night * 100,
            remPercent: Double(sleep.remSleepMinutes ?? 0) / night * 100,
            efficiency: sleep.measuredSleepEfficiency ?? 0
        )
    }

    /// The night's efficiency as a percentage, or "Not measured" when its
    /// wake was not measured (a passive Apple Watch heart-rate estimate).
    static func efficiencyText(_ sleep: SleepData) -> String {
        guard let efficiency = sleep.measuredSleepEfficiency else {
            return String(localized: "Not measured", bundle: LanguageManager.appBundle)
        }
        return String(format: "%.0f%%", locale: LanguageManager.appLocale, efficiency)
    }

    private func rangeText(_ range: ClosedRange<Double>) -> String {
        "(\(Int(range.lowerBound))–\(Int(range.upperBound))%)"
    }

    func deepPctText(sleep: SleepData) -> String {
        guard let d = sleep.deepSleepMinutes, sleep.nightSleepMinutes > 0 else { return "—" }
        return String(format: "%.0f%%", locale: LanguageManager.appLocale, Double(d) / Double(sleep.nightSleepMinutes) * 100)
    }

    func remPctText(sleep: SleepData) -> String {
        guard let r = sleep.remSleepMinutes, sleep.nightSleepMinutes > 0 else { return "—" }
        return String(format: "%.0f%%", locale: LanguageManager.appLocale, Double(r) / Double(sleep.nightSleepMinutes) * 100)
    }

    func ageRow(label: String, value: String, rangeText: String) -> some View {
        HStack {
            Text(verbatim: label)
                .font(.system(size: dt13))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Text(verbatim: value)
                .font(.system(size: dt13, weight: .medium).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: rangeText)
                .font(.system(size: dt11))
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    // MARK: - Section heading

    func sectionHeading(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: dt13, weight: .semibold))
            .detailSectionHeadingStyle()
    }
}
