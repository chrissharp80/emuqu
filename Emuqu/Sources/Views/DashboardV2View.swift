import SwiftUI

/// Dashboard home in the v2.0 layout. Two-and-a-half
/// thumb-flick scroll budget. Nintendo joystick test: sleepy user, one-
/// handed, 6:42am, 0.8 seconds — they know whether to push hard, take it
/// easy, or rest.
///
/// Layout (top to bottom):
///   1. Hero ScoreRing (210pt)
///   2. Verdict word + ConfidencePip
///   3. Today's Loop (NarrativeCard)
///   4. Subjective feedback chip
///   5. 4-up chip row (HRV / Sleep / Vitals / Load)
///   6. RecentStrip (last 7 days)
///
/// Training-load gauges, multiple narrative engines and score-breakdown
/// weights belong to RecoveryScoreDetailView (D2), not here.
struct DashboardV2View: View {
    @Environment(\.dependencies) var dependencies
    let sessions: [HRVSession]
    /// True total of sessions in the archive — `sessions` above is the
    /// 8-most-recent slice MainTabView passes for the Recent strip, NOT
    /// the user's full archive size. Without this we'd report "Day 8 of
    /// 14, Building baseline" even for a user with hundreds of sessions.
    let totalSessionCount: Int
    /// Cold-start seed for the hero score, computed at launch from the
    /// synchronously-loaded archive index (MainTabView → EmuquApp).
    /// Used only while `sessions` is still empty (pre-decrypt); the real
    /// session-based value takes over the moment it loads..
    var seedScore: Int?
    /// Cold-start seed for the non-hero summary (HRV/Sleep chips, Recent strip),
    /// from the synchronous index. Used only while `sessions` is still empty;
    /// the session-derived values take over the moment they load..
    var seedSummary: DashboardSessionPolicy.DashboardSeed?
    let isActive: Bool
    let scrollToTopToken: UUID
    let onStartRecording: () -> Void
    let onViewReport: (HRVSession) -> Void
    /// Hooks for the History view we push when the Recent strip's
    /// "View all" chip is tapped. Defaulted to no-ops so
    /// preview / test sites can omit them, but MainTabView wires them
    /// in production.
    var onDeleteSession: (HRVSession) -> Void = { _ in }
    var onUpdateSessionTags: (HRVSession, [ReadingTag], String?) -> Void = { _, _, _ in }
    var onReanalyzeSession: ((HRVSession, WindowSelectionMethod) async -> HRVSession?)?

    @Environment(RRCollector.self) var collector
    /// The HealthKit manager from the dependency container. It is
    /// `@Observable`, so reading `inferredAuthorizationDenied` in `body`
    /// drives a view update.
    var healthKit: HealthKitManager { dependencies.collection.healthKitManager }
    var settingsManager: SettingsManager { dependencies.app.settingsManager }
    /// Watched so the Today's Loop narrative card refreshes when readiness
    /// drifts during the day — a new workout updates ATL/CTL/todayTrimp,
    /// which changes whether `liveReadiness.loopCardText` has a story to
    /// tell. The medallion itself is morning-frozen, so
    /// this observer is purely for the card under it.
    var trainingMetricsCache: TrainingMetricsCache { dependencies.analysis.trainingMetricsCache }
    @State var toast: ToastPayload?
    @State var navTarget: ChipTarget?
    /// Sleep timeline edit failed to persist; shows the
    /// failure alert instead of silently confirming a lost edit.
    @State private var sleepEditSaveFailed = false
    /// Score-reveal cascade trigger.
    /// Flipped to true `revealDuration` after the dashboard appears
    /// (600ms default, 400ms for Day-30+ users). The Today's Loop
    /// slide-up + subjective chip fade observe this in the body.
    /// Stays true once flipped so re-renders during the conversation
    /// don't replay the entrance animation.
    @State private var cascadeRevealed: Bool = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// Day-14 transition. One-time particle
    /// bloom + verdict toast on the morning the user crosses from
    /// "Building baseline" into a real, scored verdict. Persisted in
    /// UserDefaults so it never fires twice. Compared against
    /// `daysCollected` on appear; flips on once and stays flipped.
    private static let day14ShownKey = "dashboard.day14TransitionShown"
    @State var day14BloomActive: Bool = false
    /// The no-Health-data notice stays dismissed. It came back on every
    /// launch, and for a strap user without an Apple Watch it never stops
    /// being true.
    @AppStorage("dashboard.healthNoDataNoticeDismissed") var healthNoDataNoticeDismissed = false

