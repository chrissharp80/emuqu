import Charts
import MessageUI
import QuickLook
import SwiftUI

/// Time range for one segment of a split-night recording.
struct LinkedSegmentInfo: Identifiable {
    let id: UUID
    let startDate: Date
    let endDate: Date
}

/// Comprehensive Recovery Report showing HRV analysis, sleep data, training load, and vitals
/// A one-stop morning readiness check for athletes and health-conscious users
struct MorningResultsView: View {
    @Environment(\.dependencies) var dependencies
    /// How many overnight sessions before the opened one its callers load as
    /// `recentSessions`: four weeks of nights, enough for the trend card, the
    /// sleep history and the summary's baseline findings.
    static let recentSessionsContextLimit = 28

    let session: HRVSession
    let result: HRVAnalysisResult
    let recentSessions: [HRVSession] // For trend comparison

    /// Required callback - either discard (for new sessions) or simple dismiss
    let onDiscard: () -> Void

    /// What the Discard confirmation tells the user they lose. Discard (shown
    /// when there is no `onDelete`) throws the reading away, so it always
    /// asks first; each caller states its own consequence (Trash, baseline,
    /// an import never saved). Nil falls back to a plain "discards" line.
    let discardMessage: String?

    // Optional callbacks for history view features
    var onDelete: (() -> Void)?
    var onReanalyze: ((HRVSession, WindowSelectionMethod) async -> HRVSession?)?
    var onUpdateTags: (([ReadingTag], String?) -> Void)?

    /// Optional callback for manual window reanalysis (timestamp in ms).
    /// Returns the analysis result so caller can decide how to display it.
    var onReanalyzeAt: ((Int64) async -> HRVAnalysisResult?)?

    /// Apply the previewed manual window. `onReanalyzeAt` alone produces
    /// an `HRVAnalysisResult` for comparison only; without persisting it
    /// back to the session the user's pick is lost when the sheet closes
    /// and the recovery score never recomputes. Callers wire this to `ReanalysisService.applyManualAnalysis`, which
    /// writes `windowUserAdjusted = true`, recomputes the recovery
    /// score against the new window, and re-archives the session.
    var onApplyManualResult: ((HRVAnalysisResult) async -> HRVSession?)?

    /// Optional callback to update stored sleep boundaries when HealthKit has more complete data
    var onUpdateSleep: ((SleepData) -> Void)?

    /// Optional callback for user-initiated sleep adjustments (exclude/boundary changes)
    var onAdjustSleep: ((SleepData) -> Void)?

    /// Optional callback to unlink a segment from the same-night merge.
    /// Returns whether the unlink was stored; the sheet removes the segment
    /// only when it was.
    var onUnlinkSegment: ((UUID) -> Bool)?

    /// Linked segment time ranges for split-night recordings. Nil for standalone sessions.
    var linkedSegments: [LinkedSegmentInfo]?

    @State var vm: MorningResultsViewModel

    // UI-only state (not shared with VM)
    @State var exportURL: IdentifiableURL?
    @State var emailURL: IdentifiableURL?
    @State var showingReanalyzeConfirmation = false
    /// The window method picked from the Analysis Window menu, waiting for
    /// the confirmation: picking one re-scores and re-saves the reading.
    @State var pendingWindowMethod: WindowSelectionMethod?
    /// The last re-analysis came back with no session (no beat data, or one
    /// already running): the score is unchanged and the alert says so.
    @State var reanalysisDeclined = false
    @State var isManualWindowMode = false
    @State var manualResult: HRVAnalysisResult?
    @State var showReportSectionPicker = false
    @State var showEmailSectionPicker = false
    @State var showingDeleteConfirmation = false
    @State var showingDiscardConfirmation = false
    @State var showingUnlinkConfirmation = false
    @State var pendingUnlinkSegmentId: UUID?
    @State var removedSegmentIds: Set<UUID> = []
    /// The last segment unlink was not stored: the segment stays linked and
    /// listed, and the "couldn't remove" alert says so.
    @State var segmentUnlinkFailed = false

