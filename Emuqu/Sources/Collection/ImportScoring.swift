import Foundation

/// Scores the nights of one import, oldest first, each against the nights
/// before it (`SessionImport.scoredForSave`).
///
/// The baseline keeps only its newest `maxHistoricalPoints` nights. For a
/// night older than those, the stored nights before it are few or none, and
/// scored on them it would fall to the absolute RMSSD bands and keep that
/// no-baseline score. Such a night is scored against its window rebuilt from
/// the archive by the tracker's own rules, with the batch's earlier nights
/// added, as a re-score of an old night is (`ReanalysisService.scoringBaseline`).
struct ImportScoring: Sendable {
    let baselineTracker: BaselineTracker
    let archive: SessionArchive
    let sleepSchedule: SleepSchedule
    let typicalSleepHours: Double
    let scoringConfig: RecoveryScoreCalculator.ScoringConfiguration

    /// `sessions` oldest first, each scored on save when it is one the app
    /// scores (`SessionImport.isScoredOnSave`).
    func scored(_ sessions: [HRVSession]) -> [HRVSession] {
        var nights = baselineTracker.pendingNights()
        var loaded: [UUID: HRVSession] = [:]
        var scored: [HRVSession] = []
        for session in sessions.sorted(by: { $0.startDate < $1.startDate }) {
            let stats = baseline(for: session, nights: nights, earlier: scored, loaded: &loaded)
            let context = RescoreContext(baselineStats: stats, typicalSleepHours: typicalSleepHours, scoringConfig: scoringConfig)
            let result = SessionImport.scored(session, context: context)
            baselineTracker.admit(result, to: &nights, sleepSchedule: sleepSchedule)
            scored.append(result)
        }
        return scored
    }

    /// The stored nights and the batch's earlier ones when the stored nights
    /// are the night's whole window (`BaselineTracker.holdsRecoveryWindow`),
    /// else the window rebuilt from the archive plus the batch's earlier
    /// nights. Archived sessions read once per batch are kept in `loaded`.
    func baseline(
        for session: HRVSession, nights: BaselineTracker.PendingNights, earlier: [HRVSession], loaded: inout [UUID: HRVSession]
    ) -> BaselineTracker.RecoveryBaselineStats? {
        let candidates = ReanalysisService.archivedBaselineCandidates(before: session, in: archive, sleepSchedule: sleepSchedule)
        let oldest = candidates.last.map { sleepSchedule.nightKey(for: $0.date) }
        guard !baselineTracker.holdsRecoveryWindow(forNightOf: session, sleepSchedule: sleepSchedule, oldestArchivedNight: oldest) else {
            return baselineTracker.recoveryBaselineStats(excludingNightOf: session, sleepSchedule: sleepSchedule, in: nights)
        }
        let archived = ReanalysisService.windowSessions(from: candidates, sleepSchedule: sleepSchedule) { id in
            if let cached = loaded[id] { return cached }
            let session = archive.retrieveLightweightOrLog(id, caller: "importBaseline")
            loaded[id] = session
            return session
        }
        return BaselineTracker.recoveryBaselineStats(rebuiltFrom: archived + earlier, beforeNightOf: session, sleepSchedule: sleepSchedule)
    }
}
