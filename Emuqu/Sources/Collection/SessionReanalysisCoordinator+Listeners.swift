import Foundation

// MARK: - Saved-session listeners

extension SessionReanalysisCoordinator {
    // MARK: - Pending-score-change surfacing

    /// Records a `PendingScoreChange` when an auto-rescore moves the score
    /// meaningfully. The dashboard reads this on appear and shows a banner
    /// so the user understands why the displayed number differs from what
    /// they last saw (e.g. Apple Watch synced sleep at 11 AM, score climbed
    /// 67 → 74; without context the new number feels arbitrary).
    ///
    /// Threshold is ≥ 3 display points — below that, the delta is within
    /// recompute noise and would be more confusing than helpful. The stored
    /// score is 0–10, so that is 0.3 here.
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
    /// Posted when refreshed sleep / training data crosses a meaningful
    /// threshold (e.g. crash-truncated 1.4 h sleep corrected to a real
    /// 5h 53m): the frozen recovery score for that session is then wrong by a
    /// wide margin, so the session is reanalysed and its score overwritten.
    /// Pull-to-refresh corrects only the displayed sleep, never the frozen
    /// score, so without this the historical score stays wrong.
    ///
    /// The token is kept in `notificationObservers`, so `deinit` removes the
    /// block observer.
    func installRescoreListener() {
        let token = NotificationCenter.default.addObserver(
            forName: .flowRecoveryRescoreNeeded,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard self != nil, let sessionId = notification.object as? UUID else { return }
            let reason = (notification.userInfo?["reason"] as? String) ?? "unknown"
            let detail = (notification.userInfo?["detail"] as? String) ?? ""
            debugLog("[Auto-rescore] notified for session \(sessionId.uuidString.prefix(8)) reason=\(reason) (\(detail))")
            Task { @MainActor [weak self] in
                await self?.handleRescoreRequest(sessionId: sessionId, reason: reason)
            }
        }
        notificationObservers.add(token)
    }

