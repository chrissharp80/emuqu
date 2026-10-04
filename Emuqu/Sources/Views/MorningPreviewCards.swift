import SwiftUI

/// The read-only half of the morning results preview: the date header, the
/// three metric cards, and the card's own background.
///
/// Split off `RecordView` because none of it reads record-screen state — it is
/// a function of the session and its analysis — and `RecordView` is over the
/// aggregate type-size threshold. The buttons and the fetch indicator stay
/// behind, because those act on state this has no business holding.
@MainActor
enum MorningPreviewCards {
    static func header(_ session: HRVSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Analysis Ready", bundle: LanguageManager.appBundle))
                    .font(.headline)
                    .foregroundStyle(AppTheme.primaryGradient)
                Text(session.startDate, style: .date)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
            Spacer()
            Image(systemName: "waveform.path.ecg")
                .font(.title2)
                .foregroundStyle(AppTheme.primaryGradient)
        }
    }

    static func metrics(_ result: HRVAnalysisResult) -> some View {
        HStack(spacing: 16) {
            MetricPreviewCard(
                title: "RMSSD",
                value: String(format: "%.0f", locale: LanguageManager.appLocale, result.timeDomain.rmssd),
                unit: String(localized: "ms", bundle: LanguageManager.appBundle),
                color: AppTheme.primary
            )
            readiness(result)
            MetricPreviewCard(
                title: String(localized: "HR", bundle: LanguageManager.appBundle),
                value: String(format: "%.0f", locale: LanguageManager.appLocale, result.timeDomain.meanHR),
                unit: String(localized: "bpm", bundle: LanguageManager.appBundle),
                color: AppTheme.accent
            )
        }
    }

    /// Absent when the analysis produced no readiness score — an early or very
    /// short recording — rather than shown as a zero.
    @ViewBuilder
    static func readiness(_ result: HRVAnalysisResult) -> some View {
        if let readiness = result.ansMetrics?.readinessScore {
            MetricPreviewCard(
                title: String(localized: "Readiness", bundle: LanguageManager.appBundle),
                value: String(format: "%.1f", locale: LanguageManager.appLocale, readiness),
                unit: "/10",
                color: AppTheme.readinessColor(readiness)
            )
        }
    }

    static var background: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(.secondarySystemGroupedBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(AppTheme.primaryGradient, lineWidth: 2)
            )
    }
}
