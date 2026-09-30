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
                // BP §D4 line 668 — tap any stage pill expands an
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
            stagePill(kind: .awake, minutes: sleep.awakeMinutes, totalMin: sleep.inBedMinutes, color: AppTheme.wongAttention.opacity(0.7))
        }
    }

    /// Tappable stage pill (BP §D4 line 668). Wrapped in a Button so
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
            stagePillLabel(label: label, minutes: minutes, totalMin: totalMin, color: color, isExpanded: isExpanded)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(String(localized: "Double tap to learn what \(label.lowercased()) sleep is and what's typical.", bundle: LanguageManager.appBundle)))
    }

    private func stagePillLabel(label: String, minutes: Int, totalMin: Int, color: Color, isExpanded: Bool) -> some View {
        let pct = totalMin > 0 ? Double(minutes) / Double(totalMin) * 100 : 0
        return VStack(spacing: 4) {
            Text(verbatim: label)
                .font(.system(size: dt11, weight: .medium))
                .foregroundStyle(color)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(verbatim: formatMinutes(minutes))
                .font(.system(size: dt14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: String(format: "%.0f%%", locale: .current, pct))
                .font(.system(size: dt10))
                .foregroundStyle(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .modifier(StagePillChrome(color: color, isExpanded: isExpanded))
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
                // These weights are how the
                // SLEEP score itself is composed (Duration 35% / Eff 25%
                // / Deep 25% / REM 15%). The Recovery Score, on a
                // separate surface, weights Sleep at 25% as one of its
                // three factors. Both screens display "25%" for two
                // unrelated meanings; this footer disambiguates.
                Text(String(localized: "These weights are how the Sleep score is composed — separate from how Sleep contributes 25% to your Recovery Score.", bundle: LanguageManager.appBundle))
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

    func computeSleepBreakdowns(sleep: SleepData) -> [SleepBreakdownEntry] {
        let target = max(typicalSleepHours, 1.0) * 60
        let durationScore = min(Double(sleep.totalSleepIncludingNapMinutes) / target, 1.2) * 100
        let efficiencyScore = sleep.sleepEfficiency
        let deepScore: Double = {
            guard let d = sleep.deepSleepMinutes, sleep.nightSleepMinutes > 0 else { return 0 }
            return min(Double(d) / Double(sleep.nightSleepMinutes) / 0.20, 1.0) * 100
        }()
        let remScore: Double = {
            guard let r = sleep.remSleepMinutes, sleep.nightSleepMinutes > 0 else { return 0 }
            return min(Double(r) / Double(sleep.nightSleepMinutes) / 0.25, 1.0) * 100
        }()
        return [
            SleepBreakdownEntry(label: String(localized: "Duration", bundle: LanguageManager.appBundle), score: min(100, durationScore), weight: ScoringWeights.Sleep.duration, ok: durationScore >= 80),
            SleepBreakdownEntry(label: String(localized: "Efficiency", bundle: LanguageManager.appBundle), score: efficiencyScore, weight: ScoringWeights.Sleep.efficiency, ok: efficiencyScore >= 85),
            SleepBreakdownEntry(label: String(localized: "Deep", bundle: LanguageManager.appBundle), score: deepScore, weight: ScoringWeights.Sleep.deepSleep, ok: deepScore >= 70),
            SleepBreakdownEntry(label: String(localized: "REM", bundle: LanguageManager.appBundle), score: remScore, weight: ScoringWeights.Sleep.remSleep, ok: remScore >= 70)
        ]
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
        if sleep.sleepEfficiency >= 95 {
            out.append(String(localized: "Excellent sleep efficiency. You're sleeping well for the time spent in bed.", bundle: LanguageManager.appBundle))
        } else if sleep.sleepEfficiency < 80 {
            out.append(String(localized: "Sleep efficiency was low — many awakenings or long time-to-fall-asleep. Worth tracking what's interrupting the night.", bundle: LanguageManager.appBundle))
        }
        if let deep = sleep.deepSleepMinutes, sleep.nightSleepMinutes > 0,
           Double(deep) / Double(sleep.nightSleepMinutes) >= 0.20 {
            out.append(String(localized: "Deep sleep made up a typical share of the night.", bundle: LanguageManager.appBundle))
        }
        return Array(out.prefix(3))
    }

    // MARK: - Recent trends

    @ViewBuilder
    var recentTrendsSection: some View {
        // Reads the cached trend (see `trendNights`)
        // instead of calling `buildTrend()` per body evaluation.
        let trend = trendNights
        if !trend.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading(String(localized: "Recent trends (15 nights)", bundle: LanguageManager.appBundle))
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
            Text(verbatim: "\(night.minutes / 60)h")
                .font(.system(size: dt9))
                .foregroundStyle(AppTheme.textTertiary)
        }
        .frame(width: 28)
    }

    struct TrendNight: Identifiable {
        /// Stable identity derived from the night's
        /// timestamp. A `UUID()` re-randomizes on every
        /// rebuild and makes ForEach treat all 15 bars as
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

    func weekday(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "E"
        return String(f.string(from: d).prefix(1))
    }

    func barColor(_ score: Double) -> Color {
        // Bands from SleepConstants.ScoreBands — shared with the morning
        // sheet's quality label (one ladder for both).
        switch score {
        case SleepConstants.ScoreBands.excellent...:
            AppTheme.wongOptimal
        case SleepConstants.ScoreBands.good ..< SleepConstants.ScoreBands.excellent:
            AppTheme.wongGood
        case SleepConstants.ScoreBands.fair ..< SleepConstants.ScoreBands.good:
            AppTheme.wongCaution
        default:
            AppTheme.wongAttention
        }
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

    private func structureCells(_ sleep: SleepData) -> some View {
        HStack(spacing: 8) {
            structureCell(label: String(localized: "Cycles", bundle: LanguageManager.appBundle), value: "\(estimatedCycles(sleep))")
            structureCell(label: String(localized: "Awakenings", bundle: LanguageManager.appBundle), value: awakeningsDescriptor(sleep))
            structureCell(label: String(localized: "Continuity", bundle: LanguageManager.appBundle), value: continuityDescriptor(sleep))
            structureCell(label: String(localized: "Architecture", bundle: LanguageManager.appBundle), value: architectureDescriptor(sleep))
        }
    }

    func estimatedCycles(_ sleep: SleepData) -> Int {
        // Each sleep cycle is ~90 min on average.
        max(1, sleep.nightSleepMinutes / 90)
    }

    func awakeningsDescriptor(_ sleep: SleepData) -> String {
        let awakeCount = sleep.stageIntervals.filter { $0.stage == .awake }.count
        if awakeCount <= 2 { return String(localized: "Minimal", bundle: LanguageManager.appBundle) }
        if awakeCount <= 5 { return String(localized: "Few", bundle: LanguageManager.appBundle) }
        return String(localized: "Many", bundle: LanguageManager.appBundle)
    }

    func continuityDescriptor(_ sleep: SleepData) -> String {
        sleep.sleepEfficiency >= 92 ? String(localized: "High", bundle: LanguageManager.appBundle) : sleep.sleepEfficiency >= 80 ? String(localized: "Normal", bundle: LanguageManager.appBundle) : String(localized: "Low", bundle: LanguageManager.appBundle)
    }

    func architectureDescriptor(_ sleep: SleepData) -> String {
        guard let deep = sleep.deepSleepMinutes, let rem = sleep.remSleepMinutes,
              sleep.nightSleepMinutes > 0 else { return "—" }
        let deepPct = Double(deep) / Double(sleep.nightSleepMinutes)
        let remPct = Double(rem) / Double(sleep.nightSleepMinutes)
        if deepPct >= 0.15 && remPct >= 0.20 { return String(localized: "Typical", bundle: LanguageManager.appBundle) }
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

    /// Stage classification on a wrist strap derives
    /// from RR variability and lacks the EEG ground truth a sleep lab provides.
    /// Awake/asleep boundaries are reliable, but per-stage splits (Deep vs Light
    /// vs REM) typically run ±10 pp of PSG. A user seeing 42% deep deserves to
    /// know both that it is outside the typical range AND that the classifier is
    /// fuzzy at extremes, so they can calibrate their trust accordingly — hence
    /// the accuracy footnote at the bottom of this card.
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
            ageComparisonRows(sleep, typical: ageTypicalRanges(age: age))
            Text(String(localized: "Based on Ohayon et al. (2004). Shaded area = typical range for your age group.", bundle: LanguageManager.appBundle))
                .font(.system(size: dt11))
                .foregroundStyle(AppTheme.textTertiary)
            Text(String(localized: "Stages estimated from heart-beat intervals have not been compared with a sleep lab, so their accuracy is unknown.", bundle: LanguageManager.appBundle))
                .font(.system(size: dt11))
                .foregroundStyle(AppTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private func ageComparisonRows(_ sleep: SleepData, typical: AgeTypical) -> some View {
        VStack(spacing: 8) {
            ageRow(label: String(localized: "Deep sleep", bundle: LanguageManager.appBundle), value: deepPctText(sleep: sleep), range: typical.deep)
            ageRow(label: String(localized: "REM sleep", bundle: LanguageManager.appBundle), value: remPctText(sleep: sleep), range: typical.rem)
            ageRow(label: String(localized: "Efficiency", bundle: LanguageManager.appBundle), value: String(format: "%.0f%%", locale: .current, sleep.sleepEfficiency), range: typical.efficiency)
        }
    }

    struct AgeTypical {
        let deep: ClosedRange<Double>
        let rem: ClosedRange<Double>
        let efficiency: ClosedRange<Double>
    }

    func ageTypicalRanges(age: Int) -> AgeTypical {
        // Loose adapter for Ohayon 2004 age-binned norms.
        switch age {
        case ..<30:   AgeTypical(deep: 18...25, rem: 22...28, efficiency: 90...96)
        case 30..<50: AgeTypical(deep: 15...22, rem: 20...26, efficiency: 87...94)
        case 50..<70: AgeTypical(deep: 12...18, rem: 18...24, efficiency: 84...92)
        default:      AgeTypical(deep: 10...16, rem: 16...22, efficiency: 80...90)
        }
    }

    func deepPctText(sleep: SleepData) -> String {
        guard let d = sleep.deepSleepMinutes, sleep.nightSleepMinutes > 0 else { return "—" }
        return String(format: "%.0f%%", locale: .current, Double(d) / Double(sleep.nightSleepMinutes) * 100)
    }

    func remPctText(sleep: SleepData) -> String {
        guard let r = sleep.remSleepMinutes, sleep.nightSleepMinutes > 0 else { return "—" }
        return String(format: "%.0f%%", locale: .current, Double(r) / Double(sleep.nightSleepMinutes) * 100)
    }

    func ageRow(label: String, value: String, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(verbatim: label)
                .font(.system(size: dt13))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Text(verbatim: value)
                .font(.system(size: dt13, weight: .medium).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: "(\(Int(range.lowerBound))-\(Int(range.upperBound))%)")
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