    /// The prior score is captured before any recompute so a meaningful
    /// delta can be detected and surfaced as a "score changed while you were
    /// away" banner. A session the archive cannot read is skipped, as one it
    /// does not hold is; the read failure is logged at `.error`.
    private func handleRescoreRequest(sessionId: UUID, reason: String) async {
        let stored = ArchivedSessionRead.read(sessionId, from: archive, caller: "Auto-rescore").session
        let priorScore = stored?.recoveryScore
        if reason == "training" {
            await recomputeTrainingOnly(sessionId: sessionId, priorScore: priorScore, reason: reason)
            return
        }
        guard let session = stored else {
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
    private func scoreOnlyFallback(sessionId: UUID, priorScore: Double?, reason: String) async {
        debugLog("[Auto-rescore] reanalyze returned nil — falling through to score-only recompute")
        guard let updated = await service.recomputeScoreOnly(sessionId: sessionId) else {
            debugLog("[Auto-rescore] score-only fallback also returned nil — leaving frozen score in place")
            return
        }
        debugLog("[Auto-rescore] score-only fallback complete — new score=\(updated.recoveryScore ?? -1)")
        finishRescore(sessionId: sessionId, prior: priorScore, updated: updated, reason: reason)
    }

    /// When the only thing that changed is the training context (the live
    /// cache healed a corrupted 0/0 frozen snapshot), there is no reason to
    /// re-window the RR series, and a full reanalyze REQUIRES a non-empty
    /// rrSeries: a crash-recovered session with empty RR would keep its broken
    /// score. Score-only recompute uses the existing analysisResult, swaps in
    /// the healed training context, and rewrites only the breakdown / score
    /// fields.
    private func recomputeTrainingOnly(sessionId: UUID, priorScore: Double?, reason: String) async {
        guard let updated = await service.recomputeScoreOnly(sessionId: sessionId) else {
            debugLog("[Auto-rescore] training-only recompute returned nil — leaving frozen score in place")
            return
        }
        debugLog("[Auto-rescore] training-only recompute complete — new score=\(updated.recoveryScore ?? -1)")
        finishRescore(sessionId: sessionId, prior: priorScore, updated: updated, reason: reason)
    }

    /// After a rescore: record the pending score change, announce the
    /// rewritten night (`.reanalysisRewroteArchivedSession`, carried onto the
    /// review card only while a night awaits acceptance, so Accept does not
    /// write the score from before the rescore back), then bump the archive
    /// signal.
    func finishRescore(sessionId: UUID, prior: Double?, updated: HRVSession, reason: String) {
        recordPendingScoreChangeIfMeaningful(
            sessionId: sessionId, prior: prior, updated: updated.recoveryScore, reason: reason
        )
        announceRewrite(updated, onlyWhileAwaitingAcceptance: true)
        archiveSignal.notifyChanged()
    }

    /// Post `.reanalysisRewroteArchivedSession` for `session`. The collector's
    /// observer runs synchronously on this (main) thread.
    func announceRewrite(_ session: HRVSession, onlyWhileAwaitingAcceptance: Bool) {
        NotificationCenter.default.post(
            name: .reanalysisRewroteArchivedSession,
            object: ArchivedSessionRewrite(session: session, onlyWhileAwaitingAcceptance: onlyWhileAwaitingAcceptance)
        )
    }

    // MARK: - CloudKit Snapshot Backfill Listener

    /// Observe `.cloudKitSnapshotBackfillNeeded`, posted by
    /// `CloudKitSyncManager` after a pull archives new sessions, and drip the
    /// HK sleep/vitals re-derivation through `backfillSnapshotsForPulledSessions`.
    /// The token is stored so `deinit` removes the observer. Also drains, once,
    /// what an earlier launch had no room for.
    func installCloudKitSnapshotBackfillListener() {
        let token = NotificationCenter.default.addObserver(
            forName: .cloudKitSnapshotBackfillNeeded,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard self != nil,
                  let ids = notification.userInfo?["sessionIds"] as? [UUID],
                  !ids.isEmpty
            else { return }
            Task { @MainActor [weak self] in
                await self?.backfillSnapshotsForPulledSessions(ids)
            }
        }
        notificationObservers.add(token)
        Task { @MainActor [weak self] in
            await self?.backfillSnapshotsForPulledSessions([])
        }
    }

    // MARK: - HealthKit sleep arrival

    /// Every `HealthKitManager.sleepDataVersion` bump checks today's morning
    /// session against the freshly-arrived HealthKit sleep
    /// (`autoRefreshTodaysSleepIfImproved`), which posts the rescore request
    /// when the new data materially improves on the frozen snapshot.
    func observeHealthKitSleep() {
        ObservationLoop.observe(self, read: { $0.healthKit.sleepDataVersion }, onChange: { coordinator, _ in
            Task { @MainActor in await coordinator.autoRefreshTodaysSleepIfImproved() }
        })
    }

    /// Runs on each HealthKit sleep-data bump (`observeHealthKitSleep`) and on
    /// foreground. If today's morning session was scored without sleep (the
    /// 30 s sleep poll at finalize time gave up before the Watch synced) or
    /// the new sleep is materially better than the frozen snapshot, it updates
    /// the snapshot and posts `.flowRecoveryRescoreNeeded`, which the rescore
    /// listener (`installRescoreListener`) acts on.
    ///
    /// Conservative gate: only today's morning session, only when the delta is
    /// ≥ 20 min or the prior snapshot was empty. Repeated bumps with no
    /// material change are no-ops.
    ///
    /// Serialised: Apple writes sleep in stages, each bumping
    /// `sleepDataVersion`, and the refresh does a multi-second
    /// `fetchSleepData`. Overlapping runs would each read the session before
    /// any sibling wrote and each post a rescore. One runs; bumps that arrive
    /// mid-run set `autoRefreshSleepPending` and cause exactly ONE trailing
    /// pass, which sees the freshly-written `.healthKit` source and no-ops. A
    /// trailing pass (not a plain skip) so a genuinely later stage isn't dropped.
    func autoRefreshTodaysSleepIfImproved() async {
        if isAutoRefreshingSleep {
            autoRefreshSleepPending = true
            return
        }
        isAutoRefreshingSleep = true
        defer { isAutoRefreshingSleep = false }
        repeat {
            autoRefreshSleepPending = false
            await performAutoRefreshTodaysSleepIfImproved()
        } while autoRefreshSleepPending
    }

    /// The most recent overnight session, if it ended within the last 18 hours.
    ///
    /// Bounded by end time, not by `startOfDay(for: entry.date) == today`:
    /// overnight sessions normally start the previous EVENING, so a start-day
    /// filter would never match. The most recent overnight session ending
    /// within ~18 h covers any bedtime before or after midnight.
    ///
    /// Decoded off the main actor: this runs on every morning foreground, and
    /// the full retrieve (disk read + AES-GCM decrypt + JSON decode of the
    /// overnight session) would freeze the UI on resume. A read that throws is
    /// logged at `.error` and treated as no session.
    private func loadTodaysOvernightSession() async -> HRVSession? {
        let candidateEntry = archive.entries
            .filter { $0.sessionType == .overnight }
            .sorted { $0.date > $1.date }
            .first { Date().timeIntervalSince($0.endDate ?? $0.date) < 18 * 60 * 60 }
        guard let candidateEntry else { return nil }
        let archiveRef = archive
        return await Task.detached {
            ArchivedSessionRead.read(candidateEntry.sessionId, from: archiveRef, caller: "AutoRescore.sleep").session
        }.value
    }

    /// Re-read HealthKit sleep for today's overnight session and, when the new
    /// window is better, update the snapshot + boundaries and (if the scoring
    /// window actually moved) ask for a rescore.
    private func performAutoRefreshTodaysSleepIfImproved() async {
        guard let session = await loadTodaysOvernightSession(),
              session.analysisResult != nil,
              // Only act on already-scored sessions. Pre-acceptance morning
              // processing handles its own sleep wait.
              session.recoveryScore != nil,
              SleepRefreshPolicy.autoSleepRefreshAllowed(for: session)
        else { return }
        let sessionEnd = session.endDate ?? session.startDate
        guard let fresh = await freshPlausibleSleep(for: session, sessionEnd: sessionEnd) else { return }
        let verdict = SleepRefreshPolicy.sleepRefreshVerdict(session: session, fresh: fresh)
        guard verdict.shouldUpdate,
              let refreshed = await persistRefreshedSleep(fresh, sessionId: session.id) else { return }
        debugLog("[AutoRescore.sleep] snapshot updated for \(session.id.uuidString.prefix(8)) prior=\(verdict.priorMinutes)m → new=\(verdict.newMinutes)m endMovedLater=\(verdict.endMovedLater) firstSnapshot=\(verdict.firstSnapshot)")
        republishRefreshedSession(refreshed)
        guard verdict.needsRescore, refreshed.sleepUserAdjusted != true else {
            debugLog("[AutoRescore.sleep] delta \(verdict.delta)m below rescore threshold, or user-adjusted boundaries kept — keeping existing score")
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
            fresh = try await healthKit.fetchSleepData(
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
    /// the UI on every morning foreground). The refresh is applied to the
    /// archived copy as it is now, not to the one read before the HealthKit
    /// fetch, so an edit saved meanwhile (a feeling, tags, a reanalysis) is
    /// kept. Returns the session as written; nil when the write failed.
    private func persistRefreshedSleep(_ fresh: SleepData, sessionId: UUID) async -> HRVSession? {
        let archiveRef = archive
        return await Task.detached { Self.applyRefreshedSleep(fresh, sessionId: sessionId, in: archiveRef) }.value
    }

    nonisolated private static func applyRefreshedSleep(
        _ fresh: SleepData, sessionId: UUID, in archive: SessionArchive
    ) -> HRVSession? {
        do {
            try archive.update(sessionId, requestingReupload: false) { SleepRefreshPolicy.applyAutoRefresh(fresh, to: &$0) }
            return archive.retrieveOrLog(sessionId, caller: "AutoRescore.sleep")
        } catch {
            debugLog("[AutoRescore.sleep] archive write failed: \(error.localizedDescription)", level: .warning)
            return nil
        }
    }

    /// Refresh the live UI even when the change is below the rescore
    /// threshold (delta < 20 min): announce the rewritten night, which a
    /// review card holding the archive's copy takes (keeping the entries made
    /// on the card), and bump the archive signal. Otherwise the displayed
    /// sleep stays stale until a manual "Refresh Sleep Data".
    private func republishRefreshedSession(_ session: HRVSession) {
        announceRewrite(session, onlyWhileAwaitingAcceptance: false)
        archiveSignal.notifyChanged()
    }

    // MARK: - CloudKit Pull Backfill

    /// Re-derive HealthKit-backed `sleepSnapshot` / `vitalsSnapshot` for
    /// sessions that arrived via a CloudKit pull. Those snapshots are
    /// stripped from CloudKit uploads (Guideline 5.1.3), so a synced past
    /// session lands with empty sleep + vitals, and
    /// `autoRefreshTodaysSleepIfImproved` only ever re-fills TODAY's session.
    ///
    /// Called after a pull archives new sessions. BOUNDED on purpose: at most
    /// `maxPerCycle` sessions are touched per invocation, on a low-priority
    /// detached fetch, so a fresh second device pulling hundreds of sessions
    /// doesn't hammer HealthKit at launch. The IDs that don't fit wait in a
    /// queue kept across launches, drained on the next pull and at each
    /// launch. They must be kept: a later pull skips sessions it already has,
    /// so it never posts them again.
    ///
    /// Respects `sleepUserAdjusted`: a user-edited boundary is the source of
    /// truth and is never overwritten. Only sessions still missing a
    /// `sleepSnapshot` are eligible — re-running is a cheap no-op.
    func backfillSnapshotsForPulledSessions(_ sessionIds: [UUID], maxPerCycle: Int = 10) async {
        let queue = PulledSnapshotBackfillQueue.adding(sessionIds)
        guard !queue.isEmpty, !PulledSnapshotBackfillQueue.isDraining else { return }
        PulledSnapshotBackfillQueue.isDraining = true
        defer { PulledSnapshotBackfillQueue.isDraining = false }
        let pass = await backfillPass(over: queue, maxPerCycle: maxPerCycle)
        PulledSnapshotBackfillQueue.removing(pass.done)
        PulledSnapshotBackfillQueue.deferring(pass.missed)
        if pass.processed > 0 {
            archiveSignal.notifyChanged()
        }
    }

    /// One pass over the front of the queue: `done` is filled in or no longer
    /// in need, `missed` is what Health had nothing for yet.
    private func backfillPass(
        over queue: [UUID], maxPerCycle: Int
    ) async -> (done: Set<UUID>, missed: [UUID], processed: Int) {
        var processed = 0
        var done: Set<UUID> = []
        var missed: [UUID] = []
        for sessionId in queue where processed < maxPerCycle {
            guard let session = await sessionNeedingSnapshots(sessionId) else { done.insert(sessionId); continue }
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
    /// adjusted it by hand (matches the autoRefresh guard). Nil for a session
    /// the archive does not hold or cannot read (the read failure is logged
    /// at `.error`). Decoded off the main actor, as `loadTodaysOvernightSession`
    /// is: the queue is drained at launch, and each read decrypts and decodes
    /// a whole session.
    private func sessionNeedingSnapshots(_ sessionId: UUID) async -> HRVSession? {
        let archiveRef = archive
        let stored = await Task.detached {
            ArchivedSessionRead.read(sessionId, from: archiveRef, caller: "CloudKitBackfill").session
        }.value
        guard let session = stored, session.sleepSnapshot == nil, session.sleepUserAdjusted != true else { return nil }
        return session
    }

    /// Strap nocturnal HR in place of Apple's daytime resting HR, as the
    /// acceptance path stores it.
    private func pulledSessionVitals(session: HRVSession, sessionEnd: Date) async -> RecoveryVitals {
        await healthKit.fetchRecoveryVitals(relativeTo: sessionEnd)
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
            try archive.update(sessionId, requestingReupload: false) {
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
    private func pulledSessionSleep(
        session: HRVSession,
        sessionEnd: Date,
        sessionId: UUID
    ) async -> SleepData? {
        let sleep: SleepData?
        do {
            sleep = try await healthKit.fetchSleepData(
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
}

// MARK: - File-scope helpers
//
// Each names no member of the coordinator and calls nothing on it, so
// none needs to be inside the type.

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
