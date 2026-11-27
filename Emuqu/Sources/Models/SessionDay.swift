import Foundation

/// The day a reading belongs to, wherever it is listed, drawn or counted. An
/// overnight belongs to the morning it ended: its sleep end, else the end of
/// the recording, so a night begun at 23:00 shares a day with the feeling
/// rated on waking, and a recording left running past waking does not move
/// it. Any other reading belongs to the day it started.
enum SessionDay {
    static func date(of session: HRVSession) -> Date {
        guard session.sessionType == .overnight else { return session.startDate }
        return session.sleepEndDate ?? session.endDate ?? session.startDate
    }

    /// The same rule on the archive index, which mirrors the session's sleep
    /// end (`SessionArchiveEntry.sleepEnd`).
    static func date(of entry: SessionArchiveEntry) -> Date {
        guard entry.sessionType == .overnight else { return entry.date }
        return entry.sleepEnd ?? entry.endDate ?? entry.date
    }
}

extension HRVSession {
    /// When the night's sleep ended: the sleep snapshot's own end, else the
    /// stored offset from the start. A zero offset is no sleep end.
    var sleepEndDate: Date? {
        if let snapshotEnd = sleepSnapshot?.sleepEnd { return snapshotEnd }
        guard let endMs = sleepEndMs, endMs > 0 else { return nil }
        return startDate.addingTimeInterval(TimeInterval(endMs) / 1000)
    }

    /// The clock time of a `t_ms` position (an analysis window, the nadir, a
    /// chart point): the beats' own clock (`RRSeries.clockTime(forTMs:)`)
    /// when `series` holds them, so a streamed night with a dropout shows
    /// when they happened; the start plus the offset when the beats are not
    /// loaded (a lightweight session).
    func clockTime(forTMs tMs: Int64, series: RRSeries?) -> Date {
        series?.clockTime(forTMs: tMs) ?? startDate.addingTimeInterval(TimeInterval(tMs) / 1000)
    }
}
