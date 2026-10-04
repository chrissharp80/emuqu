import SwiftUI

/// Peak Capacity card showing the highest sustained HRV metrics.
/// Used by SessionHRVDetailView.
struct PeakCapacityCard: View {
    let capacity: PeakCapacity
    var showInfoButton: Bool = false

    @State private var showingInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // Metrics row
            metricsRowSection

            // Brief explanation
            Text(String(localized: "Highest sustained HRV during sleep — your physiological ceiling, separate from readiness.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .zenCard()
    }

    @ViewBuilder
    private var header: some View {
        if showInfoButton {
            Button {
                showingInfo = true
            } label: {
                headerContent
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingInfo) {
                CapacityExplanationPopover()
            }
        } else {
            headerContent
        }
    }

    private var metricsRowSection: some View {
        HStack(spacing: 16) {
            // Peak RMSSD
            peakRmssdSection
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Max RMSSD: \(String(format: "%.0f", locale: LanguageManager.appLocale, capacity.peakRMSSD)) milliseconds", bundle: LanguageManager.appBundle))

            Divider()
                .frame(height: 36)
                .accessibilityHidden(true)

            // Peak SDNN
            peakSdnnSection
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Max SDNN: \(String(format: "%.0f", locale: LanguageManager.appLocale, capacity.peakSDNN)) milliseconds", bundle: LanguageManager.appBundle))

            // Window HR (if available)
            windowHrIfAvailableSection
        }
    }

    private var peakRmssdSection: some View {
        VStack(spacing: 2) {
            Text(String(localized: "Max RMSSD", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(String(format: "%.0f", locale: LanguageManager.appLocale, capacity.peakRMSSD))
                    .scaledFont(size: 24, weight: .bold)
                    .foregroundColor(AppTheme.sageText)
                Text(String(localized: "ms", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
    }

    private var peakSdnnSection: some View {
        VStack(spacing: 2) {
            Text(String(localized: "Max SDNN", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(String(format: "%.0f", locale: LanguageManager.appLocale, capacity.peakSDNN))
                    .scaledFont(size: 24, weight: .bold)
                    .foregroundColor(AppTheme.sdnnColor)
                Text(String(localized: "ms", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var windowHrIfAvailableSection: some View {
        if let meanHR = capacity.windowMeanHR {
            Divider()
                .frame(height: 36)
                .accessibilityHidden(true)

            windowHrColumn(meanHR)
        }
    }

    private func windowHrColumn(_ meanHR: Double) -> some View {
        VStack(spacing: 2) {
            Text(String(localized: "Window HR", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
            windowHrValue(meanHR)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Window heart rate: \(String(format: "%.0f", locale: LanguageManager.appLocale, meanHR)) beats per minute", bundle: LanguageManager.appBundle))
    }

    private func windowHrValue(_ meanHR: Double) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text(String(format: "%.0f", locale: LanguageManager.appLocale, meanHR))
                .scaledFont(size: 24, weight: .bold)
                .foregroundColor(AppTheme.terracottaText)
            Text(String(localized: "bpm", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    private var headerContent: some View {
        HStack {
            capacityHeaderRow
            Spacer()
            Text(String(localized: "\(String(format: "%.0f", locale: LanguageManager.appLocale, capacity.windowDurationMinutes)) min window", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    private var capacityHeaderRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.to.line")
                .foregroundColor(AppTheme.sage)
            Text(String(localized: "Autonomic Capacity", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)
            if showInfoButton {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
    }
}

/// Popover explaining autonomic capacity vs readiness
struct CapacityExplanationPopover: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            autonomicCapacitySection

            Text(String(localized: "The highest sustained HRV values observed during your sleep — your physiological ceiling, not a readiness indicator.", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)

            whatItMeasuresSection

            Divider()

            Text(String(localized: "High capacity ≠ high readiness. Your body may achieve peak HRV during deep sleep while still being fatigued overall.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
                .italic()
        }
        .padding()
        .frame(width: 300)
        .background(AppTheme.cardBackground)
    }

    private var autonomicCapacitySection: some View {
        HStack {
            Text(String(localized: "Autonomic Capacity", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppTheme.textTertiary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(String(localized: "Close", bundle: LanguageManager.appBundle))
        }
    }

    private var whatItMeasuresSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "What it measures:", bundle: LanguageManager.appBundle))
                .font(.caption.bold())
                .foregroundColor(AppTheme.textPrimary)

            measuresRow(
                glyph: "arrow.up.circle.fill",
                tint: AppTheme.sage,
                text: String(localized: "Peak parasympathetic activation during deep sleep", bundle: LanguageManager.appBundle)
            )

            measuresRow(
                glyph: "clock.fill",
                tint: AppTheme.mist,
                text: String(localized: "Sustained window (not isolated spikes)", bundle: LanguageManager.appBundle)
            )
        }
    }

    private func measuresRow(glyph: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
                .foregroundColor(tint)
                .font(.caption)
            Text(text)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
    }
}
