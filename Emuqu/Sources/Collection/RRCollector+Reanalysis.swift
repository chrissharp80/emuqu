import Foundation

// MARK: - Re-Analysis & Manual Window Selection

extension SessionReanalysisCoordinator {
    // MARK: - ReanalysisService (lazy, cached)

    /// Lazily-created service that owns all re-analysis logic.
    /// Captures `self` weakly through closures so the service does not
    /// prevent deallocation of the collector.
    /// Cached in `collector._reanalysisService` to avoid re-creating on every access.
    var reanalysisService: ReanalysisService {
        if let cached = collector._reanalysisService {
            return cached
        }
        let service = makeReanalysisService(fallbackSettings: collector.settingsManager.settings)
        collector._reanalysisService = service
        return service
    }

    /// `fallbackSettings` is the snapshot taken when the service was built; the
    /// providers fall back to it only once the collector has been deallocated.
    private func makeReanalysisService(fallbackSettings: UserSettings) -> ReanalysisService {
        ReanalysisService(
            archive: collector.archive,
            healthKit: collector.healthKit,
            analysisPipeline: collector.analysisPipeline,
            windowSelector: collector.windowSelector,
            artifactDetector: collector.artifactDetector,
            baselineTracker: collector.baselineTracker,
            settingsProvider: { [weak collector] in collector?.settingsManager.settings ?? fallbackSettings },
            scoringConfigProvider: { [weak collector] in collector?.currentScoringConfig ?? .init(from: fallbackSettings) },
            ansConfigProvider: { [weak collector] in collector?.currentANSConfig ?? Self.ansConfig(from: fallbackSettings) },
            trainingContextProvider: { [weak collector] date in collector?.createTrainingContext(relativeTo: date) },
            analyzeWithWindow: { [weak collector] session, window, flags, peak in await collector?.analyze(session, window: window, flags: flags, peakCapacity: peak) },
            analyzeFullSession: { [weak collector] session, peak in await collector?.analyze(session, peakCapacity: peak) },
            onArchiveChanged: { [weak collector] in collector?.archiveSignal.notifyChanged() },
            // Captured once, so the upload Task never reaches back through
            // the collector.
            onSessionUploaded: { [cloudSync = collector.cloudSyncManager] session in
                Task { await cloudSync.forceReuploadSession(session) }
            }
        )
    }

    private static func ansConfig(from settings: UserSettings) -> HRVAnalysisPipeline.ANSConfiguration {
        HRVAnalysisPipeline.ANSConfiguration(
            baselineRMSSD: settings.populationBaselineRMSSD,
            vo2Max: nil,
            trainingLoadAdjustment: 0
        )
    }

    // MARK: - Thin Wrappers

    /// Re-analyze a session with current algorithms.
    /// This updates HRV analysis (window, metrics) but the frozen trainingSnapshot
    /// on the session is preserved — reanalysis only changes HRV and sleep.
    ///
    /// Re-entrancy guard. If reanalysis is already
    /// running for this session id (e.g. pull-to-refresh AND the
    /// auto-rescore listener BOTH fire for the same session within
    /// a few seconds), the duplicate is skipped. The pull-to-refresh
    /// path has no timeout race (DashboardV2View.refreshDashboard is
    /// local work with no sleep-vs-result race), so this
    /// guard just prevents wasteful double-work.
    func reanalyzeSession(_ session: HRVSession, method: WindowSelectionMethod = .consolidatedRecovery) async -> HRVSession? {
        if collector.inFlightReanalyses.contains(session.id) {
            return await coalescedInFlightSession(session)
        }
        collector.inFlightReanalyses.insert(session.id)
        defer { collector.inFlightReanalyses.remove(session.id) }
        let fullSession = await fullSessionFromDisk(session)
        let sessionDate = fullSession.endDate ?? fullSession.startDate
        let pastDay = await loadPastDayTrainingLoad(asOf: sessionDate)
        defer { if let pastDay { collector.pastDayTrainingLoads[pastDay] = nil } }
        await warmTrainingMetricsCacheIfCold()
        return await reanalysisService.reanalyzeSession(fullSession, method: method)
    }