    /// Why the last PDF or RR export produced no file; drives the
    /// "Export failed" alert. Nil when there is nothing to report.
    @State var exportErrorMessage: String?

    /// The tags and notes last handed to `onUpdateTags`, nil until the first
    /// hand-off (the session's own tags and notes are the baseline then).
    @State var savedTagsAndNotes: SavedTagsAndNotes?

    /// Visible feedback for manual-window picks. Without
    /// this, a tap that the algorithm rejects (high artifact rate at
    /// that position, or out-of-range timestamp) silently does nothing
    /// and the user thinks the picker is broken.
    @State var manualPickMessage: String?
    @State var strapMergeWorking = false
    @State var strapMergeMessage: String?

    /// First-score explainer. Presents the existing
    /// "Understanding Your Score" Help article in a sheet from the small
    /// ⓘ next to the recovery ring, so a new user can learn what the
    /// number means without hunting through Help & Learn.
    @State var showingScoreExplainer = false

    /// Set once the user adjusts sleep on this screen, so a later HealthKit
    /// refetch can't replace their adjustment with raw data.
    @State private var sleepAdjustedHere = false

    /// Score ring scales with Dynamic Type for accessibility
    @ScaledMetric(relativeTo: .title) var scoreRingSize: CGFloat = 180

    /// Dynamic Type scaling for the big numeric readouts in
    /// the detail cards. Fixed `.system(size:)` values would ignore
    /// the user's text-size setting entirely. Scaled here
    /// (extensions can't hold stored @ScaledMetric props) and consumed
    /// in MorningResultsView+DetailCards.
    @ScaledMetric(relativeTo: .largeTitle) var heroScoreFontSize: CGFloat = 56
    @ScaledMetric(relativeTo: .title) var metricValueFontSize: CGFloat = 32

    /// Collector access for non-observable methods. State reads go through the
    /// sub-objects below, which own that state.
    @Environment(RRCollector.self) var collector
    @Environment(MorningCoordination.self) var morningCoordination
    /// Observe archive changes so re-analyze / sleep
    /// refresh fired from any other surface (Dashboard, History,
    /// Reanalyze All) propagates into THIS sheet too. Without this,
    /// the user could re-analyze the morning recording from the
    /// dashboard, return to the open Recovery Report sheet, and see
    /// the OLD score because `vm.session` was captured at sheet
    /// presentation time. Same problem in reverse: refresh sleep
    /// inside the report → dashboard doesn't see the change without
    /// re-fetching from disk. The view-model's
    /// `applyExternalArchiveUpdate(version:)` re-loads from
    /// `AppDependencies.current.storage.sessionArchive` and updates `reanalyzedSession` so
    /// every computed property (`displaySession`, `compositeRecoveryScore`,
    /// `recoveryBreakdown`) sees the new state.
    @Environment(ArchiveSignal.self) var archiveSignal
    /// Feeds the segment-removal animation so the
    /// transition is skipped when the user has Reduce Motion on.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Computed properties delegated to VM:
    // vm.compositeRecoveryScore, vm.displaySession, vm.displayResult, vm.hasRawData,
    // sessionReferenceDate, vm.isHistoricalSession, scoringConfig,
    // recoveryBreakdown(), analysisSummary, trendStats, trendInsight

