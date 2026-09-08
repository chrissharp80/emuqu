import Foundation

// Kept out of `UserSettings.swift` to hold that file under the
// 1,500-line debt budget; this is the obvious seam: `SleepSchedule` is a
// self-contained value type with no dependency on the rest of user settings,
// and it owns a cluster of subtle date arithmetic that is easier to reason
// about — and to test — on its own.
//
// Covered by `AcquisitionPureLogicTests`, which is where the inverted
// `daytimeHREnd` window was caught.

/// Derived sleep schedule times, computed from bedtime + typical sleep hours.
/// All times are relative to a reference date — pass to HealthKitManager and views
/// instead of using hardcoded clock assumptions.
struct SleepSchedule {
    /// Hour (0-23) and minute of expected bedtime
    let bedtimeHour: Int
    let bedtimeMinute: Int

    /// Hours of typical sleep
    let sleepHours: Double

    /// Expected wake hour/minute (bedtime + sleepHours)
    var wakeHour: Int {
        let totalMinutes = bedtimeHour * 60 + bedtimeMinute + Int(sleepHours * 60)
        return (totalMinutes / 60) % 24
    }

    var wakeMinute: Int {
        let totalMinutes = bedtimeHour * 60 + bedtimeMinute + Int(sleepHours * 60)
        return totalMinutes % 60
    }

    /// Overnight window start: 2 hours before bedtime (buffer for early nights).
    /// Two sessions belong to the same biological night when this function returns
    /// the same anchor date for both. For AM bedtimes (e.g., 2 AM) a pre-midnight
    /// session and a post-midnight session must still map to the same anchor, so we
    /// guard against the gap exceeding 18 hours.
    ///
    /// For AM bedtimes: bedtime−2h can land on the same calendar day as the
    /// session but actually belong to the PREVIOUS biological night. When the
    /// computed anchor is more than 18 hours before the session, bump it forward
    /// one day so that a pre-midnight recording and a next-morning recording
    /// share the same anchor.
    ///
    /// The bump must NOT be made conditional on the result still preceding
    /// `date`, on the theory that an anchor cannot follow the session it
    /// anchors. That is wrong here, and the regression tests pin it. For an
    /// AM bedtime (say 02:00) the night containing a
    /// 23:00 reading STARTS at 00:00 the following day, because the window
    /// opens at bedtime−2h. So the anchor legitimately falls after a
    /// pre-bedtime session: the reading belongs to the night that has not
    /// started yet. Making the bump conditional splits that 23:00 reading from
    /// the 03:00 reading four hours later, which is exactly the grouping this
    /// guard exists to preserve.
    func overnightWindowStart(relativeTo date: Date) -> Date {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        var start = calendar.date(bySettingHour: bedtimeHour, minute: bedtimeMinute, second: 0, of: dayStart) ?? dayStart
        start = start.addingTimeInterval(-2 * 60 * 60)
        if start > date {
            start = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        }
        if date.timeIntervalSince(start) > 18 * 3600 {
            start = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        }
        return start
    }

    /// Overnight window end: 4.5 hours after expected wake time
    func overnightWindowEnd(relativeTo date: Date) -> Date {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        var wake = calendar.date(bySettingHour: wakeHour, minute: wakeMinute, second: 0, of: dayStart) ?? dayStart
        if wakeHour < bedtimeHour || (wakeHour == bedtimeHour && wakeMinute <= bedtimeMinute) {
            wake = calendar.date(byAdding: .day, value: 1, to: wake) ?? wake
        }
        return wake.addingTimeInterval(4.5 * 60 * 60)
    }

    /// Morning cutoff: expected wake + 4 hours. Sessions ending before this are "morning" readings.
    func morningCutoff(relativeTo date: Date) -> Date {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        var wake = calendar.date(bySettingHour: wakeHour, minute: wakeMinute, second: 0, of: dayStart) ?? dayStart
        if wakeHour < bedtimeHour || (wakeHour == bedtimeHour && wakeMinute <= bedtimeMinute) {
            wake = calendar.date(byAdding: .day, value: 1, to: wake) ?? wake
        }
        return wake.addingTimeInterval(4 * 60 * 60)
    }

    /// Daytime HR window start: expected wake + 4 hours (fully awake, past coffee)
    func daytimeHRStart(relativeTo date: Date) -> Date {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        var wake = calendar.date(bySettingHour: wakeHour, minute: wakeMinute, second: 0, of: dayStart) ?? dayStart
        if wakeHour < bedtimeHour || (wakeHour == bedtimeHour && wakeMinute <= bedtimeMinute) {
            wake = calendar.date(byAdding: .day, value: 1, to: wake) ?? wake
        }
        return wake.addingTimeInterval(4 * 60 * 60)
    }

