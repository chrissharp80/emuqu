import Charts
import SwiftUI

// The hero, factor and explanation sections of the recovery-score detail screen.

extension RecoveryScoreDetailView {
    // MARK: - Hero

    var heroSection: some View {
        VStack(spacing: 12) {
            heroRing
            heroVerdictText
        }
        .frame(maxWidth: .infinity)
    }

    private var heroRing: some View {
        ScoreRing(
            state: .default(score: ScoreVerdict.safeDisplayScore(compositeScore), verdict: verdict),
            size: .card
        )
        .frame(width: 140, height: 140)
    }

    private var heroVerdictText: some View {
        VStack(spacing: 4) {
            Text(verbatim: verdict.localizedWord)
                .font(.system(size: dt22, weight: .semibold))
                .foregroundStyle(verdict.textColor)
            if let deltaText {
                Text(verbatim: deltaText)
                    .font(.system(size: dt14))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    // MARK: - Trend comparison

    /// The "Trend Analysis" comparison card (current
    /// vs recent-average vs personal baseline for RMSSD / RHR / Stress /
    /// Readiness). Dropping it is the "compare screen no longer shows up"
    /// report. Fed from this view's `result` + `recentSessions`.
    @ViewBuilder
    var trendComparisonSection: some View {
        if recentSessions.count >= 2 {
            TrendComparisonCard(result: result, recentSessions: recentSessions, baselineStats: baselineStats)
        }
    }

    // MARK: - What this means

    var whatThisMeansSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(String(localized: "What this means", bundle: LanguageManager.appBundle))
            NarrativeCard(text: ScoreBreakdownCopy.message(for: breakdown, loadLevel: adviceLoad.level), accent: verdict.color)
        }
    }

    // MARK: - Most Likely Explanations

    var mostLikelyExplanationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(String(localized: "Most likely explanations", bundle: LanguageManager.appBundle))
            explanationCards
        }
    }

    private var explanationCards: some View {
        VStack(spacing: 8) {
            ForEach(Array(buildExplanations().enumerated()), id: \.offset) { idx, item in
                explanationCard(index: idx + 1, title: item.title, body: item.body, badge: item.badge, badgeColor: item.badgeColor)
            }
        }
    }

    struct Explanation {
        let title: String
        let body: String
        let badge: String
        let badgeColor: Color
    }

    func buildExplanations() -> [Explanation] {
        let out = [hrvExplanation(), sleepExplanation(), vitalsExplanation()].compactMap { $0 }
        return Array(out.prefix(3))
    }

    /// #2 — deviation vs the GEOMETRIC baseline exp(mean) so the percent
    /// matches the score (percent-of-ln is meaningless).
    func hrvExplanation() -> Explanation? {
        guard let pct = hrvPercentVsBaseline else { return nil }
        let rmssd = Int(result.timeDomain.rmssd.rounded())
        if pct > 5 { return hrvAboveBaseline(rmssd: rmssd, pct: pct) }
        if pct < -10 { return hrvBelowBaseline(rmssd: rmssd, pct: pct) }
        return Explanation(
            title: String(localized: "Within your usual range", bundle: LanguageManager.appBundle),
            body: String(format: String(localized: "Today's HRV (%dms) is in your usual band. Body is in a normal recovery window.", bundle: LanguageManager.appBundle), rmssd),
            badge: String(localized: "Stable", bundle: LanguageManager.appBundle),
            badgeColor: AppTheme.wongGood
        )
    }

    /// Today's RMSSD against the GEOMETRIC baseline exp(mean), in percent.
    /// Shared by the explanation, the finding, the delta badge and the action
    /// list so they can never disagree about whether HRV is "below baseline".
    var hrvPercentVsBaseline: Double? {
        guard let mean = baselineStats?.lnRmssdMean, mean > 0 else { return nil }
        let baseline = exp(mean)
        return ((result.timeDomain.rmssd - baseline) / baseline) * 100
    }

    func hrvAboveBaseline(rmssd: Int, pct: Double) -> Explanation {
        Explanation(
            title: String(localized: "Above your baseline", bundle: LanguageManager.appBundle),
            body: String(format: String(localized: "Today's HRV (%dms) is %.0f%% above your average. Your body is well-recovered.", bundle: LanguageManager.appBundle), rmssd, pct),
            badge: String(localized: "Excellent", bundle: LanguageManager.appBundle),
            badgeColor: AppTheme.wongOptimal
        )
    }

    func hrvBelowBaseline(rmssd: Int, pct: Double) -> Explanation {
        Explanation(
            title: String(localized: "Below your baseline", bundle: LanguageManager.appBundle),
            // `pct` is negative here; the sentence already says "below".
            body: String(format: String(localized: "Today's HRV (%dms) is %.0f%% below your average. Recovery is reduced.", bundle: LanguageManager.appBundle), rmssd, abs(pct)),
            badge: String(localized: "Pay attention", bundle: LanguageManager.appBundle),
            badgeColor: AppTheme.wongCaution
        )
    }

    /// Locale-aware h/m abbreviations. Nil when the night's efficiency was
    /// not measured, since every explanation here is graded on it.
    func sleepExplanation() -> Explanation? {
        guard let sleep = session.sleepSnapshot, sleep.nightSleepMinutes > 0,
              let efficiency = sleep.measuredSleepEfficiency else { return nil }
        let dur = LocalizedDuration.hoursMinutes(minutes: sleep.nightSleepMinutes)
        let pct = Int(efficiency.rounded())
        if efficiency >= 95 {
            return Explanation(
                title: String(localized: "Excellent sleep quality", bundle: LanguageManager.appBundle),
                body: String(localized: "\(dur) at \(pct)% efficiency — minimal awakenings let your nervous system fully restore.", bundle: LanguageManager.appBundle),
                badge: String(localized: "Contributing factor", bundle: LanguageManager.appBundle),
                badgeColor: AppTheme.wongOptimal
            )
        }
        if efficiency >= 85 { return solidSleepExplanation(dur: dur, pct: pct) }
        return disruptedSleepExplanation(dur: dur, pct: pct)
    }

    func solidSleepExplanation(dur: String, pct: Int) -> Explanation {
        Explanation(
            title: String(localized: "Solid sleep", bundle: LanguageManager.appBundle),
            body: String(localized: "\(dur) at \(pct)% efficiency — enough to support recovery.", bundle: LanguageManager.appBundle),
            badge: String(localized: "Contributing factor", bundle: LanguageManager.appBundle),
            badgeColor: AppTheme.wongGood
        )
    }

    /// `RecoveryVitals.status` looks at breathing, temperature and SpO₂ only,
    /// so "All vitals at baseline … resting heart rate … within your usual
    /// range" could sit under a key finding of "Sleep HR 69 bpm (+13 vs
    /// baseline)". The HR comparison the score itself uses — whole-night mean
    /// HR against `meanHRBaseline`, in SD units — now gates that wording.
    func sleepHRAboveBaselineExplanation() -> Explanation? {
        guard let baseline = baselineStats?.meanHRBaseline, baseline > 0,
              let sd = baselineStats?.meanHRSD, sd > 0 else { return nil }
        let delta = result.timeDomain.meanHR - baseline
        guard delta >= max(sd, 3) else { return nil }
        return Explanation(
            title: String(localized: "Sleep heart rate above baseline", bundle: LanguageManager.appBundle),
            body: String(format: RecoveryDetailCopy.sleepHRAboveBaselineFormat(effectiveVitals), Int(result.timeDomain.meanHR.rounded()), Int(delta.rounded())),
            badge: String(localized: "Pay attention", bundle: LanguageManager.appBundle),
            badgeColor: AppTheme.wongCaution
        )
    }

    func disruptedSleepExplanation(dur: String, pct: Int) -> Explanation {
        Explanation(
            title: String(localized: "Disrupted sleep", bundle: LanguageManager.appBundle),
            body: String(localized: "\(dur) at \(pct)% efficiency. Awakenings are pulling efficiency down — try to get to bed earlier tonight.", bundle: LanguageManager.appBundle),
            badge: String(localized: "Pulling score down", bundle: LanguageManager.appBundle),
            badgeColor: AppTheme.wongCaution
        )
    }

    func vitalsExplanation() -> Explanation? {
        guard let v = effectiveVitals, !v.isEmpty else { return nil }
        if v.status == .normal, let hr = sleepHRAboveBaselineExplanation() { return hr }
        switch v.status {
        case .normal:
            return RecoveryDetailCopy.normalVitalsExplanation(effectiveVitals)
        case .elevated, .warning:
            return Explanation(
                title: String(localized: "Vitals above baseline", bundle: LanguageManager.appBundle),
                body: String(localized: "One or more of your overnight vitals are above your usual range. Common causes are hard training, alcohol, a warm room, dehydration or stress, and sometimes the start of an illness — worth noting.", bundle: LanguageManager.appBundle),
                badge: v.status == .warning ? String(localized: "Pay attention", bundle: LanguageManager.appBundle) : String(localized: "Watch", bundle: LanguageManager.appBundle),
                badgeColor: v.status == .warning ? AppTheme.wongAttention : AppTheme.wongCaution
            )
        }
    }

    func explanationCard(index: Int, title: String, body: String, badge: String, badgeColor: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(index).")
                .font(.system(size: dt17, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textTertiary)
                .frame(width: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                explanationHeader(title: title, badge: badge, badgeColor: badgeColor)
                Text(verbatim: body)
                    .font(.system(size: dt13))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.cardBackground)
        )
    }

    func explanationHeader(title: String, badge: String, badgeColor: Color) -> some View {
        HStack {
            Text(verbatim: title)
                .font(.system(size: dt15, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Text(verbatim: badge)
                .font(.system(size: dt11, weight: .semibold))
                .foregroundStyle(badgeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(badgeColor.opacity(0.15)))
        }
    }

    // MARK: - Score breakdown

    var scoreBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(String(localized: "Score breakdown", bundle: LanguageManager.appBundle))
            breakdownRows
            breakdownFootnote
            scoringProvenance
        }
    }

    /// Which algorithm produced this score, and how much of it is calibrated
    /// rather than validated.
    ///
    /// Two of the conditions for keeping unvalidated scoring heuristics in
    /// place rather than removing them are about this view. The unvalidated
    /// status has to be
    /// visible WHEREVER the composite is explained — not only on the
    /// methodology page a reader may never open — and a historical record has
    /// to show the version that produced it rather than being read as though
    /// today's algorithm made it.
    ///
    /// A score decoded from before versioning existed reads `unversioned`,
    /// which is the honest answer: the archive cannot tell v1 from v2.
    @ViewBuilder
    private var scoringProvenance: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(scoringVersionLine)
            Text(String(localized: "The inputs are research-informed; the weights and bands are calibrated, not outcome-validated. Tap How Emuqu Scores Recovery for which is which.", bundle: LanguageManager.appBundle))
        }
        .font(.system(size: dt12))
        .foregroundStyle(AppTheme.textTertiary)
        .padding(.top, 6)
    }

    private var scoringVersionLine: String {
        guard breakdown.scoringVersion != ScoringVersion.unversioned else {
            return String(localized: "Scored before score versions were recorded", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Scored by \(breakdown.scoringVersion)", bundle: LanguageManager.appBundle)
    }

    private var breakdownRows: some View {
        VStack(spacing: 8) {
            ForEach(breakdown.factors) { factor in
                breakdownRow(factor: factor)
            }
        }
    }

    /// The weights come from this score's own factors (they differ by tier),
    /// so the footnote can't contradict the rows above it.
    private var breakdownFootnote: some View {
        let weights = breakdown.factors
            .map { "\(RecoveryDetailCopy.factorName($0.label)) \(Int(($0.weight * 100).rounded()))%" }
            .joined(separator: ", ")
        let prose = String(localized: "HRV is your core recovery signal. Sleep is the lever you can move tonight. Vitals add overnight heart rate, breathing rate and temperature, which can shift on nights when HRV does not.", bundle: LanguageManager.appBundle)
        return Text(String(localized: "Weights for this score: \(weights).", bundle: LanguageManager.appBundle) + " " + prose)
            .font(.system(size: dt12))
            .foregroundStyle(AppTheme.textTertiary)
            .padding(.top, 4)
    }

    func breakdownRow(factor: RecoveryScoreCalculator.ScoreFactor) -> some View {
        let isExpanded = expandedFactor == factor.label
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                expandedFactor = isExpanded ? nil : factor.label
            }
        } label: {
            breakdownRowLabel(factor: factor, isExpanded: isExpanded)
        }
        .buttonStyle(.plain)
    }

    func breakdownRowLabel(factor: RecoveryScoreCalculator.ScoreFactor, isExpanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            breakdownHeader(factor: factor, color: factorColor(factor))
            breakdownBar(factor: factor, color: factorColor(factor))
            if isExpanded {
                // Written now from the factor's facts, so it follows the app
                // language and temperature unit rather than the night's.
                Text(verbatim: factor.displayDetail(temperatureUnit: settingsManager.settings.temperatureUnit))
                    .font(.system(size: dt13))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.cardBackground)
        )
    }

    func breakdownHeader(factor: RecoveryScoreCalculator.ScoreFactor, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: RecoveryDetailCopy.factorName(factor.label))
                .font(.system(size: dt15, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Text(verbatim: "\(RecoveryScoreCalculator.displayScore(factor.score))")
                .font(.system(size: dt17, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
            Text(verbatim: "× \(Int((factor.weight * 100).rounded()))%")
                .font(.system(size: dt12))
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    func breakdownBar(factor: RecoveryScoreCalculator.ScoreFactor, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppTheme.textTertiary.opacity(0.15))
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: geo.size.width * (factor.score / 100), height: 6)
            }
        }
        .frame(height: 6)
    }

    func factorColor(_ factor: RecoveryScoreCalculator.ScoreFactor) -> Color {
        switch factor.score {
        case 80...:  AppTheme.wongOptimal
        case 60..<80: AppTheme.wongGood
        case 45..<60: AppTheme.wongCaution
        default:      AppTheme.wongAttention
        }
    }

    // MARK: - SpO2 penalty

    @ViewBuilder
    var spo2PenaltyBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(AppTheme.wongAttention)
            Text(RecoveryDetailCopy.spo2PenaltyText(points: spo2Penalty.points, value: spo2Penalty.value))
                .font(.system(size: dt13))
                .foregroundStyle(AppTheme.textPrimary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.wongAttention.opacity(0.1))
        )
    }

    // MARK: - Key findings

    var keyFindingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(String(localized: "Key findings", bundle: LanguageManager.appBundle))
            keyFindingsList
        }
    }

    private var keyFindingsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(buildKeyFindings().prefix(4)), id: \.self) { finding in
                keyFindingRow(finding)
            }
        }
    }

    private func keyFindingRow(_ finding: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(AppTheme.wongGood).frame(width: 6, height: 6).padding(.top, 7)
            Text(verbatim: finding)
                .font(.system(size: dt14))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func buildKeyFindings() -> [String] {
        [hrvFinding(), sleepHRFinding(), sleepEfficiencyFinding(), stressFinding(), dfaFinding()]
            .compactMap { $0 }
    }

    /// #2 — deviation vs the GEOMETRIC baseline exp(mean) so the percent
    /// matches the score (percent-of-ln is meaningless).
    func hrvFinding() -> String {
        guard let pct = hrvPercentVsBaseline else {
            return String(localized: "HRV \(rmssdText)", bundle: LanguageManager.appBundle)
        }
        let sign = pct >= 0 ? "+" : ""
        return String(localized: "HRV \(rmssdText), \(sign)\(Int(pct.rounded()))% vs your average", bundle: LanguageManager.appBundle)
    }

    func sleepHRFinding() -> String? {
        guard let meanHR = baselineStats?.meanHRBaseline, meanHR > 0 else { return nil }
        let delta = result.timeDomain.meanHR - meanHR
        let bpm = Int(result.timeDomain.meanHR.rounded())
        guard abs(delta) >= 1 else {
            return String(localized: "Sleep HR \(bpm) bpm (at baseline)", bundle: LanguageManager.appBundle)
        }
        let sign = delta >= 0 ? "+" : ""
        return String(localized: "Sleep HR \(bpm) bpm (\(sign)\(Int(delta.rounded())) vs baseline)", bundle: LanguageManager.appBundle)
    }

    /// Nil when the night's efficiency was not measured.
    func sleepEfficiencyFinding() -> String? {
        guard let sleep = session.sleepSnapshot, sleep.nightSleepMinutes > 0,
              let efficiency = sleep.measuredSleepEfficiency else { return nil }
        let duration = LocalizedDuration.hoursMinutes(minutes: sleep.nightSleepMinutes)
        return String(localized: "Sleep efficiency \(Int(efficiency.rounded()))% across \(duration)", bundle: LanguageManager.appBundle)
    }

    /// Bands follow `HRVThresholds` (Baevsky SI) — the app's own scale — and
    /// the words do not claim a state: calling anything under 100 "very
    /// relaxed" labels an SI of 89 sitting 77 % above the user's own average
    /// very relaxed on the same screen that flags it in red.
    func stressFinding() -> String? {
        guard let stress = result.ansMetrics?.stressIndex, stress > 0 else { return nil }
        let band = stress < HRVThresholds.stressIndexVeryLow
            ? String(localized: "very low", bundle: LanguageManager.appBundle)
            : stress < HRVThresholds.stressIndexLow
            ? String(localized: "low", bundle: LanguageManager.appBundle)
            : stress < HRVThresholds.stressIndexNormal
            ? String(localized: "normal", bundle: LanguageManager.appBundle)
            : stress < HRVThresholds.stressIndexElevated
            ? String(localized: "elevated", bundle: LanguageManager.appBundle)
            : String(localized: "high", bundle: LanguageManager.appBundle)
        return String(localized: "Stress index \(Int(stress.rounded())) — \(band) band", bundle: LanguageManager.appBundle)
    }

    func dfaFinding() -> String? {
        guard let dfa = result.nonlinear.dfaAlpha1, dfa >= 0.75, dfa <= 1.0 else { return nil }
        return String(localized: "DFA α1 was within the app's reference range (0.75–1.0)", bundle: LanguageManager.appBundle)
    }

    // MARK: - What to do

    var whatToDoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(String(localized: "What to do today", bundle: LanguageManager.appBundle))
            actionList
        }
    }

    private var actionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(buildActions().prefix(3)), id: \.self) { action in
                actionRow(action)
            }
        }
    }

    private func actionRow(_ action: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.forward")
                .font(.system(size: dt12, weight: .semibold))
                .foregroundStyle(AppTheme.wongOptimal)
                .padding(.top, 5)
            Text(verbatim: action)
                .font(.system(size: dt14))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The training load as it stood on this session's morning, read by the
    /// shared advice gate, so the actions and the message above them weigh
    /// recovery and load the way every other advice surface does.
    var adviceLoad: TrainingAdviceGate.Assessment {
        let context = session.trainingSnapshot ?? session.analysisResult?.trainingContext
        return TrainingAdviceGate.assess(context.map { TrainingAdviceGate.Load(context: $0) })
    }

    func buildActions() -> [String] {
        let load = adviceLoad
        switch verdict {
        case .excellent:
            guard load.level == .clear else { return goodDayActions(load: load) }
            return [
                String(localized: "This is a great day to push yourself — your recovery is strong.", bundle: LanguageManager.appBundle),
                String(localized: "If you've got a key session planned, today is the day for it.", bundle: LanguageManager.appBundle),
                String(localized: "Hydrate and fuel well to back up the work.", bundle: LanguageManager.appBundle)
            ]
        case .good:
            return goodDayActions(load: load)
        case .fair, .payAttention, .low, .veryLow:
            return backOffActions()
        }
    }

    /// `.good` composite (or an excellent one the load holds back), but HRV
    /// may still be under baseline — the same −10 % rule `hrvExplanation`
    /// uses for "Below your baseline". Handing out "the green light is
    /// there" beside that explanation was a contradiction visible on one
    /// screen; so is handing it out while the load gate says to ease off.
    func goodDayActions(load: TrainingAdviceGate.Assessment) -> [String] {
        let lead = load.level == .easier
            ? String(localized: "Easy aerobic work is the safe bet today.", bundle: LanguageManager.appBundle)
            : String(localized: "Normal training is on the table — listen to how the warm-up feels.", bundle: LanguageManager.appBundle)
        let sleep = String(localized: "Keep nightly sleep on schedule; don't waste a good day with a bad night.", bundle: LanguageManager.appBundle)
        if let pct = hrvPercentVsBaseline, pct < -10 {
            return [
                lead,
                String(localized: "HRV is under your baseline today, so keep intensity moderate and let tomorrow's reading confirm the trend.", bundle: LanguageManager.appBundle),
                sleep
            ]
        }
        let second = load.reasonLine(bundle: LanguageManager.appBundle)
            ?? String(localized: "If you wanted a hard session, the green light is there.", bundle: LanguageManager.appBundle)
        return [lead, second, sleep]
    }

    /// Fair and below — progressively firmer advice to ease up.
    func backOffActions() -> [String] {
        switch verdict {
        case .fair:
            return [
                String(localized: "Listen to the second half of the workout, not the first.", bundle: LanguageManager.appBundle),
                String(localized: "Easy aerobic work is the safe bet today.", bundle: LanguageManager.appBundle),
                String(localized: "Get to bed earlier — sleep is the lever you can move tonight.", bundle: LanguageManager.appBundle)
            ]
        case .payAttention:
            return [
                String(localized: "Easy day or full rest — your body is asking for it.", bundle: LanguageManager.appBundle),
                String(localized: "Watch caffeine, alcohol, and stress today; they all compound.", bundle: LanguageManager.appBundle),
                String(localized: "Earlier bedtime tonight helps tomorrow's reading recover.", bundle: LanguageManager.appBundle)
            ]
        default:
            return [
                String(localized: "Take a rest day. Skip intensity.", bundle: LanguageManager.appBundle),
                String(localized: "Hydrate, eat enough, and get to bed early.", bundle: LanguageManager.appBundle),
                String(localized: "If this persists 2+ days, consider what's accumulating — load, illness, life stress.", bundle: LanguageManager.appBundle)
            ]
        }
    }
}

