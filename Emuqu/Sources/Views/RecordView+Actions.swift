import SwiftUI

// The connection section, actions and computed properties, split out of
// `RecordView.swift`. What stays behind is the recording UI itself
// and the morning-results preview.

extension RecordView {
    // MARK: - Connection Section

    // connectionSection moved to ConnectionPanel struct (isolated PolarManager observation)

    var isBatteryCritical: Bool {
        guard let battery = deviceStatus.batteryLevel else { return false }
        return battery < 10
    }

    var isBatteryLow: Bool {
        guard let battery = deviceStatus.batteryLevel else { return false }
        return battery >= 10 && battery < 20
    }

    // MARK: - Actions

    /// Dismiss overnight results — session is already archived, just clear UI state
 
    func toggleTag(_ tag: ReadingTag) {
        selectedTags.toggle(tag)
    }

    func startOvernightRecording() {
        fetchFailed = false
        Task { await startCaptureSurfacingFailure() }
    }

    /// Surface failure: neither `startOvernightStreaming` nor `startSession`
    /// sets lastError on the throwing path, so without this the user just
    /// sees the start button do nothing.
    private func startCaptureSurfacingFailure() async {
        do {
            try await startCapture(mode: extendedCaptureMode)
        } catch {
            debugLog("[RecordView] ⚠️ Failed to start recording: \(error)")
            await MainActor.run { sessionState.lastError = error }
        }
    }

    @MainActor
    private func startCapture(mode: ExtendedCaptureMode) async throws {
        let type = selectedSessionType ?? .overnight
        switch mode {
        case .streaming:
            // Streaming mode with overnight processing pipeline.
            try collector.startOvernightStreaming(sessionType: type, useDeviceInternalBackup: false)
        case .internalCapture:
            // Device-only recording mode (H10 exercise recording / Verity offline PPI).
            try await collector.startSession(sessionType: type)
        case .both:
            try collector.startOvernightStreaming(sessionType: type, useDeviceInternalBackup: true)
        }
    }

    func pauseRecording() {
        Task {
            await collector.pauseOvernightStreaming()
        }
    }

    func resumeRecording() {
        guard let pausedSession = streamingLifecycle.pausedSession else { return }
        Task {
            do {
                try collector.resumeOvernightStreaming(linkedSessionId: pausedSession.id)
            } catch {
                // `resumeOvernightStreaming` doesn't set lastError itself.
                debugLog("[RecordView] ⚠️ Failed to resume recording: \(error)")
                sessionState.lastError = error
            }
        }
    }

    func finalizeFromPause() {
        collector.finalizeFromPause()
    }

    func startLinkedRecording(linkedTo session: HRVSession) {
        Task {
            do {
                try collector.resumeOvernightStreaming(linkedSessionId: session.id)
            } catch {
                debugLog("[RecordView] ⚠️ Failed to start linked recording: \(error)")
                sessionState.lastError = error
            }
        }
    }

    func stopAndFetch() {
        Task {
            // For overnight streaming mode — morningStatus drives the processing card UI.
            // After processing completes, needsAcceptance auto-accepts and navigates to Dashboard.
            guard streamingLifecycle.isOvernightStreaming else {
                await stopInternalRecording()
                return
            }
            await stopOvernightAndApplyOutcome()
        }
    }

    private func stopOvernightAndApplyOutcome() async {
        let session = await collector.stopOvernightStreaming()
        await MainActor.run { applyStopOutcome(session, navigateOnSuccess: false) }
    }

    /// Legacy: internal recording mode (fenced off) — requires download from
    /// the H10. Keeps the screen on during the download so iOS doesn't
    /// deprioritize BLE.
    ///
    /// Gated on
    /// `settings.keepScreenOnDuringRecording` (default OFF per user request:
    /// respects iOS auto-lock by default).
    private func stopInternalRecording() async {
        let keepAwake = AppDependencies.current.app.settingsManager.settings.shouldKeepScreenOnDuringRecording
        await MainActor.run { Self.applyKeepAwake(keepAwake, disabled: true) }
        defer { Task { @MainActor in Self.applyKeepAwake(keepAwake, disabled: false) } }
        do {
            let session = try await collector.stopSession()
            await MainActor.run { applyStopOutcome(session, navigateOnSuccess: true) }
        } catch {
            // Error surfaced via sessionState.lastError.
            await MainActor.run { fetchFailed = true }
        }
    }

