import Foundation

// Recovery-period selection: which sessions belong to the same night, and
// which of them is the one to show.

// MARK: - Recovery Period Selection

extension HRVSession {
    /// Find the chained recovery window by merging sessions that belong to the same
    /// pause/resume recording period. This window is used for selecting a "best"
    /// session in the same chain and intentionally does not force an extension to
    /// the morning cutoff.
    static func recoveryPeriodWindow(
        for session: HRVSession,
        allSessions: [HRVSession],
        sleepSchedule: SleepSchedule = UserSettings().sleepSchedule,
        mergeGapSeconds: TimeInterval = UserSettings().effectiveMergeGapSeconds
    ) -> (start: Date, end: Date) {
        var earliestStart = session.startDate
        var latestEnd = session.endDate ?? session.startDate
        // Only chain overnight sessions — naps and quick readings stand alone
        guard session.sessionType == .overnight else {
            return (start: earliestStart, end: latestEnd)
        }
        // Morning cutoff = wake time + 4 hours. Sessions that start after this
        // are daytime activity, not split sleep continuation.
        let morningCutoff = sleepSchedule.morningCutoff(relativeTo: session.startDate)
        let chainable = chainableOvernightSessions(excluding: session, from: allSessions)
        expandBackward(&earliestStart, over: chainable, maxGap: mergeGapSeconds)
        expandForward(&latestEnd, over: chainable, maxGap: mergeGapSeconds, morningCutoff: morningCutoff)
        return (start: earliestStart, end: latestEnd)
    }

    /// Expand backward: sessions that ended shortly before this one started.
    private static func expandBackward(
        _ earliestStart: inout Date, over chainable: [HRVSession], maxGap: TimeInterval
    ) {
        for candidate in chainable.reversed() {
            guard let candidateEnd = candidate.endDate else { continue }
            let gap = earliestStart.timeIntervalSince(candidateEnd)
            if gap >= 0, gap <= maxGap {
                earliestStart = candidate.startDate
            }
        }
    }

    /// Expand forward: sessions that started shortly after this one ended, but
    /// only if they start within the overnight window (not daytime sessions).
    private static func expandForward(
        _ latestEnd: inout Date, over chainable: [HRVSession], maxGap: TimeInterval, morningCutoff: Date
    ) {
        for candidate in chainable {
            guard let candidateEnd = candidate.endDate else { continue }
            let gap = candidate.startDate.timeIntervalSince(latestEnd)
            if gap >= 0, gap <= maxGap, candidate.startDate <= morningCutoff {
                latestEnd = candidateEnd
            }
        }
    }

    /// Overnight sessions other than `session` that could belong to the same
    /// pause/resume chain, oldest first.
    private static func chainableOvernightSessions(
        excluding session: HRVSession, from allSessions: [HRVSession]
    ) -> [HRVSession] {
        allSessions
            .filter { ($0.state == .complete || $0.state == .paused) && $0.sessionType == .overnight && $0.id != session.id }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Sleep fetch window for overnight analysis/results.
    ///
    /// Starts from the chained recovery window and extends the end to the user's
    /// morning cutoff so segmented sleep after recording end (Apple Watch-only)
    /// is included in the fetch.
    static func sleepFetchWindow(
        for session: HRVSession,
        allSessions: [HRVSession],
        sleepSchedule: SleepSchedule = UserSettings().sleepSchedule,
        mergeGapSeconds: TimeInterval = UserSettings().effectiveMergeGapSeconds
    ) -> (start: Date, end: Date) {
        let chained = recoveryPeriodWindow(
            for: session,
            allSessions: allSessions,
            sleepSchedule: sleepSchedule,
            mergeGapSeconds: mergeGapSeconds
        )

        guard session.sessionType == .overnight else {
            return chained
        }

        let morningCutoff = sleepSchedule.morningCutoff(relativeTo: chained.start)
        return (start: chained.start, end: max(chained.end, morningCutoff))
    }

    /// From all sessions in the same recovery period, return the one with the best readiness score.
    /// This handles pause/resume: multiple segments scored separately, best score wins.
    ///
    /// Prefer the frozen composite (recoveryScore) which accounts for sleep,
    /// training, and vitals. Fall back to the raw ANS readiness only for
    /// sessions that haven't been accepted yet.
    static func bestSessionInRecoveryPeriod(for session: HRVSession, allSessions: [HRVSession]) -> HRVSession {
        let window = recoveryPeriodWindow(for: session, allSessions: allSessions)
        let candidates = allSessions.filter { scorableSession($0, in: window) }
        debugLog("[DIAG] bestSessionInRecoveryPeriod: \(candidates.count) candidates for session=\(session.id.uuidString.prefix(8))")
        for candidate in candidates {
            logCandidate(candidate)
        }
        let winner = candidates.max(by: { a, b in
            let scoreA = a.recoveryScore ?? a.analysisResult?.ansMetrics?.readinessScore ?? 0
            let scoreB = b.recoveryScore ?? b.analysisResult?.ansMetrics?.readinessScore ?? 0
            return scoreA < scoreB
        }) ?? session
        debugLog("[DIAG] bestSessionInRecoveryPeriod: winner id=\(winner.id.uuidString.prefix(8)) recoveryScore=\(winner.recoveryScore.map { String(format: "%.2f", $0) } ?? "nil")")
        return winner
    }

    /// A finished, analyzed session inside the window. Very short sessions
    /// (< 30 min) are excluded — stray test readings or accidental recordings
    /// must not override the overnight session.
    private static func scorableSession(_ session: HRVSession, in window: (start: Date, end: Date)) -> Bool {
        guard session.state == .complete || session.state == .paused,
              session.analysisResult != nil else { return false }
        guard sessionDuration(session) >= 30 * 60 else { return false }
        return session.startDate >= window.start && session.startDate <= window.end
    }

    private static func sessionDuration(_ session: HRVSession) -> TimeInterval {
        session.duration ?? session.endDate.map { $0.timeIntervalSince(session.startDate) } ?? 0
    }

    private static func logCandidate(_ candidate: HRVSession) {
        let score = candidate.recoveryScore.map { String(format: "%.2f", $0) } ?? "nil"
        let ans = candidate.analysisResult?.ansMetrics?.readinessScore.map { String(format: "%.2f", $0) } ?? "nil"
        let duration = String(format: "%.0f", sessionDuration(candidate))
        debugLog("[DIAG]   candidate id=\(candidate.id.uuidString.prefix(8)) recoveryScore=\(score) ansReadiness=\(ans) duration=\(duration)s")
    }
}
