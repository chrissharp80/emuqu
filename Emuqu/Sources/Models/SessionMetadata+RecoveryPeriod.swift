import Foundation

// Recovery-period selection: which sessions belong to the same night.

// MARK: - Recovery Period Selection

extension HRVSession {
    /// Find the chained recovery window by merging sessions that belong to the same
    /// pause/resume recording period. It intentionally does not force an
    /// extension to the morning cutoff; `sleepFetchWindow` adds that.
    static func recoveryPeriodWindow(
        for session: HRVSession,
        allSessions: [HRVSession],
        sleepSchedule: SleepSchedule,
        mergeGapSeconds: TimeInterval
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
        sleepSchedule: SleepSchedule,
        mergeGapSeconds: TimeInterval
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
}
