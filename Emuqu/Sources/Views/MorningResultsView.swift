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
    /// and the recovery score never recomputes. Callers wire this to `RRCollector.applyManualAnalysis`, which
    /// writes `windowUserAdjusted = true`, recomputes the recovery
    /// score against the new window, and re-archives the session.
    var onApplyManualResult: ((HRVAnalysisResult) async -> HRVSession?)?

    /// Optional callback to update stored sleep boundaries when HealthKit has more complete data
    var onUpdateSleep: ((SleepData) -> Void)?

    /// Optional callback for user-initiated sleep adjustments (exclude/boundary changes)
    var onAdjustSleep: ((SleepData) -> Void)?

    /// Optional callback to unlink a segment from the same-night merge
    var onUnlinkSegment: ((UUID) -> Void)?

    /// Linked segment time ranges for split-night recordings. Nil for standalone sessions.
    var linkedSegments: [LinkedSegmentInfo]?

    @State var vm: MorningResultsViewModel

    // UI-only state (not shared with VM)
    @State var exportURL: IdentifiableURL?
    @State var emailURL: IdentifiableURL?
    @State var showingReanalyzeConfirmation = false
    @State var isManualWindowMode = false
    @State var manualResult: HRVAnalysisResult?
    @State var showReportSectionPicker = false
    @State var showEmailSectionPicker = false
    @State var showingDeleteConfirmation = false
    @State var showingUnlinkConfirmation = false
    @State var pendingUnlinkSegmentId: UUID?
    @State var removedSegmentIds: Set<UUID> = []

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

    /// Collector access for non-observable methods. State reads MUST go through the
    /// sub-objects below — `collector.X` forwarders don't trigger SwiftUI re-renders.
    @Environment(RRCollector.self) var collector
    @Environment(MorningCoordination.self) var morningCoordination
    /// Observe archive changes so re-analyze / sleep
    /// refresh fired from any other surface (Dashboard, History,
    /// Reanalyze All) propagates into THIS sheet too. Without this,
    /// the user could re-analyze the morning recording from the
    /// dashboard, return to the open Recovery Report sheet, and see
    /// the OLD score because `vm.session` was captured at sheet
    /// presentation time. Same problem in reverse: refresh sleep
    /// inside the report → dashboard didn't see the change without
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
        onDelete: (() -> Void)? = nil,
        onReanalyze: ((HRVSession, WindowSelectionMethod) async -> HRVSession?)? = nil,
        onUpdateTags: (([ReadingTag], String?) -> Void)? = nil,
        onReanalyzeAt: ((Int64) async -> HRVAnalysisResult?)? = nil,
        onApplyManualResult: ((HRVAnalysisResult) async -> HRVSession?)? = nil,
        onUpdateSleep: ((SleepData) -> Void)? = nil,
        onAdjustSleep: ((SleepData) -> Void)? = nil,
        onUnlinkSegment: ((UUID) -> Void)? = nil,
        linkedSegments: [LinkedSegmentInfo]? = nil
    ) {
        self.session = session
        self.result = result
        self.recentSessions = recentSessions
        self.onDiscard = onDiscard
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
        let quality = session.hrvDataQuality
        if quality == .preSleep || quality == .insufficient { return false }
        let hasScore = vm.displaySession.recoveryScore != nil
        let hasHRV = vm.displayResult.timeDomain.rmssd > 0
        return !hasScore && !hasHRV
    }

    var body: some View {
        // Compute breakdown once per render; the score card and breakdown section both read it.
        let breakdown = vm.recoveryBreakdown()
        return withLifecycle(withDialogs(withSheets(resultsStack(breakdown))))
    }

    private func resultsStack(_ breakdown: RecoveryScoreCalculator.ScoreBreakdown) -> some View {
        ZStack {
            readableOrUnreadableBody(breakdown)

            // PDF Generation Loading Overlay
            if vm.isGeneratingPDF {
                pdfLoadingOverlay
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

        recoveryScoreCard(breakdownMessage: breakdown.message)

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
            trainingReadinessCard
        }
    }

    @ViewBuilder
    private var subjectiveReadinessSection: some View {
        if session.hrvDataQuality == .preSleep || session.hrvDataQuality == .insufficient {
            SubjectiveReadinessCard(
                perceivedReadiness: Binding(
                    get: { vm.displaySession.perceivedReadiness },
                    set: { newValue in
                        vm.updatePerceivedReadiness(newValue)
                    }
                ),
                quality: session.hrvDataQuality ?? .insufficient
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
                recentSessions: recentSessions
            )
        } label: {
            hrvMetricCard
        }
        .buttonStyle(.plain)
    }

    private var sleepDetailLink: some View {
        NavigationLink { sleepDetailDestination } label: { sleepMetricCardCompact }
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

        tagsAndNotesSection

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
                trainingContext: context
            )
        } label: {
            trainingLoadCard(context)
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
                    handleManualReanalysis(timestampMs: tsMs)
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
        scoreBreakdownSection(breakdown: breakdown)
    
        if vm.hasRawData, onReanalyze != nil {
            windowSelectionMethodSection
        }
    }

    @ViewBuilder
    private var dataSourceSection: some View {
        if let summary = vm.displaySession.dataSourceSummary {
            dataSourceSummaryCard(summary)
            // Streaming-only night → offer to pull the strap's
            // full-night internal recording and re-merge + re-score.
            if summary.selectedSource == "streaming" {
                overnightStrapMergeCard
            }
        }
    }

    // First-score explainer sheet (surfaces the existing
    // Help article rather than building new copy).
    private func withSheets(_ content: some View) -> some View {
        content
            .sheet(isPresented: $showingScoreExplainer) { scoreExplainerSheet }
            .sheet(item: $exportURL) { identifiable in
                PDFPreviewView(url: identifiable.url)
            }
            .sheet(item: $emailURL) { identifiable in
                reportMailComposer(identifiable)
            }
    }

    @ViewBuilder
    private var scoreExplainerSheet: some View {
        if let article = HelpContent.recoveryScore.articles.first(where: { $0.id == "understanding-score" })?.localized {
            NavigationStack { scoreExplainerArticle(article) }
        }
    }

    private func scoreExplainerArticle(_ article: HelpArticle) -> some View {
        HelpArticleView(article: article)
            .toolbar { scoreExplainerToolbar }
    }

    @ToolbarContentBuilder
    private var scoreExplainerToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) {
                showingScoreExplainer = false
            }
        }
    }

    private func reportMailComposer(_ identifiable: IdentifiableURL) -> some View {
        let reportDate = session.endDate ?? session.startDate
        let dateStr = reportDate.formatted(date: .abbreviated, time: .omitted)
        return MailComposerView(
            subject: String(localized: "Recovery Report – \(dateStr)", bundle: LanguageManager.appBundle),
            recipients: reportRecipients,
            ccRecipients: reportCCRecipients,
            attachmentURL: identifiable.url
        )
    }

    // Reading `defaultRecoveryEmailRecipient` alone leaves the
    // field BLANK when the user has only set the legacy generic
    // `defaultEmailRecipient` ("reports pre-pop email regressed").
    // So fall back through the same `resolvedDefaultEmailRecipient`
    // chain that MainTabView's report mailer + AssistantChatView's
    // per-message mailer use (recovery → training → legacy
    // generic). Same for the CC list.
    private var reportRecipients: [String] {
        let settings = dependencies.app.settingsManager.settings
        if let recovery = settings.defaultRecoveryEmailRecipient,
           !recovery.trimmingCharacters(in: .whitespaces).isEmpty {
            return [recovery]
        }
        return settings.resolvedDefaultEmailRecipient.map { [$0] } ?? []
    }

    private var reportCCRecipients: [String] {
        let settings = dependencies.app.settingsManager.settings
        let recoveryCC = (settings.defaultRecoveryEmailCC ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !recoveryCC.isEmpty { return recoveryCC }
        return settings.resolvedDefaultEmailCC
    }

    private func withDialogs(_ content: some View) -> some View {
        content
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

    @ViewBuilder
    private var deleteReadingActions: some View {
        Button(String(localized: "Delete", bundle: LanguageManager.appBundle), role: .destructive) {
            onDelete?()
        }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
    }

    private var deleteReadingMessage: some View {
        Text(String(localized: "This moves the reading to the Trash. You can restore it from Settings → iCloud & Data → Trash.", bundle: LanguageManager.appBundle))
    }

    @ViewBuilder
    private var reanalyzeActions: some View {
        Button(String(localized: "Re-analyze", bundle: LanguageManager.appBundle)) {
            performReanalysis()
        }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
    }

    private var reanalyzeMessage: some View {
        Text(String(localized: "This will re-run the analysis algorithms on your existing RR data. Your raw data is safe and will not be modified.", bundle: LanguageManager.appBundle))
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

    private func unlinkPendingSegment() {
        if let segmentId = pendingUnlinkSegmentId {
            _ = withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                removedSegmentIds.insert(segmentId)
            }
            onUnlinkSegment?(segmentId)
            pendingUnlinkSegmentId = nil
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
            .onChange(of: morningCoordination.isDeviceFetchInProgress) { _, inProgress in
                guard !inProgress else { return }
                refetchSleepIfNotAdjusted()
            }
            .onChange(of: morningCoordination.sleepDataVersion) { _, _ in
                refetchSleepIfNotAdjusted()
            }
            .onChange(of: archiveSignal.version) { _, _ in
                vm.applyExternalArchiveUpdate()
            }
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
            var archive: SessionArchive { dependencies.storage.sessionArchive }
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

    /// Graceful empty/error state for a session that couldn't
    /// produce a usable analysis (no HRV metrics, no score), instead of
    /// a row of near-blank "—" cards. Offers a
    /// re-analyze retry when raw beat data is on disk, and otherwise lets
    /// the user dismiss/delete. Kept inside the app's card style + the
    /// shared EmptyState component used elsewhere.
    private var unreadableSessionState: some View {
        ScrollView {
            VStack(spacing: 20) {
                unreadableEmptyState

                // Subjective fallback so the morning still has a takeaway
                // even when the physiological read failed.
                unreadableFallbackCard
            }
            .padding()
        }
        .background(AppTheme.background.ignoresSafeArea())
    }

    private var unreadableEmptyState: some View {
        EmptyState(
            glyph: "waveform.path.ecg",
            headline: String(localized: "This reading didn't process", bundle: LanguageManager.appBundle),
            message: String(localized: "We couldn't pull usable heart-rate variability from this session — it may have been too short, too noisy, or interrupted before enough clean data was captured. Your raw data is safe.", bundle: LanguageManager.appBundle),
            primaryLabel: (vm.hasRawData && onReanalyze != nil)
                ? String(localized: "Re-analyze", bundle: LanguageManager.appBundle)
                : nil,
            primaryAction: { showingReanalyzeConfirmation = true },
            secondaryLabel: onDelete != nil
                ? String(localized: "Delete reading", bundle: LanguageManager.appBundle)
                : nil,
            secondaryAction: { showingDeleteConfirmation = true }
        )
        .padding(.top, 40)
    }

    private var unreadableFallbackCard: some View {
        SubjectiveReadinessCard(
            perceivedReadiness: Binding(
                get: { vm.displaySession.perceivedReadiness },
                set: { vm.updatePerceivedReadiness($0) }
            ),
            quality: session.hrvDataQuality ?? .insufficient
        )
    }
}

// MARK: - Identifiable URL Wrapper

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}
