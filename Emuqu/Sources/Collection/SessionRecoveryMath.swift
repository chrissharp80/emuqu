import Foundation

/// The pure decisions inside crash-session recovery, lifted out of
/// `SessionRecoveryCoordinator`.
///
/// Every one of them decides what happens to data the user cannot re-record —
/// which recording survives a merge, whether an archived merge is the corrupt
/// kind, what the review card says — and every one of them was a `private
/// static` on a coordinator that also owns the strap, the archive and the
/// scoring pipeline. None of it could be reached from a test.
///
/// Two of them were wrong in ways only a mutation run found: the merge
/// tie-break was unreachable through its own caller, and the review card's
/// `Int(Double)` conversion would have killed the process on a NaN mean HR.
enum SessionRecoveryMath {
    nonisolated static func makeRecoveredWorkoutReview(from session: HRVSession) -> MorningCoordination.RecoveredWorkoutReview {
        let dur = (session.endDate ?? session.startDate).timeIntervalSince(session.startDate)
        return MorningCoordination.RecoveredWorkoutReview(
            sessionId: session.id,
            sport: session.workoutMetadata?.sport.displayName ?? "Workout",
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
    /// short for `DataSourceSelector` to judge: keep whichever holds more
    /// beats. Its own function because it is unreachable through
    /// `mergedWorkoutPoints` for any input the selector CAN judge, and an
    /// untestable branch that decides which half of a workout survives is not
    /// worth having.
    nonisolated static func longerRecording(existing: [RRPoint], strapRR: [RRPoint]) -> [RRPoint] {
        strapRR.count > existing.count ? strapRR : existing
    }

    /// Detect the v5 merge corruption: a child series longer than its parent
    /// whose timestamps jump BACKWARDS at the splice point.
    ///
    /// A correct merge produces monotonically increasing `t_ms`. The v5 bug
    /// concatenated the two series without rebasing the second, so the first
    /// beat past the parent's length restarts near zero. Comparing it against
    /// half the preceding value catches that without flagging an ordinary gap.
    nonisolated static func hasV5TimestampDiscontinuity(
        childSeries: RRSeries,
        parentBeatCount: Int
    ) -> Bool {
        guard childSeries.points.count > parentBeatCount else { return false }
        let boundaryIdx = parentBeatCount
        guard boundaryIdx < childSeries.points.count, boundaryIdx > 0 else { return false }
        let beforeBoundary = childSeries.points[boundaryIdx - 1].t_ms
        let afterBoundary = childSeries.points[boundaryIdx].t_ms
        return afterBoundary < beforeBoundary / 2
    }
}
