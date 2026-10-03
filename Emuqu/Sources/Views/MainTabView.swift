import CoreLocation
import MessageUI
import SwiftUI

/// Main tab-based navigation for the app
struct MainTabView: View {
    @Environment(\.dependencies) var dependencies
    @Environment(RRCollector.self) var collector
    @Environment(ArchiveSignal.self) var archiveSignal
    @Environment(LanguageManager.self) var languageManager
    @Environment(CloudKitSyncManager.self) var syncManager
    private var settingsManager: SettingsManager { dependencies.app.settingsManager }
    var assistantInbox: AssistantInbox { dependencies.assistant.assistantInbox }
    /// Observe scene phase so the dashboard reloads when
    /// the app comes back from background. Real-user report: "the
    /// recovery pill still is outdated when i wake up. was too high
    /// yesterday and too low today. had to restart the app to see it."
    /// Root cause: when overnight processing completes while the app
    /// is backgrounded, the new score lands on disk and bumps
    /// `archiveSignal.notifyChanged()` — but if the app was suspended
    /// the in-memory `archiveSignal.version` observer never fires.
    /// On foreground, no path forces a reload, so the dashboard keeps
    /// showing yesterday's session until the user kills + relaunches.
    /// Belt-and-braces fix: re-load on every active transition.
    @Environment(\.scenePhase) private var scenePhase
    @State var selectedTab: Tab = .dashboard
    /// A tab a screen outside the tab view (onboarding) wants opened. Taken
    /// and cleared here, so the same request cannot fire twice.
    @Binding var requestedTab: Tab?
    /// Bound NavigationStack paths for every tab. Per
    /// user request, EVERY tab tap goes back to that tab's root —
    /// state is not preserved across tab switches. (iOS HIG default
    /// is preservation; the user explicitly chose this behavior.)
    /// The wrapping `tabSelectionBinding` clears the path of whatever
    /// tab is being entered on every selection event.
    @State private var dashboardPath: NavigationPath = .init()
    @State private var recordPath: NavigationPath = .init()
    @State private var fitnessPath: NavigationPath = .init()
    @State private var coachPath: NavigationPath = .init()
    @State var morePath: NavigationPath = .init()
    /// Dashboard's session slice (35 most recent — `dashboardSessionLoadLimit`;
    /// only 8 are visible at once, but the Recent strip needs deeper coverage).
    /// TrendsV2View owns its own archive subscription — see docs/FLOWCHART.md §11a.
    @State var sessions: [HRVSession] = []
    /// True archive size, kept off the `body` path — updated by
    /// `reloadDashboardSessions` instead of read from `archive.entries` in body.
    /// SEEDED at init (see below) from the synchronously-loaded archive index,
    /// so an existing user's very first frame already knows the real count.
    /// Without the seed this started at 0 and the dashboard flashed the
    /// new-user onboarding state (No reading yet / Building baseline 0/14 /
    /// Get started) on every cold launch until the async reload landed.
    @State var totalSessionCount: Int
    /// Cold-start seed for the dashboard hero score, computed once at launch
    /// from the synchronously-loaded archive index (passed from
    /// `EmuquApp`, like `totalSessionCount`). Lets the ring show the
    /// last known score on first paint instead of blank until the async
    /// session decrypt lands. Unused after `sessions` loads.
    @State private var seedScore: Int?
    /// Cold-start seed for the rest of the dashboard summary (HRV/Sleep chips,
    /// Recent strip), computed once at launch from the index alongside
    /// `seedScore`. Unused after `sessions` loads.
    @State private var seedSummary: DashboardSessionPolicy.DashboardSeed?
    @State private var selectedReportSession: HRVSession?
    @State var refreshTask: Task<Void, Never>?
    @State var lastDashboardReloadAt: Date = .distantPast
    /// Serialized-reload coalescing state.
    /// `inFlight` = a decrypt is running; `pending` = at least one reload was
    /// requested while it ran, so run exactly once more when it finishes.
    @State var dashboardReloadInFlight = false
    @State var dashboardReloadPending = false
    /// A tab-independent reload event (foreground / archive change / CloudKit
    /// pull) arrived while the Dashboard wasn't showing — run it when it is.
    @State var dashboardReloadDeferred = false
    @State var scrollToTopToken = UUID()

