import SwiftUI

/// The "Data Quality" card shown after a reading: artifact percentage, clean
/// beat count, the analysis window when one was selected, and any errors or
/// warnings the verifier raised.
///
/// Its own type rather than an extension on `RecordView` because it is a pure
/// function of a `Verification.Result` — it reads no record-screen state and
/// changes none — and `RecordView` is over the aggregate type-size threshold.
/// Splitting a view that already takes all its input as parameters costs
/// nothing and removes it from a type that has to shrink.
struct RecordVerificationSection: View {
    let verification: Verification.Result
    /// The window the analyser settled on, when one was selected. Nil for a
    /// reading short enough that the whole recording was the window.
    let recoveryWindow: WindowSelector.RecoveryWindow?

    var body: some View {
        VStack(spacing: 12) {
            header
            windowRows
            metricRows
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private var header: some View {
        HStack {
            Text(String(localized: "Data Quality", bundle: LanguageManager.appBundle))
                .font(.headline)
            Spacer()
            Self.qualityBadge(verification.passed)
        }
    }

    @ViewBuilder
    private var windowRows: some View {
        if let recoveryWindow {
            analysisWindowDurationRow(recoveryWindow)
            analysisWindowQualityRow(recoveryWindow)
            Text(String(localized: "Best window from the middle of your sleep", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var metricRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Self.qualityRow(
                String(localized: "Artifact %", bundle: LanguageManager.appBundle),
                value: String(format: "%.1f%%", locale: .current, verification.metrics.artifactPercent),
                isGood: verification.metrics.artifactPercent < 10
            )
            Self.qualityRow(
                String(localized: "Clean Beats", bundle: LanguageManager.appBundle),
                value: "\(verification.metrics.nnCount)",
                isGood: verification.metrics.nnCount >= 200
            )
            ForEach(verification.errors, id: \.self) { error in
                verificationNote(error, icon: "xmark.circle.fill", tint: .red)
            }
            ForEach(verification.warnings, id: \.self) { warning in
                verificationNote(warning, icon: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }

    /// Static so the morning-results screen can reuse the same badge without
    /// instantiating a whole section.
    static func qualityBadge(_ passed: Bool) -> some View {
        Text(passed
            ? String(localized: "Good", bundle: LanguageManager.appBundle)
            : String(localized: "Issues Found", bundle: LanguageManager.appBundle))
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background((passed ? Color.green : Color.orange).opacity(0.2))
            .foregroundColor(passed ? .green : .orange)
            .cornerRadius(8)
    }

    static func qualityRow(_ label: String, value: String, isGood: Bool) -> some View {
        HStack {
            Text(label)
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: isGood ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundColor(isGood ? .green : .orange)
                    .font(.caption)
                Text(value)
            }
        }
        .font(.subheadline)
    }
}

@MainActor
private func analysisWindowDurationRow(_ window: WindowSelector.RecoveryWindow) -> some View {
    let durationMinutes = Double(window.endMs - window.startMs) / 60000.0
    return HStack {
        Text(String(localized: "Analysis Window", bundle: LanguageManager.appBundle))
        Spacer()
        Text(String(localized: "\(durationMinutes, specifier: "%.1f") min", bundle: LanguageManager.appBundle))
            .foregroundColor(AppTheme.textSecondary)
    }
    .font(.subheadline)
}

@MainActor
private func analysisWindowQualityRow(_ window: WindowSelector.RecoveryWindow) -> some View {
    HStack {
        Text(String(localized: "Quality", bundle: LanguageManager.appBundle))
        Spacer()
        Text("\(window.qualityScore * 100, specifier: "%.0f")%")
            .foregroundColor(AppTheme.textSecondary)
    }
    .font(.subheadline)
}

private func verificationNote(_ text: String, icon: String, tint: Color) -> some View {
    HStack {
        Image(systemName: icon)
            .foregroundColor(tint)
            .font(.caption)
        Text(text)
            .font(.caption)
            .foregroundColor(tint)
    }
}
