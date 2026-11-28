import Foundation

/// The one rule for an edit that changes a night's beats or span: a same-night
/// fold, a fill from the strap's own recording, a segment unlinked. The night
/// it commits is never half-edited: everything indexed into the beats moves
/// with them, the span follows the beats' tail, and the analysis, window,
/// quality and score are then computed again from what the night holds
/// (`requestReanalysis`), at the night's own ScoringVersion. That is the
/// edit's purpose, not a rescore of history.
///
/// A window the user picked is kept while every beat of it is still there;
/// one whose beats the edit removed no longer describes the night, so the
/// mark goes and the reanalysis chooses again.
enum NightBeatsEdit {
    /// The reason the reanalysis request carries (`.flowRecoveryRescoreNeeded`).
    static let rescoreReason = "beats"

    /// Puts `points` on `session`. Artifact flags index the old beats and
    /// are cleared for the reanalysis to detect again; the analysis and auto
    /// window are re-pointed at the same beats (`SessionMerger.reindexed`).
    static func replaceBeats(of session: inout HRVSession, with points: [RRPoint]) {
        let old = session.rrSeries?.points ?? []
        if session.windowUserAdjusted == true, let result = session.analysisResult,
           !keepsEveryBeat(of: result, from: old, in: points) {
            session.windowUserAdjusted = nil
        }
        session.rrSeries = RRSeries(points: points, sessionId: session.id, startDate: session.rrSeries?.startDate ?? session.startDate)
        session.artifactFlags = nil
        session.analysisResult = session.analysisResult.map { SessionMerger.reindexed($0, from: old, onto: points) }
        session.autoWindowResult = session.autoWindowResult.map { SessionMerger.reindexed($0, from: old, onto: points) }
        followTail(of: &session, old: old, new: points)
    }

    /// Whether every beat of `result`'s window in `old` is still in `new`:
    /// as many beats lie in the window's time span as it held.
    static func keepsEveryBeat(of result: HRVAnalysisResult, from old: [RRPoint], in new: [RRPoint]) -> Bool {
        guard result.windowStart >= 0, result.windowEnd <= old.count, result.windowStart < result.windowEnd else { return true }
        let (startMs, endMs) = (old[result.windowStart].t_ms, old[result.windowEnd - 1].t_ms)
        let kept = new.lazy.filter { $0.t_ms >= startMs && $0.t_ms <= endMs }.count
        return kept >= result.windowEnd - result.windowStart
    }

    /// The span follows the beats' tail: a tail the edit removed ends the
    /// night at the last beat kept, a longer tail extends it. The sleep
    /// bounds are kept inside the span, unless the user set them.
    private static func followTail(of session: inout HRVSession, old: [RRPoint], new: [RRPoint]) {
        let start = session.rrSeries?.startDate ?? session.startDate
        guard let newEnd = new.lastBeatEnd(after: start), let oldEnd = old.lastBeatEnd(after: start), newEnd != oldEnd else { return }
        let end = session.endDate ?? oldEnd
        session.endDate = newEnd < oldEnd ? min(end, newEnd) : max(end, newEnd)
        guard session.sleepUserAdjusted != true, let endDate = session.endDate else { return }
        let spanMs = MillisecondOffset.between(endDate, and: session.startDate, fallback: 0)
        session.sleepEndMs = session.sleepEndMs.map { min($0, spanMs) }
        session.sleepStartMs = session.sleepStartMs.map { min($0, spanMs) }
    }

    /// Asks for the night to be analysed again from what it holds
    /// (`SessionReanalysisCoordinator.handleRescoreRequest`, which keeps a
    /// window the user picked and scores it).
    /// A workout is not a night: its figures are rebuilt by
    /// `WorkoutRecoveryService`, and nothing is asked here.
    static func requestReanalysis(of session: HRVSession, detail: String) {
        guard session.sessionType != .workout else { return }
        requestReanalysis(of: session.id, detail: detail)
    }

    static func requestReanalysis(of sessionId: UUID, detail: String) {
        NotificationCenter.default.post(
            name: .flowRecoveryRescoreNeeded, object: sessionId,
            userInfo: ["reason": rescoreReason, "detail": detail]
        )
    }
}
