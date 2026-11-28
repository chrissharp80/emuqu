import Foundation

/// The pure decisions inside crash-session recovery.
///
/// Every one of them decides what happens to data the user cannot re-record —
/// which recording survives a merge, whether an archived merge is the corrupt
/// kind, what the review card says — so they live here, apart from
/// `SessionRecoveryCoordinator` (which also owns the strap, the archive and
/// the scoring pipeline), where a test can reach each one directly.
enum SessionRecoveryMath {
    /// Whether one session is a segment resumed from another.
    ///
    /// A resume gives the new segment the paused session as its first link
    /// and adds the segment to the paused session's links, so the two link
    /// each other; and the segment ran after the pause. The order is needed
    /// because the mutual link alone reads the same both ways: a paused night
    /// that was resumed has its segment as its first link. A night that only
    /// lists same-night siblings it superseded is not linked back by them.
    /// The rule is `SessionLinks.isResumeParent`, the parent stopping at its
    /// pause.
    nonisolated static func isResumedSegment(
        segmentId: UUID, segmentLinks: [UUID]?, segmentEnd: Date,
        parentId: UUID, parentLinks: [UUID]?, parentPausedAt: Date?
    ) -> Bool {
        guard let parentPausedAt else { return false }
        return SessionLinks.isResumeParent(
            SessionLinks.Node(id: parentId, links: parentLinks, end: parentPausedAt),
            of: SessionLinks.Node(id: segmentId, links: segmentLinks, end: segmentEnd)
        )
    }

    nonisolated static func makeRecoveredWorkoutReview(from session: HRVSession) -> MorningCoordination.RecoveredWorkoutReview {
        let dur = (session.endDate ?? session.startDate).timeIntervalSince(session.startDate)
        return MorningCoordination.RecoveredWorkoutReview(
            sessionId: session.id,
            sport: session.workoutMetadata?.sport.localizedName
                ?? String(localized: "Workout", bundle: LanguageManager.appBundle),
            durationSec: max(0, dur),
            distanceMeters: session.workoutMetadata?.distanceMeters ?? 0,
            // `Int(Double)` TRAPS on NaN and on anything past `Int`'s range —
            // an immediate process kill, no catch site. This runs on a session
            // that has already been through a crash and a merge, which is
            // exactly the input least worth trusting; a nonsense mean HR
            // should show as 0 in the review card, not take the app down.
            avgHR: recoveredAverageHR(session.meanHR)
        )
    }

    /// Mean HR as a whole number, or 0 when there is no honest value. Bounded
    /// to plausible physiology so a corrupt series cannot render as `avgHR:
    /// 9223372036854775807` either.
    nonisolated static func recoveredAverageHR(_ meanHR: Double?) -> Int {
        guard let meanHR, meanHR.isFinite, meanHR > 0 else { return 0 }
        return Int(min(meanHR, 300).rounded())
    }

    /// Device-preferred merge with a "whichever has more beats" fallback for
    /// when the selector can't decide.
    ///
    /// `internal` rather than `private` so the fallback can be tested directly:
    /// it decides which recording a user's recovered workout is scored from,
    /// and picking the shorter one silently discards beats they cannot get
    /// back.
    nonisolated static func mergedWorkoutPoints(
        existing: [RRPoint], strapRR: [RRPoint], sessionId: UUID, sessionStart: Date
    ) -> [RRPoint] {
        guard !existing.isEmpty else { return strapRR }
        if let selection = DataSourceSelector.selectBestSource(
            streamingPoints: existing, internalPoints: strapRR,
            sessionId: sessionId, sessionStart: sessionStart
        ) {
            return selection.points
        }
        return longerRecording(existing: existing, strapRR: strapRR)
    }

    /// The last-resort tie-break, reached only when both recordings are too
    /// short for `DataSourceSelector` to judge: when the two span the same
    /// stretch, keep whichever holds more beats; when either runs past the
    /// other (`DataSourceSelector.streamReachesPastRecording`), keep both,
    /// the strap's beats where it recorded and the archived ones outside its
    /// span. A count cannot tell which half of a recording is missing. Its
    /// own function because it is unreachable through `mergedWorkoutPoints`
    /// for any input the selector CAN judge, and an untestable branch that
    /// decides which half of a workout survives is not worth having.
    nonisolated static func longerRecording(existing: [RRPoint], strapRR: [RRPoint]) -> [RRPoint] {
        guard !DataSourceSelector.streamReachesPastRecording(internal: strapRR, streaming: existing),
              !DataSourceSelector.streamReachesPastRecording(internal: existing, streaming: strapRR) else {
            return DataSourceSelector.mergeAddingOnlyUncoveredBeats(internal: strapRR, streaming: existing)
        }
        return Self.moreBeats(existing: existing, strapRR: strapRR)
    }

    nonisolated private static func moreBeats(existing: [RRPoint], strapRR: [RRPoint]) -> [RRPoint] {
        strapRR.count > existing.count ? strapRR : existing
    }

    /// Detect the v5 merge corruption: a child series longer than its parent
    /// whose timestamps jump BACKWARDS at the splice point.
    ///
    /// A correct merge produces monotonically increasing `t_ms`. A v5-corrupted
    /// series has the two concatenated without the second rebased, so the first
    /// beat past the parent's length restarts near zero. Comparing it against
    /// half the preceding value catches that without flagging an ordinary gap.
    nonisolated static func hasV5TimestampDiscontinuity(
        childSeries: RRSeries,
        parentBeatCount: Int
    ) -> Bool {
        let boundaryIdx = parentBeatCount
        guard boundaryIdx > 0, childSeries.points.count > boundaryIdx else { return false }
        let beforeBoundary = childSeries.points[boundaryIdx - 1].t_ms
        let afterBoundary = childSeries.points[boundaryIdx].t_ms
        return afterBoundary < beforeBoundary / 2
    }
}
