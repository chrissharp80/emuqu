import Foundation

// Backup recovery and corrupted-session repair. Everything here reconstructs
// a session from the raw RR backup (local or pulled from iCloud) after the
// live path failed.

extension SessionRecoveryService {
    // MARK: - Backup Recovery

    /// Recover a session from its raw RR backup, running full analysis.
    ///
    /// - Parameters:
    ///   - sessionId: The session to recover.
    ///   - recordedType: The type the recording was started as, when known
    ///     (the launch alert's persisted state); see `recoveredSessionType`.
    ///   - analyze: Closure for windowed analysis.
    ///   - analyzeWithCapacity: Closure for full-session analysis with peak capacity.
    ///   - supersedeSameNight: Closure to supersede same-night sessions.
    /// - Returns: The recovered session, or nil if recovery failed. Nil, not
    ///   a failed session, when analysis fails: every caller reads a returned
    ///   session as recovered and saved, and said so with nothing archived.
    func recoverFromBackup(
        _ sessionId: UUID,
        recordedType: SessionType? = nil,
        analyze: (_ session: HRVSession, _ window: WindowSelector.RecoveryWindow, _ flags: [ArtifactFlags], _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        analyzeWithCapacity: (_ session: HRVSession, _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        supersedeSameNight: (_ session: inout HRVSession) -> Void,
        // Without this, every
        // recovered session gets `recoveryScore = nil` and the
        // dashboard falls back to computing the score LIVE on every
        // render: the hero score never settles, `[DIAG]
        // calculateRecoveryScore: no frozen score — calculating LIVE`
        // fires hundreds of times per minute, and the user has to tap
        // "Reanalyze" to get a score that sticks. The
        // caller passes the same `computeRecoveryScore(for:from:)` helper
        // that the normal-acceptance path uses.
        computeRecoveryScore: (_ session: HRVSession, _ analysisResult: HRVAnalysisResult?) async -> RecoveryScoreOutcome? = { _, _ in nil }
    ) async -> HRVSession? {
        debugLog("[SessionRecoveryService] Attempting to recover session \(sessionId) from backup")

        guard let data = await retrieveBackupWithParentMerge(sessionId) else { return nil }
        if let stored = keptArchivedCopy(over: data, sessionId: sessionId) { return stored }

        var session = HRVSession(
            id: sessionId, startDate: data.sessionStart, endDate: data.endDate,
            state: .collecting,
            sessionType: Self.recoveredSessionType(for: data, sessionId: sessionId, recordedType: recordedType),
            rrSeries: data.series, analysisResult: nil, artifactFlags: data.flags
        )

        await analyzeSession(&session, series: data.series, flags: data.flags, analyze: analyze, analyzeWithCapacity: analyzeWithCapacity)
        session.state = session.analysisResult != nil ? .complete : .failed
        guard session.state == .complete else { return nil }

        supersedeSameNight(&session)
        await stampFrozenScore(on: &session, computeRecoveryScore: computeRecoveryScore)
        return archiveRecovered(session, sessionId: sessionId)
    }

    /// Two-tier classification for a recovered backup.
    ///
    /// Quality gate. A backup with too few beats can't be a real
    /// overnight session; a typical overnight captures 28,000+ beats
    /// (≈ 7 hours × 70 bpm). A short partial backup (a 22-minute one holds
    /// ≈ 1,500 beats) recovered as `.overnight` would land on that recovery
    /// night and could replace the real overnight score on the dashboard.
    ///
    ///   • ≥ 4,000 beats AND ≥ 60 min → `.overnight` (≈ 1 hour at 65 bpm, the
    ///     minimum credible "the user actually slept under the strap").
    ///   • Below the floor → `.quick`. Still archived — it is the user's data
    ///     and is never silently dropped — but it does not compete for the
    ///     night's overnight slot in the dashboard's most-recent-by-recovery-
    ///     night selection.
    ///
    /// A legitimate short overnight (fell asleep on the couch, 90-minute nap)
    /// clears the bar and is treated as overnight.
    ///
    /// A recording known to have been started as something other than an
    /// overnight (`recordedType`: a nap, a quick reading) keeps that type: the
    /// gate only ever downgrades, and a nap long enough to clear it is still
    /// a nap, not the night's reading. Nil or `.overnight` (Lost Sessions,
    /// which knows no type, and an interrupted night) goes through the gate.
    /// `internal` so the classification can be tested. Getting this wrong in
    /// the `.overnight` direction lets a short recovered fragment displace a
    /// real overnight reading on the same date.
    static func recoveredSessionType(for data: BackupData, sessionId: UUID, recordedType: SessionType? = nil) -> SessionType {
        if let recordedType, recordedType != .overnight { return recordedType }
        // Named `backupBeatCount`, not `beats`: `check_log_redaction.sh` treats
        // a bare `beats` interpolated into a log line as a raw RR series, and it
        // is right to — the distinction between "the series" and "how many are
        // in it" should be visible in the name.
        let backupBeatCount = data.series.points.count
        let durationSec = (data.endDate ?? data.sessionStart).timeIntervalSince(data.sessionStart)
        guard backupBeatCount >= minBeatsForOvernight, durationSec >= minDurationSecForOvernight else {
            debugLog("[SessionRecoveryService] backup \(sessionId.uuidString.prefix(8)) has only \(backupBeatCount) beats over \(Self.describeSeconds(durationSec))s — recovering as `.quick` not `.overnight` so it doesn't displace a real overnight reading on the same date", level: .info)
            return .quick
        }
        return .overnight
    }

    /// Seconds for a log line, without forcing `Int(Double)` on a value
    /// derived from a stored date — that traps on NaN or infinity, and the
    /// dates here come out of a backup file.
    static func describeSeconds(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite,
              seconds >= Double(Int.min), seconds <= Double(Int.max) else { return "unknown" }
        return String(Int(seconds))
    }

    private static let minBeatsForOvernight = 4_000
    private static let minDurationSecForOvernight: TimeInterval = 60 * 60

    /// Freeze the recovery score BEFORE archiving.
    ///
    /// Without it the recovered session is archived with no frozen score and
    /// the dashboard live-recomputes on every render — never settling, never
    /// matching the AI assistant's snapshot, forcing the user to tap
    /// "Reanalyze" to make it stick.
    private func stampFrozenScore(
        on session: inout HRVSession,
        computeRecoveryScore: (_ session: HRVSession, _ analysisResult: HRVAnalysisResult?) async -> RecoveryScoreOutcome?
    ) async {
        guard let result = await computeRecoveryScore(session, session.analysisResult) else {
            debugLog("[SessionRecoveryService] WARN: recovered session \(session.id.uuidString.prefix(8)) — score computation returned nil; dashboard will fall back to LIVE recompute on every render", level: .warning)
            return
        }
        session.recoveryScore = result.score
        session.scoreBreakdown = result.breakdown
        stampSnapshots(from: result, on: &session)
        // Keep the training context the score was computed with, so the
        // frozen readiness below and later reads use the same load.
        if let training = result.trainingContext {
            session.analysisResult?.trainingContext = training
            if session.trainingSnapshot == nil { session.trainingSnapshot = training }
        }
        session.frozenReadiness = ReanalysisService.computeFrozenReadiness(
            compositeScore: result.breakdown.compositeScore,
            trainingContext: session.trainingSnapshot ?? session.analysisResult?.trainingContext
        )
    }

    /// Persist sleep/vitals snapshots alongside the score. The
    /// scorer fetched them live to produce the breakdown; without stamping
    /// them the dashboard's live-recompute path reads nil and renders a tier-1
    /// breakdown that contradicts the frozen score.
    ///
    /// Overnight only. Short backups are deliberately recovered
    /// as `.quick` so they do not displace a real overnight, and stamping last
    /// night's `sleepSnapshot` onto them re-creates exactly that displacement
    /// through the dashboard sleep chip.
    private func stampSnapshots(from result: RecoveryScoreOutcome, on session: inout HRVSession) {
        guard session.sessionType == .overnight else { return }
        if let snapshot = result.sleepSnapshot { session.sleepSnapshot = snapshot }
        if let vitals = result.vitalsSnapshot { session.vitalsSnapshot = vitals }
    }

    /// Archive, mark the raw backup consumed, mirror the night to Apple Health
    /// (when the export is on), and kick off the cloud upload. The baseline
    /// takes the night in from the archive change (`BaselineArchiveSync`).
    /// Returns the night that now holds the recording: the recording itself,
    /// or the night already archived that the archive folded it into, which
    /// is then what Apple Health and iCloud get, as on acceptance. Exporting
    /// the recording under its own id put a second copy of the night's
    /// samples in Apple Health.
    ///
    /// Reports failure honestly. Returning the session on an archive failure
    /// would count it as recovered and let the UI announce "Recovered N of N"
    /// while nothing was persisted.
    /// Returning nil keeps the raw backup un-archived and eligible for the
    /// next recovery attempt.
    ///
    /// A night the archive already holds under this id (a backup recovered
    /// again) keeps what the user set on it (`SessionArchive.archiveRebuilt`).
    private func archiveRecovered(_ session: HRVSession, sessionId: UUID) -> HRVSession? {
        do {
            let entry = try archive.archiveRebuilt(session)
            let night = archive.retrieveOrLog(entry.sessionId, caller: "SessionRecoveryService.archiveRecovered") ?? session
            rawBackup.markAsArchived(sessionId)
            exportToHealth(night)
            Task { await cloudSyncManager.uploadSession(night) }
            debugLog("[SessionRecoveryService] Successfully recovered and archived session \(sessionId) as \(night.id.uuidString.prefix(8)), frozenScore=\(night.recoveryScore.map { String(format: "%.2f", $0) } ?? "nil")")
            return night
        } catch {
            debugLog("[SessionRecoveryService] Failed to archive recovered session \(sessionId.uuidString.prefix(8)): \(error)", level: .error)
            return nil
        }
    }

    /// The archived copy that holds more than the backup
    /// (`archivedCopyHoldingMore`), with the backup marked archived: the
    /// night holds all of it.
    private func keptArchivedCopy(over data: BackupData, sessionId: UUID) -> HRVSession? {
        guard let stored = archivedCopyHoldingMore(than: data.series.points.count, sessionId: sessionId) else { return nil }
        rawBackup.markAsArchived(sessionId)
        return stored
    }

    /// The copy the archive holds under `sessionId` when it has more beats
    /// than the `backupBeatCount` rebuilt from the backup. Written over by the rebuild,
    /// the night would lose what only it holds (a strap fetch merged in, a
    /// fuller copy from another device), so recovery keeps it
    /// (`FullerCopy`). Nil when the archive holds no readable copy, or one
    /// the rebuild covers.
    func archivedCopyHoldingMore(than backupBeatCount: Int, sessionId: UUID) -> HRVSession? {
        guard archive.store.exists(sessionId),
              let stored = archive.retrieveOrLog(sessionId, caller: "SessionRecoveryService.archivedCopyHoldingMore"),
              !FullerCopy.covers(backupBeatCount, stored.rrSeries?.points.count ?? 0) else { return nil }
        debugLog("[SessionRecoveryService] The archive holds more of \(sessionId.uuidString.prefix(8)) than its backup (\(backupBeatCount) beats), so the archived copy is kept")
        return stored
    }

    // MARK: - Fuller backups beside an archived fragment

    /// Unarchived backups, other than the `live` recordings', whose recording
    /// the archive holds in a night that lacks a stretch of their beats
    /// (`strandsBeats`). A night recovered from a backup pulled early in
    /// another device's night is such a fragment: the fuller backup pulled
    /// later is saved beside it (`cloudBackupDisposition`), and with the
    /// night archived the scan neither lists it nor rebuilds the night from
    /// it. A download the morning saved below half its backup
    /// (`retireRawBackupIfSafe`) is another.
    func strandedFullerBackupIds(excluding live: Set<UUID>) -> [UUID] {
        let deleted = archive.store.deletedIds.union(ForgottenSessions.ids)
        return rawBackup.unarchivedSessionIds.filter { id in
            !live.contains(id) && !deleted.contains(id) && archive.holdsNight(id) && holdsStrandedBeats(id)
        }
    }

    /// Whether the backup, on its parent's clock for a resumed segment
    /// (`pointsOnParentClock`), strands beats beside its archived night.
    private func holdsStrandedBeats(_ id: UUID) -> Bool {
        guard let backup = storedBackup(id),
              let night = archive.retrieveOrLog(archive.archivedId(of: id), caller: "SessionRecoveryService.holdsStrandedBeats") else { return false }
        let (points, start) = pointsOnParentClock(backup, sessionId: id)
        return Self.strandsBeats(points, from: start, beside: night)
    }

    /// Whether a backup holds beats the night keeping its recording lacks:
    /// more beats than the night (`FullerCopy`), and at least
    /// `minRecoverableBeatCount` of them after the night's last beat. A
    /// night and its own backup end together, however their counts differ
    /// (a strap download filled in from the stream holds fewer beats than the
    /// stream); a fragment ends early, where the backup it came from went on.
    /// A night with no beats lacks any backup a recovery could analyse.
    static func strandsBeats(_ points: [RRPoint], from start: Date, beside night: HRVSession) -> Bool {
        let nightPoints = night.rrSeries?.points ?? []
        guard !FullerCopy.covers(nightPoints.count, points.count) else { return false }
        guard let nightEnd = nightPoints.lastBeatEnd(after: night.startDate) else { return points.count >= minRecoverableBeatCount }
        let nightEndMs = nightEnd.timeIntervalSince(start) * 1000
        return points.lazy.filter { Double($0.exportTimeMs) >= nightEndMs }.count >= minRecoverableBeatCount
    }

    /// Brings a stranded backup's beats into the night holding its
    /// recording, through the merge every second copy of one night goes
    /// through (`SessionMerger.mergeSessionData`): the backup is analysed and
    /// scored as a recovery is, both copies' beats are kept, and the night
    /// takes the backup's analysis when it was computed on more beats, as an
    /// iCloud copy with more beats gives it. The night's own edits stay.
    /// False, with the backup left as it is, when it does not analyse or the
    /// night no longer lacks its beats.
    func mergeStrandedBackup(
        _ id: UUID,
        analyze: (_ session: HRVSession, _ window: WindowSelector.RecoveryWindow, _ flags: [ArtifactFlags], _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        analyzeWithCapacity: (_ session: HRVSession, _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        computeRecoveryScore: (_ session: HRVSession, _ analysisResult: HRVAnalysisResult?) async -> RecoveryScoreOutcome?
    ) async -> Bool {
        let nightId = archive.archivedId(of: id)
        guard let data = await retrieveBackupWithParentMerge(id),
              let night = archive.retrieveOrLog(nightId, caller: "SessionRecoveryService.mergeStrandedBackup") else { return false }
        var imported = HRVSession(
            id: nightId, startDate: data.sessionStart, endDate: data.endDate, state: .collecting, sessionType: night.sessionType,
            rrSeries: RRSeries(points: data.series.points, sessionId: nightId, startDate: data.sessionStart),
            analysisResult: nil, artifactFlags: data.flags
        )
        await analyzeSession(&imported, series: data.series, flags: data.flags, analyze: analyze, analyzeWithCapacity: analyzeWithCapacity)
        guard imported.analysisResult != nil else { return false }
        imported.state = .complete
        await stampFrozenScore(on: &imported, computeRecoveryScore: computeRecoveryScore)
        return writeStrandedMerge(imported, backupId: id)
    }

    /// Merges into the night as stored at the write, so an edit made during
    /// the analysis is kept, and only while it still lacks the beats; the
    /// backup is then marked archived and the night queued to go up again.
    private func writeStrandedMerge(_ imported: HRVSession, backupId: UUID) -> Bool {
        let wrote = attempt("recovery.mergeStrandedBackup") {
            try archive.updateIfChanged(imported.id, requestingReupload: true) { Self.merge(imported, intoNightLackingIt: &$0) }
        }
        guard wrote == true else { return false }
        rawBackup.markAsArchived(backupId)
        NightBeatsEdit.requestReanalysis(of: imported, detail: "a stranded backup's beats were merged in")
        debugLog("[SessionRecoveryService] Merged the fuller backup \(backupId.uuidString.prefix(8)) (\(imported.rrSeries?.points.count ?? 0) beats) into night \(imported.id.uuidString.prefix(8))")
        return true
    }

    /// Merges the session rebuilt from a backup into the night while the
    /// night still lacks its beats (`strandsBeats`); whether it changed it.
    private static func merge(_ imported: HRVSession, intoNightLackingIt night: inout HRVSession) -> Bool {
        guard strandsBeats(imported.rrSeries?.points ?? [], from: imported.startDate, beside: night) else { return false }
        return SessionMerger.mergeSessionData(from: imported, into: &night)
    }

    /// When an interrupted recording paused: where its beats ran out, never
    /// later than `now`; `now` when nothing dates it. The app is relaunched
    /// after the recording stopped, often hours after; dated by the relaunch,
    /// the pause would show as moments ago on the Record tab and in the
    /// resume check.
    nonisolated static func interruptedPauseDate(lastBeatEnd: Date?, now: Date) -> Date {
        min(lastBeatEnd ?? now, now)
    }

    /// Recover a session from backup into a paused state (for interrupted recordings),
    /// archived under its own id.
    ///
    /// - Parameters:
    ///   - sessionId: The session to recover.
    ///   - sessionType: The session type to assign.
    ///   - analyze: Closure for windowed analysis.
    ///   - analyzeWithCapacity: Closure for full-session analysis with peak capacity.
    /// - Returns: The recovered paused session, or nil if recovery failed.
    func recoverToPausedState(
        _ sessionId: UUID,
        sessionType: SessionType,
        analyze: (_ session: HRVSession, _ window: WindowSelector.RecoveryWindow, _ flags: [ArtifactFlags], _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        analyzeWithCapacity: (_ session: HRVSession, _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?
    ) async -> HRVSession? {
        debugLog("[SessionRecoveryService] Recovering interrupted session \(sessionId.uuidString.prefix(8)) to paused state")
        guard let data = await retrieveBackupWithParentMerge(sessionId) else { return nil }
        if let stored = archivedCopyHoldingMore(than: data.series.points.count, sessionId: sessionId) { return stored }
        var session = HRVSession(
            id: sessionId, startDate: data.sessionStart, endDate: data.endDate,
            state: .collecting, sessionType: sessionType,
            rrSeries: data.series, analysisResult: nil, artifactFlags: data.flags
        )
        await analyzeSession(&session, series: data.series, flags: data.flags, analyze: analyze, analyzeWithCapacity: analyzeWithCapacity)
        session.state = .paused
        session.pausedDate = Self.interruptedPauseDate(lastBeatEnd: data.endDate, now: Date())
        // Never folded into another same-night entry: the merge would keep
        // that entry's id and drop this one, and the Resume the Record tab
        // offers for this id would find nothing to resume. The night is
        // merged, if it should be, when it is stopped and archived for good.
        guard attempt("recovery.archivePaused", { try archive.archive(session, skipSameNightMerge: true) }) != nil else { return nil }
        debugLog("[SessionRecoveryService] \u{2705} Interrupted session recovered to paused state (\(data.backup.beatCount) beats). Ready to resume.")
        return session
    }
}