    @MainActor
    private func applyStopOutcome(_ session: HRVSession?, navigateOnSuccess: Bool) {
        if session?.state == .complete, session?.analysisResult != nil {
            fetchFailed = false
            if navigateOnSuccess { selectedTab = .dashboard }
        } else if session?.state == .failed {
            fetchFailed = true
        }
    }

    func retryFetch() {
        Task { await performRetryFetch() }
    }

    /// The keep-awake is gated on user preference (default off).
    /// On failure `fetchFailed` stays true so the user can retry again.
    private func performRetryFetch() async {
        let keepAwake = AppDependencies.current.app.settingsManager.settings.shouldKeepScreenOnDuringRecording
        await MainActor.run {
            Self.applyKeepAwake(keepAwake, disabled: true)
            isRetrying = true
        }
        defer { Task { @MainActor in Self.applyKeepAwake(keepAwake, disabled: false) } }
        let session = try? await collector.retryFetchRecording()
        await MainActor.run { finishRetry(session) }
    }

    /// Only touches the idle timer when the user opted in, so a workout that
    /// legitimately holds it disabled isn't cleared by an opt-out session.
    @MainActor
    private static func applyKeepAwake(_ keepAwake: Bool, disabled: Bool) {
        guard keepAwake else { return }
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    @MainActor
    private func finishRetry(_ session: HRVSession?) {
        isRetrying = false
        if session?.state == .complete { fetchFailed = false }
    }

    func startStreaming(seconds: Int) {
        fetchFailed = false
        debugLog("startStreaming called with \(seconds) seconds")
        do {
            try collector.startStreamingSession(durationSeconds: seconds)
        } catch {
            debugLog("startStreaming error: \(error)")
            sessionState.lastError = error
        }
    }

    func stopStreaming() {
        Task {
            let session = await collector.stopStreamingSession()
            persistTagsForStoppedSession(session)
        }
    }

    /// Tags and notes typed during the capture are written back once the
    /// session exists. Notes alone are saved too.
    private func persistTagsForStoppedSession(_ session: HRVSession?) {
        guard let session, !selectedTags.isEmpty || !sessionNotes.isEmpty else { return }
        do {
            try collector.archive.updateTags(session.id, tags: Array(selectedTags), notes: sessionNotes.isEmpty ? nil : sessionNotes)
        } catch {
            debugLog("[RecordView] ⚠️ Failed to save tags for session \(session.id.uuidString.prefix(8)): \(error)")
        }
    }

    func acceptSession() {
        Task {
            await applyPendingTags()
            do {
                try await collector.acceptSession()
            } catch {
                debugLog("[RecordView] ⚠️ Failed to accept session: \(error)")
            }
            await MainActor.run {
                selectedTags.removeAll()
                sessionNotes = ""
            }
        }
    }

    /// The session may not be archived yet (e.g. recovered from device). When
    /// the archive write fails, apply the tags directly to `currentSession` so
    /// `acceptSession()` picks them up.
    private func applyPendingTags() async {
        guard let session = sessionState.currentSession else { return }
        do {
            try collector.archive.updateTags(session.id, tags: Array(selectedTags), notes: sessionNotes.isEmpty ? nil : sessionNotes)
        } catch {
            applyTagsToCurrentSession()
        }
    }

    @MainActor
    private func applyTagsToCurrentSession() {
        sessionState.currentSession?.tags = Array(selectedTags)
        if !sessionNotes.isEmpty {
            sessionState.currentSession?.notes = sessionNotes
        }
    }

    func rejectSession() {
        Task {
            await collector.rejectSession()
            await MainActor.run {
                selectedTags.removeAll()
                sessionNotes = ""
                quickSource = nil
                selectedSessionType = nil
            }
        }
    }

    // MARK: - Computed Properties

    var isSessionActive: Bool {
        deviceStatus.isStreaming ||
            streamingLifecycle.isOvernightStreaming ||
            streamingLifecycle.isPaused ||
            sessionState.isCollecting ||
            deviceStatus.isRecordingOnDevice ||
            morningCoordination.morningStatus != nil ||
            sessionState.needsAcceptance ||
            (sessionState.currentSession?.state == .complete && sessionState.currentSession?.analysisResult != nil)
    }

    /// True only when a recording is actively running. Unlike isSessionActive,
    /// this excludes post-session states (needsAcceptance, completed session)
    /// so the capture mode picker stays visible between sessions.
    var isActivelyRecording: Bool {
        deviceStatus.isStreaming ||
            streamingLifecycle.isOvernightStreaming ||
            streamingLifecycle.isPaused ||
            sessionState.isCollecting ||
            deviceStatus.isRecordingOnDevice
    }
}

#Preview {
    NavigationStack {
        RecordView(selectedTab: .constant(.record))
            .environment(RRCollector())
            .environment(AppDependencies.current.app.settingsManager)
    }
}

