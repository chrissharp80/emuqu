import CoreLocation
import MessageUI
import SwiftUI

// Tab ordering and the Send-report toolbar menu. Members are internal rather
// than `private` because Swift's `private` does not reach across files.

extension MainTabView {
    // MARK: - More tab

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

    /// Load the dashboard's slice. One in-flight load at a time: a request
    /// that arrives while one runs sets `dashboardReloadPending` and runs once
    /// the current load finishes. Requests while another tab is showing are
    /// deferred until the Dashboard is shown.
    ///
    /// A user log showed
    /// `[MainTabView] scenePhase → active — refreshing dashboard` firing
    /// THREE TIMES in a row after a single audio interruption (system
    /// quirk: backgrounded → inactive → active toggles trigger N
    /// `.onChange` callbacks within a few hundred ms). Requests that land
    /// while a load runs collapse into one trailing reload; a request within
    /// 50 ms of the last load start is deferred to the end of that window
    /// rather than dropped, so a change that lands just after a very fast load
    /// still reaches the dashboard.
    func reloadDashboardSessions() {
        guard dashboardReloadIsWanted() else { return }
        // Never cancel an in-flight decrypt: it runs on a `Task.detached` that
        // ignores cancellation. Mark a trailing reload instead, checked before
        // the debounce so a request landing just after a load starts is not
        // dropped.
        if dashboardReloadInFlight {
            dashboardReloadPending = true
            return
        }
        guard dashboardReloadPassesDebounce() else {
            scheduleDebouncedDashboardReload()
            return
        }
        startDashboardLoad()
    }

    /// One trailing reload at the end of the 50 ms window; further requests in
    /// the window ride on it.
    func scheduleDebouncedDashboardReload() {
        guard !dashboardReloadPending else { return }
        dashboardReloadPending = true
        Task {
            await sleepQuietly(50_000_000, context: "dashboard reload debounce")
            dashboardReloadPending = false
            reloadDashboardSessions()
        }
    }

    /// Don't decrypt the dashboard slice while another tab is showing. These
    /// reloads fire on foreground / archive-change / CloudKit-pull — all
    /// tab-independent — so tapping Record/Fitness was triggering a
    /// ~35-session dashboard decrypt unrelated to that screen. Defer to when
    /// the Dashboard is actually shown (it paints from cache meanwhile).
    func dashboardReloadIsWanted() -> Bool {
        guard selectedTab == .dashboard else {
            dashboardReloadDeferred = true
            return false
        }
        return true
    }

    /// False for a request that lands within 50 ms of the last load start.
    func dashboardReloadPassesDebounce() -> Bool {
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
        let requestedAt = Date()
        let archiveRef = collector.archive
        refreshTask = Task {
            var timing = DashboardLoadTiming(requestedAt: requestedAt)
            timing.startedAt = Date()
            let loaded = await collector.recentSessionsAsync(limit: Self.dashboardSessionLoadLimit)
            timing.decryptedAt = Date()
            // Compute the true archive count off the main thread too, so the
            // body doesn't read `archive.entries.count` (lock + potential
            // full-index re-sort) on every render.
            let count = await Task.detached { archiveRef.entries.count }.value
            timing.countedAt = Date()
            await MainActor.run { [timing] in
                applyDashboardLoad(loaded, count: count, timing: timing)
            }
        }
    }

