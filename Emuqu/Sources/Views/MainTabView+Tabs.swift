import CoreLocation
import MessageUI
import SwiftUI

// Tab ordering and the Send-report toolbar menu. Members are internal rather
// than `private` because Swift's `private` does not reach across files.

extension MainTabView {
    // MARK: - Conditionally-ordered tabs
    //
    // History / Trends / Settings get reordered based on
    // `hideFitnessTab` so the user always has Settings as a primary
    // visible icon when they've opted out of workout tracking. See the
    // ordering block in `body` for the full rationale.

    @ViewBuilder
    var moreTab: some View {
        LazyView(
            // Bound path so `tabSelectionBinding` can reset to root on
            // every More-tab selection event. Without the binding the
            // stack manages its own state and the user stays on
            // whatever sub-page they were on.
            NavigationStack(path: $morePath) {
                MoreMenuView(scrollToTopToken: scrollToTopToken)
            }
        )
        .tabItem {
            Label(Tab.more.localizedName(bundle: LanguageManager.appBundle), systemImage: selectedTab == .more ? Tab.more.iconFilled : Tab.more.icon)
        }
        .tag(Tab.more)
        .accessibilityLabel(String(localized: "More tab", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Trends, Settings, Help, About", bundle: LanguageManager.appBundle))
        .accessibilityIdentifier("tab.more")
    }

    /// Load the dashboard's slice. One in-flight task at a time; new loads
    /// cancel the prior. No flags, no cooldown, no warm-start.
    ///
    /// A user log showed
    /// `[MainTabView] scenePhase → active — refreshing dashboard` firing
    /// THREE TIMES in a row after a single audio interruption (system
    /// quirk: backgrounded → inactive → active toggles trigger N
    /// `.onChange` callbacks within a few hundred ms). Each one cancelled
    /// the prior in-flight load and spawned a new one — fine for
    /// correctness, wasteful for perf. The 50 ms guard below collapses
    /// the burst into one effective reload while still letting genuine
    /// distinct triggers (archive save, CloudKit pull) reload promptly.
    func reloadDashboardSessions() {
        guard dashboardReloadIsWanted() else { return }
        // Serialized path: never cancel an in-flight decrypt. The decrypt runs
        // on a `Task.detached` that ignores cancellation, so cancelling only
        // orphaned it while a new one piled on. Instead, if one is already
        // running, mark a trailing reload and let the current finish — then run
        // exactly once more with the latest archive state.
        if dashboardReloadInFlight {
            dashboardReloadPending = true
            return
        }
        startDashboardLoad()
    }

    /// Don't decrypt the dashboard slice while another tab is showing. These
    /// reloads fire on foreground / archive-change / CloudKit-pull — all
    /// tab-independent — so tapping Record/Fitness was triggering a
    /// ~35-session dashboard decrypt unrelated to that screen. Defer to when
    /// the Dashboard is actually shown (it paints from cache meanwhile).
    func dashboardReloadIsWanted() -> Bool {
        if selectedTab != .dashboard {
            dashboardReloadDeferred = true
            return false
        }
        let now = Date()
        guard now.timeIntervalSince(lastDashboardReloadAt) >= 0.05 else { return false }
        lastDashboardReloadAt = now
        return true
    }

    /// One dashboard decrypt at a time. On completion, applies the result and
    /// fires a single trailing reload if any request arrived while it ran.
    /// Bypasses the 50 ms debounce (the trailing run must not be swallowed).
    func startDashboardLoad() {
        dashboardReloadInFlight = true
        let startedAt = Date()
        let archiveRef = collector.archive
        refreshTask = Task {
            let loaded = await collector.recentSessionsAsync(limit: Self.dashboardSessionLoadLimit)
            let decryptedAt = Date()
            // Compute the true archive count off the main thread too, so the
            // body doesn't read `archive.entries.count` (lock + potential
            // full-index re-sort) on every render.
            let count = await Task.detached { archiveRef.entries.count }.value
            let countedAt = Date()
            await MainActor.run {
                applyDashboardLoad(
                    loaded, count: count, startedAt: startedAt,
                    decryptedAt: decryptedAt, countedAt: countedAt
                )
            }
        }
    }

    @MainActor
    func applyDashboardLoad(
        _ loaded: [HRVSession], count: Int, startedAt: Date,
        decryptedAt: Date, countedAt: Date
    ) {
        sessions = loaded
        totalSessionCount = count
        dependencies.storage.uiStateCache.setDashboard(buildDashboardSnapshot(from: loaded))
        logDashboardTiming(loaded.count, startedAt: startedAt, decryptedAt: decryptedAt, countedAt: countedAt)
        // Real "the dashboard has its data, we're interactive" signal —
        // opens the LaunchCoordinator's housekeeping phase (idempotent).
        dependencies.app.launchCoordinator.signalDashboardReady()
        dashboardReloadInFlight = false
        if dashboardReloadPending {
            dashboardReloadPending = false
            startDashboardLoad()
        }
    }

    /// Where the dashboard reload's time actually went.
    ///
    /// The single total this used to print said "35 sessions decrypted in
    /// 7430ms" and was read — by me — as 7.4 seconds of decryption. It is not:
    /// a lightweight read of a 25,000-beat overnight session measures 0.94 ms,
    /// so thirty-five of them is tens of milliseconds, not seconds. The total
    /// spans a task hop, the parallel read, an archive-index count that takes
    /// `archiveLock`, and a hop back to the main actor — and any of those can
    /// be the seconds.
    ///
    /// Splitting it is the difference between knowing and guessing. Logged only
    /// when it is slow enough to matter, so the ordinary sub-second reload stays
    /// one line.
    @MainActor
    private func logDashboardTiming(
        _ sessionCount: Int, startedAt: Date, decryptedAt: Date, countedAt: Date
    ) {
        let readMs = Int(decryptedAt.timeIntervalSince(startedAt) * 1000)
        let countMs = Int(countedAt.timeIntervalSince(decryptedAt) * 1000)
        let totalMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        guard totalMs >= Self.slowDashboardReloadMs else {
            debugLog("[LaunchTiming] dashboard reload: \(sessionCount) sessions in \(totalMs)ms", level: .info)
            return
        }
        debugLog(
            "[LaunchTiming] SLOW dashboard reload: \(sessionCount) sessions in \(totalMs)ms — "
                + "read \(readMs)ms, index count \(countMs)ms, apply \(totalMs - readMs - countMs)ms",
            level: .info
        )
    }

    /// Build the dashboard display snapshot for `UIStateCache`, using the SAME
    /// `DashboardSessionPolicy` selectors the view renders from — so the cached
    /// values are identical to what the live path shows (parity by construction).
    func buildDashboardSnapshot(from sessions: [HRVSession]) -> UIStateCache.DashboardSnapshot {
        let cal = Calendar.current
        let overnight = DashboardSessionPolicy.latestOvernightComplete(in: sessions, calendar: cal)
        let hero = overnight?.recoveryScore.map { ScoreVerdict.safeDisplayScore($0 * 10) }
        let hrv = overnight?.analysisResult.map { Int($0.timeDomain.rmssd.rounded()) }
        let sleepMin = (overnight?.sleepSnapshot ?? DashboardSessionPolicy.latestWithSleep(in: sessions)?.sleepSnapshot)?.totalSleepIncludingNapMinutes
        let recent = DashboardSessionPolicy.recentDays(from: sessions, today: Date(), calendar: cal)
            .map { UIStateCache.RecentDaySnapshot(date: $0.date, score: $0.score) }
        let vitals = DashboardSessionPolicy.latestWithVitals(in: sessions)?.vitalsSnapshot
        return UIStateCache.DashboardSnapshot(
            heroScore: hero,
            hrvRmssdMs: hrv,
            sleepMinutes: (sleepMin ?? 0) > 0 ? sleepMin : nil,
            recentDays: recent,
            vitals: vitals
        )
    }

    @MainActor
    func publishDashboardSessions(_ loaded: [HRVSession], totalCount: Int) {
        guard !Task.isCancelled else { return }
        sessions = loaded
        totalSessionCount = totalCount
        dependencies.storage.uiStateCache.setDashboard(buildDashboardSnapshot(from: loaded))
        dependencies.app.launchCoordinator.signalDashboardReady()
    }

    func startRecording() {
        selectedTab = .record
    }

    /// Hand a question to the Assistant tab and switch to it. An empty string
    /// just opens the tab without pre-filling. Questions ending in `?` auto-send;
    /// other text just pre-fills the input for the user to edit.
    func askAssistant(_ question: String) {
        dependencies.assistant.assistantInbox.pendingDraft = question.isEmpty ? nil : question
        dependencies.assistant.assistantInbox.requestOpen()
    }

    func deleteSession(_ session: HRVSession) {
        do {
            try collector.archive.delete(session.id)
            collector.notifyArchiveChanged()
            // Sync deletion to iCloud
            Task { await dependencies.storage.cloudKitSyncManager.uploadDeletion(session.id) }
        } catch {
            debugLog("Failed to delete session: \(error)")
        }
    }

    func updateTags(session: HRVSession, tags: [ReadingTag], notes: String?) {
        do {
            try collector.archive.updateTags(session.id, tags: tags, notes: notes)
            collector.notifyArchiveChanged()
        } catch {
            debugLog("Failed to update tags: \(error)")
        }
    }

    func reanalyzeSession(_ session: HRVSession, method: WindowSelectionMethod) async -> HRVSession? {
        // ReanalysisService calls `onArchiveChanged` which bumps
        // `RRCollector.archiveVersion`. Dashboard, TrendView, and the
        // MainTabView dashboard-sessions loader all observe that signal
        // and refresh themselves — no manual session write needed.
        await collector.reanalyzeSession(session, method: method)
    }

    // MARK: - Send report (Dashboard toolbar menu)

    /// Most-recent overnight HRV session in the dashboard slice.
    /// Drives the "Send recovery report" menu item — disabled when
    /// nil so the user doesn't tap an action that has no data.
    var mostRecentOvernight: HRVSession? {
        sessions.first(where: { $0.sessionType == .overnight })
    }

    /// Most-recent workout session in the dashboard slice.
    var mostRecentWorkout: HRVSession? {
        sessions.first(where: { $0.sessionType == .workout })
    }

    /// Most-recent (workout, same-day-overnight) pair, if any. The
    /// daily holistic report needs both halves; without an overnight
    /// the day collapses to a workout-only PDF (which is what the
    /// `.workout` menu item already covers, so no point in
    /// duplicating it under `.daily` when there's no overnight).
    func mostRecentDailyPair() -> (workout: HRVSession, overnight: HRVSession)? {
        let cal = Calendar.current
        let overnightByDay: [Date: HRVSession] = sessions.reduce(into: [:]) { dict, s in
            guard s.sessionType == .overnight else { return }
            let day = cal.startOfDay(for: s.startDate)
            if dict[day] == nil { dict[day] = s }
        }
        for s in sessions where s.sessionType == .workout {
            let day = cal.startOfDay(for: s.startDate)
            if let overnight = overnightByDay[day] {
                return (s, overnight)
            }
        }
        return nil
    }

    /// The training-load refresh happens inside the detached task
    /// so the report reflects archive writes since the last cache refresh
    /// (plain `live()` could freeze a stale TSB/ACWR). See
    /// `TrainingLoadRegistry.liveRefreshed()`.
    func prepareAndSendReport(_ kind: SendReportKind) {
        guard preparingReportKind == nil else { return }
        preparingReportKind = kind
        reportPrepError = nil
        let inputs = sendReportInputs()
        Task.detached(priority: .userInitiated) {
            let outcome = await Self.renderReport(
                kind: kind,
                inputs: inputs,
                liveLoadSnapshot: await TrainingLoadRegistry.liveRefreshed()
            )
            await MainActor.run { finishReportPreparation(outcome) }
        }
    }

    /// Everything `renderReport` needs, captured on the main actor before the
    /// detached render starts. Internal rather than private because
    /// `renderReport` lives in `MainTabView+Reports.swift` and Swift's
    /// `private` does not reach across files.
    struct SendReportInputs {
        let recovery: HRVSession?
        let workout: HRVSession?
        let pair: (workout: HRVSession, overnight: HRVSession)?
        let recentOvernight: [HRVSession]
        let maxHR: Int
        let restingHR: Int
        let lthr: Int
        let units: UnitsPreference
    }

    func sendReportInputs() -> SendReportInputs {
        let settings = dependencies.app.settingsManager.settings
        return SendReportInputs(
            recovery: mostRecentOvernight,
            workout: mostRecentWorkout,
            pair: mostRecentDailyPair(),
            recentOvernight: sessions.filter { $0.sessionType == .overnight && $0.isReliableForHRVAggregates },
            maxHR: settings.effectiveMaxHR,
            restingHR: settings.effectiveRestingHR,
            lthr: settings.effectiveLTHR,
            units: UnitsPreferenceStore.current.resolved
        )
    }

    @MainActor
    func finishReportPreparation(_ outcome: RenderOutcome) {
        preparingReportKind = nil
        switch outcome {
        case .ok(let url):
            pendingReportMailURL = IdentifiableURL(url: url)
        case .failed(let message):
            reportPrepError = message
        }
    }

    /// Two-state outcome from `renderReport` so the call site doesn't
    /// have to bridge `Result<URL, String>` (String isn't Error) and
    /// doesn't pay for typed-error ceremony just to surface a message.
    enum RenderOutcome {
        case ok(URL)
        case failed(String)
    }
}