    /// Seed `totalSessionCount` from the archive index. `SessionArchive.init`'s
    /// `loadIndex()` populates `archive.entries` synchronously BEFORE first
    /// paint, so the count is authoritative here. `collector` is an
    /// @EnvironmentObject (not available during init), so the value is passed
    /// down from `EmuquApp`, where the collector is the owning
    /// @State. Defaults to 0 for previews/tests constructing `MainTabView()`.
    init(
        initialSessionCount: Int = 0,
        initialSeedScore: Int? = nil,
        initialSeedSummary: DashboardSessionPolicy.DashboardSeed? = nil,
        requestedTab: Binding<Tab?> = .constant(nil)
    ) {
        _requestedTab = requestedTab
        _totalSessionCount = State(initialValue: initialSessionCount)
        _seedScore = State(initialValue: initialSeedScore)
        _seedSummary = State(initialValue: initialSeedSummary)
    }

    /// Dashboard "Send report" toolbar menu state. Tapping
    /// one of the menu items kicks off PDF generation for the
    /// appropriate session type, and once the URL lands the mail
    /// composer pops via `pendingReportMailURL`. While the render is in
    /// flight we show a non-blocking alert; the menu items are
    /// disabled so a second tap can't double-fire.
    @State var preparingReportKind: SendReportKind?
    @State var pendingReportMailURL: IdentifiableURL?
    @State var reportPrepError: String?

