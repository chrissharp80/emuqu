import SwiftUI

// MARK: - RecordView Sections

extension RecordView {
    // MARK: - Overnight Done Section (auto-saved)

    // MARK: - Acceptance Section

    var acceptanceSection: some View {
        VStack(spacing: 12) {
            Text(String(localized: "Save this reading?", bundle: LanguageManager.appBundle))
                .font(.headline)

            Text(String(localized: "Accepting will save the session and clear the \(deviceStatus.connectedDeviceType?.displayName ?? String(localized: "device", bundle: LanguageManager.appBundle)) memory", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)

            acceptanceButtons
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private var acceptanceButtons: some View {
        HStack(spacing: 12) {
            Button(action: rejectSession) {
                Label(String(localized: "Discard", bundle: LanguageManager.appBundle), systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)

            Button(action: acceptSession) {
                Label(String(localized: "Save", bundle: LanguageManager.appBundle), systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Body sections
    // MARK: - Record stack sections
    //
    // One property per child of the stack, in the order they render. Each keeps
    // its original guard conditions and its original explanatory comment; only
    // the enclosing declaration is new.

    /// Step 1: Session Type Picker (hidden during active sessions)
    @ViewBuilder
    var sessionTypeSection: some View {
        if !isSessionActive {
            RecordSessionSelector(
                selectedSessionType: $selectedSessionType,
                quickSource: $quickSource
            )
        }
    }

    /// Selected session indicator with "Change" button
    @ViewBuilder
    var selectedSessionSection: some View {
        if selectedSessionType != nil, !isSessionActive {
            RecordSelectedSessionHeader(
                selectedSessionType: selectedSessionType,
                onChange: clearSelectedSession
            )
        }
    }

    /// Reading-type tag picker — pre-session ("flag this as
    /// 'sick' / 'late caffeine' before I start") so the
    /// selected tags persist onto the session at archive
    /// time via the existing `updateTags` flow (see
    /// `RecordView+Actions.applyTagsToCurrentSession`). Same gating
    /// as `RecordSelectedSessionHeader` above so tags only
    /// appear once the user has committed to a session
    /// type; hidden the moment recording starts so the
    /// live HRV view stays clean.
    @ViewBuilder
    var preSessionTagSection: some View {
        if selectedSessionType != nil, !isSessionActive {
            ReadingTagSelector(
                selectedTags: selectedTags,
                onToggle: { toggleTag($0) },
                onMore: { showingTagPicker = true }
            )
        }
    }

    /// Step 2: Source picker for Quick Reading (Polar vs Watch Breathe)
    @ViewBuilder
    var quickSourceSection: some View {
        if selectedSessionType == .quick, !isSessionActive, quickSource == nil {
            quickSourcePicker
        }
    }

    /// Step 3: Connection Section (Polar source or Extended/Nap sessions)
    /// Hidden during: overnight streaming, morning acceptance, device fetch, or processing
    @ViewBuilder
    var connectionSection: some View {
        if selectedSessionType != nil, !streamingLifecycle.isOvernightStreaming,
           !sessionState.needsAcceptance, !morningCoordination.isDeviceFetchInProgress,
           morningCoordination.morningStatus == nil {
            let needsConnection = selectedSessionType == .overnight || selectedSessionType == .nap ||
                (selectedSessionType == .quick && quickSource == .polar)
            if needsConnection, !deviceStatus.isStreaming {
                ConnectionPanel(polarManager: collector.polarManager, collector: collector, selectedSessionType: selectedSessionType)
            }
        }
    }

    /// Watch Breathe Section (shown when Watch Breathe source is selected within Quick)
    @ViewBuilder
    var watchBreatheSectionIfSelected: some View {
        if selectedSessionType == .quick, quickSource == .watchBreathe { watchBreathePanel }
    }

    /// The panel's inputs, gathered in one place so the section above stays a
    /// single condition rather than a wall of arguments nested inside it.
    private var watchBreathePanel: some View {
        WatchBreathePanel(
            reading: breatheReading,
            saved: breatheSaved,
            isWaiting: isWaitingForBreathe,
            listenStartDate: collector.healthKit.breatheListenStartDate,
            diagnostics: collector.healthKit.breatheDiagnostics,
            onSave: { saveBreatheSession($0) },
            onDismiss: { dismissBreatheReading() },
            onCancel: { cancelBreatheWait() }
        )
    }

    private func cancelBreatheWait() {
        stopWaitingForBreathe()
        withAnimation { quickSource = nil }
    }

    /// Recoverable data — shown whenever device has stranded data, regardless of session type selection.
    /// This must be visible immediately after connecting so the user can recover crashed/orphaned sessions.
    /// Triggers on EITHER: completed recordings (hasStoredExercise) OR active recording still running (isRecordingOnDevice).
    @ViewBuilder
    var recoverableDataSection: some View {
        if deviceStatus.isDeviceConnected, deviceStatus.hasStoredExercise || deviceStatus.isRecordingOnDevice, !fetchFailed, !sessionState.needsAcceptance, !deviceStatus.isStreaming, !sessionState.isCollecting, deviceStatus.fetchProgress == nil, morningCoordination.morningStatus == nil {
            RecoverableDataCard(
                deviceName: deviceStatus.connectedDeviceType?.displayName ?? String(localized: "Device", bundle: LanguageManager.appBundle),
                onRecover: recoverStoredData,
                onDiscard: discardAndStartFresh
            )
        }
    }

    /// Step 3: Active session controls (connected + streaming/recording/paused).
    @ViewBuilder
    var activeSessionSection: some View {
        if deviceStatus.isDeviceConnected || streamingLifecycle.isPaused,
           morningCoordination.morningStatus == nil, selectedSessionType != nil {
            // These sections are hidden during quick streaming to keep the live view at
            // the top, but stay visible during overnight streaming / paused so the user
            // still sees the status UI.
            // These sections are hidden during quick streaming to keep the live view at the top
            // But stay visible during overnight streaming / paused so the user sees the status UI
            if !deviceStatus.isStreaming || streamingLifecycle.isOvernightStreaming || streamingLifecycle.isPaused {
                retryFetchSection
                strapRecoverySection
                recoveredWorkoutReviewSection
                continueRecoverySection
                overnightRecordingSectionIfSelected
            }
            quickReadingSectionIfSelected
        }
    }

    /// Retry Fetch Section (shown when fetch failed)
    @ViewBuilder
    var retryFetchSection: some View {
        if fetchFailed {
            RetryFetchCard(
                isRetrying: isRetrying,
                isConnected: deviceStatus.connectionState == .connected,
                // Surface the specific reason for the most recent failure so the user
                // picks the right next step. Polar SDK errors get humanised; anything
                // else falls back to the platform localizedDescription.
                errorReason: sessionState.lastError.map { PolarErrorMessages.humanize($0) },
                onRetry: retryFetch,
                onCancelRetry: cancelFetchRetry,
                onDismiss: dismissFailedFetch
            )
        }
    }

    func cancelFetchRetry() {
        collector.polarManager.cancelFetch()
        isRetrying = false
    }

    func dismissFailedFetch() {
        fetchFailed = false
        collector.resetSession()
        quickSource = nil
        selectedSessionType = nil
    }

    /// Interrupted-workout recovery from
    /// the strap. Shows whenever a workout was
    /// recording when the app died (persisted state,
    /// not yet archived). Pulls the H10's complete
    /// on-device recording — no Lost Sessions
    /// disk-browsing, targeted at exactly this session.
    /// The manual "recover from strap" card hides once a
    /// recovery is pending review — otherwise both show and
    /// the user can trigger a second (junk) recovery.
    @ViewBuilder
    var strapRecoverySection: some View {
        if let workoutId = interruptedWorkoutId,
           morningCoordination.recoveredWorkoutReview == nil {
            workoutStrapRecoveryCard(sessionId: workoutId)
        }
    }

    /// Review/trim a just-recovered workout
    /// before keeping it. A crash can leave the strap
    /// recording long after you finish; this lets you
    /// drag the end back instead of a silent garbage save.
    @ViewBuilder
    var recoveredWorkoutReviewSection: some View {
        if let review = morningCoordination.recoveredWorkoutReview {
            RecoveredWorkoutReviewCard(
                review: review,
                onSave: { keepRecoveredWorkout(review, endSec: $0) },
                onDiscard: { discardRecoveredWorkout(review) }
            )
        }
    }

    /// Continue Recovery card — positioned right before the recording
    /// section so both resume affordances are in the same visual area.
    @ViewBuilder
    var continueRecoverySection: some View {
        if (selectedSessionType == .overnight || selectedSessionType == .nap)
            && !streamingLifecycle.isOvernightStreaming && !streamingLifecycle.isPaused,
            let recentSession = sessionState.recentPausedSession {
            continueRecoveryCard(session: recentSession)
        }
    }

    @ViewBuilder
    var overnightRecordingSectionIfSelected: some View {
        if selectedSessionType == .overnight || selectedSessionType == .nap {
            overnightRecordingSection
        }
    }

    /// Quick Reading Section (Polar source only)
    @ViewBuilder
    var quickReadingSectionIfSelected: some View {
        if selectedSessionType == .quick, quickSource == .polar {
            quickReadingSection
        }
    }

    /// Morning Processing Card (shown during stop -> analyze flow)
    @ViewBuilder
    var morningProcessingSection: some View {
        if let status = morningCoordination.morningStatus {
            MorningProcessingCard(
                status: status,
                onSkipDeviceFetch: {
                    collector.deviceFetchPolicy = .skipByUser
                    collector.polarManager.cancelFetch()
                },
                onSkipSleepWait: {
                    collector.morningProcessingService.skipSleepWait = true
                }
            )
        }
    }

    /// Live Data Section (when quick streaming only - not overnight)
    /// Guard with morningStatus == nil to prevent flashing during
    /// the stop-overnight → morning-processing transition.
    @ViewBuilder
    var liveDataSection: some View {
        if deviceStatus.isStreaming, !streamingLifecycle.isOvernightStreaming, morningCoordination.morningStatus == nil {
            LiveDataPanel(polarManager: collector.polarManager)
        }
    }

    /// Verification Section (when pending acceptance)
    @ViewBuilder
    var verificationSectionIfPending: some View {
        if let verification = sessionState.verificationResult {
            RecordVerificationSection(
                verification: verification,
                recoveryWindow: sessionState.recoveryWindow
            )
        }
    }

    /// Results Preview for quick readings (tap to see full results)
    /// Overnight/nap sessions auto-accept and navigate to Dashboard.
    @ViewBuilder
    var morningResultsPreviewSection: some View {
        if sessionState.needsAcceptance,
           let session = sessionState.currentSession,
           let result = session.analysisResult,
           session.sessionType != .overnight,
           session.sessionType != .nap {
            morningResultsPreview(session: session, result: result)
        }
    }

    /// Results Preview (for streaming readings) - tap to see full report
    @ViewBuilder
    var quickResultsSection: some View {
        if let session = sessionState.currentSession,
           session.state == .complete,
           !sessionState.needsAcceptance,
           let result = session.analysisResult {
            QuickResultsCard(
                session: session,
                result: result,
                onViewReport: { presentQuickReport(session: session, result: result) },
                onDone: clearFinishedQuickReading
            )
        }
    }

    func presentQuickReport(session: HRVSession, result: HRVAnalysisResult) {
        Task {
            cachedRecentSessions = await collector.recentSessionsAsync(limit: MorningResultsView.recentSessionsContextLimit)
            quickPresentation = ResultsPresentation(session: session, result: result)
        }
    }

    func clearFinishedQuickReading() {
        collector.resetSession()
        selectedTags.removeAll()
        sessionNotes = ""
        quickSource = nil
        selectedSessionType = nil
    }

    /// Acceptance: quick readings need Save/Discard
    /// Overnight/nap sessions auto-accept via onChange handler.
    @ViewBuilder
    var acceptanceSectionIfNeeded: some View {
        if sessionState.needsAcceptance,
           let sessionType = sessionState.currentSession?.sessionType,
           sessionType != .overnight,
           sessionType != .nap {
            acceptanceSection
        }
    }

    // MARK: - Results covers

    func morningCover(_ presentation: ResultsPresentation) -> some View {
        NavigationStack {
            morningResultsWithAlert(presentation)
                .overlay { reanalyzingOverlay }
                .toolbar { morningDoneToolbar }
        }
    }

    func morningResultsWithAlert(_ presentation: ResultsPresentation) -> some View {
        morningResults(presentation)
            .alert(sleepEditFailedTitle, isPresented: $sleepEditSaveFailed) {
                Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) {}
            } message: {
                Text(String(localized: "Your timeline change couldn't be stored. Please try again.", bundle: LanguageManager.appBundle))
            }
    }

    var sleepEditFailedTitle: String {
        String(localized: "Sleep edit not saved", bundle: LanguageManager.appBundle)
    }

    func morningResults(_ presentation: ResultsPresentation) -> some View {
        let session = presentation.session
        return MorningResultsView(
            session: session,
            result: reanalyzedResult ?? presentation.result,
            recentSessions: cachedRecentSessions,
            onDiscard: { dismissMorningReading() },
            onReanalyze: { await collector.reanalyzeSession($0, method: $1) },
            onReanalyzeAt: { await collector.reanalyzeAtPosition(session, targetMs: $0) },
            onApplyManualResult: { await applyManualMorningResult($0, to: session) },
            onUpdateSleep: { collector.updateSessionSleepBoundaries(sessionId: session.id, sleepData: $0) },
            onAdjustSleep: { adjustMorningSleep($0, for: session) },
            onUnlinkSegment: { collector.unlinkSegment(segmentId: $0, fromSession: session.id) },
            linkedSegments: collector.archive.linkedSegments(for: session)
        )
    }

    func dismissMorningReading() {
        discardMorningReading()
        morningPresentation = nil
        reanalyzedResult = nil
    }

    /// The morning sheet must not only preview a manual window but
    /// apply it: a choice held in `@State` only never
    /// recomputes the score. Persisting through `ReanalysisService` makes
    /// `windowUserAdjusted` + `recoveryScore` stick.
    func applyManualMorningResult(_ manualResult: HRVAnalysisResult, to session: HRVSession) async -> HRVSession? {
        await collector.applyManualAnalysis(session, result: manualResult)
    }

    /// Surfaces persist failure (see DashboardV2View's onAdjust note).
    func adjustMorningSleep(_ sleepData: SleepData, for session: HRVSession) {
        if !collector.updateSessionSleepBoundaries(sessionId: session.id, sleepData: sleepData, isUserAdjustment: true) {
            sleepEditSaveFailed = true
        }
    }

    @ViewBuilder
    var reanalyzingOverlay: some View {
        if isReanalyzing {
            ZStack {
                Color.black.opacity(0.3)
                reanalyzingLabel
            }
            .ignoresSafeArea()
        }
    }

    var morningDoneToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle), action: finishMorningReading)
        }
    }

    func finishMorningReading() {
        if let newResult = reanalyzedResult {
            collector.updateCurrentSessionResult(newResult)
        }
        saveMorningReading()
        morningPresentation = nil
        reanalyzedResult = nil
    }

    func quickCover(_ presentation: ResultsPresentation) -> some View {
        NavigationStack {
            quickResults(presentation)
                .toolbar { quickDoneToolbar(presentation) }
        }
    }

    func quickResults(_ presentation: ResultsPresentation) -> some View {
        let session = presentation.session
        return MorningResultsView(
            session: session,
            result: presentation.result,
            recentSessions: cachedRecentSessions,
            onDiscard: { discardQuickReading(session) },
            onUpdateSleep: { collector.updateSessionSleepBoundaries(sessionId: session.id, sleepData: $0) }
        )
    }

    func discardQuickReading(_ session: HRVSession) {
        do {
            try collector.archive.delete(session.id)
            Task { await AppDependencies.current.storage.cloudKitSyncManager.uploadDeletion(session.id) }
        } catch {
            debugLog("[RecordView] ⚠️ Failed to delete discarded session \(session.id.uuidString.prefix(8)): \(error)")
        }
        resetAfterQuickReading()
    }

    func resetAfterQuickReading() {
        quickPresentation = nil
        collector.resetSession()
        quickSource = nil
        selectedSessionType = nil
    }

    func quickDoneToolbar(_ presentation: ResultsPresentation) -> some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) {
                finishQuickReading(presentation)
            }
        }
    }