// MARK: - Copy helpers

/// Wording the detail screen picks from its inputs. Kept outside the view so
/// the view type stays within its size budget; nothing here reads view state.
@MainActor
enum RecoveryDetailCopy {
    /// `ScoreDetailBuilder` labels factors with fixed English identifiers;
    /// these are their catalog names.
    static func factorName(_ label: String) -> String {
        switch label {
        case "HRV": String(localized: "HRV", bundle: LanguageManager.appBundle)
        case "Sleep": String(localized: "Sleep", bundle: LanguageManager.appBundle)
        case "Vitals": String(localized: "Vitals", bundle: LanguageManager.appBundle)
        case "Training Load": String(localized: "Training Load", bundle: LanguageManager.appBundle)
        default: label
        }
    }

    /// Names breathing and temperature as in range only when both were
    /// measured; the strap's heart rate alone makes the vitals non-empty.
    static func sleepHRAboveBaselineFormat(_ vitals: RecoveryVitals?) -> String {
        guard let v = vitals, v.respiratoryRate != nil, v.wristTemperature != nil else {
            return String(localized: "Overnight heart rate averaged %d bpm, %d above your usual.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Overnight heart rate averaged %d bpm, %d above your usual. Breathing and temperature are in range, so this is the one vital out of line tonight.", bundle: LanguageManager.appBundle)
    }

    /// With neither breathing rate nor temperature measured, only the strap's
    /// heart rate was compared, and the card says so.
    static func normalVitalsExplanation(_ vitals: RecoveryVitals?) -> RecoveryScoreDetailView.Explanation {
        guard let v = vitals, v.respiratoryRate == nil, v.wristTemperature == nil else {
            return RecoveryScoreDetailView.Explanation(
                title: String(localized: "All vitals at baseline", bundle: LanguageManager.appBundle),
                // Not a list: naming every vital claimed temperatures nobody measured.
                body: String(localized: "Every vital measured last night is within your usual range. No systemic stress flagged.", bundle: LanguageManager.appBundle),
                badge: String(localized: "Contributing factor", bundle: LanguageManager.appBundle),
                badgeColor: AppTheme.wongOptimal
            )
        }
        return RecoveryScoreDetailView.Explanation(
            title: String(localized: "Sleep heart rate at baseline", bundle: LanguageManager.appBundle),
            body: String(localized: "Only sleep heart rate was measured last night, and it is within your usual range.", bundle: LanguageManager.appBundle),
            badge: String(localized: "Contributing factor", bundle: LanguageManager.appBundle),
            badgeColor: AppTheme.wongOptimal
        )
    }

    /// The value clause is left out when no SpO₂ reading is in hand, rather
    /// than reading "dropped to 0%".
    static func spo2PenaltyText(points: Int, value: Double?) -> String {
        guard let value else {
            return String(localized: "−\(points) penalty: low SpO₂.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "−\(points) penalty: SpO₂ dropped to \(Int(value.rounded()))%.", bundle: LanguageManager.appBundle)
    }

    /// The method a stored result was selected by, from the fixed English
    /// shapes `WindowSelector` writes (`peakSelectionReason`,
    /// `manualSelectionReason`). Nil for the default organized-recovery
    /// selection.
    static func storedWindowMethod(_ reason: String?) -> WindowSelectionMethod? {
        guard let reason else { return nil }
        if reason.hasPrefix("Manual selection") { return .custom }
        if reason.hasPrefix("Peak SDNN (Total Power") { return .peakTotalPower }
        if reason.hasPrefix("Peak SDNN") { return .peakSDNN }
        if reason.hasPrefix("Peak RMSSD") { return .peakRMSSD }
        return nil
    }
}