    @MainActor
    func applyDashboardLoad(_ loaded: [HRVSession], count: Int, timing: DashboardLoadTiming) {
        sessions = loaded
        totalSessionCount = count
        dependencies.storage.uiStateCache.setDashboard(buildDashboardSnapshot(from: loaded))
        logDashboardTiming(loaded.count, timing: timing)
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
    /// A single total is misleading: a lightweight read of a 25,000-beat
    /// overnight session measures 0.94 ms, so thirty-five of them is tens of
    /// milliseconds, yet the total spans a wait for the main thread, the
    /// parallel read, an archive-index count that takes `archiveLock`, and a
    /// hop back to the main actor — and any of those can be the seconds.
    ///
    /// The wait is split out because the load's task is created on the main
    /// actor and cannot start until the main thread is free; charged to the
    /// read, a busy main thread and a slow archive read look alike.
    ///
    /// Logged only when it is slow enough to matter, so the ordinary sub-second
    /// reload stays one line.
    @MainActor
    private func logDashboardTiming(_ sessionCount: Int, timing: DashboardLoadTiming) {
        let totalMs = DashboardLoadTiming.milliseconds(from: timing.requestedAt, to: Date())
        guard totalMs >= Self.slowDashboardReloadMs else {
            debugLog("[LaunchTiming] dashboard reload: \(sessionCount) sessions in \(totalMs)ms", level: .info)
            return
        }
        let waitMs = DashboardLoadTiming.milliseconds(from: timing.requestedAt, to: timing.startedAt)
        let readMs = DashboardLoadTiming.milliseconds(from: timing.startedAt, to: timing.decryptedAt)
        let countMs = DashboardLoadTiming.milliseconds(from: timing.decryptedAt, to: timing.countedAt)
        debugLog(
            "[LaunchTiming] SLOW dashboard reload: \(sessionCount) sessions in \(totalMs)ms — "
                + "waited \(waitMs)ms for the main thread, read \(readMs)ms, index count \(countMs)ms, "
                + "apply \(totalMs - waitMs - readMs - countMs)ms",
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

    /// The night the dashboard hero shows (same `DashboardSessionPolicy`
    /// selector). Drives the "Send recovery report" menu item — disabled
    /// when nil so the user doesn't tap an action that has no data.
    var mostRecentOvernight: HRVSession? {
        DashboardSessionPolicy.latestOvernightComplete(in: sessions, calendar: .current)
    }

    /// Most-recent workout session in the dashboard slice.
    var mostRecentWorkout: HRVSession? {
        sessions.first(where: { $0.sessionType == .workout })
    }

    /// Most-recent (workout, night-before) pair, if any. The daily holistic
    /// report needs both halves; without an overnight the day collapses to a
    /// workout-only PDF, which the `.workout` menu item already covers.
    ///
    /// The night is the latest reliable overnight that started within the 36 h
    /// before the workout, the same lookback the Coach report uses, so a
    /// 23:00 bedtime pairs with the next day's training and a workout is never
    /// paired with the night after it.
    func mostRecentDailyPair() -> (workout: HRVSession, overnight: HRVSession)? {
        let nights = sessions.filter { $0.sessionType == .overnight && $0.isReliableForHRVAggregates }
        for workout in sessions where workout.sessionType == .workout {
            let earliest = workout.startDate.addingTimeInterval(-36 * 3600)
            let night = nights
                .filter { $0.startDate >= earliest && $0.startDate < workout.startDate }
                .max { $0.startDate < $1.startDate }
            if let night { return (workout, night) }
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
                inputs: Self.withFullSessions(inputs),
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
        let baselineStats: BaselineTracker.RecoveryBaselineStats?
        let maxHR: Int
        let restingHR: Int
        let lthr: Int
        let units: UnitsPreference
        var temperatureUnit: TemperatureUnit = .regionDefault
    }

    func sendReportInputs() -> SendReportInputs {
        let settings = dependencies.app.settingsManager.settings
        return SendReportInputs(
            recovery: mostRecentOvernight,
            workout: mostRecentWorkout,
            pair: mostRecentDailyPair(),
            recentOvernight: sessions.filter { $0.sessionType == .overnight && $0.isReliableForHRVAggregates },
            baselineStats: collector.baselineTracker.recoveryBaselineStats,
            maxHR: settings.effectiveMaxHR,
            restingHR: settings.effectiveRestingHR,
            lthr: settings.effectiveLTHR,
            units: UnitsPreferenceStore.current.resolved,
            temperatureUnit: settings.temperatureUnit
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
