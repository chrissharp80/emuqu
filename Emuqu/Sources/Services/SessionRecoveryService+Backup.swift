import Foundation

// Backup recovery and corrupted-session repair, split out of
// `SessionRecoveryService.swift` to keep that type under the
// 500-line body ceiling. Everything here reconstructs a session from the raw
// RR backup (local or pulled from iCloud) after the live path failed.

extension SessionRecoveryService {
    // MARK: - Backup Recovery

    /// Recover a session from its raw RR backup, running full analysis.
    ///
    /// - Parameters:
    ///   - sessionId: The session to recover.
    ///   - analyze: Closure for windowed analysis.
    ///   - analyzeWithCapacity: Closure for full-session analysis with peak capacity.
    ///   - supersedeSameNight: Closure to supersede same-night sessions.
    /// - Returns: The recovered session, or nil if recovery failed.
    func recoverFromBackup(
        _ sessionId: UUID,
        analyze: (_ session: HRVSession, _ window: WindowSelector.RecoveryWindow, _ flags: [ArtifactFlags], _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        analyzeWithCapacity: (_ session: HRVSession, _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        supersedeSameNight: (_ session: inout HRVSession) -> Void,
        // Without this, every
        // recovered session gets `recoveryScore = nil` and the
        // dashboard falls back to computing the score LIVE on every
        // render. Beta user report: the backup
        // recovery completed fine but the hero score never settled
        // — `[DIAG] calculateRecoveryScore: no frozen score —
        // calculating LIVE` fires hundreds of times per minute
        // because the frozen field is permanently nil, and the user
        // has to tap "Reanalyze" manually to get a score that sticks. Same
        // taxonomy of closure parameters as `recoverAndPatchSession`
        // above; caller passes the same `computeRecoveryScore(for:from:)`
        // helper that the normal-acceptance path uses.
        computeRecoveryScore: (_ session: HRVSession, _ analysisResult: HRVAnalysisResult?) async -> RecoveryScoreOutcome? = { _, _ in nil }
    ) async -> HRVSession? {
        debugLog("[SessionRecoveryService] Attempting to recover session \(sessionId) from backup")

        guard let data = retrieveBackupWithParentMerge(sessionId) else { return nil }

        var session = HRVSession(
            id: sessionId, startDate: data.sessionStart, endDate: data.endDate,
            state: .collecting,
            sessionType: Self.recoveredSessionType(for: data, sessionId: sessionId),
            rrSeries: data.series, analysisResult: nil, artifactFlags: data.flags
        )

        await analyzeSession(&session, series: data.series, flags: data.flags, analyze: analyze, analyzeWithCapacity: analyzeWithCapacity)
        session.state = session.analysisResult != nil ? .complete : .failed
        guard session.state == .complete else { return session }

        supersedeSameNight(&session)
        await stampFrozenScore(on: &session, computeRecoveryScore: computeRecoveryScore)
        guard archiveRecovered(session, sessionId: sessionId) else { return nil }
        return session
    }

    /// Two-tier classification for a recovered backup.
    ///
    /// Quality gate. A backup with too few beats can't be a real
    /// overnight session; a typical overnight captures 28,000+ beats
    /// (≈ 7 hours × 70 bpm). Beta tester report: a 22-minute partial backup
    /// (≈ 1,500 beats) was auto-recovered as `.overnight`, landed on Monday's
    /// recovery night, and replaced Monday's real overnight score on the
    /// dashboard. The user's complaint: "wtf … how did it replace a whole
    /// night."
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
    /// `internal` so the classification can be tested. Getting this wrong in
    /// the `.overnight` direction lets a short recovered fragment displace a
    /// real overnight reading on the same date.
    static func recoveredSessionType(for data: BackupData, sessionId: UUID) -> SessionType {
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
    /// Mirrors the score-stamping `recoverAndPatchSession` does.
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
        session.frozenReadiness = ReanalysisService.computeFrozenReadiness(
            compositeScore: result.breakdown.compositeScore,
            trainingContext: session.trainingSnapshot ?? session.analysisResult?.trainingContext
        )
    }

    /// Persist sleep/vitals snapshots alongside the score. The
    /// scorer fetched them live to produce the breakdown; without stamping
    /// them the dashboard's live-recompute path reads nil and renders a tier-1
    /// breakdown that contradicts the frozen score (seen in the field:
    /// frozenScore 9.75 archived, tier-1 recompute 16 s later,
    /// contradictory factor scores on screen).
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

    /// Archive, mark the raw backup consumed, and kick off the cloud upload.
    ///
    /// Reports failure honestly. Returning the session on an
    /// archive failure would make `recoverAllLostSessions` count it "recovered" and
    /// the UI announce "Recovered N of N" while nothing was persisted.
    /// Returning false keeps the raw backup un-archived and eligible for the
    /// next recovery attempt.
    private func archiveRecovered(_ session: HRVSession, sessionId: UUID) -> Bool {
        do {
            try archive.archive(session)
            rawBackup.markAsArchived(sessionId)
            Task { await cloudSyncManager.uploadSession(session) }
            debugLog("[SessionRecoveryService] Successfully recovered and archived session \(sessionId) — frozenScore=\(session.recoveryScore.map { String(format: "%.2f", $0) } ?? "nil")")
            return true
        } catch {
            debugLog("[SessionRecoveryService] Failed to archive recovered session \(sessionId.uuidString.prefix(8)): \(error)", level: .error)
            return false
        }
    }

    /// Recover a session from backup into a paused state (for interrupted recordings).
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
        guard let data = retrieveBackupWithParentMerge(sessionId) else { return nil }
        var session = HRVSession(
            id: sessionId, startDate: data.sessionStart, endDate: data.endDate,
            state: .collecting, sessionType: sessionType,
            rrSeries: data.series, analysisResult: nil, artifactFlags: data.flags
        )
        await analyzeSession(
            &session, series: data.series, flags: data.flags,
            analyze: analyze, analyzeWithCapacity: analyzeWithCapacity
        )
        session.state = .paused
        session.pausedDate = Date()
        guard attempt("recovery.archivePaused", { try archive.archive(session) }) != nil else { return nil }
        debugLog("[SessionRecoveryService] \u{2705} Interrupted session recovered to paused state (\(data.backup.beatCount) beats). Ready to resume.")
        return session
    }

    /// Recover all lost sessions from backups.
    func recoverAllLostSessions(
        analyze: @escaping (_ session: HRVSession, _ window: WindowSelector.RecoveryWindow, _ flags: [ArtifactFlags], _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        analyzeWithCapacity: @escaping (_ session: HRVSession, _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        supersedeSameNight: @escaping (_ session: inout HRVSession) -> Void
    ) async -> Int {
        let lost = await checkForLostSessions()
        var recovered = 0

        for (id, date, _) in lost {
            debugLog("[SessionRecoveryService] Recovering session from \(date)...")
            if await recoverFromBackup(id, analyze: analyze, analyzeWithCapacity: analyzeWithCapacity, supersedeSameNight: supersedeSameNight) != nil {
                recovered += 1
            }
        }

        debugLog("[SessionRecoveryService] Recovered \(recovered) of \(lost.count) lost sessions")
        return recovered
    }

    // MARK: - Corrupted Session Recovery

    func findCorruptedSessions(toleranceDays: Int = 1) -> [CorruptedSessionInfo] {
        let corrupted = rawBackup.allBackups().compactMap {
            mismatchInfo(for: $0, toleranceDays: toleranceDays)
        }
        if !corrupted.isEmpty {
            debugLog("[SessionRecoveryService] \u{274c} Found \(corrupted.count) potentially corrupted sessions")
        }
        return corrupted.sorted { $0.backupDate > $1.backupDate }
    }

    /// A backup whose capture date disagrees with its archived session's date
    /// by more than `toleranceDays` — the signature of a corrupted write.
    private func mismatchInfo(
        for backup: RawRRBackup.BackupEntry, toleranceDays: Int
    ) -> CorruptedSessionInfo? {
        guard let archiveEntry = archive.entries.first(where: { $0.sessionId == backup.id }) else {
            return nil
        }
        let calendar = Calendar.current
        let archiveDay = calendar.startOfDay(for: archiveEntry.date)
        let backupDay = calendar.startOfDay(for: backup.captureDate)
        let daysDifference = abs(calendar.dateComponents([.day], from: backupDay, to: archiveDay).day ?? 0)
        guard daysDifference > toleranceDays else { return nil }
        return CorruptedSessionInfo(
            sessionId: backup.id,
            archiveDate: archiveEntry.date,
            backupDate: backup.captureDate,
            dateMismatchDays: daysDifference,
            beatCount: backup.beatCount
        )
    }

    func restoreCorruptedSession(
        _ sessionId: UUID,
        analyze: (_ session: HRVSession, _ window: WindowSelector.RecoveryWindow, _ flags: [ArtifactFlags], _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        analyzeWithCapacity: (_ session: HRVSession, _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?
    ) async -> HRVSession? {
        debugLog("[SessionRecoveryService] Attempting to restore corrupted session \(sessionId)")
        // Corrupted sessions don't merge parent data — use backup directly.
        guard let backup = storedBackup(sessionId) else { return nil }
        let series = RRSeries(points: backup.points, sessionId: sessionId, startDate: backup.captureDate)
        let flags = artifactDetector.detectArtifacts(in: series)
        // Preserve user-entered tags and notes from the existing (corrupted) session.
        let existingSession = try? archive.retrieve(sessionId)
        var session = HRVSession(
            id: sessionId, startDate: backup.captureDate, endDate: Self.backupEndDate(backup),
            state: .analyzing, sessionType: existingSession?.sessionType ?? .overnight,
            rrSeries: series, analysisResult: nil, artifactFlags: flags,
            tags: existingSession?.tags ?? [], notes: existingSession?.notes
        )
        await analyzeSession(
            &session, series: series, flags: flags,
            analyze: analyze, analyzeWithCapacity: analyzeWithCapacity
        )
        session.state = session.analysisResult != nil ? .complete : .failed
        guard session.state == .complete else { return session }
        return archiveRestored(session, captureDate: backup.captureDate)
    }

    private func archiveRestored(_ session: HRVSession, captureDate: Date) -> HRVSession? {
        do {
            try archive.archive(session)
            Task { await cloudSyncManager.uploadSession(session) }
            debugLog("[SessionRecoveryService] Successfully restored session \(session.id) with date \(captureDate)")
            return session
        } catch {
            debugLog("[SessionRecoveryService] Failed to archive restored session: \(error)")
            return nil
        }
    }

    /// Restore all corrupted sessions.
    func restoreAllCorruptedSessions(
        toleranceDays: Int = 1,
        analyze: @escaping (_ session: HRVSession, _ window: WindowSelector.RecoveryWindow, _ flags: [ArtifactFlags], _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?,
        analyzeWithCapacity: @escaping (_ session: HRVSession, _ peakCapacity: PeakCapacity?) async -> HRVAnalysisResult?
    ) async -> Int {
        let corrupted = findCorruptedSessions(toleranceDays: toleranceDays)
        var restoredCount = 0

        for info in corrupted where await restoreCorruptedSession(info.sessionId, analyze: analyze, analyzeWithCapacity: analyzeWithCapacity) != nil {
            restoredCount += 1
        }

        debugLog("[SessionRecoveryService] Restored \(restoredCount) of \(corrupted.count) corrupted sessions")
        return restoredCount
    }
}
