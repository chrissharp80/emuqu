import SwiftUI

// MARK: - Morning Processing Card

/// Card shown during the stop -> analyze flow after tapping "I'm Up."
/// Shows a clean progress indicator. In the normal streaming-first flow
/// this appears briefly; in the device-fetch fallback it shows longer
/// with a skip button.
struct MorningProcessingCard: View {
    let status: RRCollector.MorningProcessingStatus
    let onSkipDeviceFetch: () -> Void
    var onSkipSleepWait: (() -> Void)?

    /// Number formatter for beat counts, in the app language.
    private static var beatFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = LanguageManager.appLocale
        return f
    }

    var body: some View {
        VStack(spacing: 16) {
            processingProgress

            beatCountRow

            deviceFetchSection

            skipDeviceFetchButton

            skipSleepWaitButton
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .animation(.easeInOut(duration: 0.3), value: status)
    }

    /// Progress indicator
    private var processingProgress: some View {
        VStack(spacing: 12) {
            if isProcessingComplete(status) {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(size: 36)
                    .foregroundColor(AppTheme.sage)
            } else {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(AppTheme.sage)
            }

            Text(processingStepMessage(status))
                .font(.subheadline.weight(.medium))
                .foregroundColor(isProcessingComplete(status) ? AppTheme.sage : AppTheme.textPrimary)
        }
        .padding(.top, 12)
    }

    /// Beat count (compact, secondary — not the hero element)
    @ViewBuilder
    private var beatCountRow: some View {
        if beatCount(for: status) > 0 {
            Text(String(localized: "\(formatBeats(beatCount(for: status))) heartbeats", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    /// Device fetch details — only shown during device-fetch fallback
    @ViewBuilder
    private var deviceFetchSection: some View {
        if showsDeviceFetchSection(status) {
            deviceFetchDetails
        }
    }

    private var deviceFetchDetails: some View {
        VStack(spacing: 8) {
            dataSourceRow(
                label: String(localized: "Streamed", bundle: LanguageManager.appBundle),
                value: formattedStreamedValue(for: status),
                icon: "checkmark"
            )
            dataSourceRow(
                label: String(localized: "Device", bundle: LanguageManager.appBundle),
                value: deviceRowValue(for: status),
                icon: deviceRowIcon(for: status)
            )
            if let source = sourceLabel(for: status) {
                dataSourceRow(
                    label: String(localized: "Source", bundle: LanguageManager.appBundle),
                    value: source,
                    icon: nil
                )
            }
        }
        .padding(.horizontal, 4)
    }

    private func useStreamedBeatsLabel(_ streamingBeats: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "forward.fill")
            Text(String(localized: "Use \(formatBeats(streamingBeats)) streamed beats", bundle: LanguageManager.appBundle))
        }
        .font(.subheadline.weight(.medium))
        .frame(maxWidth: .infinity)
    }

    /// Skip button — shown only during device fetch fallback
    @ViewBuilder
    private var skipDeviceFetchButton: some View {
        if case let .fetchingDevice(streamingBeats) = status {
            Button {
                onSkipDeviceFetch()
            } label: {
                useStreamedBeatsLabel(streamingBeats)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .padding(.top, 4)

            Text(String(localized: "Your streamed data is safe. Device backup is optional.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    /// Skip button — shown during sleep data polling
    @ViewBuilder
    private var skipSleepWaitButton: some View {
        if case .waitingForSleep = status, let onSkipSleepWait {
            skipSleepWaitPrompt(onSkipSleepWait)
        }
    }

    private func skipSleepWaitPrompt(_ skip: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Text(String(localized: "This isn't downloading from the strap. We're waiting for Apple Watch to write last night's sleep to Health.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
            skipSleepWaitAction(skip)
        }
        .padding(.top, 4)
    }

    private func skipSleepWaitAction(_ skip: @escaping () -> Void) -> some View {
        Button {
            skip()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "forward.fill")
                Text(String(localized: "Skip — analyze without sleep data", bundle: LanguageManager.appBundle))
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.secondary)
    }

    // MARK: - Helpers

    private func formatBeats(_ count: Int) -> String {
        Self.beatFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private func beatCount(for status: RRCollector.MorningProcessingStatus) -> Int {
        switch status {
        case let .saving(beats): beats
        case let .fetchingDevice(beats): beats
        case let .waitingForSleep(beats, _): beats
        case let .analyzing(beats, _, _, _): beats
        case let .complete(beats, _, _, _): beats
        }
    }

    private func processingStepMessage(_ status: RRCollector.MorningProcessingStatus) -> String {
        switch status {
        case .saving: String(localized: "Securing data...", bundle: LanguageManager.appBundle)
        case .fetchingDevice: String(localized: "Downloading from strap...", bundle: LanguageManager.appBundle)
        // Be explicit it's an Apple Watch / Health sync we're waiting on — the
        // user reported assuming the spinner meant "downloading from the
        // strap" (which doesn't happen for streaming-only sessions). Calling
        // out HealthKit explicitly removes the ambiguity.
        case .waitingForSleep: String(localized: "Waiting for Apple Watch sleep data...", bundle: LanguageManager.appBundle)
        case .analyzing: String(localized: "Calculating your score...", bundle: LanguageManager.appBundle)
        case .complete: String(localized: "Ready", bundle: LanguageManager.appBundle)
        }
    }

    private func isProcessingComplete(_ status: RRCollector.MorningProcessingStatus) -> Bool {
        if case .complete = status { return true }
        return false
    }

    /// Device fetch detail rows are only shown during the fallback path
    /// (when streaming data was insufficient and we had to wait for device data).
    private func showsDeviceFetchSection(_ status: RRCollector.MorningProcessingStatus) -> Bool {
        switch status {
        case .fetchingDevice: true
        case let .analyzing(_, _, deviceBeats, _) where deviceBeats != nil: true
        case let .complete(_, _, deviceBeats, _) where deviceBeats != nil: true
        default: false
        }
    }

    private func formattedStreamedValue(for status: RRCollector.MorningProcessingStatus) -> String {
        switch status {
        case let .saving(beats): formatBeats(beats)
        case let .fetchingDevice(beats): formatBeats(beats)
        case let .waitingForSleep(beats, _): formatBeats(beats)
        case let .analyzing(_, streamedBeats, _, _): formatBeats(streamedBeats)
        case let .complete(_, streamedBeats, _, _): formatBeats(streamedBeats)
        }
    }

    private func deviceRowValue(for status: RRCollector.MorningProcessingStatus) -> String {
        switch status {
        case .saving, .waitingForSleep: return ""
        case .fetchingDevice: return String(localized: "Retrieving...", bundle: LanguageManager.appBundle)
        case let .analyzing(_, _, deviceBeats, _), let .complete(_, _, deviceBeats, _):
            if let db = deviceBeats {
                return formatBeats(db)
            }
            return "\u{2014}"
        }
    }

    private func deviceRowIcon(for status: RRCollector.MorningProcessingStatus) -> String? {
        switch status {
        case .saving, .waitingForSleep: nil
        case .fetchingDevice: nil // spinner shown instead
        case let .analyzing(_, _, deviceBeats, _), let .complete(_, _, deviceBeats, _):
            deviceBeats != nil ? "checkmark" : "minus"
        }
    }

    private func sourceLabel(for status: RRCollector.MorningProcessingStatus) -> String? {
        switch status {
        case .saving, .fetchingDevice, .waitingForSleep: nil
        case let .analyzing(_, _, _, source), let .complete(_, _, _, source):
            switch source {
            case "composite": String(localized: "Streamed + Strap", bundle: LanguageManager.appBundle)
            case "internal": String(localized: "Strap", bundle: LanguageManager.appBundle)
            case "streaming": String(localized: "Streamed", bundle: LanguageManager.appBundle)
            // An unrecognised raw tag has no translation; show no row
            // rather than untranslated English.
            default: nil
            }
        }
    }

    private func dataSourceRow(label: String, value: String, icon: String?) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .frame(width: 80, alignment: .leading)
            Spacer()
            dataSourceValue(value: value, icon: icon)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(AppTheme.sectionTint)
        .cornerRadius(AppTheme.smallCornerRadius)
    }

    private func dataSourceValue(value: String, icon: String?) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(AppTheme.textPrimary)
            if let icon {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(icon == "checkmark" ? .green : .secondary)
            }
        }
    }
}
