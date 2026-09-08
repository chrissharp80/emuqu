import SwiftUI

// MARK: - Recoverable Data Section

/// Shown when the connected device has stored recording data from a previous session
/// that can be recovered (completed recordings or an active recording still running).
struct RecoverableDataCard: View {
    let deviceName: String
    let onRecover: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            recoveryPromptHeader

            Text(String(localized: "Your device has stored recording data from a previous session. You can recover this data now or start a new recording (which will clear the old data).", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.leading)
            recoverDataButton
            discardStartFreshButton
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.primary.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AppTheme.primary.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private var recoveryPromptHeader: some View {
        HStack {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .foregroundColor(AppTheme.primary)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Data Found on \(deviceName)", bundle: LanguageManager.appBundle))
                    .font(.headline)
                    .foregroundColor(AppTheme.primary)
                Text(String(localized: "Previous recording available to recover", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
            Spacer()
        }
    }

    private var recoverDataButton: some View {
        Button(action: onRecover) {
            Label(String(localized: "Recover Data", bundle: LanguageManager.appBundle), systemImage: "arrow.down.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.primary)
    }

    private var discardStartFreshButton: some View {
        Button(action: onDiscard) {
            Text(String(localized: "Discard & Start Fresh", bundle: LanguageManager.appBundle))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .foregroundColor(.red)
    }
}

// MARK: - Fetch Progress View

/// Shows the progress of a data fetch from the device (stopping, listing, downloading, etc.).
struct FetchProgressCard: View {
    let progress: PolarManager.FetchProgress
    let deviceName: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            statusRow
            progressBar
            percentageRow
            cancelFetchButton
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius)
                .fill(progressBackgroundColor(for: progress.stage))
        )
    }

    /// Status icon and message.
    private var statusRow: some View {
        HStack(spacing: 10) {
            progressIcon(for: progress.stage)
                .font(.title2)
                .foregroundColor(progressColor(for: progress.stage))
            statusText
            Spacer()
            inFlightSpinner
        }
    }

    private var statusText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(progress.statusMessage.isEmpty ? progress.stage.rawValue : progress.statusMessage)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(AppTheme.textPrimary)

            if progress.attempt > 1 {
                Text(String(localized: "Attempt \(progress.attempt) of \(progress.maxAttempts)", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder
    private var inFlightSpinner: some View {
        if progress.stage != .complete, progress.stage != .failed {
            ProgressView()
                .scaleEffect(0.8)
        }
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            progressTrack(width: geometry.size.width)
        }
        .frame(height: 8)
    }

    private func progressTrack(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            // Background
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.2))
                .frame(height: 8)

            // Progress fill
            RoundedRectangle(cornerRadius: 4)
                .fill(progressColor(for: progress.stage))
                .frame(width: width * progress.progress, height: 8)
                .animation(.easeInOut(duration: 0.3), value: progress.progress)
        }
    }

    /// Percentage, and the reassurance that nothing is lost if the fetch
    /// stalls — the data is still on the strap.
    private var percentageRow: some View {
    HStack {
        Text("\(Int(progress.progress * 100))%")
            .font(.caption)
            .foregroundColor(AppTheme.textSecondary)
            .monospacedDigit()
        Spacer()
        if progress.stage == .retrying || progress.stage == .failed {
            Text(String(localized: "Data is safe on \(deviceName)", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
    }
    }

    /// Always available during a fetch.
    @ViewBuilder
    private var cancelFetchButton: some View {
    if progress.stage != .complete {
        Button(action: onCancel) {
            Label(String(localized: "Cancel", bundle: LanguageManager.appBundle), systemImage: "xmark.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.secondary)
    }
    }

    // MARK: - Progress Helpers

    private func progressIcon(for stage: PolarManager.FetchProgress.Stage) -> Image {
        switch stage {
        case .stopping:
            Image(systemName: "stop.circle")
        case .finalizing:
            Image(systemName: "externaldrive")
        case .listingExercises:
            Image(systemName: "magnifyingglass")
        case .fetchingData:
            Image(systemName: "arrow.down.circle")
        case .reconnecting:
            Image(systemName: "antenna.radiowaves.left.and.right")
        case .retrying:
            Image(systemName: "arrow.clockwise")
        case .complete:
            Image(systemName: "checkmark.circle.fill")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private func progressColor(for stage: PolarManager.FetchProgress.Stage) -> Color {
        switch stage {
        case .stopping, .finalizing, .listingExercises, .fetchingData:
            AppTheme.primary
        case .reconnecting, .retrying:
            .orange
        case .complete:
            AppTheme.sage
        case .failed:
            .red
        }
    }

    private func progressBackgroundColor(for stage: PolarManager.FetchProgress.Stage) -> Color {
        switch stage {
        case .reconnecting, .retrying:
            Color.orange.opacity(0.1)
        case .complete:
            AppTheme.sage.opacity(0.1)
        case .failed:
            Color.red.opacity(0.1)
        default:
            AppTheme.sectionTint
        }
    }
}

// MARK: - Retry Fetch Section

/// Shown when a data fetch has failed, allowing the user to retry or dismiss.
struct RetryFetchCard: View {
    let isRetrying: Bool
    let isConnected: Bool
    /// Humanised reason for the most recent failure, e.g. "Lost
    /// connection mid-transfer". When non-nil, replaces the generic
    /// "was not retrieved successfully" copy with something specific
    /// to the actual error so the user can pick the right next step
    /// (move closer / wait / restart strap). Pass through
    /// `PolarErrorMessages.humanize(_:)` upstream so SDK errors get
    /// translated.
    var errorReason: String?
    let onRetry: () -> Void
    let onCancelRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            fetchFailedHeader
            failureReasonText
            dataStaysOnStrapNote
            retryFetchButton
            cancelRetryButton
            dismissFailureButton
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private var fetchFailedHeader: some View {
        HStack {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.orange)
            .font(.title2)
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Data Fetch Failed", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundColor(.orange)
            Text(String(localized: "Your recording data is still on the device", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
        Spacer()
        }
    }

    @ViewBuilder
    private var failureReasonText: some View {
    if let reason = errorReason, !reason.isEmpty {
        Text(reason)
            .font(.subheadline)
            .foregroundColor(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    } else {
        Text(String(localized: "The recording data was not retrieved successfully. Don't worry — the data is still stored on your device. Try fetching again.", bundle: LanguageManager.appBundle))
            .font(.subheadline)
            .foregroundColor(AppTheme.textSecondary)
            .multilineTextAlignment(.leading)
    }
    }

    /// The data sticks around on the strap until a NEW recording overwrites it.
    /// Spelling that out so the user doesn't feel pressured to immediately
    /// re-attempt under a flaky Bluetooth link — they can come back tonight from
    /// a less crowded RF environment and pick the data up then.
    private var dataStaysOnStrapNote: some View {
    Text(String(localized: "Your data stays on the strap until a new recording starts. You can try again later if Bluetooth keeps dropping.", bundle: LanguageManager.appBundle))
        .font(.caption2)
        .foregroundColor(AppTheme.textSecondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var retryFetchButton: some View {
        Button(action: onRetry) {
            retryFetchLabel
        }
    .buttonStyle(.borderedProminent)
    .tint(.orange)
    .disabled(isRetrying || !isConnected)
    }

    private var retryFetchLabel: some View {
        HStack {
            if isRetrying {
                ProgressView()
                    .scaleEffect(0.8)
                    .tint(.white)
            }
            Label(isRetrying
                ? String(localized: "Fetching...", bundle: LanguageManager.appBundle)
                : String(localized: "Retry Fetch Data", bundle: LanguageManager.appBundle), systemImage: "arrow.clockwise")
        }
        .frame(maxWidth: .infinity)
    }

    /// Shown only while a retry is actually in flight.
    @ViewBuilder
    private var cancelRetryButton: some View {
    if isRetrying {
        Button(action: onCancelRetry) {
            Label(String(localized: "Cancel", bundle: LanguageManager.appBundle), systemImage: "xmark.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }
    }

    private var dismissFailureButton: some View {
    Button(action: onDismiss) {
        Text(String(localized: "Dismiss", bundle: LanguageManager.appBundle))
            .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    }
}
