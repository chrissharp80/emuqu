import SwiftUI

/// Visual breakdown of the composite recovery score showing each factor's
/// contribution (HRV, sleep, training, vitals) with bar charts and penalties.
struct ScoreBreakdownCard: View {
    let breakdown: RecoveryScoreCalculator.ScoreBreakdown
    var translate: (String) -> String = { $0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            breakdownHeader

            factorRows

            penaltiesSection
        }
    }

    private var breakdownHeader: some View {
        HStack {
            Image(systemName: "chart.bar.fill")
                .foregroundColor(AppTheme.primary)
            Text(String(localized: "SCORE BREAKDOWN", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)
            Spacer()
        }
    }

    private var factorRows: some View {
        ForEach(breakdown.factors) { factor in
            VStack(alignment: .leading, spacing: 6) {
                factorHeader(factor)
                factorBar(factor)
                Text(translate(factor.detail))
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(factorAccessibilityLabel(factor))
        }
    }

    /// The same translated label and detail the row shows.
    private func factorAccessibilityLabel(_ factor: RecoveryScoreCalculator.ScoreFactor) -> String {
        let label = translate(factor.label)
        let score = RecoveryScoreCalculator.displayScore(factor.score)
        let impact = switch factor.impact {
        case .positive: String(localized: "positive", bundle: LanguageManager.appBundle)
        case .neutral: String(localized: "neutral", bundle: LanguageManager.appBundle)
        case .negative: String(localized: "negative", bundle: LanguageManager.appBundle)
        }
        let weight = Int((factor.weight * 100).rounded())
        let detail = translate(factor.detail)
        return String(localized: "\(label): \(score) out of 100, \(impact) impact, weight \(weight) percent. \(detail)", bundle: LanguageManager.appBundle)
    }

    private func factorHeader(_ factor: RecoveryScoreCalculator.ScoreFactor) -> some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(factorColor(factor.impact))
                    .frame(width: 8, height: 8)
                Text(translate(factor.label))
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(AppTheme.textPrimary)
            }
            Spacer()
            Text("\(RecoveryScoreCalculator.displayScore(factor.score))")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundColor(factorColor(factor.impact))
            Text("\u{00D7} \(Int(factor.weight * 100))%")
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    private func factorBar(_ factor: RecoveryScoreCalculator.ScoreFactor) -> some View {
        GeometryReader { geo in
            factorBarTrack(factor, width: geo.size.width)
        }
        .frame(height: 6)
    }

    private func factorBarTrack(_ factor: RecoveryScoreCalculator.ScoreFactor, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(factorColor(factor.impact).opacity(0.15))
                .frame(height: 6)
            RoundedRectangle(cornerRadius: 3)
                .fill(factorColor(factor.impact))
                .frame(width: width * CGFloat(factor.score / 100), height: 6)
        }
    }

    private func penaltyRow(_ penalty: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(AppTheme.terracotta)
            Text(translate(penalty))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Penalty: \(translate(penalty))", bundle: LanguageManager.appBundle))
    }

    @ViewBuilder
    private var penaltiesSection: some View {
        if !breakdown.penalties.isEmpty {
            Divider()
                .padding(.vertical, 4)
            ForEach(breakdown.penalties, id: \.self) { penaltyRow($0) }
        }
    }

    private func factorColor(_ impact: RecoveryScoreCalculator.ScoreFactor.Impact) -> Color {
        switch impact {
        case .positive: AppTheme.sage
        case .neutral: AppTheme.softGold
        case .negative: AppTheme.terracotta
        }
    }
}
