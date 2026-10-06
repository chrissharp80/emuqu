import SwiftUI

// MARK: - RecordView Panels

extension RecordPanels {
    // MARK: - Extended Recording Section

    var overnightRecordingSection: some View {
        VStack(spacing: 16) {
            overnightHeader

            if !isActivelyRecording, deviceStatus.fetchProgress == nil {
                extendedCaptureModePicker
            }

            overnightStreamingStatus

            deviceRecordingStatus

            fetchProgressSection

            overnightActionButtons

            overnightHintText
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var overnightHintText: some View {
        if !deviceStatus.isRecordingOnDevice, !streamingLifecycle.isOvernightStreaming, deviceStatus.recordingState == .idle, deviceStatus.fetchProgress == nil {
            VStack(spacing: 4) {
                Text(String(localized: "Start before bed - retrieve when you wake up", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
                Text(String(localized: "Analysis uses the strongest recovery window from the middle of your sleep", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }

    /// Fetch progress, with Cancel. Shown during overnight streaming too: arming
    /// the H10's backup first retrieves any recording still on the strap, and
    /// that download needs the same progress and the same way out.
    @ViewBuilder
    private var fetchProgressSection: some View {
        if let progress = deviceStatus.fetchProgress {
            FetchProgressCard(
                progress: progress,
                deviceName: deviceStatus.connectedDeviceType?.displayName ?? String(localized: "device", bundle: LanguageManager.appBundle),
                onCancel: { collector.polarManager.cancelFetch() }
            )
        }
    }

    /// Device-only recording mode (Verity Sense offline PPI or H10 internal).
    /// Shows after starting a recording, or after crash recovery when the device
    /// is still recording.
    @ViewBuilder
    private var deviceRecordingStatus: some View {
        if deviceStatus.isRecordingOnDevice, !streamingLifecycle.isOvernightStreaming, deviceStatus.fetchProgress == nil {
            DeviceRecordingStatus(
                deviceStatus: deviceStatus,
                persistedStartTime: collector.getPersistedRecordingState()?.startTime
            )
        }
    }

    /// Overnight streaming mode active.
    @ViewBuilder
    private var overnightStreamingStatus: some View {
        if streamingLifecycle.isOvernightStreaming {
            OvernightStreamingStatus(
                streamingLifecycle: streamingLifecycle,
                polarManager: collector.polarManager,
                strapBackup: strapBackupState
            )
        }
    }

    /// What the H10's own recording is doing tonight, for the status card.
    private var strapBackupState: OvernightStreamingStatus.StrapBackup {
        guard collector.useDeviceBackupForOvernight, deviceStatus.connectedDeviceType != .veritySense else { return .notRequested }
        return collector.overnightDeviceBackupActive ? .recording : .starting
    }

    private var overnightHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Extended Recording", bundle: LanguageManager.appBundle))
                    .font(.headline)
                Text(extendedRecordingSubtitle)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
            Spacer()
            recordingStatusBadge
        }
    }

    /// Capture modes offered for the connected device. The Verity Sense hardware
    /// physically cannot stream live AND record to internal memory at the same
    /// time (one radio mode at a time), so `.both` — which exists only to merge
    /// the H10's parallel internal backup into the live stream — is never a real
    /// option for it. Offering it would be a lie: the backend already coerces it
    /// to streaming-only for Verity. So drop it from the picker entirely and give
    /// Verity users a true "one or the other" choice.
    var availableCaptureModes: [RecordView.ExtendedCaptureMode] {
        if deviceStatus.connectedDeviceType == .veritySense {
            return [.streaming, .internalCapture]
        }
        return RecordView.ExtendedCaptureMode.allCases
    }

    var extendedCaptureModePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            captureModeSection

            captureModePicker

            Text(extendedCaptureModeHelpText)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var captureModePicker: some View {
        Picker(String(localized: "Capture Mode", bundle: LanguageManager.appBundle), selection: $extendedCaptureMode) {
            ForEach(availableCaptureModes) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var captureModeSection: some View {
        HStack {
            Text(String(localized: "Capture Mode", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .fontWeight(.semibold)

            Spacer()

            makeDefaultSection
        }
    }

    @ViewBuilder
    private var makeDefaultSection: some View {
        if extendedCaptureMode.rawValue != settingsManager.settings.defaultCaptureMode {
            Button {
                settingsManager.settings.defaultCaptureMode = extendedCaptureMode.rawValue
            } label: {
                Text(String(localized: "Make Default", bundle: LanguageManager.appBundle))
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .tint(AppTheme.sage)
        }
    }

    var recordingStatusBadge: some View {
        HStack(spacing: 6) {
            if streamingLifecycle.isOvernightStreaming || deviceStatus.isRecordingOnDevice || deviceStatus.recordingState == .recording {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Text(recordingStatusText)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(.systemBackground))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Status: \(recordingStatusText)", bundle: LanguageManager.appBundle))
    }

    var recordingStatusText: String {
        // Overnight streaming mode
        if streamingLifecycle.isOvernightStreaming {
            return String(localized: "Streaming overnight", bundle: LanguageManager.appBundle)
        }

        switch deviceStatus.recordingState {
        case .idle:
            return deviceStatus.isRecordingOnDevice
                ? String(localized: "Recording", bundle: LanguageManager.appBundle)
                : String(localized: "Ready", bundle: LanguageManager.appBundle)
        case .starting: return String(localized: "Starting...", bundle: LanguageManager.appBundle)
        case .recording: return String(localized: "Recording", bundle: LanguageManager.appBundle)
        case .stopping: return String(localized: "Stopping...", bundle: LanguageManager.appBundle)
        case .fetching: return String(localized: "Fetching Data...", bundle: LanguageManager.appBundle)
        }
    }

    var extendedRecordingSubtitle: String {
        if streamingLifecycle.isOvernightStreaming {
            return String(localized: "Live Bluetooth stream with automatic analysis", bundle: LanguageManager.appBundle)
        }
        if deviceStatus.isRecordingOnDevice {
            return String(localized: "Recording on device memory", bundle: LanguageManager.appBundle)
        }
        switch extendedCaptureMode {
        case .streaming:
            return String(localized: "Live Bluetooth stream only", bundle: LanguageManager.appBundle)
        case .internalCapture:
            return String(localized: "Record directly on device memory (no live stream)", bundle: LanguageManager.appBundle)
        case .both:
            return String(localized: "Live stream + strap internal backup", bundle: LanguageManager.appBundle)
        }
    }

    var extendedCaptureModeHelpText: String {
        let isVerity = deviceStatus.connectedDeviceType == .veritySense
        switch extendedCaptureMode {
        case .streaming:
            if isVerity {
                return String(localized: "Verity Sense streams optical intervals live. Internal recording cannot run at the same time.", bundle: LanguageManager.appBundle)
            }
            return String(localized: "Streaming only. Waking analysis uses BLE data and skips strap memory fetch.", bundle: LanguageManager.appBundle)
        case .internalCapture:
            return String(localized: "Battery-efficient device-only capture. Fetch and analyze when you wake up.", bundle: LanguageManager.appBundle)
        case .both:
            // Never shown for a Verity Sense: `availableCaptureModes` drops
            // `.both` and RecordView coerces it away when one connects.
            return String(localized: "Maximum recovery reliability: stream live and fetch strap memory in the morning.", bundle: LanguageManager.appBundle)
        }
    }

    var overnightActionButtons: some View {
        VStack(spacing: 12) {
            // === STATE: Paused ===
            if streamingLifecycle.isPaused {
                pausedStateButtons
            } else if streamingLifecycle.isOvernightStreaming && morningCoordination.morningStatus == nil {
                streamingStateButtons
            } else if deviceStatus.isRecordingOnDevice || deviceStatus.recordingState == .recording {
                legacyRecordingButtons
            } else {
                idleStateButtons
            }

            if isActionDisabled {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
    }

    @ViewBuilder
    private var pausedStateButtons: some View {
        pausedScorePreview

        resumeButton

        if deviceStatus.connectionState != .connected {
            Text(String(localized: "Reconnect device to resume", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }

        finishFromPauseButton
    }

    private var finishFromPauseButton: some View {
        Button(action: finalizeFromPause) {
            Label(String(localized: "Done", bundle: LanguageManager.appBundle), systemImage: "checkmark.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.zen(AppTheme.sage))
        .accessibilityLabel(String(localized: "Finish session", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "End the paused session and analyze results", bundle: LanguageManager.appBundle))
    }

    private var resumeButton: some View {
        Button(action: resumeRecording) {
            Label(String(localized: "Resume Recording", bundle: LanguageManager.appBundle), systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.zen(AppTheme.primary))
        .disabled(deviceStatus.connectionState != .connected)
        .accessibilityLabel(String(localized: "Resume Recording", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Continue the paused HRV recording session", bundle: LanguageManager.appBundle))
    }

    @ViewBuilder
    private var streamingStateButtons: some View {
        // === STATE: Overnight streaming active ===
        // Connection health warning — device may be unreachable
        connectionLostWarning

        imUpButton

        Button(action: pauseRecording) {
            Label(String(localized: "Pause & Resume Later", bundle: LanguageManager.appBundle), systemImage: "pause.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(AppTheme.warning)
        .disabled(isActionDisabled)
        .accessibilityLabel(String(localized: "Pause and Resume Later", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Pause the recording so you can continue it later", bundle: LanguageManager.appBundle))
    }

    private var imUpButton: some View {
        Button(action: stopAndFetch) {
            Label(String(localized: "I'm Up", bundle: LanguageManager.appBundle), systemImage: "sunrise.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.zen(AppTheme.sage))
        .disabled(isActionDisabled)
        .accessibilityLabel(String(localized: "I'm Up", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "End overnight recording and analyze your HRV", bundle: LanguageManager.appBundle))
    }

    @ViewBuilder
    private var connectionLostWarning: some View {
        if collector.polarManager.connectionHealthWarning || deviceStatus.connectionState == .disconnected {
            connectionLostBanner
        } else if collector.polarManager.isBatteryReadingStale {
            staleBatteryBanner
        }
    }

    /// The device may be unreachable; data up to the disconnect is already saved.
    private var connectionLostBanner: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .foregroundColor(AppTheme.alert)
                Text(String(localized: "Device connection lost", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(AppTheme.alert)
            }
            Text(String(localized: "Your data up to the disconnect has been saved. Tap \"I'm Up\" to process what was captured.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(10)
        .background(AppTheme.alert.opacity(0.08))
        .cornerRadius(8)
    }

    private var staleBatteryBanner: some View {
        HStack(spacing: 6) {
            // Stale battery warning
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(AppTheme.warning)
            Text(String(localized: "Battery reading may be outdated — device hasn't reported an update in hours", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.warning)
        }
        .padding(10)
        .background(AppTheme.warning.opacity(0.08))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var legacyRecordingButtons: some View {
        Button(action: stopAndFetch) {
            // === STATE: Legacy internal recording active ===
            Label(String(localized: "Wake Up - Get Results", bundle: LanguageManager.appBundle), systemImage: "sunrise.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.zen(AppTheme.sage))
        .disabled(isActionDisabled)
        .accessibilityLabel(String(localized: "Wake Up — get results", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Stop the device recording and download data for analysis", bundle: LanguageManager.appBundle))
    }

    @ViewBuilder
    private var idleStateButtons: some View {
        // === STATE: Not recording ===
        Button(action: startOvernightRecording) {
            Label(String(localized: "Start Extended Recording", bundle: LanguageManager.appBundle), systemImage: "moon.zzz.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.zen(AppTheme.primary))
        .disabled(isActionDisabled || deviceStatus.connectionState != .connected || isBatteryCritical)
        .accessibilityLabel(String(localized: "Start Extended Recording", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Begin an overnight HRV recording session", bundle: LanguageManager.appBundle))

        if deviceStatus.connectionState != .connected {
            connectDevicePrompt
        } else if isBatteryCritical {
            batteryCriticalNote
        } else if isBatteryLow {
            batteryLowNote
        } else if collector.hasUnrecoveredData {
            unrecoveredDataNote
        }
    }

    private var connectDevicePrompt: some View {
        Text(String(localized: "Connect to Polar device first", bundle: LanguageManager.appBundle))
            .font(.caption)
            .foregroundColor(AppTheme.textSecondary)
    }

    private var batteryCriticalNote: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "battery.0")
                    .foregroundColor(AppTheme.alert)
                Text(String(localized: "Battery too low to record", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(AppTheme.alert)
            }
            Text(String(localized: "Charge your device above 10% before starting", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var batteryLowNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(AppTheme.warning)
            Text(String(localized: "Battery is low (\(deviceStatus.batteryLevel ?? 0)%) — recording may not last all night", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.warning)
        }
    }

    private var unrecoveredDataNote: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(String(localized: "Unrecovered data on device", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.orange)
            }
            Text(String(localized: "Recover or discard before starting new recording", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    // MARK: - Paused Score Preview

    @ViewBuilder
    var pausedScorePreview: some View {
        VStack(spacing: 12) {
            pausedHeader

            pausedMetricCards

            dataSavedNote
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AppTheme.warning.opacity(0.5), lineWidth: 1.5)
                )
        )
    }

    private var dataSavedNote: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.shield.fill")
                .font(.caption)
                .foregroundColor(AppTheme.sage)
            Text(String(localized: "Your data is saved", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.sageText)
        }
    }

    @ViewBuilder
    private var pausedMetricCards: some View {
        if let session = streamingLifecycle.pausedSession, let result = session.analysisResult {
            MorningPreviewCards.metrics(result)
        }
    }

    private var pausedHeader: some View {
        HStack {
            Image(systemName: "pause.circle.fill")
                .font(.title2)
                .foregroundColor(AppTheme.warning)
            pausedHeaderText
            Spacer()
        }
    }

    private var pausedHeaderText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Recording Paused", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)
            if let pausedDate = streamingLifecycle.pausedSession?.pausedDate {
                Text("Paused \(pausedDate, style: .relative) ago", bundle: LanguageManager.appBundle)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }

    // MARK: - Continue Recovery Card

    func continueRecoveryCard(session: HRVSession) -> some View {
        VStack(spacing: 12) {
            continueRecoveryHeader(session: session)
            continueRecoveryScoreLine(session: session)
            continueRecoveryButton(session: session)
            if deviceStatus.connectionState != .connected {
                Text(String(localized: "Connect device to resume", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AppTheme.primary.opacity(0.3), lineWidth: 1.5)
                )
        )
    }

    private func continueRecoveryButton(session: HRVSession) -> some View {
        Button {
            startLinkedRecording(session)
        } label: {
            Label(String(localized: "Continue Recording", bundle: LanguageManager.appBundle), systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.zen(AppTheme.primary))
        .disabled(deviceStatus.connectionState != .connected)
        .accessibilityLabel(String(localized: "Continue Recording", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Pick up the previous session and add more data", bundle: LanguageManager.appBundle))
    }

    var isActionDisabled: Bool {
        switch deviceStatus.recordingState {
        case .starting, .stopping, .fetching: true
        case .idle, .recording: false
        }
    }

    func recoverStoredData() {
        Task { await performDeviceRecovery() }
    }

    /// The keep-awake is gated on user preference (default
    /// off), and only touched when the user opted in, so a workout that
    /// legitimately holds the idle timer disabled isn't cleared by an
    /// opt-out session.
    private func performDeviceRecovery() async {
        let keepAwake = AppDependencies.current.app.settingsManager.settings.shouldKeepScreenOnDuringRecording
        await MainActor.run { Self.applyRecoveryKeepAwake(keepAwake, disabled: true) }
        defer { Task { @MainActor in Self.applyRecoveryKeepAwake(keepAwake, disabled: false) } }
        do {
            _ = try await collector.recoverFromDevice()
        } catch {
            await MainActor.run { fetchFailed = true }
        }
    }

    @MainActor
    private static func applyRecoveryKeepAwake(_ keepAwake: Bool, disabled: Bool) {
        guard keepAwake else { return }
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    func discardAndStartFresh() {
        Task {
            do {
                try await collector.polarManager.discardStoredExercises()
            } catch {
                // `discardStoredExercises` doesn't set lastError itself.
                debugLog("[RecordView] ⚠️ Failed to discard stored recordings: \(error)")
                sessionState.lastError = error
            }
        }
    }

    // MARK: - Quick Reading Section

    var quickReadingSection: some View {
        VStack(spacing: 16) {
            quickReadingHeader

            if deviceStatus.isStreaming, !streamingLifecycle.isOvernightStreaming, morningCoordination.morningStatus == nil {
                streamingProgressPanel
            } else if !deviceStatus.isRecordingOnDevice, deviceStatus.recordingState == .idle, !streamingLifecycle.isOvernightStreaming {
                quickReadingOptions
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var streamingProgressPanel: some View {
        StreamingProgressPanel(
            collector: collector,
            streamingLifecycle: streamingLifecycle,
            polarManager: collector.polarManager,
            breathingAudio: breathingAudio,
            stopStreaming: stopStreaming
        )
    }

    @ViewBuilder
    private var quickReadingOptions: some View {
        VStack(spacing: 12) {
            Text(String(localized: "For daytime checks, post-workout recovery, or if you can't do overnight", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)

            quickReadingButtonsOrWarning
        }
    }

    @ViewBuilder
    private var quickReadingButtonsOrWarning: some View {
        if isBatteryCritical {
            batteryTooLowNote
        } else {
            quickReadingChoices
        }
    }

    @ViewBuilder
    private var batteryTooLowNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "battery.0")
                .foregroundColor(AppTheme.alert)
            Text(String(localized: "Battery too low — charge above 10%", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.alert)
        }
    }

    @ViewBuilder
    private var quickReadingChoices: some View {
        quickReadingButtonRow

        batteryLowWarning
    }

    @ViewBuilder
    private var batteryLowWarning: some View {
        if isBatteryLow {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(AppTheme.warning)
                Text(String(localized: "Battery is low (\(deviceStatus.batteryLevel ?? 0)%)", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.warning)
            }
        }
    }

    private var quickReadingButtonRow: some View {
        HStack(spacing: 12) {
            twoMinuteButton

            threeMinuteButton

            fiveMinuteButton
        }
    }

    private var fiveMinuteButton: some View {
        QuickReadingButton(
            duration: String(localized: "5 min", bundle: LanguageManager.appBundle),
            description: String(localized: "Full", bundle: LanguageManager.appBundle),
            icon: "clock.badge.checkmark",
            color: AppTheme.primary,
            action: { startStreaming(300) }
        )
    }

    private var threeMinuteButton: some View {
        QuickReadingButton(
            duration: String(localized: "3 min", bundle: LanguageManager.appBundle),
            description: String(localized: "Standard", bundle: LanguageManager.appBundle),
            icon: "clock.fill",
            color: AppTheme.sage,
            action: { startStreaming(180) }
        )
    }

    private var twoMinuteButton: some View {
        QuickReadingButton(
            duration: String(localized: "2 min", bundle: LanguageManager.appBundle),
            description: String(localized: "Basic", bundle: LanguageManager.appBundle),
            icon: "clock",
            color: AppTheme.mist,
            action: { startStreaming(120) }
        )
    }

    private var quickReadingHeader: some View {
        HStack {
            quickReadingHeaderText
            Spacer()
            liveBadge
        }
    }

    private var quickReadingHeaderText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Quick Reading", bundle: LanguageManager.appBundle))
                .font(.headline)
            Text(String(localized: "Spot check - keep app open during recording", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var liveBadge: some View {
        if deviceStatus.isStreaming {
            HStack(spacing: 6) {
                Circle()
                    .fill(AppTheme.sage)
                    .frame(width: 8, height: 8)
                Text(String(localized: "Live", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.sageText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(AppTheme.sectionTint)
            .clipShape(Capsule())
        }
    }

    private struct QuickReadingButton: View {
        let duration: String
        let description: String
        let icon: String
        let color: Color
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                buttonTile
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "\(duration) quick reading", bundle: LanguageManager.appBundle))
            .accessibilityValue(description)
            .accessibilityHint(String(localized: "Start a quick HRV reading of this duration", bundle: LanguageManager.appBundle))
        }

        private var buttonTile: some View {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
                Text(duration)
                    .font(.subheadline.bold())
                    .foregroundColor(AppTheme.textPrimary)
                Text(description)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(AppTheme.cardBackground)
            .cornerRadius(AppTheme.smallCornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius)
                    .stroke(color.opacity(0.3), lineWidth: 1)
            )
        }
    }
}

// MARK: - File-scope helpers
//
// Kept out of RecordView. Each names no member of the
// type and calls nothing that stayed behind, so none needed to be inside
// it. `private` at file scope is fileprivate, so every call site in this
// file resolves exactly as before.

@MainActor
private func continueRecoveryHeader(session: HRVSession) -> some View {
    HStack {
        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
            .font(.title3)
            .foregroundColor(AppTheme.primary)
        continueRecoveryTitle(session: session)
        Spacer()
    }
}

@ViewBuilder
@MainActor
private func continueRecoveryTitle(session: HRVSession) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(String(localized: "Continue Recovery", bundle: LanguageManager.appBundle))
            .font(.headline)
            .foregroundColor(AppTheme.textPrimary)
        if let endDate = session.endDate {
            Text("Last segment ended \(endDate, style: .relative) ago", bundle: LanguageManager.appBundle)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
    }
}

/// The night's recovery score so far, on the 0–100 scale the rest of the
/// app shows. Continuing links a new segment and the night is scored again.
@ViewBuilder
@MainActor
private func continueRecoveryScoreLine(session: HRVSession) -> some View {
    if let score = session.recoveryScore {
        let display = ScoreVerdict.safeDisplayScore(score * 10)
        HStack(spacing: 4) {
            Text(String(localized: "Recovery so far: \(display)", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.recoveryColor(Double(display)))
            Text(String(localized: "— recording the rest of the night re-scores it", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
    }
}
