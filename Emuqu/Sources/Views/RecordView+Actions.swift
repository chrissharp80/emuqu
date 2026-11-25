import SwiftUI

// The connection section, actions and computed properties.
// `RecordView.swift` holds the recording UI itself and the
// morning-results preview.

extension RecordView {
    // MARK: - Connection Section

    // connectionSection is the ConnectionPanel struct (isolated PolarManager observation).

    var isBatteryCritical: Bool {
        guard let battery = deviceStatus.batteryLevel else { return false }
        return battery < 10
    }

    var isBatteryLow: Bool {
        guard let battery = deviceStatus.batteryLevel else { return false }
        return battery >= 10 && battery < 20
    }

    // MARK: - Actions

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
            try collector.overnightStreaming.startOvernightStreaming(sessionType: type, useDeviceInternalBackup: false)
        case .internalCapture:
            // Device-only recording mode (H10 exercise recording / Verity offline PPI).
            try await collector.deviceRecording.startSession(sessionType: type)
        case .both:
            try collector.overnightStreaming.startOvernightStreaming(sessionType: type, useDeviceInternalBackup: true)
        }
    }

    func pauseRecording() {
        Task {
            await collector.control.pauseOvernightStreaming()
        }
    }

    func resumeRecording() {
        guard let pausedSession = streamingLifecycle.pausedSession else { return }
        Task {
            do {
                try collector.control.resumeOvernightStreaming(linkedSessionId: pausedSession.id)
            } catch {
                // `resumeOvernightStreaming` doesn't set lastError itself.
                debugLog("[RecordView] ⚠️ Failed to resume recording: \(error)")
                sessionState.lastError = error
            }
        }
    }

    func finalizeFromPause() {
        collector.control.finalizeFromPause()
    }

    /// Ends the recording in progress without keeping anything from it. The
    /// overnight stream and the strap-only recording each have their own
    /// discard; `startOver` starts a fresh recording once the discard has
    /// finished, so the new night never inherits the old one's strap copy.
    func discardRecording(startOver: Bool) {
        Task { @MainActor in
            isDiscarding = true
            defer { isDiscarding = false }
            fetchFailed = false
            let discarded: Bool
            if streamingLifecycle.isOvernightStreaming {
                discarded = await collector.control.discardOvernightRecording() != nil
            } else {
                discarded = await collector.control.discardDeviceRecording()
            }
            guard startOver, discarded, !streamingLifecycle.isPaused else { return }
            startOvernightRecording()
        }
    }

    func discardPausedNight() {
        Task { @MainActor in
            isDiscarding = true
            defer { isDiscarding = false }
            await collector.control.discardPausedRecording()
        }
    }

    func startLinkedRecording(linkedTo session: HRVSession) {
        Task {
            do {
                try collector.control.resumeOvernightStreaming(linkedSessionId: session.id)
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
        let session = await collector.overnightStreaming.stopOvernightStreaming()
        await MainActor.run { applyStopOutcome(session, navigateOnSuccess: false) }
    }

    /// Internal recording mode (the strap records to its own memory) —
    /// requires download from the H10. Keeps the screen on during the download so iOS doesn't
    /// deprioritize BLE.
    ///
    /// Gated on
    /// `settings.shouldKeepScreenOnDuringRecording` (the toggle, on by
    /// default, and off in Low Power Mode).
    ///
    /// `stopSession` throws only before the download starts (strap not
    /// connected) and does not record that error itself, so it is set here
    /// for the alert and the Retry card's reason.
    @MainActor
    private func stopInternalRecording() async {
        await RecordingKeepAwake.during {
            do {
                let session = try await collector.deviceRecording.stopSession()
                applyStopOutcome(session, navigateOnSuccess: true)
            } catch {
                sessionState.lastError = error
                fetchFailed = true
            }
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

    /// The keep-awake is gated on user preference (on by default, off in Low Power Mode).
    /// On failure `fetchFailed` stays true so the user can retry again. A
    /// retry that cannot start (strap disconnected between tap and call)
    /// throws without recording why, so the error is set here.
    @MainActor
    private func performRetryFetch() async {
        isRetrying = true
        await RecordingKeepAwake.during {
            do {
                let session = try await collector.recovery.retryFetchRecording()
                finishRetry(session)
            } catch {
                sessionState.lastError = error
                finishRetry(nil)
            }
        }
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
            try collector.quickReading.startStreamingSession(durationSeconds: seconds)
        } catch {
            debugLog("startStreaming error: \(error)")
            sessionState.lastError = error
        }
    }

    /// A quick reading is archived as it stops, so its tags and notes
    /// (picked before or during the capture) are written then, through the
    /// same `persistTagsAndNotes` as every other save, morning tag included.
    /// A failed reading is not archived and gets none.
    func stopStreaming() {
        Task {
            let session = await collector.quickReading.stopStreamingSession()
            guard let session, session.state == .complete else { return }
            await persistTagsAndNotes(for: session)
        }
    }

    /// Save for a reading awaiting acceptance, from the Save button, the
    /// morning sheet's Done and Continue to Dashboard alike: tags and notes,
    /// acceptance, then the picker returns to no selection.
    ///
    /// When acceptance fails the reading stays awaiting acceptance with the
    /// error raised (`acceptSession` sets `lastError`), and the selection is
    /// kept, so Save again writes the same tags and notes.
    func acceptSession() {
        Task {
            if let session = sessionState.currentSession { await persistTagsAndNotes(for: session) }
            do {
                try await collector.morning.acceptSession()
            } catch RRCollector.CollectorError.noSessionToAccept {
                debugLog("[RecordView] ⚠️ No complete session to accept")
            } catch {
                debugLog("[RecordView] ⚠️ Failed to accept session: \(error)")
                return
            }
            await MainActor.run {
                selectedTags.removeAll()
                sessionNotes = ""
                selectedSessionType = nil
            }
        }
    }

    func rejectSession() {
        Task {
            await collector.rejectSession()
            await MainActor.run {
                selectedTags.removeAll()
                sessionNotes = ""
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

/// Keeps the screen on around a strap download when the user opted in
/// (`shouldKeepScreenOnDuringRecording`: the toggle, on by default, and
/// off in Low Power Mode). It takes the hold only when
/// nothing else holds it, and gives back only a hold it took, so a flow that
/// already kept the screen on (Get Me Back) is not cleared when the download
/// ends — the same ownership rule as `GetMeBackView.resetScreenState`.
/// Shared by Stop, Retry and Recover.
enum RecordingKeepAwake {
    @MainActor
    static func during(_ work: () async -> Void) async {
        let keepAwake = AppDependencies.current.app.settingsManager.settings.shouldKeepScreenOnDuringRecording
        let takesHold = keepAwake && !UIApplication.shared.isIdleTimerDisabled
        if takesHold { UIApplication.shared.isIdleTimerDisabled = true }
        await work()
        if takesHold { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// Review + trim a just-recovered crash workout before keeping it. A crash
/// can leave the strap recording long after the workout ends, so the
/// auto-trim is only a best guess — this lets the user drag the end back to
/// where the workout actually finished (or discard it) instead of a silent
/// archive of a wrong-length session.
struct RecoveredWorkoutReviewCard: View {
    let review: MorningCoordination.RecoveredWorkoutReview
    /// Why the last Save or Discard stored nothing, shown under the buttons.
    let failureMessage: String?
    let onSave: (Double) -> Void // chosen end, seconds from start
    let onDiscard: () -> Void
    @State private var endMinutes: Double
    /// Discard waits for confirmation: it removes the workout from history.
    @State private var confirmingDiscard = false

    init(
        review: MorningCoordination.RecoveredWorkoutReview,
        failureMessage: String?,
        onSave: @escaping (Double) -> Void,
        onDiscard: @escaping () -> Void
    ) {
        self.review = review
        self.failureMessage = failureMessage
        self.onSave = onSave
        self.onDiscard = onDiscard
        _endMinutes = State(initialValue: max(1, (review.durationSec / 60).rounded()))
    }

    var maxMinutes: Double { max(2, (review.durationSec / 60).rounded()) }

    /// Minutes the save keeps. The slider can sit past a recording shorter
    /// than 90 s (its range is at least 1...2), so the summary reads the
    /// chosen end rather than the slider.
    var keptMinutes: Int { Int(max(1, (chosenEndSec / 60).rounded())) }

    /// The slider moves in whole minutes, so its starting value is the
    /// duration rounded. At or past that value the end is the recording's
    /// own end, to the second: saving untouched must neither drop the last
    /// seconds nor ask for an end past the data.
    var chosenEndSec: Double {
        let untrimmed = max(1, (review.durationSec / 60).rounded())
        guard endMinutes < untrimmed else { return review.durationSec }
        return min(endMinutes * 60, review.durationSec)
    }

    /// The distance with its unit in the app's language, through the shared
    /// units formatter.
    var distanceText: String {
        guard review.distanceMeters > 0 else { return "" }
        return " · " + UnitsPreferenceStore.current.formatDistance(meters: review.distanceMeters)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            summaryLine
            trimHint
            Slider(value: $endMinutes, in: 1 ... maxMinutes, step: 1)
                .tint(AppTheme.sage)
            actionRow
            failureLine
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
        Text(String(localized: "\(review.sport) · \(keptMinutes) min\(distanceText) · avg HR \(review.avgHR)", bundle: LanguageManager.appBundle))
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
        Button { onSave(chosenEndSec) } label: {
            Text(String(localized: "Save", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(AppTheme.primary)
                .foregroundColor(.white)
                .cornerRadius(8)
        }
    }

    /// Asks first; the confirmation says what survives the delete (the raw
    /// backup, `discardRecoveredWorkout`).
    private var discardButton: some View {
        Button { confirmingDiscard = true } label: {
            Text(String(localized: "Discard", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(AppTheme.terracotta.opacity(0.12))
                .foregroundColor(AppTheme.terracotta)
                .cornerRadius(8)
        }
        .confirmationDialog(
            String(localized: "Discard this recovered workout?", bundle: LanguageManager.appBundle),
            isPresented: $confirmingDiscard,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Discard", bundle: LanguageManager.appBundle), role: .destructive, action: onDiscard)
        } message: {
            Text(String(localized: "It's removed from your history. Its backup is kept, so you can recover it again from Settings → iCloud & Data → Recover Lost Sessions.", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var failureLine: some View {
        if let failureMessage {
            Text(failureMessage)
                .font(.caption2)
                .foregroundColor(AppTheme.terracottaText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
