import SwiftUI

/// "Why is readiness here?" — pushed when the user taps the Dashboard hero
/// medallion. The medallion is live (drifts during the day with training and
/// fatigue dissipation); this view explains *why* it's at its current value
/// in plain physiological language.
///
/// Layout follows the Joystick playbook: small recap ring at top, one-sentence
/// observation below, then a stack of plain-language signal rows. No charts —
/// the chart story lives on the contributor chips. This is the explanation,
/// not the dashboard.
///
/// Voice: observational, never diagnostic. "Today's run pulled this down" not
/// "you overtrained." Numbers are honest and rounded the way humans talk.
struct ReadinessExplainView: View {
    let readiness: LiveReadiness
    /// Optional jump-off to the morning HRV report. The strip below the
    /// medallion is the primary entry point for the morning view; this is
    /// just a courtesy link from inside the explainer for users who arrived
    /// via the medallion and now want to see where the day started.
    var onViewMorningReport: (() -> Void)?

    private var scoreInt: Int { RecoveryScoreCalculator.displayScore(readiness.score) }
    private var verdict: ScoreVerdict { ScoreVerdict(score: readiness.score) }
    private var morningInt: Int { Int(readiness.morningRecovery.rounded()) }
    private var morningVerdict: ScoreVerdict { ScoreVerdict(score: readiness.morningRecovery) }

