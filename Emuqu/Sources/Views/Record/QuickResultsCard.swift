import SwiftUI

// MARK: - Quick Results Preview Card

/// Post-recording results card for quick/streaming readings.
/// Shows key metrics (RMSSD, HR, readiness) with options to view the full report or dismiss.
struct QuickResultsCard: View {
    @Environment(\.dependencies) var dependencies
    let session: HRVSession
    let result: HRVAnalysisResult
    let onViewReport: () -> Void
    let onDone: () -> Void

    private var settingsManager: SettingsManager { dependencies.app.settingsManager }
    var body: some View {
        v2Body
    }

    /// Build plan §4.3 R3.4 — score reveal card.
    /// Hero ScoreRing (verdict-coloured) + verdict word + one-line interpretation,
    /// View Full Report + Done buttons.
    private var v2Body: some View {
        let score10 = session.recoveryScore ?? (result.ansMetrics?.readinessScore ?? 5)
        let score = ScoreVerdict.safeDisplayScore(score10 * 10)
        let verdict = ScoreVerdict(score: Double(score))
        return VStack(spacing: 18) {
            quickResultsHeader
            ScoreRing(state: .default(score: score, verdict: verdict), size: .card, snappy: true)
                .frame(width: 120, height: 120)
            verdictText(verdict)
            quickResultsMetrics
            viewFullReportButton
                .buttonStyle(.plain)
            quickResultsDoneButton
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(AppTheme.cardBackground))
    }

    private var quickResultsHeader: some View {
        HStack {
            Text(String(localized: "Reading complete", bundle: LanguageManager.appBundle))
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
            Text(session.startDate, format: .dateTime.hour().minute())
                .scaledFont(size: 12)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private func verdictText(_ verdict: ScoreVerdict) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: verdict.word)
                .scaledFont(size: 22, weight: .semibold)
                .foregroundStyle(verdict.color)
            Text(verbatim: verdict.subverdict)
                .scaledFont(size: 14)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    /// Readiness replaces SDNN in the third slot when the ANS metrics computed —
    /// it's the more actionable of the two.
    private var quickResultsMetrics: some View {
        HStack(spacing: 10) {
            v2Stat(label: "RMSSD", value: String(Int(result.timeDomain.rmssd.rounded())), unit: "ms")
            v2Stat(label: "Sleep HR", value: String(Int(result.timeDomain.meanHR.rounded())), unit: "bpm")
            if let r = result.ansMetrics?.readinessScore {
                v2Stat(label: "Ready", value: String(format: "%.1f", locale: .current, r), unit: "/10")
            } else {
                v2Stat(label: "SDNN", value: String(Int(result.timeDomain.sdnn.rounded())), unit: "ms")
            }
        }
    }

    private var quickResultsDoneButton: some View {
        Button(action: onDone) {
            Text(String(localized: "Done", bundle: LanguageManager.appBundle))
                .scaledFont(size: 14)
                .foregroundStyle(AppTheme.primary)
        }
        .buttonStyle(.plain)
    }

    private var viewFullReportButton: some View {
        Button(action: onViewReport) {
            Text(String(localized: "View full report", bundle: LanguageManager.appBundle))
                .scaledFont(size: 16, weight: .semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(AppTheme.primary))
                .foregroundStyle(.white)
        }
    }

    private func v2Stat(label: String, value: String, unit: String) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: label)
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(AppTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: value)
                    .scaledFont(size: 18, weight: .semibold, design: .rounded, monospacedDigit: true)
                    .foregroundStyle(AppTheme.textPrimary)
                Text(verbatim: unit)
                    .scaledFont(size: 11)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(AppTheme.sectionTint))
    }

}
