import SwiftUI

/// Recording view for HRV data collection - supports both overnight H10 recording and quick streaming
struct RecordView: View {
    @Environment(RRCollector.self) var collector
    // Direct sub-object observation. Reading recording state through
    // `collector.X` forwarders does NOT trigger SwiftUI re-renders because
    // RRCollector itself publishes nothing — its state lives on these
    // sub-objects. Every recording-state read in this view (and its +Panels
    // / +Sections extensions) goes through these references.
    @Environment(DeviceStatus.self) var deviceStatus
    @Environment(StreamingLifecycle.self) var streamingLifecycle
    @Environment(SessionState.self) var sessionState
    @Environment(MorningCoordination.self) var morningCoordination
    @Environment(SettingsManager.self) var settingsManager
    @Binding var selectedTab: MainTabView.Tab
    var scrollToTopToken: UUID = .init()
    @State var selectedTags: Set<ReadingTag> = []
    @State var showingTagPicker = false
    @State var sessionNotes = ""
    @State private var showingError = false
    @State var morningPresentation: ResultsPresentation?
    @State var quickPresentation: ResultsPresentation?
    /// The Marco Altini moment. While
    /// `pendingMorningPresentation` is non-nil, the PreScorePromptView
    /// (full-screen) gates the score reveal. On prompt completion, the
    /// answers are persisted to the session's morning-feeling tags and
    /// `morningPresentation` is set, triggering the actual results sheet.
    @State var pendingMorningPresentation: ResultsPresentation?
    @State var fetchFailed = false
    @State var isRetrying = false
    /// Sleep timeline edit failed to persist (see
    /// DashboardV2View.sleepEditSaveFailed).
    @State var sleepEditSaveFailed = false
    @State var selectedSessionType: SessionType? = .overnight
    @State var cachedRecentSessions: [HRVSession] = []
    /// Interrupted-workout (crash) recover-from-strap UI state.
    @State private var isRecoveringWorkout = false
    @State private var workoutRecoverMessage: String?
    /// Loaded once on appear (NOT per-render — it scans backup headers) so the
    /// recovery card shows even when the crash flag is missing.
    @State var interruptedWorkoutId: UUID?
    @State var breathingAudio = BreathingAudioManager()

    /// Captures session + result at presentation time so the fullScreenCover content
    /// never reads a stale/nil sessionState.currentSession. Eliminates the race condition
    /// where currentSession becomes nil between trigger and SwiftUI content evaluation.
    struct ResultsPresentation: Identifiable {
        let id: UUID
        let session: HRVSession
        let result: HRVAnalysisResult
        init(session: HRVSession, result: HRVAnalysisResult) {
            id = session.id
            self.session = session
            self.result = result
        }
    }