    /// Which canned report the user wants to send from the toolbar
    /// menu. Each maps to a different generator: recovery → standalone
    /// HRV PDF, daily → HolisticDailyReport (workout + same-day
    /// overnight), workout → WorkoutPDFReport (workout-only).
    enum SendReportKind: String, Identifiable {
        case recovery, daily, workout
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recovery: return String(localized: "Send recovery report", bundle: LanguageManager.appBundle)
            case .daily: return String(localized: "Send daily report", bundle: LanguageManager.appBundle)
            case .workout: return String(localized: "Send workout report", bundle: LanguageManager.appBundle)
            }
        }
        var icon: String {
            switch self {
            case .recovery: return "moon.stars.fill"
            case .daily: return "doc.text.image.fill"
            case .workout: return "figure.run"
            }
        }
    }

    /// Five tabs.
    /// Dashboard / Record / Fitness / Coach / More.
    /// History collapses into Dashboard via the Recent strip; Trends, Settings,
    /// Help, About live in More. The `Assistant`, `History`, `Trends`, and
    /// `Settings` cases are not top-level tabs; they exist because deep links
    /// and the More menu still route to them.
    enum Tab: String, CaseIterable {
        case dashboard = "Dashboard"
        case record = "Record"
        case fitness = "Fitness"
        case coach = "Flo"  // The tab hosts the main conversational AI (Flo). The mid-workout trigger voice is what we call "Coach" (see WorkoutVoiceCoach).
        case more = "More"
        // Retired tab IDs kept as cases for back-compat with deep links
        // (e.g. AssistantInbox routes to .coach now, but external references
        // to .assistant continue to compile during the migration window).
        case assistant = "Assistant"
        case history = "History"
        case trends = "Trends"
        case settings = "Settings"

        /// Localized display name using the current language bundle.
        func localizedName(bundle: Bundle) -> String {
            String(localized: String.LocalizationValue(rawValue), bundle: bundle)
        }

        var icon: String {
            switch self {
            case .dashboard: "heart.text.square"
            case .record: "waveform.circle"
            case .fitness: "figure.run"
            case .coach, .assistant: "sparkles"
            case .more: "ellipsis.circle"
            case .history: "list.bullet.rectangle"
            case .trends: "chart.line.uptrend.xyaxis"
            case .settings: "gearshape"
            }
        }

        var iconFilled: String {
            switch self {
            case .dashboard: "heart.text.square.fill"
            case .record: "waveform.circle.fill"
            case .fitness: "figure.run"
            case .coach, .assistant: "sparkles"
            case .more: "ellipsis.circle.fill"
            case .history: "list.bullet.rectangle.fill"
            case .trends: "chart.line.uptrend.xyaxis"
            case .settings: "gearshape.fill"
            }
        }
    }

    /// Selection binding that intercepts every tab-bar event and
    /// resets the corresponding tab's nav path. Per user request:
    /// every tap on a tab — re-tap of the active one OR
    /// switch from a different tab — returns the user to that tab's
    /// root. iOS HIG's default is to preserve state; the user
    /// explicitly chose this behavior. Easy to dial back per-tab if
    /// it ever proves friction-y.
    private var tabSelectionBinding: Binding<Tab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                switch newValue {
                case .dashboard: dashboardPath = NavigationPath()
                case .record: recordPath = NavigationPath()
                case .fitness: fitnessPath = NavigationPath()
                case .coach, .assistant: coachPath = NavigationPath()
                case .more, .history, .trends, .settings: morePath = NavigationPath()
                }
                selectedTab = newValue
            }
        )
    }

    @ViewBuilder
    var body: some View {
        let _ = dependencies.app.keyboardPerfSignpost.event("MainTabView.body")
        tabsWithObservers
            .sheet(item: $pendingReportMailURL) { reportMailSheet($0) }
            .alert(String(localized: "Couldn't prepare report", bundle: LanguageManager.appBundle), isPresented: .constant(reportPrepError != nil)) {
                Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) {
                    reportPrepError = nil
                }
            } message: {
                Text(reportPrepError ?? "")
            }
            .sheet(item: $selectedReportSession) { reportSheet($0) }
    }

    /// Send-report mail composer. The PDF renders off-main, then
    /// this sheet pops with the saved training-email defaults pre-filled. The
    /// user reviews and taps Send (or Cancel); the composer is Apple standard.
    @ViewBuilder
    private func reportMailSheet(_ wrapper: IdentifiableURL) -> some View {
        if MFMailComposeViewController.canSendMail() {
            let defaults = dependencies.app.settingsManager.settings
            let to = (defaults.defaultTrainingEmailRecipient ?? defaults.resolvedDefaultEmailRecipient)
                .map { [$0] } ?? []
            let cc = defaults.resolvedDefaultEmailCC
            MailComposerView(
                subject: String(localized: "Emuqu report", bundle: LanguageManager.appBundle),
                recipients: to,
                ccRecipients: cc,
                attachmentURL: wrapper.url,
                onDismiss: { pendingReportMailURL = nil }
            )
        } else {
            // No mail account configured — fall back to the
            // system share sheet so the user can route the PDF
            // through Messages, Files, AirDrop, whatever.
            ShareSheet(activityItems: [wrapper.url])
        }
    }

    /// Recovery Score detail.
    @ViewBuilder
    private func reportSheet(_ session: HRVSession) -> some View {
        if let result = session.analysisResult {
            reportNavigation(session, result: result)
        }
    }

    private func reportNavigation(_ session: HRVSession, result: HRVAnalysisResult) -> some View {
        NavigationStack {
            recoveryScoreDetail(session, result: result)
                .toolbar { reportDoneToolbar }
        }
    }

    private func recoveryScoreDetail(_ session: HRVSession, result: HRVAnalysisResult) -> some View {
        RecoveryScoreDetailView(
            session: session,
            result: result,
            recentSessions: sessions,
            baselineStats: collector.scoringBaselineStats(for: session),
            totalSessionCount: collector.baselineTracker.daysCollected,
            onReanalyze: { await rescoreReport(session, method: $0) },
            onReanalyzeAt: { await rescoreReportAt(session, targetMs: $0) }
        )
    }

    /// The returned session must be written back: the sheet holds the copy
    /// captured at present-time, so if the result is dropped the view keeps
    /// rendering the pre-reanalyze score and window even after
    /// ReanalysisService rewrote the archive ("reanalyze doesn't work" meaning
    /// "the screen doesn't update"). Writing the updated session back rebuilds
    /// the sheet against the new value.
    private func rescoreReport(_ session: HRVSession, method: WindowSelectionMethod) async {
        // Write the updated session back to `selectedReportSession`
        // so SwiftUI rebuilds the sheet against the new value and
        // the new score / window / breakdown all render. Same
        // pattern in the manual-window path below.
        if let updated = await reanalyzeSession(session, method: method) {
            selectedReportSession = updated
        }
    }

    /// Same fix as `rescoreReport`, for the manual-window path.
    private func rescoreReportAt(_ session: HRVSession, targetMs: Int64) async {
        if let manual = await collector.reanalyzeAtPosition(session, targetMs: targetMs),
           let updated = await collector.applyManualAnalysis(session, result: manual) {
            selectedReportSession = updated
        }
    }

    private var reportDoneToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) {
                selectedReportSession = nil
            }
        }
    }

    // MARK: - Tab structure
    //
    // `body` is split into the tab list, the styling that applies to it, and
    // the observers that react to it, so no single declaration nests five tab
    // definitions and fifteen modifiers. Every piece is a computed property on
    // this same struct, so the view tree is unchanged.

    private var tabsWithObservers: some View {
        styledTabs
            .onChange(of: settingsManager.settings.hideFitnessTab) { _, hidden in
                leaveHiddenFitnessTab(hidden)
            }
            .onChange(of: archiveSignal.version) { _, _ in reloadDashboardSessions() }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                refreshOnForeground(from: oldPhase, to: newPhase)
            }
            .onChange(of: syncManager.pullVersion) { _, _ in reloadDashboardSessions() }
            .onChange(of: selectedTab) { oldTab, newTab in resetPath(from: oldTab, to: newTab) }
            .onChange(of: assistantInbox.openRequestToken) { _, token in
                openCoachIfRequested(token)
            }
            .onChange(of: requestedTab) { _, tab in openRequestedTab(tab) }
            .onDisappear { refreshTask?.cancel() }
    }

    // MARK: - Tab observers

    /// If the user hid the Fitness tab while it was selected, jump back to
    /// Dashboard so they do not land on a tab that no longer exists.
    private func leaveHiddenFitnessTab(_ hidden: Bool) {
        // If the user hid the Fitness tab while Fitness was the
        // active selection, jump back to Dashboard so they don't
        // land on a tab that no longer exists.
        if hidden, selectedTab == .fitness {
            selectedTab = .dashboard
        }
    }

    /// Every foreground transition reloads the dashboard slice so any
    /// score that landed in the archive while backgrounded (overnight processing,
    /// morning re-score, push-triggered reanalyze) shows up immediately instead of
    /// waiting for a restart. Cheap: a lightweight read of the recent-sessions slice.
    private func refreshOnForeground(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        guard newPhase == .active, oldPhase != .active else { return }
        NSLog("[MainTabView] scenePhase → active — refreshing dashboard")
        reloadDashboardSessions()
        Task { @MainActor in await refreshTodaysSleep() }
    }

    /// Re-pull today's sleep from HealthKit on every foreground. The live HK
    /// observer alone does not fire reliably when the Apple Watch syncs
    /// overnight sleep while the app is killed or backgrounded — without this
    /// the morning sleep stays stale until the user opens the Sleep section
    /// and taps "Refresh Sleep Data".
    ///
    /// No second `reloadDashboardSessions` here: autoRefresh calls
    /// `archiveSignal.notifyChanged()` when it actually changes something,
    /// which drives the onChange reload. When it changes nothing, the first
    /// reload already ran.
    private func refreshTodaysSleep() async {
        await collector.autoRefreshTodaysSleepIfImproved()
    }

    /// Belt-and-braces path reset for the newly-selected tab. Tab
    /// switches normally hit `tabSelectionBinding.set`, which resets the
    /// destination path, but some scene-reactivation paths (state restoration,
    /// deep-link handoff, the AssistantInbox-driven `selectedTab` assignment)
    /// bypass the binding setter. This catches those.
    private func resetPath(from oldTab: Tab, to newTab: Tab) {
        guard newTab != oldTab else { return }
        scrollToTopToken = UUID()
        // Belt-and-braces path reset for the
        // newly-selected tab. Tab switches normally hit
        // `tabSelectionBinding.set` which resets the destination
        // path, but in some scene-reactivation paths (state
        // restoration, deep-link handoff, the AssistantInbox-driven
        // selectedTab assignment below) the binding setter is
        // bypassed. This onChange catches those.
        switch newTab {
        case .dashboard: resetDashboardPath()
        case .record: recordPath = NavigationPath()
        case .fitness: fitnessPath = NavigationPath()
        case .coach, .assistant: coachPath = NavigationPath()
        case .more, .history, .trends, .settings: morePath = NavigationPath()
        }
    }

    private func resetDashboardPath() {
        dashboardPath = NavigationPath()
        // Run any reload that was deferred while off the Dashboard.
        if dashboardReloadDeferred {
            dashboardReloadDeferred = false
            reloadDashboardSessions()
        }
    }

    /// Any view (Dashboard toolbar, History context menu, etc.) can request the
    /// Coach tab by bumping `AssistantInbox.openRequestToken`.
    private func openCoachIfRequested(_ token: UUID?) {
        // Any view (Dashboard toolbar, History context menu, etc.) can request
        // the Coach tab by bumping `AssistantInbox.openRequestToken`.
        if token != nil, selectedTab != .coach {
            selectedTab = .coach
        }
    }

    private func openRequestedTab(_ tab: Tab?) {
        guard let tab else { return }
        selectedTab = tab
        requestedTab = nil
    }

    private var styledTabs: some View {
        tabs
            .tint(.blue)
            .environment(settingsManager)
            // Composed identity that includes hideFitnessTab so SwiftUI
            // rebuilds the TabView when the toggle flips. Without this, the
            // conditional `if !hideFitnessTab { ... }` inside TabView does not always
            // reliably swap structure on toggle.
            .id("\(settingsManager.settings.appearanceTheme.rawValue)-\(settingsManager.settings.hideFitnessTab)")
            .onAppear { NSLog("[MainTabView] onAppear — tab view visible") }
            .task { await bootstrapTabs() }
    }

    private func bootstrapTabs() async {
        NSLog("[MainTabView] .task fired — calling reloadDashboardSessions()")
        reloadDashboardSessions()
        // Auto-recover a workout that was recording when the app
        // crashed: if the persisted flag is still set, connect the strap and merge
        // its complete on-device recording with the streamed data — no manual step.
        // No-op when nothing was interrupted; falls back to the manual Record-tab
        // card if the strap cannot be reached. Detached so it never blocks launch.
        Task { await recoverInterruptedWorkoutOnLaunch() }
    }

    private func recoverInterruptedWorkoutOnLaunch() async {
        await collector.autoRecoverInterruptedWorkoutOnLaunch()
        // Also surface any ALREADY-archived recovered workout the user
        // hasn't confirmed yet (e.g. a prior silent recovery with a
        // wrong, over-long duration) so they can trim it.
        if collector.morningCoordination.recoveredWorkoutReview == nil {
            collector.surfaceExistingRecoveredWorkoutForReview()
        }
        // If anything needs review, land the user on Record so the
        // review/trim card is visible — never a silent archive.
        if collector.morningCoordination.recoveredWorkoutReview != nil {
            selectedTab = .record
        }
    }

    private var tabs: some View {
        TabView(selection: tabSelectionBinding) {
            dashboardTab
            recordTab
            fitnessTab
            coachTab
            // More Tab — Trends, History, Settings,
            // Help, About all live here.
            moreTab
        }
    }

    /// Dashboard Tab — v2 layout (the only layout).
    @ViewBuilder
    private var dashboardRoot: some View {
        DashboardV2View(
            sessions: sessions,
            totalSessionCount: totalSessionCount,
            seedScore: seedScore,
            seedSummary: seedSummary,
            isActive: selectedTab == .dashboard,
            scrollToTopToken: scrollToTopToken,
            onStartRecording: { startRecording() },
            onViewReport: { selectedReportSession = $0 },
            onDeleteSession: { deleteSession($0) },
            onUpdateSessionTags: { updateTags(session: $0, tags: $1, notes: $2) },
            onReanalyzeSession: { await reanalyzeSession($0, method: $1) }
        )
    }

    private var dashboardTab: some View {
        NavigationStack(path: $dashboardPath) {
            dashboardRoot
                .navigationTitle(Tab.dashboard.localizedName(bundle: LanguageManager.appBundle))
                .toolbar { dashboardToolbar }
        }
        .tabItem {
            Label(Tab.dashboard.localizedName(bundle: LanguageManager.appBundle), systemImage: selectedTab == .dashboard ? Tab.dashboard.iconFilled : Tab.dashboard.icon)
        }
        .tag(Tab.dashboard)
        .accessibilityLabel(String(localized: "Dashboard tab", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Shows your recovery score and recent sessions", bundle: LanguageManager.appBundle))
        .accessibilityIdentifier("tab.dashboard")
    }

    /// The dashboard trailing toolbar:
    /// notifications, the send-report selector, and the Ask Flo prompt menu.
    @ToolbarContentBuilder
    private var dashboardToolbar: some ToolbarContent {
        notificationsToolbarItem
        sendReportToolbarItem
        askFloToolbarItem
    }

    /// Trailing toolbar:
    /// ✨ Coach quick-prompt menu, 🔔 Notifications.
    private var notificationsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                NotificationsSettingsPage()
            } label: {
                Image(systemName: "bell")
            }
            .accessibilityLabel(String(localized: "Notifications", bundle: LanguageManager.appBundle))
        }
    }

    /// Send-report selector. The user wanted SEND, not
    /// browse: pick which type (recovery / daily /
    /// workout) and the mail composer opens with the
    /// rendered PDF attached.
    /// Browse stays as the last item so the list view
    /// is still one tap away.
    private var sendReportToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu { sendReportMenu } label: { sendReportMenuLabel }
                .accessibilityLabel(String(localized: "Send report", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var sendReportMenu: some View {
        sendReportButton(.recovery, enabled: mostRecentOvernight != nil)
        sendReportButton(.daily, enabled: mostRecentDailyPair() != nil)
        sendReportButton(.workout, enabled: mostRecentWorkout != nil)
        Divider()
        NavigationLink {
            ReportsListView()
        } label: {
            Label(String(localized: "Browse all reports", bundle: LanguageManager.appBundle), systemImage: "doc.text.image")
        }
    }

    private func sendReportButton(_ kind: SendReportKind, enabled: Bool) -> some View {
        Button {
            prepareAndSendReport(kind)
        } label: {
            Label(kind.label, systemImage: kind.icon)
        }
        .disabled(preparingReportKind != nil || !enabled)
    }

    @ViewBuilder
    private var sendReportMenuLabel: some View {
        if preparingReportKind != nil {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "paperplane")
        }
    }

    private var askFloToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu { askFloMenu } label: { Image(systemName: "sparkles") }
                // Without an accessibility label VoiceOver announces the SF Symbol
                // name: "Sparkle".
                .accessibilityLabel(String(localized: "Ask Flo", bundle: LanguageManager.appBundle))
                .accessibilityHint(String(localized: "Quick questions about today's recovery", bundle: LanguageManager.appBundle))
                .accessibilityIdentifier("dashboard.askFlo")
        }
    }

    @ViewBuilder
    private var askFloMenu: some View {
        ForEach(askFloPrompts, id: \.title) { askFloButton($0) }
        Divider()
        askFloButton(openAssistantPrompt)
    }

    private struct AskFloPrompt {
        let title: String
        let icon: String
        let prompt: String
    }

    /// Computed, not `static let`, on purpose. These titles and prompts come from
    /// `String(localized:bundle: LanguageManager.appBundle)`, and the app has an
    /// in-app language picker — a stored static would resolve once against
    /// whatever bundle was live at first access and then never change, so the
    /// menu would keep the old language after a switch.
    private var askFloPrompts: [AskFloPrompt] {
        [
            AskFloPrompt(
                title: String(localized: "Why is my score this?", bundle: LanguageManager.appBundle),
                icon: "questionmark.circle",
                prompt: String(localized: "Why is my recovery score what it is today? Use the factor breakdown and probable causes — be specific.", bundle: LanguageManager.appBundle)
            ),
            AskFloPrompt(
                title: String(localized: "Should I train today?", bundle: LanguageManager.appBundle),
                icon: "figure.run",
                prompt: String(localized: "Should I train hard today, train easy, or rest? Use my recovery score and training load (ATL/CTL/TSB).", bundle: LanguageManager.appBundle)
            ),
            AskFloPrompt(
                title: String(localized: "What changed from yesterday?", bundle: LanguageManager.appBundle),
                icon: "arrow.left.arrow.right",
                prompt: String(localized: "Compare today to yesterday. What changed in HRV, sleep, training load, and vitals?", bundle: LanguageManager.appBundle)
            )
        ]
    }

    private var openAssistantPrompt: AskFloPrompt {
        AskFloPrompt(
            title: String(localized: "Open AI Assistant…", bundle: LanguageManager.appBundle),
            icon: "sparkles",
            prompt: ""
        )
    }

    private func askFloButton(_ item: AskFloPrompt) -> some View {
        Button {
            askAssistant(item.prompt)
        } label: {
            Label(item.title, systemImage: item.icon)
        }
    }

    /// Record Tab — deferred until user taps Record
    /// (avoids creating BreathingAudioManager + AVSpeechSynthesizer at launch)
    @ViewBuilder
    private var recordTab: some View {
        LazyView(
            NavigationStack(path: $recordPath) {
                RecordView(selectedTab: $selectedTab, scrollToTopToken: scrollToTopToken)
            }
        )
        .tabItem {
            Label(Tab.record.localizedName(bundle: LanguageManager.appBundle), systemImage: selectedTab == .record ? Tab.record.iconFilled : Tab.record.icon)
        }
        .tag(Tab.record)
        .accessibilityLabel(String(localized: "Record tab", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Start a new HRV recording session", bundle: LanguageManager.appBundle))
        .accessibilityIdentifier("tab.record")
    }

    /// Fitness Tab — workout capture, effort metrics, and voice coach.
    ///
    /// Hidden when user has opted out via Settings →
    /// `hideFitnessTab` (recovery-only / HRV-only users get a
    /// cleaner tab bar without dead surfaces). When hidden, the tab bar
    /// has one fewer tab and the workout surfaces don't exist for that user.
    @ViewBuilder
    private var fitnessTab: some View {
        if !settingsManager.settings.hideFitnessTab {
            LazyView(
                NavigationStack(path: $fitnessPath) {
                    FitnessTabView(scrollToTopToken: scrollToTopToken)
                }
            )
            .tabItem {
                Label(Tab.fitness.localizedName(bundle: LanguageManager.appBundle), systemImage: selectedTab == .fitness ? Tab.fitness.iconFilled : Tab.fitness.icon)
            }
            .tag(Tab.fitness)
            .accessibilityLabel(String(localized: "Fitness tab", bundle: LanguageManager.appBundle))
            .accessibilityHint(String(localized: "Record and review workouts", bundle: LanguageManager.appBundle))
            .accessibilityIdentifier("tab.fitness")
        }
    }

    /// Coach Tab.
    /// Deferred so the chat ViewModel + Keychain reads
    /// happen only when the user opens it.
    /// 
    /// Gated on enableAIAssistant.
    /// When OFF: tab disappears entirely (same shape as the
    /// hideFitnessTab gate above). The Assistant chat view model,
    /// provider registry, and AssistantInbox all skip work when
    /// the tab isn't accessible.
    @ViewBuilder
    private var coachTab: some View {
        if settingsManager.settings.enableAIAssistant {
            LazyView(
                NavigationStack(path: $coachPath) {
                    // V2 chrome (model
                    // badge, context chips, suggested-prompts
                    // sheet).
                    CoachHomeV2View(scrollToBottomSignal: scrollToTopToken)
                }
            )
            .tabItem {
                Label(Tab.coach.localizedName(bundle: LanguageManager.appBundle), systemImage: Tab.coach.icon)
            }
            .tag(Tab.coach)
            .accessibilityLabel(String(localized: "Flo tab", bundle: LanguageManager.appBundle))
            .accessibilityHint(String(localized: "Ask questions about your recovery data", bundle: LanguageManager.appBundle))
            .accessibilityIdentifier("tab.coach")
        }
    }

    /// Dashboard shows recent sessions. 35 so the Recent strip
    /// (30 days back) has enough
    /// archive coverage to find the matching session for every
    /// in-window day, even if the user reads more than once on some
    /// days. Lightweight loader (no rrSeries deserialization) keeps
    /// the cost negligible — ~35× small JSON parses, well under the
    /// per-frame budget. TrendsV2View loads the full archive itself;
    /// History paginates off the lightweight index.
    static let dashboardSessionLoadLimit = 35
    /// Above this, the reload log breaks its total into phases. One launch in
    /// five in a field log crossed it; the median was 497 ms.
    static let slowDashboardReloadMs = 1_500
}

/// The moments one dashboard reload passed through, for `logDashboardTiming`.
/// Each later mark defaults to the request, so a phase that never ran reads as
/// zero rather than as the time since 1970.
struct DashboardLoadTiming: Sendable {
    let requestedAt: Date
    var startedAt: Date
    var decryptedAt: Date
    var countedAt: Date

    init(requestedAt: Date) {
        self.requestedAt = requestedAt
        startedAt = requestedAt
        decryptedAt = requestedAt
        countedAt = requestedAt
    }

    static func milliseconds(from start: Date, to end: Date) -> Int {
        Int(end.timeIntervalSince(start) * 1000)
    }
}

#Preview {
    MainTabView()
        .environment(RRCollector())
        .environment(AppDependencies.current.storage.cloudKitSyncManager)
        .environment(AppDependencies.current.services.languageManager)
}