    /// Surfaces "your score updated while you were away" — written by the
    /// auto-rescore listener when an HK sleep / training arrival moves the
    /// score ≥ 3 points. Read on dashboard appear, cleared on tap or
    /// dismiss so it doesn't reappear next launch.
    @State var pendingScoreChange: PendingScoreChange.Entry?

    /// Solid-colour fallback when the user has Reduce
    /// Transparency on (translucent card/banner backgrounds become
    /// hard to read against busy wallpapers / high-contrast needs).
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency

    /// Dynamic Type scaling for the headings / checklist /
    /// verdict / CTA text (fixed `.system(size:)` would ignore
    /// the user's text-size setting). Scaled relative to the nearest
    /// matching text style so the visual hierarchy is preserved.
    @ScaledMetric(relativeTo: .title2) var headingFontSize: CGFloat = 22
    @ScaledMetric(relativeTo: .subheadline) var subheadingFontSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) var rowTitleFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption) var rowSubtitleFontSize: CGFloat = 12
    @ScaledMetric(relativeTo: .headline) var verdictFontSize: CGFloat = 22
    @ScaledMetric(relativeTo: .headline) var baselineFontSize: CGFloat = 17

    /// Chip taps push into detail views via the
    /// hosting NavigationStack. Each chip routes to its dedicated detail
    /// surface (D3/D4/D5/D6). Using a single `navTarget` enum + a
    /// `.navigationDestination` lets us keep the dashboard simple while
    /// using a real push (rather than a half-wired closure that just
    /// presents the morning report).
    enum ChipTarget: Hashable {
        case hrv
        case sleep
        case vitals
        case load
        case history
        case readiness
    }

    /// Most recent session of any kind — including incomplete in-progress
    /// ones. Used for "is there even an entry for today" checks.
    var latest: HRVSession? { sessions.first }

    /// Most recent session that has a usable analysisResult — what the
    /// chip values render from. The latest session may legitimately be
    /// nil-data for a moment (a fresh recording before processing
    /// completes); falling back to the most-recent-with-data avoids
    /// "—" on a user's dashboard when there's perfectly good data one
    /// session back.
    var latestComplete: HRVSession? {
        sessions.first { $0.analysisResult != nil }
    }

    /// Most recent **overnight** session with an analysis result — what the
    /// HRV chip and hero score render from. The quality-aware selection rule
    /// lives in
    /// `DashboardSessionPolicy.latestOvernightComplete`.
    var latestOvernightComplete: HRVSession? {
        DashboardSessionPolicy.latestOvernightComplete(in: sessions, calendar: .current)
    }

    /// Most recent session with a sleep snapshot attached.
    var latestWithSleep: HRVSession? {
        DashboardSessionPolicy.latestWithSleep(in: sessions)
    }

    /// Most recent session with a vitals snapshot attached.
    var latestWithVitals: HRVSession? {
        DashboardSessionPolicy.latestWithVitals(in: sessions)
    }

    private var todaysSessions: [HRVSession] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return sessions.filter { cal.startOfDay(for: $0.startDate) == today }
    }

    /// What the hero ring shows — the frozen morning Recovery Score. This is
    /// "what your night gave you": the dashboard has
    /// one hero number and that number is the morning recovery score, not
    /// live training readiness. The day's drift story (today's workout
    /// pulling on the body, fatigue dissipating through a rest day) lives
    /// in the Today's Loop narrative card under the medallion — see
    /// `todaysLoopText()` and `liveReadiness` below.
    ///
    /// Overnight-only so a quick mid-day exercise
    /// capture (3 ms RMSSD during a walk) doesn't flash onto the dashboard
    /// as today's recovery.
    /// Cached dashboard snapshot from `UIStateCache`, consulted only while
    /// `sessions` is still empty (cold start) as the instant-paint source. The
    /// live path overwrites the moment `sessions` loads, so this can only ever
    /// show a prior-correct value, never a wrong one.
    var cachedDashboard: UIStateCache.DashboardSnapshot? {
        sessions.isEmpty ? dependencies.storage.uiStateCache.dashboard : nil
    }

    var displayedScore: Int? {
        if let s = latestOvernightComplete, let score = s.recoveryScore {
            return ScoreVerdict.safeDisplayScore(score * 10)  // 0-10 → 0-100, non-finite-safe
        }
        // Cold-start: the full sessions haven't decrypted yet (`sessions`
        // empty). Show the last-known score from the cache (else the index
        // seed) so the ring isn't blank on first paint. Self-correcting — the
        // branch above wins the instant `sessions` loads.
        if sessions.isEmpty {
            return cachedDashboard?.heroScore ?? seedScore
        }
        return nil
    }

    var verdict: ScoreVerdict? {
        displayedScore.map { ScoreVerdict(score: Double($0)) }
    }

    /// Live readiness drift, scoped to the narrative card under the hero.
    /// The medallion stays frozen at morning recovery by design; this
    /// is what powers "Your moderate 37-min walk is the day's main event"
    /// when today has a story to tell. Nil-tolerant to keep the hero
    /// rendering when training metrics haven't synced.
    var liveReadiness: LiveReadiness? {
        guard let session = latestOvernightComplete,
              let score01 = session.recoveryScore else { return nil }
        return LiveReadiness.compute(
            recoveryScore: score01 * 10,
            morningSession: session,
            liveMetrics: dependencies.analysis.trainingMetricsCache.current
        )
    }

    /// True archive size, not the dashboard slice. Drives baseline-vs-
    /// full-algorithm gates throughout the dashboard.
    var daysCollected: Int { totalSessionCount }

    /// Nights in the personal baseline, at most one a day. The building /
    /// provisional / full gates count these. They counted every archived
    /// session, so workouts, naps and quick readings reached "Day 14" and
    /// "Full algorithm" after five nights.
    var baselineNights: Int { collector.baselineTracker.daysCollected }

    var body: some View {
        let _ = dependencies.app.keyboardPerfSignpost.event("DashboardV2View.body")
        ScrollViewReader { proxy in
            dashboardScroll(proxy)
        }
        .background(AppTheme.background.ignoresSafeArea())
        // A stable handle for "the Dashboard is what is on
        // screen". Asserting `isSelected` on the tab-bar button is not an
        // option: SwiftUI does not reliably report it; asserting on
        // the destination itself is both stronger and less brittle.
        .accessibilityIdentifier("dashboard.root")
        .toastBanner($toast)
        .navigationDestination(item: $navTarget) { destination(for: $0) }
    }

    private func dashboardScroll(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            dashboardTopSentinel
            dashboardStack
        }
        // Pull-to-refresh re-runs the analysis
        // pipeline against today's data with the current algorithm
        // and surfaces a "Re-analyzed." toast.
        .refreshable { await refreshDashboard() }
        .onChange(of: scrollToTopToken) { _, _ in scrollToTop(proxy) }
    }

    /// Skip the scroll animation under Reduce Motion.
    private func scrollToTop(_ proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo("dashboardTop", anchor: .top)
        } else {
            withAnimation { proxy.scrollTo("dashboardTop", anchor: .top) }
        }
    }

    /// A zero-height marker at the very top of the scroll view. It carries the
    /// dashboard’s appear/refresh wiring because it is the one element that
    /// exists in every dashboard state.
    private var dashboardTopSentinel: some View {
        Color.clear.frame(height: 0).id("dashboardTopHidden")
            .onAppear { onDashboardAppear() }
            .onReceive(NotificationCenter.default.publisher(for: .pendingScoreChangeWritten)) {
                applyPendingScoreChange($0)
            }
    }

    private func onDashboardAppear() {
        if isActive {
            dependencies.services.validationTelemetry.recordDashboardOpen()
        }
        // Load any pending "score changed while you were
        // away" notice written by the auto-rescore listener.
        pendingScoreChange = PendingScoreChange.read()
        scheduleCascadeReveal()
        celebrateDay14IfNeeded()
    }

    /// Fire the cascade
    /// AFTER the score ring's reveal completes. Users with a full baseline
    /// get the snappier 400ms ring; everyone
    /// else gets 600ms. We delay slightly past the
    /// ring's full reveal so the loop card lands on
    /// a settled hero, not a still-animating one.
    private func scheduleCascadeReveal() {
        guard !cascadeRevealed else { return }
        let snappy = ScoreAppearancePolicy.stage(baselineNights: baselineNights) == .full
        let ringDuration: Double = snappy ? 0.4 : 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + ringDuration) {
            cascadeRevealed = true
        }
    }

    /// Day-14 transition (`ScoreAppearancePolicy.scoreShownNights`).
    /// Fires once when the baseline just reached that night
    /// AND the persistent flag hasn't been set yet.
    /// Particle bloom plus a one-time toast.
    private func celebrateDay14IfNeeded() {
        guard baselineNights == ScoreAppearancePolicy.scoreShownNights,
              !UserDefaults.standard.bool(forKey: Self.day14ShownKey),
              let v = verdict else { return }
        UserDefaults.standard.set(true, forKey: Self.day14ShownKey)
        day14BloomActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            toast = ToastPayload(
                glyph: "sparkles",
                message: String(localized: "Your baseline is set. Today: \(v.localizedWord).", bundle: LanguageManager.appBundle),
                tint: v.color
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            day14BloomActive = false
        }
    }

    /// Gate the banner spring on Reduce Motion.
    private func applyPendingScoreChange(_ note: Notification) {
        guard let entry = note.object as? PendingScoreChange.Entry else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) {
            pendingScoreChange = entry
        }
    }

    private var dashboardStack: some View {
        VStack(spacing: 18) {
            Color.clear.frame(height: 0).id("dashboardTop")
            healthKitDeniedBannerIfNeeded
            scoreChangedBannerIfNeeded
            SampleDataBanner()
            heroSection
                .padding(.top, 24) // 24pt top padding
            dashboardBodySections
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 32)
    }

    /// HealthKit-denied banner. `HealthKitManager`
    /// infers denial after a probe query (privacy shield means
    /// it can't read the grant state directly); this is the
    /// first view to actually surface that signal.
    @ViewBuilder
    private var healthKitDeniedBannerIfNeeded: some View {
        // Not before a first night: a new phone has no Apple Health sleep or
        // HRV yet, so the notice met everyone straight after they allowed
        // access.
        if healthKit.inferredAuthorizationDenied, !healthNoDataNoticeDismissed, baselineNights > 0 {
            healthKitDeniedBanner
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var scoreChangedBannerIfNeeded: some View {
        if let change = pendingScoreChange {
            scoreChangedBanner(change)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Day-1 dashboard state.
    /// ScoreRing in `building-baseline` state, with a
    /// 3-item checklist replacing the chips, Today's
    /// Loop, and Recent strip below. The sample-data offer
    /// for someone with no strap yet sits in the hero's
    /// baseline slot (`baselineProgressOrSampleOffer`). Once the user has
    /// ANY reading (daysCollected >= 1), the standard
    /// dashboard layout takes over — even at "Day 1 of
    /// 14" the ring shows progress and the loop card,
    /// chips, and strip are real.
    @ViewBuilder
    private var dashboardBodySections: some View {
        if daysCollected == 0 {
            day1Checklist
        } else {
            revealedDashboardSections
        }
    }

    /// Score-reveal cascade.
    /// Today's Loop slides up from below over 300ms
    /// with a subtle bounce; the subjective chip
    /// fades in 200ms after that. Both gated on
    /// `cascadeRevealed` (flipped after the ring's
    /// reveal completes — 600ms or 400ms snappy mode).
    /// Reduce Motion bypasses both and shows static.
    @ViewBuilder
    private var revealedDashboardSections: some View {
        todaysLoopSection
            .opacity(cascadeRevealed || reduceMotion ? 1 : 0)
            .offset(y: (cascadeRevealed || reduceMotion) ? 0 : 16)
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: cascadeRevealed)
        feedbackChipSection
            .opacity(cascadeRevealed || reduceMotion ? 1 : 0)
            .animation(.easeOut(duration: 0.2).delay(0.3), value: cascadeRevealed)
        chipsRow
        recentStripSection
        fullReportLink
    }

    @ViewBuilder
    private func destination(for target: ChipTarget) -> some View {
        switch target {
        case .hrv: hrvDestination
        case .sleep: sleepDestination
        case .vitals: vitalsDestination
        case .load: LoadTrajectoryLoader()
        case .history: historyDestination
        case .readiness: readinessDestination
        }
    }

    /// Single source of truth: the chip displays data from the
    /// morning overnight session (`latestOvernightComplete`), so
    /// the detail must open the same session. Routing to
    /// `latestComplete` would push the most-recent capture of
    /// any type — including a 3 ms mid-workout `.workout`
    /// session — making the chip and the detail tell different
    /// stories about "today's HRV." That violated the rule that the morning
    /// hero and its detail agree, and produced the user-reported divergence
    /// (chip says 85 ms, detail shows 3 ms from the afternoon
    /// workout).
    @ViewBuilder
    private var hrvDestination: some View {
        if let session = latestOvernightComplete, let result = session.analysisResult {
            HRVDetailV2View(
                session: session,
                result: result,
                recentSessions: sessions,
                baselineStats: collector.scoringBaselineStats(for: session)
            )
        } else {
            EmptyState(
                glyph: "waveform.path.ecg",
                headline: String(localized: "No HRV reading yet", bundle: LanguageManager.appBundle),
                message: String(localized: "Take your first reading from the Record tab.", bundle: LanguageManager.appBundle)
            )
        }
    }

    /// Same single-source-of-truth rule as .hrv — the chip
    /// shows the morning overnight's sleep snapshot; the detail
    /// must open that same session.
    @ViewBuilder
    private var sleepDestination: some View {
        if let session = latestOvernightComplete {
            sleepDetail(for: session)
                .alert(sleepEditFailedTitle, isPresented: $sleepEditSaveFailed) {
                    dismissAlertButton
                } message: {
                    Text(sleepEditFailedMessage)
                }
        } else {
            EmptyState(
                glyph: "bed.double",
                headline: String(localized: "No sleep data yet", bundle: LanguageManager.appBundle),
                message: String(localized: "Sleep data appears once your overnight reading processes.", bundle: LanguageManager.appBundle)
            )
        }
    }

    private var dismissAlertButton: some View {
        Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) {}
    }

    private var sleepEditFailedTitle: String {
        String(localized: "Sleep edit not saved", bundle: LanguageManager.appBundle)
    }

    private var sleepEditFailedMessage: String {
        String(localized: "Your timeline change couldn't be stored. Please try again.", bundle: LanguageManager.appBundle)
    }

    /// When this session has no sleep snapshot the view shows the latest
    /// night that does, so an edit must be saved to that night, not this one.
    private func sleepDetail(for session: HRVSession) -> some View {
        let source = session.sleepSnapshot == nil ? (latestWithSleep ?? session) : session
        return SleepDetailV2View(
            session: session,
            sleepData: source.sleepSnapshot,
            recoveryVitals: session.vitalsSnapshot,
            recentSessions: sessions,
            temperatureUnit: settingsManager.settings.temperatureUnit,
            typicalSleepHours: settingsManager.settings.typicalSleepHours,
            userAge: ageFromBirthday(settingsManager.settings.birthday),
            onAdjust: { saveSleepBoundaries($0, for: source) }
        )
    }

    /// Surface persist failure rather than letting
    /// the edit die in a debugLog while the
    /// editor confirms success.
    private func saveSleepBoundaries(_ adjusted: SleepData, for session: HRVSession) {
        if !collector.updateSessionSleepBoundaries(
            sessionId: session.id,
            sleepData: adjusted,
            isUserAdjustment: true
        ) {
            sleepEditSaveFailed = true
        }
    }

    private var vitalsDestination: some View {
        VitalsDetailV2View(
            vitals: latestWithVitals?.vitalsSnapshot ?? latest?.vitalsSnapshot,
            recentSessions: sessions,
            temperatureUnit: settingsManager.settings.temperatureUnit
        )
    }

    private var historyDestination: some View {
        HistoryView(
            onDelete: onDeleteSession,
            onUpdateTags: onUpdateSessionTags,
            onReanalyze: onReanalyzeSession,
            scrollToTopToken: scrollToTopToken
        )
    }

    @ViewBuilder
    private var readinessDestination: some View {
        if let r = liveReadiness {
            ReadinessExplainView(readiness: r, onViewMorningReport: viewMorningReportAction)
        } else {
            noReadinessState
        }
    }

    /// Opens the morning report for today's overnight session, or nothing when
    /// there isn't one yet.
    private var viewMorningReportAction: (() -> Void)? {
        latestOvernightComplete.map { session in
            { onViewReport(session) }
        }
    }

    private var noReadinessState: some View {
        EmptyState(
            glyph: "figure.mind.and.body",
            headline: String(localized: "No readiness yet", bundle: LanguageManager.appBundle),
            message: String(localized: "Take your first overnight reading to see today's readiness.", bundle: LanguageManager.appBundle)
        )
    }
}
