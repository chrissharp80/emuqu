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

    /// Score reveal card.
    /// Hero ScoreRing (verdict-coloured) + verdict word + one-line interpretation,
    /// View Full Report + Done buttons.
    private var v2Body: some View {
        VStack(spacing: 18) {
            quickResultsHeader
            ScoreRing(state: ringState, size: .card, snappy: true)
                .frame(width: 120, height: 120)
            if let verdict = scoredVerdict { verdictText(verdict) }
            quickResultsMetrics
            viewFullReportButton
                .buttonStyle(.plain)
            quickResultsDoneButton
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(AppTheme.cardBackground))
    }

    /// The recovery score, else the ANS readiness (both 0–10). Nil when the
    /// reading produced neither, so no made-up score is shown.
    private var score10: Double? {
        session.recoveryScore ?? result.ansMetrics?.readinessScore
    }

    private var scoredVerdict: ScoreVerdict? {
        score10.map { ScoreVerdict(score: Double(ScoreVerdict.safeDisplayScore($0 * 10))) }
    }

    private var ringState: ScoreRing.DisplayState {
        guard let score10, let verdict = scoredVerdict else { return .noData }
        return .default(score: ScoreVerdict.safeDisplayScore(score10 * 10), verdict: verdict)
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
            Text(verbatim: verdict.localizedWord)
                .scaledFont(size: 22, weight: .semibold)
                .foregroundStyle(verdict.textColor)
            Text(verbatim: verdict.localizedSubverdict)
                .scaledFont(size: 14)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    /// Readiness replaces SDNN in the third slot when the ANS metrics computed —
    /// it's the more actionable of the two.
    private var quickResultsMetrics: some View {
        HStack(spacing: 10) {
            v2Stat(label: "RMSSD", value: String(Int(result.timeDomain.rmssd.rounded())), unit: Self.msUnit)
            v2Stat(
                label: String(localized: "Avg HR", bundle: LanguageManager.appBundle),
                value: String(Int(result.timeDomain.meanHR.rounded())),
                unit: String(localized: "bpm", bundle: LanguageManager.appBundle)
            )
            if let r = result.ansMetrics?.readinessScore {
                v2Stat(
                    label: String(localized: "Readiness", bundle: LanguageManager.appBundle),
                    value: String(format: "%.1f", locale: LanguageManager.appLocale, r),
                    unit: "/10"
                )
            } else {
                v2Stat(label: "SDNN", value: String(Int(result.timeDomain.sdnn.rounded())), unit: Self.msUnit)
            }
        }
    }

    private static var msUnit: String { String(localized: "ms", bundle: LanguageManager.appBundle) }

    private var quickResultsDoneButton: some View {
        Button(action: onDone) {
            Text(String(localized: "Done", bundle: LanguageManager.appBundle))
                .scaledFont(size: 14)
                .foregroundStyle(AppTheme.primary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
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
            v2StatValue(value, unit: unit)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(AppTheme.sectionTint))
        // One element: VoiceOver read the label, the number and the unit as
        // three stops.
        .accessibilityElement(children: .combine)
    }

    private func v2StatValue(_ value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(verbatim: value)
                .scaledFont(size: 18, weight: .semibold, design: .rounded, monospacedDigit: true)
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: unit)
                .scaledFont(size: 11)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

}