    /// The analysis reads the load as of the session's date. A past day's load
    /// goes into the per-day store, never the shared current-load cache, so
    /// a live read made meanwhile cannot pick up a past day's numbers. Returns
    /// the day key to clear afterwards; nil for today, whose load is the cache.
    private func loadPastDayTrainingLoad(asOf sessionDate: Date) async -> Date? {
        let calendar = Calendar.current
        guard collector.settingsManager.settings.enableTrainingLoadIntegration,
              !calendar.isDateInToday(sessionDate) else { return nil }
        let day = calendar.startOfDay(for: sessionDate)
        collector.pastDayTrainingLoads[day] = await collector.healthKit.calculateTrainingLoad(relativeTo: sessionDate)
        return day
    }

    /// Return the CURRENT session, not nil. At the call site a
    /// nil is indistinguishable from a real "no RR data" failure, so
    /// pull-to-refresh printed "this session is missing raw beat data"
    /// whenever a manual reanalyze coincided with the auto-rescore that a
    /// fresh Apple-sleep sync kicks off (that rescore holds the in-flight
    /// guard through its slow HealthKit work — exactly while HealthKit is busy
    /// fetching sleep). The RR data is intact; the in-flight run will
    /// finish and bump `collector.archiveSignal` to refresh the UI. Handing back the
    /// current session lets the caller register success instead of lying.
    private func coalescedInFlightSession(_ session: HRVSession) async -> HRVSession? {
        debugLog("[Reanalyze] suppressing duplicate run for \(session.id.uuidString.prefix(8)) — already in flight")
        let archive = self.collector.archive
        let id = session.id
        return await Task.detached(priority: .userInitiated) {
            archive.retrieveOrLog(id, caller: "reanalyze.inFlightCoalesce") ?? session
        }.value
    }

    /// The dashboard hands us sessions loaded
    /// via `retrieveLightweightOrLog` (rrSeries=nil for performance).
    /// `ReanalysisService.reanalyzeSession` bails if rrSeries is nil,
    /// so pull-to-refresh on the hero would show "Can't re-analyze
    /// — this session is missing raw beat data" even when the
    /// session file on disk has the full RR stream. Re-load the
    /// FULL session from disk before reanalysis so the rrSeries
    /// gate sees what's actually on disk, not the in-memory
    /// lightweight copy.
    private func fullSessionFromDisk(_ session: HRVSession) async -> HRVSession {
        let archive = self.collector.archive
        let sessionId = session.id
        return await Task.detached(priority: .userInitiated) {
            archive.retrieveOrLog(sessionId, caller: "RRCollector.reanalyzeSession") ?? session
        }.value
    }

    /// Warm `AppDependencies.current.analysis.trainingMetricsCache.current` BEFORE
    /// reanalyze runs, but ONLY when it's cold/empty. We deliberately
    /// use `Date()` (now-anchor, the same reference the rest of the
    /// app uses for the live cache) and NOT the session date (morning-
    /// anchor). Using the session date republishes the
    /// cache with yesterday-evening values — silently swapping the
    /// dashboard TRAINING LOAD card from 25/17 (now-anchor) to 32/19
    /// (morning-anchor) every time the user tapped Reanalyze and
    /// making the breakdown's training factor disagree with the card.
    /// The shared cache is a single-writer singleton; reanalyze must
    /// not pollute it with a different time anchor than the rest of
    /// the app.
    private func warmTrainingMetricsCacheIfCold() async {
        let cache = AppDependencies.current.analysis.trainingMetricsCache
        let isCold = cache.current == nil
            || ((cache.current?.atl ?? 0) == 0 && (cache.current?.ctl ?? 0) == 0)
        guard isCold else { return }
        await cache.refresh()
    }

    // MARK: - Pending-score-change surfacing

    /// Records a `PendingScoreChange` when an auto-rescore moves the score
    /// meaningfully. The dashboard reads this on appear and shows a banner
    /// so the user understands why the displayed number differs from what
    /// they last saw (e.g. Apple Watch synced sleep at 11 AM, score climbed
    /// 67 → 74; without context the new number feels arbitrary).
    ///
    /// Threshold is ≥ 3 display points — below that, the delta is within
    /// recompute noise and would be more confusing than helpful. The stored
    /// score is 0–10, so that is 0.3 here; 3 stored points was 30 on screen.
    @MainActor
    fileprivate func recordPendingScoreChangeIfMeaningful(
        sessionId: UUID, prior: Double?, updated: Double?, reason: String
    ) {
        guard let prior, let updated else { return }
        let displayDelta = abs(updated - prior) * 10
        guard displayDelta >= 3 else { return }
        PendingScoreChange.write(.init(
            sessionId: sessionId,
            priorScore: prior,
            newScore: updated,
            reason: reason,
            timestamp: Date()
        ))
        debugLog("[Auto-rescore] pending score change recorded: \(prior) → \(updated) (Δ \(displayDelta))")
    }