    init(
        session: HRVSession,
        result: HRVAnalysisResult,
        recentSessions: [HRVSession] = [],
        onDiscard: @escaping () -> Void,
        discardMessage: String? = nil,
        onDelete: (() -> Void)? = nil,
        onReanalyze: ((HRVSession, WindowSelectionMethod) async -> HRVSession?)? = nil,
        onUpdateTags: (([ReadingTag], String?) -> Void)? = nil,
        onReanalyzeAt: ((Int64) async -> HRVAnalysisResult?)? = nil,
        onApplyManualResult: ((HRVAnalysisResult) async -> HRVSession?)? = nil,
        onUpdateSleep: ((SleepData) -> Void)? = nil,
        onAdjustSleep: ((SleepData) -> Void)? = nil,
        onUnlinkSegment: ((UUID) -> Bool)? = nil,
        linkedSegments: [LinkedSegmentInfo]? = nil
    ) {
        self.session = session
        self.result = result
        self.recentSessions = recentSessions
        self.onDiscard = onDiscard
        self.discardMessage = discardMessage
        self.onDelete = onDelete
        self.onReanalyze = onReanalyze
        self.onUpdateTags = onUpdateTags
        self.onReanalyzeAt = onReanalyzeAt
        self.onApplyManualResult = onApplyManualResult
        self.onUpdateSleep = onUpdateSleep
        self.onAdjustSleep = onAdjustSleep
        self.onUnlinkSegment = onUnlinkSegment
        self.linkedSegments = linkedSegments
        _vm = State(wrappedValue: MorningResultsViewModel(
            session: session,
            result: result,
            recentSessions: recentSessions
        ))
    }

    /// A session is "unreadable" when it carries no usable
    /// HRV metrics (rmssd ≤ 0) AND no recovery score AND the data-quality
    /// flag didn't already route us into the SubjectiveReadinessCard path.
    /// Without this guard the post-reading payoff screen renders a row of
    /// near-blank cards (score 0, "—" everywhere) instead of explaining
    /// what went wrong. The subjective-readiness path (preSleep /
    /// insufficient) is intentionally NOT treated as unreadable — that
    /// flow has its own card.
    private var sessionIsUnreadable: Bool {
        let quality = vm.displaySession.hrvDataQuality
        if quality == .preSleep || quality == .insufficient { return false }
        let hasScore = vm.displaySession.recoveryScore != nil
        let hasHRV = vm.displayResult.timeDomain.rmssd > 0
        return !hasScore && !hasHRV
    }

    var body: some View {
        // Compute breakdown once per render; the score card and breakdown section both read it.
        let breakdown = vm.recoveryBreakdown()
        return withLifecycle(withExportHandling(withDialogs(withSheets(resultsStack(breakdown)))))
    }

    private func resultsStack(_ breakdown: RecoveryScoreCalculator.ScoreBreakdown) -> some View {
        ZStack {
            readableOrUnreadableBody(breakdown)

            // PDF Generation Loading Overlay
            if vm.isGeneratingPDF {
                reanalysis.pdfLoadingOverlay
            }

            // Reanalysis Loading Overlay
            if vm.isReanalyzing {
                reanalysisLoadingOverlay
            }
        }
    }