    /// Daytime HR window end: bedtime - 1 hour (before winding down)
    /// Uses the same day-shift logic as `daytimeHRStart` to ensure the
    /// window end is always after the window start.
    ///
    /// Why the bounds share one anchor: shifting them independently INVERTS
    /// this window for every normal schedule, including the shipped default
    /// (22:00 bedtime, 8 h sleep).
    ///
    /// `daytimeHRStart` shifts wake forward a day when `wakeHour <
    /// bedtimeHour` (the ordinary "sleep through midnight" case), so for the
    /// default it returns wake+4h on day D+1. Code that does NOT shift bedtime
    /// in that same branch returns bedtime−1h on day D — a full day *earlier*
    /// than the start.
    ///
    /// `fetchDaytimeRestingHR` feeds both bounds straight into
    /// `HKQuery.predicateForSamples(withStart:end:)`. An inverted range
    /// matches nothing, the `count >= 10` guard then returns nil, and the
    /// caller treats daytime resting HR as an optional refinement that is
    /// simply absent. So the inversion fails silently, for everyone,
    /// permanently: nothing crashes and no number looks wrong, a contributing
    /// signal is just never there.
    ///
    /// The window is derived from a single anchor instead of two
    /// independently-shifted ones: take the same wake instant
    /// `daytimeHRStart` uses, then find the bedtime that FOLLOWS it — later
    /// the same day for a 22:00 bedtime, the following calendar day for an
    /// 02:00 one. Ordered by construction, for every schedule.
    func daytimeHREnd(relativeTo date: Date) -> Date {
        let calendar = Calendar.current
        let wake = wakeInstant(relativeTo: date, calendar: calendar)
        let wakeDayStart = calendar.startOfDay(for: wake)
        var bedtime = calendar.date(
            bySettingHour: bedtimeHour, minute: bedtimeMinute, second: 0, of: wakeDayStart
        ) ?? wakeDayStart
        if bedtime <= wake {
            bedtime = calendar.date(byAdding: .day, value: 1, to: bedtime) ?? bedtime
        }
        return bedtime.addingTimeInterval(-1 * 60 * 60)
    }

    /// The wake instant this schedule implies for `date`, shared by
    /// `morningCutoff`, `daytimeHRStart` and `daytimeHREnd` so all three anchor
    /// to the same moment. Recomputing it inline in each is how `daytimeHREnd`
    /// drifts out of step with `daytimeHRStart`.
    private func wakeInstant(relativeTo date: Date, calendar: Calendar) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        var wake = calendar.date(
            bySettingHour: wakeHour, minute: wakeMinute, second: 0, of: dayStart
        ) ?? dayStart
        if wakeHour < bedtimeHour || (wakeHour == bedtimeHour && wakeMinute <= bedtimeMinute) {
            wake = calendar.date(byAdding: .day, value: 1, to: wake) ?? wake
        }
        return wake
    }

    /// Daytime-nap search window for the waking day that leads into the night
    /// anchored at `date` (that night's bedtime). It is the clean daytime GAP
    /// *between* two nights' overnight windows: it starts at the PRIOR night's
    /// overnight-window end (this morning's wake + 4.5h) and ends at this night's
    /// overnight-window start (bedtime − 2h). Because both bounds are the actual
    /// overnight-window edges, a nap can never share clock time with either
    /// night's sleep — a morning "back-to-sleep" belongs to the night, not a nap.
    /// A very early bedtime / long schedule can make the window empty or inverted;
    /// callers treat `end <= start` as "no nap".
    func daytimeNapWindow(relativeTo date: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let end = overnightWindowStart(relativeTo: date) // this night's bedtime − 2h
        let dayStart = calendar.startOfDay(for: end)
        var wake = calendar.date(bySettingHour: wakeHour, minute: wakeMinute, second: 0, of: dayStart) ?? dayStart
        if wake >= end {
            wake = calendar.date(byAdding: .day, value: -1, to: wake) ?? wake
        }
        // + 4.5h matches overnightWindowEnd's offset — this is exactly where the
        // prior night's overnight window ends, so the nap window clears it and can
        // never claim a morning back-to-sleep that belongs to that night.
        let start = wake.addingTimeInterval(4.5 * 60 * 60)
        return (start, end)
    }

    /// Check whether a given date falls inside the overnight window
    func isInOvernightWindow(_ date: Date) -> Bool {
        let start = overnightWindowStart(relativeTo: date)
        let end = overnightWindowEnd(relativeTo: date)
        return date >= start && date <= end
    }

    /// Whether a session end time qualifies as a "morning reading"
    func isMorningReading(endDate: Date) -> Bool {
        let cutoff = morningCutoff(relativeTo: endDate)
        return endDate <= cutoff
    }
}