    enum ExtendedCaptureMode: String, CaseIterable, Identifiable {
        case streaming
        case internalCapture
        case both

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .streaming: String(localized: "Streaming", bundle: LanguageManager.appBundle)
            case .internalCapture: String(localized: "Internal", bundle: LanguageManager.appBundle)
            case .both: String(localized: "Both", bundle: LanguageManager.appBundle)
            }
        }
    }

    @State var extendedCaptureMode: ExtendedCaptureMode = .both

    var body: some View {
        recordSurface
            .alert(String(localized: "Error", bundle: LanguageManager.appBundle), isPresented: $showingError) {
                errorAlertActions
            } message: {
                errorAlertMessage
            }
            // SessionState is @Observable, so there is no `$lastError`. Key the
            // change on a String projection because `Error?` is not Equatable.
            .onChange(of: sessionState.lastError.map { String(describing: $0) }) { _, newError in
                presentErrorIfActionable(newError)
            }
            .onChange(of: sessionState.needsAcceptance) { _, needsAcceptance in
                routeOvernightAcceptance(needsAcceptance)
            }
            .onAppear { restoreCaptureMode() }
            // A Verity Sense can't do `.both`; if it connects while that mode is
            // selected (e.g. carried over from an H10 default), fall back to a
            // valid choice so the segmented picker doesn't render with no selection.
            .onChange(of: deviceStatus.connectedDeviceType) { _, _ in coerceCaptureModeForDevice() }
    }

    /// The scroll surface plus everything it can present over itself.
    private var recordSurface: some View {
        recordScroll
            .navigationTitle(String(localized: "Record", bundle: LanguageManager.appBundle))
            .background(AppTheme.background)
            .sheet(isPresented: $showingTagPicker) { tagPickerSheet }
            .fullScreenCover(item: $pendingMorningPresentation) { preScoreCover($0) }
            .fullScreenCover(item: $morningPresentation) { morningCover($0) }
            .fullScreenCover(item: $quickPresentation) { quickCover($0) }
    }

    // MARK: - Body structure
    //
    // `body` is split into the scroll container, the stack of sections, and
    // one property per section (as one declaration it was 444 lines nested
    // eight deep). Every extraction is a computed property on this same
    // struct, so view identity and @State ownership are unaffected — no
    // child structs, no state moved.

    private var recordScroll: some View {
        ScrollViewReader { scrollProxy in
            ScrollView { recordStack }
                .onChange(of: scrollToTopToken) { scrollToTop(scrollProxy) }
                .task { await resolveInterruptedWorkout() }
        }
    }

    private var recordStack: some View {
        VStack(spacing: 20) {
            sessionTypeSection
            selectedSessionSection
            preSessionTagSection
            connectionSection
            recoverableDataSection
            activeSessionSection
            morningProcessingSection
            liveDataSection
            verificationSectionIfPending
            morningResultsPreviewSection
            quickResultsSection
            acceptanceSectionIfNeeded
        }
        .padding()
        .id("recordTop")
    }

    /// Resolve an interrupted workout once on appear.
    private func resolveInterruptedWorkout() async {
        // Flag OR newest un-archived workout backup, so the recovery card shows
        // even when the crash flag did not persist. 2026-08 — off-main: the scan
        // does per-backup disk I/O and was trapping the main thread here.
        interruptedWorkoutId = await collector.findInterruptedWorkoutSessionId()
    }

    // MARK: - Sheets and covers

    private var tagPickerSheet: some View {
        TagPickerSheet(
            selectedTags: $selectedTags,
            availableTags: settingsManager.settings.allTags
        )
    }

    /// The pre-score subjective prompt fires BEFORE the
    /// morning-results sheet. Captures feeling / soreness / motivation and gates
    /// the score reveal. Skipping still gates the reveal — there is no bypass.
    private func preScoreCover(_ pending: ResultsPresentation) -> some View {
        PreScorePromptView { answers, _ in
            // Persist answers as morning-feeling tags on the session. Even on skip
            // we hand off to the score reveal — the prompt is mandatory to appear,
            // never mandatory to answer.
            applyMorningFeelingAnswers(answers, to: pending.session)
            pendingMorningPresentation = nil
            morningPresentation = pending
        }
    }

    @ViewBuilder
    private var errorAlertActions: some View {
        Button(String(localized: "OK", bundle: LanguageManager.appBundle)) {
            // Clean up stale failed session so the view resets to idle
            if sessionState.currentSession?.state == .failed {
                fetchFailed = false
                collector.resetSession()
            }
        }
    }

    /// Humanise Polar SDK errors. Raw `PolarErrors` enum text
    /// ("PolarBleSdk.PolarErrors error 3.") gives the user no idea whether
    /// to retry or give up (reported by a tester with an H10 stuck at 30%
    /// retrieval after an overnight session).
    @ViewBuilder
    private var errorAlertMessage: some View {
        if let error = sessionState.lastError {
            Text(PolarErrorMessages.humanize(error))
        } else {
            Text(String(localized: "Unknown error", bundle: LanguageManager.appBundle))
        }
    }

    // MARK: - Body event handlers

    private func presentErrorIfActionable(_ newError: String?) {
        // Don't show error popup during overnight streaming - user is asleep and can't act on it
        // Error will be visible when they wake up and try to get morning reading
        if newError != nil, !streamingLifecycle.isOvernightStreaming {
            showingError = true
        }
    }

    private func routeOvernightAcceptance(_ needsAcceptance: Bool) {
        // Overnight/nap: go to Dashboard and auto-accept immediately.
        // Device fetch is now inline (completed before score is shown),
        // so the score is final — no background refinement to wait for.
        if needsAcceptance,
           let session = sessionState.currentSession,
           session.analysisResult != nil,
           session.sessionType == .overnight || session.sessionType == .nap {
            selectedTab = .dashboard
            autoAcceptOvernight()
        }
    }

    private func restoreCaptureMode() {
        // Restore capture mode from persisted state when returning to a paused session.
        if streamingLifecycle.isPaused, let useBackup = collector.getPersistedCaptureMode() {
            extendedCaptureMode = useBackup ? .both : .streaming
        } else if !streamingLifecycle.isOvernightStreaming {
            // Load user's saved default capture mode preference
            extendedCaptureMode = ExtendedCaptureMode(rawValue: settingsManager.settings.defaultCaptureMode) ?? .both
        }
        coerceCaptureModeForDevice()
    }

    /// Snap `.both` to `.streaming` when a Verity Sense is connected — that strap
    /// can't stream and record internally at once, so `.both` isn't a real option
    /// for it (see `availableCaptureModes`). No-op for the H10.
    func coerceCaptureModeForDevice() {
        if deviceStatus.connectedDeviceType == .veritySense, extendedCaptureMode == .both {
            extendedCaptureMode = .streaming
        }
    }

    /// One-tap recovery of a crashed workout straight from the strap's
    /// on-device recording — no Lost Sessions disk-list, no junk.
    @ViewBuilder
    func workoutStrapRecoveryCard(sessionId _: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            workoutRecoverHeader
            Text(String(localized: "A workout was recording when the app closed. Your strap kept the full session — connect it, then recover here. (No need to dig through Lost Sessions.)", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            workoutRecoverError
            Button(action: startWorkoutRecovery) { workoutRecoverButtonLabel }
                .buttonStyle(.plain)
                .disabled(isRecoveringWorkout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.terracotta.opacity(0.08))
        .overlay(workoutRecoverBorder)
        .cornerRadius(12)
    }

    private var workoutRecoverHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.heart.fill")
                .foregroundColor(AppTheme.terracotta)
            Text(String(localized: "Unfinished workout", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.textPrimary)
        }
    }

    private var workoutRecoverBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(AppTheme.terracotta.opacity(0.3), lineWidth: 1)
    }

    @ViewBuilder
    private var workoutRecoverError: some View {
        if let msg = workoutRecoverMessage {
            Text(msg)
                .font(.caption2)
                .foregroundColor(AppTheme.terracottaText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workoutRecoverButtonLabel: some View {
        HStack(spacing: 6) {
            if isRecoveringWorkout { ProgressView().scaleEffect(0.7) }
            Text(isRecoveringWorkout
                ? String(localized: "Recovering\u{2026}", bundle: LanguageManager.appBundle)
                : String(localized: "Recover workout from strap", bundle: LanguageManager.appBundle))
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(AppTheme.primary)
        .foregroundColor(.white)
        .cornerRadius(8)
    }

    /// On success we stay on Record — the review/trim card then appears so the
    /// user can confirm/trim before keeping it, instead of jumping away to a
    /// silent archive.
    private func startWorkoutRecovery() {
        Task {
            isRecoveringWorkout = true
            workoutRecoverMessage = nil
            let recovered = await collector.recoverInterruptedWorkoutFromStrap()
            isRecoveringWorkout = false
            if recovered != nil {
                interruptedWorkoutId = nil
            } else {
                workoutRecoverMessage = String(localized: "Couldn't recover — make sure the strap is connected, then try again.", bundle: LanguageManager.appBundle)
            }
        }
    }

    /// Auto-accept overnight/nap session and clear UI state.
    func autoAcceptOvernight() {
        debugLog("[AutoAccept] autoAcceptOvernight called")
        Task {
            if let session = sessionState.currentSession {
                await scoreLatestVersion(of: session)
            } else {
                debugLog("[AutoAccept] currentSession is nil — skipping")
            }
            await MainActor.run {
                collector.clearAcceptanceState()
                selectedTags.removeAll()
                sessionNotes = ""
                debugLog("[AutoAccept] clearAcceptanceState done")
            }
        }
    }

    /// Read from the archive to get the latest version — background
    /// refinement may have archived a composite/device session under the same
    /// ID, superseding the streaming-only one.
    ///
    /// Off-main decode. `archive.retrieve` does a synchronous
    /// disk read + decrypt + full rrSeries JSON decode; this Task inherits the
    /// @MainActor view isolation, so a sync call would freeze the UI for the
    /// whole-night payload at wake time. `retrieveFullSessionAsync` runs it on
    /// a detached task.
    private func scoreLatestVersion(of session: HRVSession) async {
        debugLog("[AutoAccept] currentSession=\(session.id.uuidString.prefix(8)), source=\(session.dataSourceSummary?.selectedSource ?? "nil")")
        let retrieved = await collector.retrieveFullSessionAsync(session.id)
        let latestSession = retrieved ?? session
        debugLog("[AutoAccept] archive.retrieve(\(session.id.uuidString.prefix(8))): \(retrieved == nil ? "FAILED — using in-memory session" : "OK"), source=\(latestSession.dataSourceSummary?.selectedSource ?? "nil")")
        await collector.updateCompositeRecoveryScore(for: latestSession, exportMetrics: true)
    }

}
