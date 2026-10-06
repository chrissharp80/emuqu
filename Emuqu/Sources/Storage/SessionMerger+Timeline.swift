import Foundation

// MARK: - One clock, one gap rule
//
// Every path that combines two recordings of one wearer answers the same two
// questions: are these the same recording, the same sleep, or separate
// sleeps; and where do both sit on one clock. `RRPoint.t_ms` counts from the
// start of its own recording, so two series share a clock only once one is
// shifted by the real time between their starts. The archive merge, batch
// import, the morning same-night merge and the relink migration all take
// their answers from here.

extension SessionMerger {
    /// How two recordings relate in time.
    enum RecordingRelation: Equatable {
        /// Their spans overlap: two copies of one recording, such as the
        /// streamed copy and the strap's own file, or a re-import.
        case sameRecording
        /// Disjoint, with no more than the merge gap between one's end and
        /// the other's start: two segments of one sleep.
        case sameSleep
        /// Further apart than the merge gap: separate sleeps.
        case separate
    }

    /// The relation between two recording spans under `mergeGap`, the
    /// user's "segments within this gap count as one night" setting.
    static func relation(
        of lhs: DateInterval, to rhs: DateInterval, mergeGap: TimeInterval
    ) -> RecordingRelation {
        if overlaps(lhs, rhs) { return .sameRecording }
        return gapBetween(lhs, rhs) <= mergeGap ? .sameSleep : .separate
    }

    /// Whether two spans share any time. Spans that only touch do not; a
    /// zero-length span overlaps one it lies inside, ends included.
    static func overlaps(_ lhs: DateInterval, _ rhs: DateInterval) -> Bool {
        let shared = min(lhs.end, rhs.end).timeIntervalSince(max(lhs.start, rhs.start))
        if shared > 0 { return true }
        return (lhs.duration == 0 || rhs.duration == 0) && shared >= 0
    }

    /// Time between two recordings; zero when they touch or overlap.
    static func gapBetween(_ lhs: DateInterval, _ rhs: DateInterval) -> TimeInterval {
        let (first, second) = lhs.start <= rhs.start ? (lhs, rhs) : (rhs, lhs)
        return max(0, second.start.timeIntervalSince(first.end))
    }

    /// A recording's span; a missing or earlier end collapses to the start.
    static func span(start: Date, end: Date?) -> DateInterval {
        DateInterval(start: start, end: max(end ?? start, start))
    }

    /// An archived recording's span, from its index entry.
    static func span(of entry: SessionArchiveEntry) -> DateInterval {
        span(start: entry.date, end: entry.endDate)
    }

    /// A session's span: its end date, or its last beat when it has none.
    static func span(of session: HRVSession) -> DateInterval {
        span(start: session.startDate, end: session.endDate ?? session.rrSeries?.actualEndDate)
    }

    /// `items` in time order, split into runs wherever the next recording
    /// starts more than `gap` after the latest end so far in the run. Each run
    /// is one sleep under the merge-gap setting.
    static func runsWithinGap<Item>(
        _ items: [Item], gap: TimeInterval, span: (Item) -> DateInterval
    ) -> [[Item]] {
        var runs: [[Item]] = []
        var runEnd = Date.distantPast
        for item in items.sorted(by: { span($0).start < span($1).start }) {
            let itemSpan = span(item)
            if let last = runs.indices.last, itemSpan.start.timeIntervalSince(runEnd) <= gap {
                runs[last].append(item)
                runEnd = max(runEnd, itemSpan.end)
            } else {
                runs.append([item])
                runEnd = itemSpan.end
            }
        }
        return runs
    }

    // MARK: Common clock

    /// `points` moved `offsetMs` later on both the session clock and the
    /// wall clock.
    static func rebased(_ points: [RRPoint], by offsetMs: Int64) -> [RRPoint] {
        offsetMs == 0 ? points : points.map { $0.shifted(by: offsetMs) }
    }

    /// `points`, counted from `start`, re-counted from `clockStart`. The
    /// offset is the real time between the two starts.
    static func rebased(_ points: [RRPoint], from start: Date, onto clockStart: Date) -> [RRPoint] {
        rebased(points, by: MillisecondOffset.between(start, and: clockStart, fallback: 0))
    }

    /// The clock two recordings share: it starts at the earlier start.
    static func commonClockStart(of lhs: HRVSession, and rhs: HRVSession) -> Date {
        min(lhs.startDate, rhs.startDate)
    }
}
