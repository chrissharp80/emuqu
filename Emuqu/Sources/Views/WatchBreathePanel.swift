import SwiftUI

/// The Apple Watch Breathe capture panel: wait for a session, show the SDNN it
/// produced, and offer to save it — with HealthKit diagnostics underneath so a
/// user seeing nothing can tell whether Watch data is reaching Health at all.
///
/// Its own type rather than an extension on `RecordView` because every one of
/// these views is a function of values passed in, and `RecordView` is over the
/// aggregate type-size threshold. The actions stay on `RecordView`, which owns
/// the state they mutate; this takes them as closures so the panel can be read,
/// and changed, without the record screen in view.
struct WatchBreathePanel: View {
    /// The reading Health handed over, or nil while still listening.
    let reading: HealthKitManager.BreatheHRVReading?
    let saved: Bool
    let isWaiting: Bool
    /// The 5-minute listen ended without a session.
    var timedOut = false
    /// When the HealthKit observer started, for the elapsed row.
    let listenStartDate: Date?
    let diagnostics: HealthKitManager.BreatheDiagnostics?
    let onSave: (HealthKitManager.BreatheHRVReading) -> Void
    let onDismiss: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            watchBreatheSection2

            breatheSessionDetectedSection
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private var watchBreatheSection2: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Watch Breathe", bundle: LanguageManager.appBundle))
                    .font(.headline)
                Text(String(localized: "SDNN from Apple Watch", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
            Spacer()
            if isWaiting {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var breatheSessionDetectedSection: some View {
        if let reading {
            breatheReadingResult(reading)
        } else {
            breatheListeningState
        }
    }

    /// Reading received — show result
    private func breatheReadingResult(_ reading: HealthKitManager.BreatheHRVReading) -> some View {
        VStack(spacing: 12) {
            breatheResultHeader(reading)

            breatheResultValue(reading)

            breatheSaveActions(reading)
        }
    }

    private func breatheResultHeader(_ reading: HealthKitManager.BreatheHRVReading) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(AppTheme.sage)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Breathe session detected", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.medium))
                Text(reading.sourceName)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func breatheSaveActions(_ reading: HealthKitManager.BreatheHRVReading) -> some View {
        if !saved {
            breatheSaveButtons(reading)
        } else {
            breatheSavedConfirmation
        }
    }

    private func breatheSaveButtons(_ reading: HealthKitManager.BreatheHRVReading) -> some View {
        HStack(spacing: 12) {
            Button {
                onSave(reading)
            } label: {
                Label(String(localized: "Save to History", bundle: LanguageManager.appBundle), systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.zen(AppTheme.sage))

            dismissButton
                .buttonStyle(.zenSecondary)
        }
    }

    private var breatheSavedConfirmation: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(AppTheme.sage)
            Text(String(localized: "Saved to history", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.sageText)
        }
    }

    /// Listening — auto-started when source was selected
    private var breatheListeningState: some View {
        VStack(spacing: 16) {
            if timedOut {
                Text(String(localized: "No Breathe session arrived within 5 minutes. Tap Watch Breathe to listen again.", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
            }
            breatheListeningHeader

            breatheElapsedRow

            breatheDiagnosticsRow

            breatheCancelButton
        }
    }

    private var breatheListeningHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: "applewatch")
                .scaledFont(size: 40)
                .foregroundColor(AppTheme.primary)
            Text(String(localized: "Open the Breathe app on your Apple Watch and complete a session", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var breatheElapsedRow: some View {
        if let listenStartDate {
            breatheElapsedLabel(listenStartDate)
        }
    }

    /// Diagnostics — shows whether Watch data is reaching HealthKit at all
    @ViewBuilder
    private var breatheDiagnosticsRow: some View {
        if let diagnostics {
            breatheDiagnosticsView(diagnostics)
        }
    }

    private var breatheCancelButton: some View {
        Button {
            onCancel()
        } label: {
            Text(String(localized: "Back", bundle: LanguageManager.appBundle))
        }
        .buttonStyle(.zenSecondary)
    }

    private var dismissButton: some View {
        Button {
            onDismiss()
        } label: {
            Text(String(localized: "Dismiss", bundle: LanguageManager.appBundle))
        }
    }

    private func breatheDiagnosticsView(_ diag: HealthKitManager.BreatheDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text(String(localized: "Apple Health Status", bundle: LanguageManager.appBundle))
                .font(.caption2.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
            sdnnDiagnosticRows(diag)
            mindfulDiagnosticRow(diag)
            Text(String(localized: "24h: \(diag.sdnnCount24h) SDNN, \(diag.mindfulSessionCount24h) mindful sessions", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    @ViewBuilder
    private func sdnnDiagnosticRows(_ diag: HealthKitManager.BreatheDiagnostics) -> some View {
        if let date = diag.lastSDNNDate, let value = diag.lastSDNNValue, let source = diag.lastSDNNSource {
            diagnosticRow(icon: "checkmark.circle.fill", tint: AppTheme.sage) {
                Text("Last SDNN: \(String(format: "%.0f", locale: LanguageManager.appLocale, value))ms — \(date, style: .relative) ago", bundle: LanguageManager.appBundle)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textSecondary)
            }
            Text(String(localized: "Source: \(source)", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        } else {
            diagnosticRow(icon: "exclamationmark.triangle.fill", tint: AppTheme.warning) {
                Text(String(localized: "No SDNN data found in Apple Health", bundle: LanguageManager.appBundle))
                    .font(.caption2)
                    .foregroundColor(AppTheme.warning)
            }
            Text(String(localized: "Check Health app → Heart → Heart Rate Variability", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    @ViewBuilder
    private func mindfulDiagnosticRow(_ diag: HealthKitManager.BreatheDiagnostics) -> some View {
        if let date = diag.lastMindfulDate {
            diagnosticRow(icon: "checkmark.circle.fill", tint: AppTheme.sage) {
                Text("Last Mindful session: \(date, style: .relative) ago", bundle: LanguageManager.appBundle)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textSecondary)
            }
        } else {
            diagnosticRow(icon: "exclamationmark.triangle.fill", tint: AppTheme.warning) {
                Text(String(localized: "No Mindful Sessions found — has the Breathe app been used?", bundle: LanguageManager.appBundle))
                    .font(.caption2)
                    .foregroundColor(AppTheme.warning)
            }
        }
    }

    private func diagnosticRow(icon: String, tint: Color, @ViewBuilder label: () -> some View) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(tint)
                .font(.caption2)
            label()
        }
    }
}

@MainActor
private func breatheResultValue(_ reading: HealthKitManager.BreatheHRVReading) -> some View {
    HStack(alignment: .lastTextBaseline, spacing: 4) {
        Text(String(format: "%.0f", locale: .current, reading.sdnn))
            .scaledFont(size: 36, weight: .bold)
            .foregroundColor(AppTheme.sdnnColor)
        Text(String(localized: "ms SDNN", bundle: LanguageManager.appBundle))
            .font(.subheadline)
            .foregroundColor(AppTheme.textSecondary)
        Spacer()
        Text(reading.date, style: .time)
            .font(.caption)
            .foregroundColor(AppTheme.textSecondary)
    }
}

@MainActor
private func breatheElapsedLabel(_ start: Date) -> some View {
    HStack(spacing: 6) {
        ProgressView()
            .scaleEffect(0.8)
        TimelineView(.periodic(from: start, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(start))
            let minutes = elapsed / 60
            let seconds = elapsed % 60
            Text(String(localized: "Listening... \(String(format: "%d:%02d", minutes, seconds))", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
                .monospacedDigit()
        }
    }
}