    // MARK: - Auto-rescore listener

    /// Install a NotificationCenter observer for `.flowRecoveryRescoreNeeded`.
    /// Posted by the dashboard when refreshed sleep / training data
    /// crosses a meaningful threshold (e.g. crash-truncated 1.4 h sleep
    /// gets corrected to a real 5h 53m). The frozen recovery score for
    /// that session is now wrong by a wide margin, so we automatically
    /// reanalyze and overwrite it.
    ///
    /// Without this, the user is left with a permanently wrong
    /// historical score — even after pull-to-refresh fixes the
    /// dashboard's *displayed* sleep, the frozen score stays stuck
    /// at the truncated value because reanalyze isn't on the
    /// refresh path.
    ///
    /// The token is captured so `deinit` can remove this
    /// block observer; discarding it leaks the observer
    /// and the captured collector in tests/previews.
    func installRescoreListener() {
        let token = NotificationCenter.default.addObserver(
            forName: .flowRecoveryRescoreNeeded,
            object: nil,
            queue: .main
        ) { [weak collector] notification in
            guard let collector, let sessionId = notification.object as? UUID else { return }
            let reason = (notification.userInfo?["reason"] as? String) ?? "unknown"
            let detail = (notification.userInfo?["detail"] as? String) ?? ""
            debugLog("[Auto-rescore] notified for session \(sessionId.uuidString.prefix(8)) reason=\(reason) (\(detail))")
            Task { @MainActor [weak collector] in
                await collector?.reanalysis.handleRescoreRequest(sessionId: sessionId, reason: reason)
            }
        }
        collector.notificationObservers.add(token)
    }

    /// The prior score is captured before any recompute so we can detect
    /// a meaningful delta and surface a "score changed while you were away"
    /// banner.
    @MainActor
    private func handleRescoreRequest(sessionId: UUID, reason: String) async {
        let priorScore = (try? collector.archive.retrieve(sessionId))?.recoveryScore
        if reason == "training" {
            await recomputeTrainingOnly(sessionId: sessionId, priorScore: priorScore, reason: reason)
            return
        }
        guard let session = try? collector.archive.retrieve(sessionId) else {
            debugLog("[Auto-rescore] could not retrieve session — skipping")
            return
        }
        debugLog("[Auto-rescore] reanalyzing session — prior score=\(session.recoveryScore ?? -1)")
        if let updated = await reanalyzeSession(session) {
            debugLog("[Auto-rescore] complete — new score=\(updated.recoveryScore ?? -1)")
            finishRescore(sessionId: sessionId, prior: priorScore, updated: updated, reason: reason)
            return
        }
        await scoreOnlyFallback(sessionId: sessionId, priorScore: priorScore, reason: reason)
    }

    /// Full reanalyze refused (no rrSeries, etc). Score-only
    /// recompute is the safety net — at minimum it heals a
    /// corrupted training snapshot and rebuilds the breakdown
    /// from the existing analysisResult. Better than leaving
    /// a wrong score visible to the user.
    @MainActor
    private func scoreOnlyFallback(sessionId: UUID, priorScore: Double?, reason: String) async {
        debugLog("[Auto-rescore] reanalyze returned nil — falling through to score-only recompute")
        guard let updated = await reanalysisService.recomputeScoreOnly(sessionId: sessionId) else {
            debugLog("[Auto-rescore] score-only fallback also returned nil — leaving frozen score in place")
            return
        }
        debugLog("[Auto-rescore] score-only fallback complete — new score=\(updated.recoveryScore ?? -1)")
        finishRescore(sessionId: sessionId, prior: priorScore, updated: updated, reason: reason)
    }

