import SwiftUI

// MARK: - Metric Cell

struct HRVMetricCell: View {
    let label: String
    let value: String
    @State private var showingInfo = false

    @ViewBuilder
    var body: some View {
        Button {
            showingInfo = true
        } label: {
            bodyLabel
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingInfo) {
            MetricExplanationPopover(metric: label)
        }
    }

    private var bodyLabel: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                Text(value)
                    .font(.system(.subheadline, design: .rounded).bold())
                    .foregroundColor(AppTheme.textPrimary)
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
            }
            Text(label)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(AppTheme.sectionTint)
        .cornerRadius(AppTheme.smallCornerRadius)
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(AppTheme.primary)
            Text(title)
                .font(.subheadline.bold())
                .foregroundColor(AppTheme.textPrimary)
        }
    }
}

// MARK: - Trend Comparison Row

struct TrendComparisonRow: View {
    let metric: String
    let current: Double
    let average: Double
    let baseline: Double?
    let unit: String
    let higherIsBetter: Bool

    private var diff: Double {
        current - average
    }

    private var pctDiff: Double {
        average > 0 ? (diff / average) * 100 : 0
    }

    private var trendColor: Color {
        let isGood = higherIsBetter ? diff > 0 : diff < 0
        let isBad = higherIsBetter ? diff < 0 : diff > 0

        if abs(pctDiff) < 5 { return AppTheme.textSecondary }
        if isGood { return AppTheme.sage }
        if isBad, abs(pctDiff) > 15 { return AppTheme.terracotta }
        if isBad { return AppTheme.softGold }
        return AppTheme.textSecondary
    }

    private var trendIcon: String {
        if abs(pctDiff) < 5 { return "equal" }
        // Direction only; whether the change is good shows in `trendColor`.
        return diff > 0 ? "arrow.up.right" : "arrow.down.right"
    }

    var body: some View {
        HStack {
            valueColumn
            Spacer()
            trendColumn
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppTheme.sectionTint)
        .cornerRadius(AppTheme.smallCornerRadius)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(metric): \(formatValue(current)) \(unit), \(abs(pctDiff) < 5 ? String(localized: "stable", bundle: LanguageManager.appBundle) : pctDiff > 0 ? String(localized: "up", bundle: LanguageManager.appBundle) : String(localized: "down", bundle: LanguageManager.appBundle)) \(String(format: "%.0f", locale: LanguageManager.appLocale, abs(pctDiff))) percent versus average of \(formatValue(average))", bundle: LanguageManager.appBundle))
    }

    private var valueColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric)
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(formatValue(current))
                    .font(.system(.headline, design: .rounded).bold())
                    .foregroundColor(trendColor)
                Text(unit)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
    }

    private var trendColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: trendIcon)
                    .font(.caption2)
                    .foregroundColor(trendColor)
                Text(String(format: "%+.0f%%", locale: LanguageManager.appLocale, pctDiff))
                    .font(.caption.bold())
                    .foregroundColor(trendColor)
            }
            Text(String(localized: "vs avg \(formatValue(average))", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    private func formatValue(_ value: Double) -> String {
        if unit == "/10" || unit == "" {
            return String(format: "%.1f", locale: LanguageManager.appLocale, value)
        }
        return String(format: "%.0f", locale: LanguageManager.appLocale, value)
    }
}

// MARK: - Diagnostic Card

struct DiagnosticCard: View {
    let title: String
    let explanation: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            primaryAssessmentSection

            Text(explanation)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(color.opacity(0.08))
        .cornerRadius(AppTheme.cornerRadius)
    }

    private var primaryAssessmentSection: some View {
        HStack(spacing: 12) {
            assessmentGlyph
            assessmentTitle
            Spacer()
        }
    }

    private var assessmentGlyph: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.15))
                .frame(width: 44, height: 44)
            Image(systemName: icon)
                .scaledFont(size: 20, weight: .semibold)
                .foregroundColor(color)
        }
    }

    private var assessmentTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundColor(color)
            Text(String(localized: "Primary Assessment", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }
}

// MARK: - Probable Cause Row

struct ProbableCauseRow: View {
    let rank: Int
    let cause: String
    /// Display text, possibly translated.
    let confidence: String
    let explanation: String
    /// Untranslated `CauseConfidence` raw value that picks the badge colour;
    /// the display text can't, because it may be translated.
    var confidenceLevel: String?

    private var confidenceColor: Color {
        switch DetectedCause.CauseConfidence(rawValue: confidenceLevel ?? confidence) {
        case .critical, .veryHigh: AppTheme.dustyRose
        case .high: AppTheme.terracotta
        case .moderateHigh: AppTheme.softGold
        case .moderate: AppTheme.mist
        case .pattern, .contributingFactor, .goodSign, .excellent: AppTheme.sage
        case .lowModerate, .low, .none: AppTheme.textTertiary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            rankedCauseRow

            Text(explanation)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(AppTheme.sectionTint)
        .cornerRadius(AppTheme.smallCornerRadius)
    }

    private var rankedCauseRow: some View {
        HStack {
            Text("\(rank).")
                .font(.caption.bold())
                .foregroundColor(AppTheme.textTertiary)
            Text(cause)
                .font(.subheadline.bold())
                .foregroundColor(AppTheme.textPrimary)
            Spacer()
            Text(confidence)
                .font(.caption2.bold())
                .foregroundColor(confidenceColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(confidenceColor.opacity(0.15))
                .cornerRadius(6)
        }
    }
}