/// Review + trim a just-recovered crash workout before keeping it. A crash
/// can leave the strap recording long after the workout ends, so the
/// auto-trim is only a best guess — this lets the user drag the end back to
/// where the workout actually finished (or discard it) instead of a silent
/// archive of a wrong-length session.
struct RecoveredWorkoutReviewCard: View {
    let review: MorningCoordination.RecoveredWorkoutReview
    let onSave: (Double) -> Void // chosen end, seconds from start
    let onDiscard: () -> Void
    @State private var endMinutes: Double

    init(
        review: MorningCoordination.RecoveredWorkoutReview,
        onSave: @escaping (Double) -> Void,
        onDiscard: @escaping () -> Void
    ) {
        self.review = review
        self.onSave = onSave
        self.onDiscard = onDiscard
        _endMinutes = State(initialValue: max(1, (review.durationSec / 60).rounded()))
    }

    var maxMinutes: Double { max(2, (review.durationSec / 60).rounded()) }

    var distanceText: String {
        guard review.distanceMeters > 0 else { return "" }
        if UnitsPreferenceStore.current.resolved == .imperial {
            return String(format: " · %.2f mi", locale: .current, review.distanceMeters / 1609.344)
        }
        return String(format: " · %.2f km", locale: .current, review.distanceMeters / 1000.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            summaryLine
            trimHint
            Slider(value: $endMinutes, in: 1 ... maxMinutes, step: 1)
                .tint(AppTheme.sage)
            actionRow
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.sage.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(AppTheme.sage.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(AppTheme.sage)
            Text(String(localized: "Recovered workout — check it", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.textPrimary)
        }
    }

    private var summaryLine: some View {
        Text(String(localized: "\(review.sport) · \(Int(endMinutes)) min\(distanceText) · avg HR \(review.avgHR)", bundle: LanguageManager.appBundle))
            .font(.caption)
            .foregroundColor(AppTheme.textSecondary)
    }

    private var trimHint: some View {
        Text(String(localized: "If the strap kept recording after you finished, drag the end back to where the workout actually ended, then Save.", bundle: LanguageManager.appBundle))
            .font(.caption2)
            .foregroundColor(AppTheme.textSecondary.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            saveButton
                .buttonStyle(.plain)
            discardButton
                .buttonStyle(.plain)
        }
    }

    private var saveButton: some View {
        Button { onSave(endMinutes * 60) } label: {
            Text(String(localized: "Save", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(AppTheme.primary)
                .foregroundColor(.white)
                .cornerRadius(8)
        }
    }

    private var discardButton: some View {
        Button { onDiscard() } label: {
            Text(String(localized: "Discard", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(AppTheme.terracotta.opacity(0.12))
                .foregroundColor(AppTheme.terracotta)
                .cornerRadius(8)
        }
    }
}