    private var reanalysisLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text(String(localized: "Analyzing...", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(.white)
            }
            .padding(24)
            .background(AppTheme.cardBackground.opacity(0.95))
            .cornerRadius(12)
        }
    }

    @ViewBuilder
    private func readableOrUnreadableBody(
        _ breakdown: RecoveryScoreCalculator.ScoreBreakdown
    ) -> some View {
        if sessionIsUnreadable {
            unreadableSessionState
        } else {
            ScrollView {
                resultsSections(breakdown)
                    .padding()
            }
            .background(AppTheme.background.ignoresSafeArea())
            // The morning screen proper, as opposed to the unreadable-session
            // state above it. A UI test asserting "the results rendered" has
            // to be able to tell those two apart.
            .accessibilityIdentifier("morning.root")
        }
    }

    @ViewBuilder
    private func resultsSections(_ breakdown: RecoveryScoreCalculator.ScoreBreakdown) -> some View {
        VStack(spacing: 20) {
            heroAndReadinessSections(breakdown)
            primaryMetricsSections
            trainingAndVitalsSections(breakdown)
        }
    }

    @ViewBuilder
    private func heroAndReadinessSections(
        _ breakdown: RecoveryScoreCalculator.ScoreBreakdown
    ) -> some View {
        // MARK: - Recovery Score Hero (matches Recovery Dashboard)

        cards.recoveryScoreCard(breakdownMessage: ScoreBreakdownCopy.message(for: breakdown, loadLevel: vm.adviceLoadLevel))

        // Feeling badge (read-only in this view — editing only
        // happens on the Dashboard while the session is today's.
        // Once it leaves the dashboard, the feeling is frozen).
        if let feeling = vm.displaySession.morningFeeling {
            MorningFeelingBadge(feeling: feeling)
        }
        // MARK: - Subjective Readiness (when HRV data is invalid)

        subjectiveReadinessSection

        // MARK: - Training Readiness (today only; the readiness frozen at acceptance)

        if !vm.isHistoricalSession {
            cards.trainingReadinessCard
        }
    }

    /// Reads `displaySession`, so a re-analysis on this screen that sets or
    /// clears `.insufficient` re-routes the card without reopening the sheet.
    @ViewBuilder
    private var subjectiveReadinessSection: some View {
        let quality = vm.displaySession.hrvDataQuality
        if quality == .preSleep || quality == .insufficient {
            SubjectiveReadinessCard(
                perceivedReadiness: Binding(
                    get: { vm.displaySession.perceivedReadiness },
                    set: { newValue in
                        vm.updatePerceivedReadiness(newValue)
                    }
                ),
                quality: quality ?? .insufficient
            )
        }
    }

    private var primaryMetricsSections: some View {
        // MARK: - Primary Metrics Row (HRV + Sleep side-by-side)

        HStack(spacing: 12) {
            hrvDetailLink
            sleepDetailLink
        }

        // Sleep detail is accessible via the compact sleep card above.
        // The full-width sleep card belongs in SleepDetailView only.

    }

    private var hrvDetailLink: some View {
        NavigationLink {
            SessionHRVDetailView(
                session: vm.displaySession,
                result: vm.displayResult,
                recentSessions: recentSessions,
                baselineStats: vm.baselineStats
            )
        } label: {
            cards.hrvMetricCard
        }
        .buttonStyle(.plain)
    }

    private var sleepDetailLink: some View {
        NavigationLink { sleepDetailDestination } label: { cards.sleepMetricCardCompact }
            .buttonStyle(.plain)
    }

    private var sleepDetailDestination: some View {
        // Routed to the V2 sleep detail (same surface
        // the dashboard opens). V2 takes the session
        // directly, which also gives this entry point
        // the strap-derived context.
        SleepDetailV2View(
            session: vm.displaySession,
            sleepData: vm.healthKitSleep,
            recoveryVitals: vm.recoveryVitals,
            recentSessions: recentSessions,
            temperatureUnit: dependencies.app.settingsManager.settings.temperatureUnit,
            typicalSleepHours: dependencies.app.settingsManager.settings.typicalSleepHours,
            userAge: dependencies.app.settingsManager.settings.age,
            onAdjust: { adjusted in
                sleepAdjustedHere = true
                vm.healthKitSleep = adjusted
                onAdjustSleep?(adjusted)
            }
        )
    }

    @ViewBuilder
    private func trainingAndVitalsSections(
        _ breakdown: RecoveryScoreCalculator.ScoreBreakdown
    ) -> some View {
        trainingLoadSection

        // Overnight Charts (inline between training and vitals)
        overnightChartsSection(breakdown)

        // Data Source Summary (transparency card showing what data was used)
        dataSourceSection

        // Analysis Summary
        analysisSummarySection

        cards.tagsAndNotesSection

        actionButtons
    }

    // Training Load (dashboard style) — tappable for detail
    // Priority: top-level frozen snapshot > analysisResult fallback
    @ViewBuilder
    private var trainingLoadSection: some View {
        if let frozenTraining = vm.displaySession.trainingSnapshot
            ?? vm.displayResult.trainingContext {
            trainingDetailLink(frozenTraining)
        }
    }

    private func trainingDetailLink(_ context: TrainingContext) -> some View {
        NavigationLink {
            TrainingDetailView(
                trainingMetrics: nil,
                trainingContext: context,
                followsLiveLoad: !vm.isHistoricalSession
            )
        } label: {
            cards.trainingLoadCard(context)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func overnightChartsSection(
        _ breakdown: RecoveryScoreCalculator.ScoreBreakdown
    ) -> some View {
        if session.sessionType == .overnight {
            OvernightChartsView(
                session: vm.displaySession,
                result: vm.displayResult,
                healthKitSleep: dependencies.app.settingsManager.settings.enableSleepIntegration ? vm.healthKitSleep : nil,
                onReanalyzeAt: isManualWindowMode && onReanalyzeAt != nil ? { tsMs in
                    reanalysis.handleManualReanalysis(timestampMs: tsMs)
                } : nil,
                isManualWindowMode: isManualWindowMode,
                manualResult: manualResult,
                hideSleepRow: !vm.isHistoricalSession && vm.healthKitSleep != nil,
                interChartContent: { interChartSections(breakdown) }
            )
        }
    }

    @ViewBuilder
    private func interChartSections(
        _ breakdown: RecoveryScoreCalculator.ScoreBreakdown
    ) -> some View {
        // Score Breakdown - what's contributing and what's holding back
        cards.scoreBreakdownSection(breakdown: breakdown)
    
        if vm.hasRawData, onReanalyze != nil {
            reanalysis.windowSelectionMethodSection
        }
    }

    @ViewBuilder
    private var dataSourceSection: some View {
        if let summary = vm.displaySession.dataSourceSummary {
            cards.dataSourceSummaryCard(summary)
            // Streaming-only night → offer to pull the strap's
            // full-night internal recording and re-merge + re-score.
            if summary.selectedSource == "streaming" {
                reanalysis.overnightStrapMergeCard
            }
        }
    }

    // First-score explainer sheet (surfaces the existing
    // Help article rather than building new copy).
    //
    // The PDF preview and the mail composer share ONE `.sheet(item:)`: two
    // stacked `.sheet(item:)` modifiers on one view can drop the second on
    // present (see FitnessTabView's summary sheet).
    private func withSheets(_ content: some View) -> some View {
        content
            .sheet(isPresented: $showingScoreExplainer) {
                RecoveryScoreExplainerSheet { showingScoreExplainer = false }
            }
            .sheet(item: reportFileSheetBinding) { sheet in
                switch sheet {
                case .preview(let identifiable): PDFPreviewView(url: identifiable.url)
                case .mail(let identifiable): reportMailComposer(identifiable)
                }
            }
    }

    /// The export shown, preview first. Dismissing clears the one shown.
    private var reportFileSheetBinding: Binding<ReportFileSheet?> {
        Binding(
            get: { exportURL.map(ReportFileSheet.preview) ?? emailURL.map(ReportFileSheet.mail) },
            set: { newValue in
                guard newValue == nil else { return }
                if exportURL != nil { exportURL = nil } else { emailURL = nil }
            }
        )
    }

    /// The report's mail composer, addressed from the user's recovery-report
    /// defaults (`RecoveryReportMailComposer`).
    private func reportMailComposer(_ identifiable: IdentifiableURL) -> some View {
        RecoveryReportMailComposer(
            settings: dependencies.app.settingsManager.settings,
            reportDate: session.endDate ?? session.startDate,
            attachmentURL: identifiable.url
        )
    }

    private func withDialogs(_ content: some View) -> some View {
        withDiscardAndRescoreDialogs(withSegmentUnlinkFailedAlert(content))
            .confirmationDialog(
                Text(String(localized: "Delete Reading", bundle: LanguageManager.appBundle)),
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) { deleteReadingActions } message: { deleteReadingMessage }
            .confirmationDialog(
                Text(String(localized: "Re-analyze Session", bundle: LanguageManager.appBundle)),
                isPresented: $showingReanalyzeConfirmation,
                titleVisibility: .visible
            ) { reanalyzeActions } message: { reanalyzeMessage }

            .confirmationDialog(
                Text(String(localized: "Remove Segment", bundle: LanguageManager.appBundle)),
                isPresented: $showingUnlinkConfirmation,
                titleVisibility: .visible
            ) { removeSegmentActions } message: { removeSegmentMessage }
    }

    /// The Discard confirmation, which states what the reading's caller
    /// loses, and the Analysis Window pick's confirmation (it re-scores and
    /// re-saves the reading).
    private func withDiscardAndRescoreDialogs(_ content: some View) -> some View {
        withReanalysisDeclinedAlert(content)
            .confirmationDialog(
                Text(String(localized: "Discard this reading?", bundle: LanguageManager.appBundle)),
                isPresented: $showingDiscardConfirmation,
                titleVisibility: .visible
            ) { discardReadingActions } message: { discardReadingMessage }
            .confirmationDialog(
                Text(String(localized: "Re-analyze Session", bundle: LanguageManager.appBundle)),
                isPresented: pendingWindowMethodBinding,
                titleVisibility: .visible,
                presenting: pendingWindowMethod
            ) { method in
                windowMethodActions(method)
            } message: { method in
                windowMethodMessage(method)
            }
    }

    /// Raised by `applyReanalyzedSession` when a re-analysis came back with
    /// no session: the score on screen and on disk is unchanged.
    private func withReanalysisDeclinedAlert(_ content: some View) -> some View {
        content.alert(
            String(localized: "This reading wasn't re-analyzed. Its score is unchanged.", bundle: LanguageManager.appBundle),
            isPresented: $reanalysisDeclined
        ) {
            Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) {}
        }
    }

    /// Raised by `unlinkPendingSegment` when the unlink was not stored.
    private func withSegmentUnlinkFailedAlert(_ content: some View) -> some View {
        content.alert(
            String(localized: "Couldn't remove this segment. Try again.", bundle: LanguageManager.appBundle),
            isPresented: $segmentUnlinkFailed
        ) {
            Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) {}
        }
    }

    @ViewBuilder
    private var deleteReadingActions: some View {
        Button(String(localized: "Delete", bundle: LanguageManager.appBundle), role: .destructive) {
            onDelete?()
        }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
    }

    /// Discard throws the reading away, so its Tags & Notes edits are dropped
    /// rather than handed to `onUpdateTags` (a save for a reading about to be
    /// deleted or rejected), and marked handled so the sheet's onDisappear
    /// does not hand them off either.
    @ViewBuilder
    private var discardReadingActions: some View {
        Button(String(localized: "Discard", bundle: LanguageManager.appBundle), role: .destructive) {
            savedTagsAndNotes = SavedTagsAndNotes(tags: vm.selectedTags, notes: vm.notes)
            onDiscard()
        }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
    }

    private var discardReadingMessage: some View {
        Text(discardMessage ?? String(localized: "This discards the reading.", bundle: LanguageManager.appBundle))
    }

    private var deleteReadingMessage: some View {
        Text(String(localized: "This moves the reading to the Trash. You can restore it from Settings → iCloud & Data → Trash.", bundle: LanguageManager.appBundle))
    }

    @ViewBuilder
    private var reanalyzeActions: some View {
        Button(String(localized: "Re-analyze", bundle: LanguageManager.appBundle)) {
            reanalysis.performReanalysis()
        }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
    }

    private var reanalyzeMessage: some View {
        Text(String(localized: "This re-runs the analysis on this reading's beat data and saves the new score in place of the current one. The beat data itself is not changed.", bundle: LanguageManager.appBundle))
    }

    private var pendingWindowMethodBinding: Binding<Bool> {
        Binding(
            get: { pendingWindowMethod != nil },
            set: { if !$0 { pendingWindowMethod = nil } }
        )
    }

    @ViewBuilder
    private func windowMethodActions(_ method: WindowSelectionMethod) -> some View {
        Button(String(localized: "Re-analyze", bundle: LanguageManager.appBundle)) {
            pendingWindowMethod = nil
            reanalysis.applyWindowMethod(method)
        }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {
            pendingWindowMethod = nil
        }
    }

    /// A past night's pick re-scores that night only; tonight's also becomes
    /// the method new readings start with (`applyWindowMethod`).
    private func windowMethodMessage(_ method: WindowSelectionMethod) -> some View {
        let name = method.displayName
        return Text(vm.isHistoricalSession
            ? String(localized: "This re-scores this past reading with \(name) and saves the new score in place of the current one. The beat data itself is not changed.", bundle: LanguageManager.appBundle)
            : String(localized: "This re-scores the reading with \(name) and saves the new score in place of the current one. New readings will also use \(name). The beat data itself is not changed.", bundle: LanguageManager.appBundle))
    }

    @ViewBuilder
    private var removeSegmentActions: some View {
        Button(String(localized: "Remove", bundle: LanguageManager.appBundle), role: .destructive) {
            unlinkPendingSegment()
        }

        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {
            pendingUnlinkSegmentId = nil
        }
    }

    /// The segment leaves the list only once the unlink is stored; when it
    /// is not, it stays listed (still linked and scored) and the alert says so.
    private func unlinkPendingSegment() {
        guard let segmentId = pendingUnlinkSegmentId else { return }
        pendingUnlinkSegmentId = nil
        guard onUnlinkSegment?(segmentId) == true else {
            segmentUnlinkFailed = true
            return
        }
        _ = withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            removedSegmentIds.insert(segmentId)
        }
    }

    private var removeSegmentMessage: some View {
        Text(String(localized: "This will unlink this segment from the combined recording. The segment's data will no longer be included in analysis.", bundle: LanguageManager.appBundle))
    }

    // When the archive changes (re-analyze, sleep
    // adjustment, retro-apply, etc.), pull the freshly-archived
    // version of THIS session into `vm.reanalyzedSession`. Every
    // computed property reads through `displaySession`, so the
    // score, breakdown, training readiness pill, and HRV/sleep
    // labels all update without any further wiring.
    //
    // Filtered by session id inside the helper so unrelated
    // archive churn (other sessions trashed, baseline updates)
    // doesn't trigger re-renders here.
    private func withLifecycle(_ content: some View) -> some View {
        content
            .task { await hydrateAndLoad() }
            .onChange(of: morningCoordination.sleepDataVersion) { _, _ in
                refetchSleepIfNotAdjusted()
            }
            .onChange(of: archiveSignal.version) { _, _ in
                vm.applyExternalArchiveUpdate()
            }
            // A swipe-dismiss or a parent's own Done closes the sheet without
            // the in-card Done button; tag and note edits are handed over here.
            .onDisappear { saveTagsAndNotesIfChanged() }
    }

    /// Deletes each exported PDF / RR CSV from tmp once its preview or mail
    /// sheet closes (it is plaintext health data), and reports an export that
    /// produced no file.
    private func withExportHandling(_ content: some View) -> some View {
        content
            .onChange(of: exportURL) { old, new in removeExportFile(old, replacedBy: new) }
            .onChange(of: emailURL) { old, new in removeExportFile(old, replacedBy: new) }
            .alert(
                String(localized: "Export failed", bundle: LanguageManager.appBundle),
                isPresented: Binding(get: { exportErrorMessage != nil }, set: { if !$0 { exportErrorMessage = nil } }),
                presenting: exportErrorMessage
            ) { _ in
                Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) {}
            } message: { Text($0) }
    }

    private func removeExportFile(_ old: IdentifiableURL?, replacedBy new: IdentifiableURL?) {
        guard let old, old.id != new?.id else { return }
        attempt("MorningResultsView.removeExportFile") { try FileManager.default.removeItem(at: old.url) }
    }

    private func refetchSleepIfNotAdjusted() {
        guard !vm.isHistoricalSession, !sleepAdjustedHere,
              vm.displaySession.sleepUserAdjusted != true else { return }
        Task { await vm.fetchHealthKitSleep() }
    }

    private func hydrateAndLoad() async {
        vm.baselineStats = collector.scoringBaselineStats(for: vm.displaySession)
        vm.onUpdateSleep = onUpdateSleep
        await hydrateDisplaySessionIfNeeded()
        await vm.loadInitialData()
    }

    // Hydrate the displayed session if it arrived
    // lightweight (rrSeries stripped at decode time for memory).
    // Without this:
    //   • The chart's drag tooltip can't compute RMSSD at the
    //     touch point ("slider doesn't show values as it moves").
    //   • The "Choose Window" picker fails because the analyzer
    //     gets a session with nil rrSeries.
    //   • `vm.hasRawData` returns false, hiding the method
    //     dropdown entirely.
    // ReanalysisService.hydrated covers the analysis path; this
    // covers the chart UI by promoting the hydrated session
    // into `vm.reanalyzedSession`, which `displaySession` reads
    // through.
    private func hydrateDisplaySessionIfNeeded() async {
        if vm.displaySession.rrSeries?.points.isEmpty ?? true {
            let sessionId = vm.session.id
            // Off-main hydration. `.task` runs on
            // MainActor by default, and this retrieve holds the
            // archiveLock through SHA256 + decrypt + full JSON decode
            // (including the rrSeries we explicitly want here). On
            // long overnights that's 50–150 ms of main-thread block
            // right as the view appears. Detach so the user sees the
            // chart skeleton immediately and the points arrive when
            // the disk read finishes.
            // Resolved on the main actor; the detached task reads only the archive.
            let archive = dependencies.storage.sessionArchive
            let stored = await Task.detached(priority: .userInitiated) {
                archive.retrieveOrLog(sessionId, caller: "MorningResultsView.hydrate")
            }.value
            if let stored, stored.rrSeries?.points.isEmpty == false {
                vm.reanalyzedSession = stored
                debugLog("[MorningResultsView] Hydrated lightweight session \(sessionId.uuidString.prefix(8)) at view appearance")
            }
        }
    }

    // Data loading (fetchHealthKitSleep, fetchLiveTrainingContext, fetchDayTrimp)
    // is handled by MorningResultsViewModel.loadInitialData().

    /// The screen for a reading with no usable analysis
    /// (`UnreadableReadingState`): Re-analyze only when raw beat data is on
    /// disk and the caller can re-analyze, Delete only when it can delete;
    /// each asks first through this view's confirmation dialogs.
    private var unreadableSessionState: some View {
        UnreadableReadingState(
            canReanalyze: vm.hasRawData && onReanalyze != nil,
            canDelete: onDelete != nil,
            perceivedReadiness: Binding(
                get: { vm.displaySession.perceivedReadiness },
                set: { vm.updatePerceivedReadiness($0) }
            ),
            quality: vm.displaySession.hrvDataQuality ?? .insufficient,
            onReanalyze: { showingReanalyzeConfirmation = true },
            onDelete: { showingDeleteConfirmation = true }
        )
    }
}

// MARK: - Identifiable URL Wrapper

/// What the report's single file sheet shows: the PDF/CSV preview or the
/// mail composer, each with its file.
enum ReportFileSheet: Identifiable {
    case preview(IdentifiableURL)
    case mail(IdentifiableURL)

    var id: UUID {
        switch self {
        case .preview(let file), .mail(let file): file.id
        }
    }
}

struct IdentifiableURL: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

/// The tags and notes of a morning report as last stored, so a hand-off to
/// `onUpdateTags` only happens when the user changed one of them.
struct SavedTagsAndNotes: Equatable {
    let tags: Set<ReadingTag>
    let notes: String
}