    /// When the only thing that changed is the
    /// training context (live cache healed a corrupted 0/0
    /// frozen snapshot), there is no reason to re-window the
    /// RR series. Worse, full reanalyze REQUIRES a non-empty
    /// rrSeries — crash-recovered sessions sometimes land with
    /// empty RR and full reanalyze silently returns nil,
    /// leaving the broken 98 score in place. Score-only
    /// recompute uses the existing analysisResult, swaps in
    /// the healed training context, and rewrites only the
    /// breakdown / score fields.
    @MainActor
    private func recomputeTrainingOnly(sessionId: UUID, priorScore: Double?, reason: String) async {
        guard let updated = await reanalysisService.recomputeScoreOnly(sessionId: sessionId) else {
            debugLog("[Auto-rescore] training-only recompute returned nil — leaving frozen score in place")
            return
        }
        debugLog("[Auto-rescore] training-only recompute complete — new score=\(updated.recoveryScore ?? -1)")
        finishRescore(sessionId: sessionId, prior: priorScore, updated: updated, reason: reason)
    }

    @MainActor
    private func finishRescore(sessionId: UUID, prior: Double?, updated: HRVSession, reason: String) {
        recordPendingScoreChangeIfMeaningful(
            sessionId: sessionId, prior: prior, updated: updated.recoveryScore, reason: reason
        )
        collector.archiveSignal.notifyChanged()
    }

    // MARK: - CloudKit Snapshot Backfill Listener

    /// Observe `.cloudKitSnapshotBackfillNeeded`, posted by
    /// `CloudKitSyncManager` after a pull archives new sessions, and drip the
    /// HK sleep/vitals re-derivation through `backfillSnapshotsForPulledSessions`.
    /// The token is stored so `deinit` removes the observer.
    func installCloudKitSnapshotBackfillListener() {
        let token = NotificationCenter.default.addObserver(
            forName: .cloudKitSnapshotBackfillNeeded,
            object: nil,
            queue: .main
        ) { [weak collector] notification in
            guard let collector,
                  let ids = notification.userInfo?["sessionIds"] as? [UUID],
                  !ids.isEmpty
            else { return }
            Task { @MainActor [weak collector] in
                await collector?.reanalysis.backfillSnapshotsForPulledSessions(ids)
            }
        }
        collector.notificationObservers.add(token)
        // Whatever an earlier launch had no room for.
        Task { @MainActor [weak collector] in
            await collector?.reanalysis.backfillSnapshotsForPulledSessions([])
        }
    }

    /// Re-analyze all sessions with current algorithms.
    /// Returns (updated, skipped) where skipped counts sessions with manual window overrides.
    func reanalyzeAllSessions(from: Date? = nil, to: Date? = nil, progress: @escaping (Int, Int) -> Void = { _, _ in }) async -> (updated: Int, skipped: Int) {
        await reanalysisService.reanalyzeAllSessions(sessions: collector.archivedSessions, from: from, to: to, progress: progress)
    }

    // MARK: - Sleep Retro-Apply

    /// Reprocess sleep data for all sessions using current settings.
    /// Called when `enableHRVSleepAugmentation` or `exportSleepData` is toggled so the
    /// change applies retroactively. For each session:
    ///   1. Re-runs the sleep pipeline (picking up the current augmentation setting)
    ///   2. Backfills a `sleepSnapshot` from HRV/RR data when none existed before
    ///   3. Recalculates recovery score with the updated sleep data
    ///   4. Writes sleep to Apple Health when `exportSleepData` is enabled
    func retroApplySleepSettings(progress: @escaping (Int, Int) -> Void = { _, _ in }) async -> Int {
        await reanalysisService.retroApplySleepSettings(sessions: collector.archivedSessions, progress: progress)
    }

    // MARK: - Manual Window Reanalysis

    /// Reanalyze a session at a specific timestamp (for manual window selection)
    func reanalyzeAtPosition(_ session: HRVSession, targetMs: Int64) async -> HRVAnalysisResult? {
        await reanalysisService.reanalyzeAtPosition(session, targetMs: targetMs)
    }

    /// Apply a manually-selected analysis result to a session and persist it.
    func applyManualAnalysis(_ session: HRVSession, result: HRVAnalysisResult) async -> HRVSession? {
        await reanalysisService.applyManualAnalysis(session, result: result)
    }

