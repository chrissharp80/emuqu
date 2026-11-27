import Foundation

// MARK: - The window of a night older than the stored ones

extension BaselineTracker {
    /// Whether the stored nights are the whole recovery window of the night
    /// of `session`: `recoveryWindowNights` of them are before it, or they
    /// reach back to `oldestArchivedNight` (the oldest archived night that
    /// could hold a baseline night), so none was trimmed (`maxHistoricalPoints`).
    func holdsRecoveryWindow(forNightOf session: HRVSession, sleepSchedule: SleepSchedule, oldestArchivedNight: Date?) -> Bool {
        let stored = pendingNights().points
        let night = sleepSchedule.nightKey(for: session.startDate)
        let before = stored.filter { sleepSchedule.nightKey(for: $0.date) < night }
        guard before.count < Self.recoveryWindowNights else { return true }
        guard let oldestArchivedNight, let oldestStored = stored.first else { return oldestArchivedNight == nil }
        return sleepSchedule.nightKey(for: oldestStored.date) <= oldestArchivedNight
    }

    /// The recovery baseline the night of `session` is scored against,
    /// rebuilt from `sessions` by the tracker's own rules: the same nights as
    /// `baselineRMSSDs(rebuiltFrom:beforeNightOf:sleepSchedule:)` and the
    /// statistics of `recoveryBaselineStats(excludingNightOf:sleepSchedule:)`,
    /// for a night older than the stored nights reach. Nil below `minimumDays`.
    static func recoveryBaselineStats(
        rebuiltFrom sessions: [HRVSession], beforeNightOf session: HRVSession, sleepSchedule: SleepSchedule
    ) -> RecoveryBaselineStats? {
        stats(from: nights(rebuiltFrom: sessions, beforeNightOf: session, sleepSchedule: sleepSchedule))
    }

    /// The baseline nights `sessions` hold before the night of `session`,
    /// oldest first, one per night.
    static func nights(
        rebuiltFrom sessions: [HRVSession], beforeNightOf session: HRVSession, sleepSchedule: SleepSchedule
    ) -> [BaselineDataPoint] {
        let night = sleepSchedule.nightKey(for: session.startDate)
        let points = sessions
            .filter { isBaselineCandidate($0) && sleepSchedule.nightKey(for: $0.startDate) < night }
            .sorted { $0.startDate < $1.startDate }
            .compactMap { candidate in candidate.analysisResult.map { dataPoint(session: candidate, result: $0) } }
        var nights: [BaselineDataPoint] = []
        for point in points {
            mergeIntoNight(point, into: &nights, sleepSchedule: sleepSchedule)
        }
        return nights.sorted { $0.date < $1.date }
    }
}
