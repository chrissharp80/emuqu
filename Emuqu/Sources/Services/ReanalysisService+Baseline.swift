import Foundation

// The nights a re-score compares a session with.
//
// `BaselineTracker` keeps only the newest `maxHistoricalPoints` nights, so
// for a night older than those its own window (the `recoveryWindowNights`
// nights before it) is no longer in the tracker. Scored against what the
// tracker still holds before it (few nights, or none), its HRV factor would
// fall to the absolute RMSSD bands and the night would be stamped with a
// no-baseline score it was never first given. Such a night's window is
// rebuilt from the archive by the tracker's own rules instead
// (`BaselineTracker.recoveryBaselineStats(rebuiltFrom:beforeNightOf:sleepSchedule:)`).

extension ReanalysisService {
    /// The baseline `session` is re-scored against: the nights before it,
    /// never its own (a reading is compared with the nights before it, never
    /// with itself). The tracker's stored nights when they are the whole
    /// window (`BaselineTracker.holdsRecoveryWindow`), else the window rebuilt
    /// from the archive. Nil when fewer than
    /// `RecoveryBaselineStats.minimumDays` nights came before it.
    ///
    /// Reanalysis selects the recovery window with the SAME rule as the
    /// initial ("morning") analyze: ranked against the rolling baseline, so a
    /// nil here would rank by raw RMSSD and pick a higher-HRV window than the
    /// morning did.
    func scoringBaseline(for session: HRVSession) -> BaselineTracker.RecoveryBaselineStats? {
        let schedule = settingsProvider().sleepSchedule
        let candidates = Self.archivedBaselineCandidates(before: session, in: archive, sleepSchedule: schedule)
        let oldest = candidates.last.map { schedule.nightKey(for: $0.date) }
        guard !baselineTracker.holdsRecoveryWindow(forNightOf: session, sleepSchedule: schedule, oldestArchivedNight: oldest) else {
            return baselineTracker.recoveryBaselineStats(excludingNightOf: session, sleepSchedule: schedule)
        }
        let key = ArchivedBaselineMemo.key(for: session, candidates: candidates)
        if let memo = archivedBaselineMemo.value(for: key) { return memo.stats }
        let stats = Self.rebuiltBaseline(for: session, candidates: candidates, in: archive, sleepSchedule: schedule)
        archivedBaselineMemo.store(stats, for: key)
        return stats
    }

    /// Rebuilds `session`'s archive window off the main actor when the
    /// re-score needs one, so the re-score's own reads of
    /// `scoringBaseline(for:)` find it ready instead of reading the archive
    /// on the main actor.
    func prepareScoringBaseline(for session: HRVSession) async {
        let schedule = settingsProvider().sleepSchedule
        let candidates = Self.archivedBaselineCandidates(before: session, in: archive, sleepSchedule: schedule)
        let oldest = candidates.last.map { schedule.nightKey(for: $0.date) }
        guard !baselineTracker.holdsRecoveryWindow(forNightOf: session, sleepSchedule: schedule, oldestArchivedNight: oldest) else { return }
        let key = ArchivedBaselineMemo.key(for: session, candidates: candidates)
        guard archivedBaselineMemo.value(for: key) == nil else { return }
        let archive = archive
        let stats = await Task.detached(priority: .userInitiated) {
            Self.rebuiltBaseline(for: session, candidates: candidates, in: archive, sleepSchedule: schedule)
        }.value
        archivedBaselineMemo.store(stats, for: key)
    }

    /// Whether a re-score of `session` keeps its stored score, breakdown and
    /// frozen readiness: no baseline can be built for its night (`baseline`
    /// is nil) and it already has a score. A no-baseline score would replace
    /// the baseline-relative one it may have been given.
    nonisolated static func keepsStoredScore(_ session: HRVSession, baseline: BaselineTracker.RecoveryBaselineStats?) -> Bool {
        guard baseline == nil, session.recoveryScore != nil, session.scoreBreakdown != nil else { return false }
        debugLog("[ReanalysisService] No baseline for the nights before \(session.id.uuidString.prefix(8)); keeping its stored score")
        return true
    }

    /// The archived overnight sessions that may hold a baseline night before
    /// the night of `session`, newest first, by the index alone.
    nonisolated static func archivedBaselineCandidates(
        before session: HRVSession, in archive: SessionArchive, sleepSchedule: SleepSchedule
    ) -> [SessionArchiveEntry] {
        let night = sleepSchedule.nightKey(for: session.startDate)
        return archive.store.entries
            .filter { $0.sessionType == .overnight && $0.isReliableForHRVAggregates && sleepSchedule.nightKey(for: $0.date) < night }
            .sorted { $0.date > $1.date }
    }

    /// The baseline rebuilt from `candidates`, read newest first until one
    /// more night than the window holds is in hand, so the window's oldest
    /// night is complete.
    nonisolated static func rebuiltBaseline(
        for session: HRVSession, candidates: [SessionArchiveEntry], in archive: SessionArchive, sleepSchedule: SleepSchedule
    ) -> BaselineTracker.RecoveryBaselineStats? {
        let sessions = windowSessions(from: candidates, sleepSchedule: sleepSchedule) {
            archive.retrieveLightweightOrLog($0, caller: "scoringBaseline")
        }
        return BaselineTracker.recoveryBaselineStats(rebuiltFrom: sessions, beforeNightOf: session, sleepSchedule: sleepSchedule)
    }

    /// The baseline candidates among `candidates` (newest first), loaded by
    /// `load` until one more night than the window holds is in hand.
    nonisolated static func windowSessions(
        from candidates: [SessionArchiveEntry], sleepSchedule: SleepSchedule, load: (UUID) -> HRVSession?
    ) -> [HRVSession] {
        var sessions: [HRVSession] = []
        var nights = Set<Date>()
        for entry in candidates {
            guard nights.count <= BaselineTracker.recoveryWindowNights else { break }
            guard let loaded = load(entry.sessionId), BaselineTracker.isBaselineCandidate(loaded) else { continue }
            sessions.append(loaded)
            nights.insert(sleepSchedule.nightKey(for: loaded.startDate))
        }
        return sessions
    }
}

/// Archive-rebuilt baselines already computed, so the several reads one
/// re-score makes (window, classification, score) rebuild once. Keyed by the
/// night and the index entries it was built from (ids and file hashes), so a
/// session archived, changed or deleted since is a different key and nothing
/// stale is read.
struct ArchivedBaselineMemo {
    struct Value {
        let stats: BaselineTracker.RecoveryBaselineStats?
    }

    private var values: [Int: Value] = [:]
    private static let capacity = 64

    static func key(for session: HRVSession, candidates: [SessionArchiveEntry]) -> Int {
        var hasher = Hasher()
        hasher.combine(session.id)
        hasher.combine(session.startDate)
        for entry in candidates {
            hasher.combine(entry.sessionId)
            hasher.combine(entry.fileHash)
        }
        return hasher.finalize()
    }

    func value(for key: Int) -> Value? {
        values[key]
    }

    mutating func store(_ stats: BaselineTracker.RecoveryBaselineStats?, for key: Int) {
        if values.count >= Self.capacity { values.removeAll() }
        values[key] = Value(stats: stats)
    }
}