    /// Called from `bindHealthKitSleep` when
    /// `HealthKitManager.sleepDataVersion` bumps (Apple Watch finished
    /// syncing overnight sleep; iPhone "inBed" landed; user manually
    /// pulled Health data). If today's morning session was scored
    /// without sleep (the 30 s sleep poll at finalize time gave up
    /// before Watch synced) OR the new sleep is materially better than
    /// the frozen snapshot, post `.flowRecoveryRescoreNeeded` so the
    /// existing rescore listener (`installRescoreListener`) reanalyzes
    /// the session and overwrites the stale score.
    ///
    /// This was the missing wiring that left the user manually tapping
    /// "Reanalyze" every morning — `DashboardV2View` doesn't use
    /// the dashboard's own sleep-refresh path (since removed), so the rescore
    /// notification was never posted on the auto-arrival path.
    ///
    /// Conservative gate: only fires for today's morning session, only
    /// when the delta is ≥ 20 min (same threshold the dashboard's
    /// manual refresh used) or when the prior snapshot was empty.
    /// Idempotent: repeated bumps with no material change are no-ops.
    ///
    /// Reentrancy wrapper. Apple writes sleep in STAGES, each
    /// bumping `sleepDataVersion` (see `bindHealthKitSleep`), and the underlying
    /// refresh does a multi-second `fetchSleepData`. Without serialization the
    /// overlapping invocations each read the session BEFORE any sibling wrote,
    /// all compute `sourceUpgradedToWatch = true`, and all post
    /// `.flowRecoveryRescoreNeeded` → the session reanalyzes twice against
    /// identical Apple data (seen in a field log). Serialize:
    /// one runs; bumps that arrive mid-run set `collector.autoRefreshSleepPending` and
    /// cause exactly ONE trailing pass, which sees the freshly-written
    /// `.healthKit` source and no-ops. A trailing pass (not a plain skip) so a
    /// genuinely later stage isn't dropped.
    @MainActor
    func autoRefreshTodaysSleepIfImproved() async {
        if collector.isAutoRefreshingSleep {
            collector.autoRefreshSleepPending = true
            return
        }
        collector.isAutoRefreshingSleep = true
        defer { collector.isAutoRefreshingSleep = false }
        repeat {
            collector.autoRefreshSleepPending = false
            await performAutoRefreshTodaysSleepIfImproved()
        } while collector.autoRefreshSleepPending
    }

    /// The most recent overnight session, if it ended within the last 18 hours.
    ///
    /// Deliberately NOT `startOfDay(for: entry.date) == today`: that would
    /// require the session to have STARTED after midnight. Overnight
    /// sessions normally start the previous EVENING (e.g. 11 PM), so their
    /// start-day is YESTERDAY and such a filter never matches — the
    /// auto-refresh would silently never run. Taking the most recent overnight
    /// session and bounding it by end time (~18 h, covering any bedtime before
    /// or after midnight) matches how people actually sleep.
    ///
    /// Decoded off the main actor: this runs on every morning
    /// foreground, and the full retrieve (disk read + AES-GCM decrypt + JSON
    /// decode of the overnight session) freezes the UI on resume otherwise.
    private func loadTodaysOvernightSession() async -> HRVSession? {
        let candidateEntry = collector.archive.entries
            .filter { $0.sessionType == .overnight }
            .sorted { $0.date > $1.date }
            .first { Date().timeIntervalSince($0.endDate ?? $0.date) < 18 * 60 * 60 }
        guard let candidateEntry else { return nil }
        let archiveRef = collector.archive
        return await Task.detached { try? archiveRef.retrieve(candidateEntry.sessionId) }.value
    }

    /// Re-read HealthKit sleep for today's overnight session and, when the new
    /// window is better, update the snapshot + boundaries and (if the scoring
    /// window actually moved) ask for a rescore.
    private func performAutoRefreshTodaysSleepIfImproved() async {
        guard var session = await loadTodaysOvernightSession(),
              session.analysisResult != nil,
              // Only act on already-scored sessions. Pre-acceptance morning
              // processing handles its own sleep wait.
              session.recoveryScore != nil,
              SleepRefreshPolicy.autoSleepRefreshAllowed(for: session)
        else { return }
        let sessionEnd = session.endDate ?? session.startDate
        guard let fresh = await freshPlausibleSleep(for: session, sessionEnd: sessionEnd) else { return }
        let verdict = SleepRefreshPolicy.sleepRefreshVerdict(session: session, fresh: fresh)
        guard verdict.shouldUpdate else { return }
        SleepRefreshPolicy.applyFreshSleep(fresh, to: &session)
        guard await persistRefreshedSleep(session) else { return }
        debugLog("[AutoRescore.sleep] snapshot updated for \(session.id.uuidString.prefix(8)) prior=\(verdict.priorMinutes)m → new=\(verdict.newMinutes)m endMovedLater=\(verdict.endMovedLater) firstSnapshot=\(verdict.firstSnapshot)")
        republishRefreshedSession(session)
        guard verdict.needsRescore else {
            debugLog("[AutoRescore.sleep] delta \(verdict.delta)m below rescore threshold — keeping existing score")
            return
        }
        postSleepRescoreRequest(sessionId: session.id, fresh: fresh, verdict: verdict)
    }