    func finishQuickReading(_ presentation: ResultsPresentation) {
        Task {
            await collector.updateCompositeRecoveryScore(for: presentation.session, exportMetrics: true)
        }
        resetAfterQuickReading()
    }

    // MARK: - Extracted callbacks
    //
    // Each of these would, as an inline closure, put its enclosing
    // view one level past the spec nesting limit. Lifting the closure out is
    // the flattening; the call sites above read as the intent.

    func scrollToTop(_ proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo("recordTop", anchor: .top) }
    }

    func clearSelectedSession() {
        if isWaitingForBreathe { stopWaitingForBreathe() }
        breatheReading = nil
        breatheSaved = false
        quickSource = nil
        withAnimation { selectedSessionType = nil }
    }

    func keepRecoveredWorkout(_ review: MorningCoordination.RecoveredWorkoutReview, endSec: Double) {
        interruptedWorkoutId = nil
        Task { await collector.retrimRecoveredWorkout(sessionId: review.sessionId, endSec: endSec) }
    }

    func discardRecoveredWorkout(_ review: MorningCoordination.RecoveredWorkoutReview) {
        interruptedWorkoutId = nil
        collector.discardRecoveredWorkout(sessionId: review.sessionId)
    }

    var reanalyzingLabel: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            Text(String(localized: "Reanalyzing...", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(.white)
        }
        .padding(20)
        .background(Color.black.opacity(0.7))
        .cornerRadius(12)
    }

}

// MARK: - File-scope helpers
//
// Each names no member of RecordView and calls nothing inside it, so
// none needs to be a member. `private` at file scope is fileprivate, so
// every call site in this file resolves.