    var body: some View {
        ScrollView { stack }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(Text(String(localized: "Readiness", bundle: LanguageManager.appBundle)))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 18) {
            heroRecap
            headlineObservation
            signalStack
            if onViewMorningReport != nil {
                morningReportLink
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
    }

    // MARK: - Hero recap

    private var heroRecap: some View {
        HStack(spacing: 16) {
            ScoreRing(state: .default(score: scoreInt, verdict: verdict), size: .card)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: verdict.localizedWord)
                    .scaledFont(size: 22, weight: .semibold)
                    .foregroundStyle(verdict.textColor)
                Text(String(localized: "Readiness right now", bundle: LanguageManager.appBundle))
                    .scaledFont(size: 14)
                    .foregroundStyle(AppTheme.textTertiary)
            }
            Spacer()
        }
    }

    // MARK: - Headline

    /// One-sentence observation, sourced from the snapshot so the same
    /// language can flow to the loop card under the medallion. The model
    /// already names the day's main event (workout or fatigue dissipation)
    /// when there is one; this view just renders.
    private var headlineObservation: some View {
        Text(verbatim: readiness.headline)
            .scaledFont(size: 17, weight: .semibold)
            .foregroundStyle(AppTheme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Signal stack

    @ViewBuilder
    private var morningRow: some View {
        row(
            label: String(localized: "This morning", bundle: LanguageManager.appBundle),
            value: "\(morningInt) · \(morningVerdict.localizedWord)",
            tint: morningVerdict.color
        )
    }

    private var todayTrainingRow: some View {
        row(
            label: String(localized: "Today's training", bundle: LanguageManager.appBundle),
            value: todayTrainingValue,
            tint: todayTrainingTint
        )
    }

    private var acuteFatigueRow: some View {
        row(
            label: String(localized: "Acute fatigue", bundle: LanguageManager.appBundle),
            value: acuteFatigueValue,
            tint: acuteFatigueTint
        )
    }

    private var loadVsFitnessRow: some View {
        row(
            label: String(localized: "Load vs fitness", bundle: LanguageManager.appBundle),
            value: loadVsFitnessValue,
            tint: loadVsFitnessTint
        )
    }

    private var hoursSinceRow: some View {
        row(
            label: String(localized: "Hours since reading", bundle: LanguageManager.appBundle),
            value: hoursSinceValue,
            tint: AppTheme.textSecondary
        )
    }

    private var signalStack: some View {
        VStack(spacing: 0) {
            morningRow
            divider
            todayTrainingRow
            divider
            acuteFatigueRow
            divider
            loadVsFitnessRow
            divider
            hoursSinceRow
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppTheme.cardBackground)
        )
    }

    private func row(label: String, value: String, tint: Color) -> some View {
        HStack {
            Text(verbatim: label)
                .scaledFont(size: 15)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(verbatim: value)
                .scaledFont(size: 15, weight: .semibold, monospacedDigit: true)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Rectangle()
            .fill(AppTheme.textTertiary.opacity(0.15))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    // MARK: - Row values

    private var todayTrainingValue: String {
        if let w = readiness.todayPrimaryWorkout {
            // "Hard 45-min run" — capitalised first letter for the row.
            let phrase = w.phrase
            return phrase.prefix(1).uppercased() + phrase.dropFirst()
        }
        let t = Int(readiness.todayTrimp.rounded())
        if t == 0 { return String(localized: "None yet", bundle: LanguageManager.appBundle) }
        // Accumulated load with no single named workout (multiple short
        // sessions, manual TRIMP, etc). Fall back to the bucketed word
        // without leaning on the raw number.
        if t < 30 { return String(localized: "Easy", bundle: LanguageManager.appBundle) }
        if t < 80 { return String(localized: "Moderate", bundle: LanguageManager.appBundle) }
        if t < 150 { return String(localized: "Hard", bundle: LanguageManager.appBundle) }
        return String(localized: "Very hard", bundle: LanguageManager.appBundle)
    }

    /// Light training is informational (secondary); harder training pulls the
    /// readiness number, so colour the row accordingly.
    private var todayTrainingTint: Color {
        let t = readiness.todayTrimp
        if t == 0 { return AppTheme.textSecondary }
        if t < 30 { return AppTheme.textPrimary }
        if t < 80 { return AppTheme.wongGood }
        if t < 150 { return AppTheme.wongCaution }
        return AppTheme.wongAttention
    }

    /// Acute fatigue is the decayed sum of recent workout TRIMP. Bucket
    /// against ATL since "high" is contextual to the user's training load.
    private var acuteFatigueValue: String {
        let af = readiness.acuteFatigueLoad
        if af < 10 { return String(localized: "Low", bundle: LanguageManager.appBundle) }
        // Default thresholds when we can't compare to ATL — mirror the
        // calculator's piecewise mapping (capacity ratio 0.8/1.0/1.3 maps to
        // sweet-spot/matched/overreaching).
        guard let acr = readiness.acuteChronicRatio else {
            if af < 50 { return String(localized: "Moderate", bundle: LanguageManager.appBundle) }
            return String(localized: "Elevated", bundle: LanguageManager.appBundle)
        }
        if acr < 0.8 { return String(localized: "Low — well within fitness", bundle: LanguageManager.appBundle) }
        if acr < 1.0 { return String(localized: "Moderate", bundle: LanguageManager.appBundle) }
        if acr < 1.3 { return String(localized: "Elevated", bundle: LanguageManager.appBundle) }
        return String(localized: "High — recent load above usual", bundle: LanguageManager.appBundle)
    }

    private var acuteFatigueTint: Color {
        guard let acr = readiness.acuteChronicRatio else {
            // The same cut as the label: below 50 reads Low or Moderate.
            return readiness.acuteFatigueLoad < 50 ? AppTheme.textPrimary : AppTheme.wongCaution
        }
        if acr < 1.0 { return AppTheme.wongOptimal }
        if acr < 1.3 { return AppTheme.wongCaution }
        return AppTheme.wongAttention
    }

    private var loadVsFitnessValue: String {
        guard let acr = readiness.acuteChronicRatio else { return String(localized: "Building baseline", bundle: LanguageManager.appBundle) }
        return String(format: "%.2f×", locale: LanguageManager.appLocale, acr)
    }

    private var loadVsFitnessTint: Color {
        guard let acr = readiness.acuteChronicRatio else { return AppTheme.textSecondary }
        if acr < 1.0 { return AppTheme.textPrimary }
        if acr < 1.3 { return AppTheme.wongCaution }
        return AppTheme.wongAttention
    }

    private var hoursSinceValue: String {
        let h = readiness.hoursSinceMorning
        if h < 1 { return String(localized: "Just now", bundle: LanguageManager.appBundle) }
        if h < 24 { return String(localized: "\(Int(h.rounded())) h", bundle: LanguageManager.appBundle) }
        if h < 48 { return String(localized: "Yesterday's reading", bundle: LanguageManager.appBundle) }
        let days = Int(h / 24)
        return String(localized: "\(days) days ago", bundle: LanguageManager.appBundle)
    }

    // MARK: - Morning report link

    private var morningReportLink: some View {
        Button {
            onViewMorningReport?()
        } label: {
            HStack {
                Text(String(localized: "View morning report", bundle: LanguageManager.appBundle))
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(AppTheme.primary)
                Spacer()
                Image(systemName: "chevron.forward")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(AppTheme.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(AppTheme.primary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}