    /// Reject a sleep block that can't physically belong to this
    /// recording. HealthKit can return a full night's 419-min block for a
    /// 12.8-min pre-sleep clip (paused while still awake); attaching it
    /// fabricates hours of "sleep", moves the session's `sleepEnd` onto the
    /// wrong calendar day, and rewrites the file — tripping its integrity
    /// hash and dropping it from sync. Guard every automatic attach.
    private func freshPlausibleSleep(for session: HRVSession, sessionEnd: Date) async -> SleepData? {
        let fresh: SleepData?
        do {
            fresh = try await collector.healthKit.fetchSleepData(
                for: session.startDate, recordingEnd: sessionEnd, rrPoints: session.rrSeries?.points
            )
        } catch {
            debugLog("[AutoRescore.sleep] HK fetch failed: \(error.localizedDescription)", level: .warning)
            return nil
        }
        guard let fresh, fresh.nightSleepMinutes > 0 else { return nil }
        guard fresh.plausiblyBelongsToRecording(start: session.startDate, end: sessionEnd) else {
            debugLog("[AutoRescore.sleep] rejected snapshot for \(session.id.uuidString.prefix(8)) — \(fresh.nightSleepMinutes)m sleep window does not overlap the \(Int(sessionEnd.timeIntervalSince(session.startDate) / 60))m recording", level: .warning)
            return nil
        }
        return fresh
    }

    /// Encode+encrypt+write off the main actor (otherwise it blocks
    /// the UI on every morning foreground).
    private func persistRefreshedSleep(_ session: HRVSession) async -> Bool {
        let archiveRef = collector.archive
        return await Task.detached {
            do {
                _ = try archiveRef.archive(session)
                return true
            } catch {
                debugLog("[AutoRescore.sleep] archive write failed: \(error.localizedDescription)", level: .warning)
                return false
            }
        }.value
    }

    /// Refresh the LIVE UI even when the change is below the
    /// rescore threshold (delta < 20 min). If the snapshot is
    /// written to the archive but neither `collector.currentSession` nor the archive
    /// signal is updated, the displayed sleep stays stale until a
    /// manual "Refresh Sleep Data".
    private func republishRefreshedSession(_ session: HRVSession) {
        if collector.currentSession?.id == session.id {
            collector.currentSession = session
        }
        collector.archiveSignal.notifyChanged()
    }

    // MARK: - CloudKit Pull Backfill

    /// Re-derive HealthKit-backed `sleepSnapshot` / `vitalsSnapshot` for
    /// sessions that arrived via a CloudKit pull. Those snapshots are
    /// stripped from CloudKit uploads (Guideline 5.1.3), so a synced past
    /// session lands with empty sleep + vitals. `autoRefreshTodaysSleepIfImproved`
    /// only ever re-fills TODAY's session on a live HK observer bump, so
    /// HISTORY stayed blank until the user manually opened each one.
    ///
    /// Called by `CloudKitSyncManager` after a pull archives new sessions.
    /// BOUNDED on purpose: at most `maxPerCycle` sessions are touched per
    /// invocation, on a low-priority detached fetch, so a fresh second
    /// device pulling hundreds of sessions doesn't hammer HealthKit at
    /// launch. The IDs that don't fit wait in a queue kept across launches,
    /// drained on the next pull and at each launch. They used to be dropped:
    /// a later pull skips sessions it already has, so it never posted them
    /// again, and a new phone restoring 300 nights filled in 10.
    ///
    /// Respects `sleepUserAdjusted`: a user-edited boundary is the source of
    /// truth and is never overwritten. Only sessions still missing a
    /// `sleepSnapshot` are eligible — re-running is a cheap no-op.
    @MainActor
    func backfillSnapshotsForPulledSessions(_ sessionIds: [UUID], maxPerCycle: Int = 10) async {
        let queue = PulledSnapshotBackfillQueue.adding(sessionIds)
        guard !queue.isEmpty, !PulledSnapshotBackfillQueue.isDraining else { return }
        PulledSnapshotBackfillQueue.isDraining = true
        defer { PulledSnapshotBackfillQueue.isDraining = false }
        let pass = await backfillPass(over: queue, maxPerCycle: maxPerCycle)
        PulledSnapshotBackfillQueue.removing(pass.done)
        PulledSnapshotBackfillQueue.deferring(pass.missed)
        if pass.processed > 0 {
            collector.archiveSignal.notifyChanged()
        }
    }

    /// One pass over the front of the queue: `done` is filled in or no longer
    /// in need, `missed` is what Health had nothing for yet.
    @MainActor
    private func backfillPass(
        over queue: [UUID], maxPerCycle: Int
    ) async -> (done: Set<UUID>, missed: [UUID], processed: Int) {
        var processed = 0
        var done: Set<UUID> = []
        var missed: [UUID] = []
        for sessionId in queue where processed < maxPerCycle {
            guard let session = sessionNeedingSnapshots(sessionId) else { done.insert(sessionId); continue }
            processed += 1
            if await backfillOneSession(session, sessionId: sessionId) {
                done.insert(sessionId)
            } else {
                missed.append(sessionId)
            }
        }
        return (done, missed, processed)
    }

    /// The session, when it still has no sleep data and the user hasn't
    /// adjusted it by hand (matches the autoRefresh guard).
    @MainActor
    private func sessionNeedingSnapshots(_ sessionId: UUID) -> HRVSession? {
        guard let session = try? collector.archive.retrieve(sessionId),
              session.sleepSnapshot == nil, session.sleepUserAdjusted != true
        else { return nil }
        return session
    }

    /// Strap nocturnal HR in place of Apple's daytime resting HR, as the
    /// acceptance path stores it.
    @MainActor
    private func pulledSessionVitals(session: HRVSession, sessionEnd: Date) async -> RecoveryVitals {
        await collector.healthKit.fetchRecoveryVitals(relativeTo: sessionEnd)
            .withStrapNocturnalRHR(session.analysisResult?.timeDomain.meanHR)
    }

    /// HK queries run on HealthKit's own background queues; each
    /// `await` here yields the main actor between sessions. Capped by
    /// the caller's `maxPerCycle` so the per-pull cost stays bounded.
    ///
    /// Returns false when Health had nothing yet, or the write failed, so the
    /// session is tried again on a later pass. The result is applied to the
    /// archived copy as it is after the Health reads, not to the copy read
    /// before them, so an edit made meanwhile is kept.
    @MainActor
    private func backfillOneSession(_ session: HRVSession, sessionId: UUID) async -> Bool {
        let sessionEnd = session.endDate ?? session.startDate
        let sleep = await pulledSessionSleep(session: session, sessionEnd: sessionEnd, sessionId: sessionId)
        let vitals = await pulledSessionVitals(session: session, sessionEnd: sessionEnd)
        guard sleep != nil || !vitals.isEmpty else {
            debugLog("[CloudKitBackfill] no HK sleep/vitals yet for \(sessionId.uuidString.prefix(8)) — skipping")
            return false
        }
        do {
            // Not uploaded again: the sleep and vitals snapshots are stripped
            // from iCloud payloads, so the upload would carry no change.
            try collector.archive.update(sessionId, requestingReupload: false) {
                Self.applyBackfill(sleep: sleep, vitals: vitals, to: &$0)
            }
            debugLog("[CloudKitBackfill] re-derived snapshots for \(sessionId.uuidString.prefix(8)) sleep=\(sleep != nil) vitals=\(!vitals.isEmpty)")
        } catch {
            debugLog("[CloudKitBackfill] archive write failed for \(sessionId.uuidString.prefix(8)): \(error.localizedDescription)", level: .warning)
            return false
        }
        return true
    }

    /// Fills only what is still empty, on the copy as stored now.
    private static func applyBackfill(
        sleep: SleepData?, vitals: HealthKitManager.RecoveryVitals, to stored: inout HRVSession
    ) {
        if let sleep, stored.sleepSnapshot == nil, stored.sleepUserAdjusted != true {
            SleepRefreshPolicy.applyPulledSleep(sleep, to: &stored)
        }
        if !vitals.isEmpty, stored.vitalsSnapshot == nil { stored.vitalsSnapshot = vitals }
    }

    /// Same plausibility gate as the live auto-rescore path: a pulled
    /// short clip must not get a full night's HealthKit block grafted on.
    @MainActor
    private func pulledSessionSleep(
        session: HRVSession,
        sessionEnd: Date,
        sessionId: UUID
    ) async -> SleepData? {
        let sleep: SleepData?
        do {
            sleep = try await collector.healthKit.fetchSleepData(
                for: session.startDate, recordingEnd: sessionEnd, rrPoints: session.rrSeries?.points
            )
        } catch {
            debugLog("[CloudKitBackfill] sleep fetch failed for \(sessionId.uuidString.prefix(8)): \(error.localizedDescription)", level: .warning)
            return nil
        }
        guard let sleep, sleep.nightSleepMinutes > 0 else { return nil }
        guard sleep.plausiblyBelongsToRecording(start: session.startDate, end: sessionEnd) else {
            debugLog("[CloudKitBackfill] rejected implausible sleep for \(sessionId.uuidString.prefix(8)) — \(sleep.nightSleepMinutes)m does not overlap the \(Int(sessionEnd.timeIntervalSince(session.startDate) / 60))m recording", level: .warning)
            return nil
        }
        return sleep
    }

    /// Update stored session's sleep boundaries and snapshot when HealthKit has more
    /// complete data. This ensures the frozen snapshot captures late sleep segments
    /// (e.g., the user went back to sleep after the recording ended and Apple Watch
    /// tracked it). Only updates if the new data covers a longer sleep period.
    @discardableResult
    func updateSessionSleepBoundaries(sessionId: UUID, sleepData: SleepData, isUserAdjustment: Bool = false) -> Bool {
        reanalysisService.updateSessionSleepBoundaries(sessionId: sessionId, sleepData: sleepData, isUserAdjustment: isUserAdjustment)
    }

    /// Remove a linked segment from a session's same-night merge.
    /// The unlinked segment becomes a standalone session again, and the parent
    /// session's linkedSessionIds list is updated.
    func unlinkSegment(segmentId: UUID, fromSession sessionId: UUID) {
        reanalysisService.unlinkSegment(segmentId: segmentId, fromSession: sessionId)
    }

    /// Recompute training snapshots from HealthKit workout history for all
    /// archived sessions.  Fixes sessions whose ATL/CTL/TSB drifted because
    /// a background device refinement overwrote the frozen morning values.
    func repairTrainingSnapshots(progress: @escaping (Int, Int) -> Void = { _, _ in }) async -> ReanalysisService.TrainingRepairResult {
        await reanalysisService.repairTrainingSnapshots(sessions: collector.archivedSessions, progress: progress)
    }

    /// Update the current session's analysis result (for manual reanalysis)
    func updateCurrentSessionResult(_ result: HRVAnalysisResult) {
        collector.currentSession?.analysisResult = result
    }
}

// MARK: - File-scope helpers
//
// Kept out of RRCollector: each names no member of the type and calls
// nothing inside it, so none needs to be a member. `private` at file scope
// is fileprivate, so every call site in this file resolves the same way.

@MainActor
private func postSleepRescoreRequest(
    sessionId: UUID,
    fresh: SleepData,
    verdict: SleepRefreshPolicy.SleepRefreshVerdict
) {
    let rescoreReason: String = if verdict.sourceUpgradedToWatch {
        "source upgraded to \(fresh.boundarySource.rawValue)"
    } else if verdict.onsetMovedMaterially {
        "onset moved \(verdict.onsetMovedMin)m"
    } else {
        "Δtotal \(verdict.delta)m"
    }
    debugLog("[AutoRescore.sleep] rescoring (\(rescoreReason)) — posting .flowRecoveryRescoreNeeded for \(sessionId.uuidString.prefix(8))")
    NotificationCenter.default.post(
        name: .flowRecoveryRescoreNeeded,
        object: sessionId,
        userInfo: [
            "reason": "sleep",
            "detail": "auto-refresh on HK sleep arrival: \(verdict.priorMinutes)m → \(verdict.newMinutes)m (Δ \(verdict.delta)m), \(rescoreReason)"
        ]
    )
}
