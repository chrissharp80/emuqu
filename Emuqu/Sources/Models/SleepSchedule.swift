import Foundation

// Kept out of `UserSettings.swift` to hold that file under the
// 1,500-line debt budget; this is the obvious seam: `SleepSchedule` is a
// self-contained value type with no dependency on the rest of user settings,
// and it owns a cluster of subtle date arithmetic that is easier to reason
// about — and to test — on its own.
//
// Covered by `AcquisitionPureLogicTests`.

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

    /// Overnight window end: 4.5 hours after the wake that ends the night
    /// `overnightWindowStart` opens.
    ///
    /// Anchored on the window's own start, not on `date`'s calendar day. Taking
    /// the wake from `date`'s day and pushing it a day forward was right for an
    /// evening anchor and wrong for any anchor after midnight: a morning reading,
    /// a night started at 00:15, or `fetchLastNightSleep`'s start-of-day anchor
    /// got the NEXT night's wake, so the window held two nights and their sleep
    /// was added together whenever the second one had already happened.
    func overnightWindowEnd(relativeTo date: Date) -> Date {
        firstWake(after: overnightWindowStart(relativeTo: date)).addingTimeInterval(4.5 * 60 * 60)
    }

    /// Morning cutoff for the night that opens at `nightStart` (an
    /// `overnightWindowStart` result): that night's wake + 4 hours.
    func morningCutoff(forNightStartingAt nightStart: Date) -> Date {
        firstWake(after: nightStart).addingTimeInterval(4 * 60 * 60)
    }

    /// The first expected wake time strictly after `start`.
    private func firstWake(after start: Date) -> Date {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: start)
        let wake = calendar.date(bySettingHour: wakeHour, minute: wakeMinute, second: 0, of: dayStart) ?? dayStart
        return wake > start ? wake : (calendar.date(byAdding: .day, value: 1, to: wake) ?? wake)
    }

    /// Morning cutoff for the night `date` belongs to: that night's wake + 4
    /// hours. Anchored on `overnightWindowStart`, like `overnightWindowEnd`,
    /// so a reading after midnight gets this morning's cutoff, not tomorrow's.
    /// The baseline's morning-reading rule and the sleep fetch window read
    /// this one, so changing it changes which data feeds the score.
    func morningCutoff(relativeTo date: Date) -> Date {
        morningCutoff(forNightStartingAt: overnightWindowStart(relativeTo: date))
    }

    /// Daytime HR window start: 4 hours after the wake that opened the waking
    /// day leading into the night `date` belongs to (fully awake, past coffee).
    ///
    /// Both daytime bounds anchor on that night's `overnightWindowStart`, so
    /// a session that starts at 23:00 or at 01:00 reads the afternoon and
    /// evening BEFORE it, never a day that has not happened yet. Ordered for
    /// any schedule shorter than 19 hours of sleep.
    func daytimeHRStart(relativeTo date: Date) -> Date {
        wake(before: overnightWindowStart(relativeTo: date)).addingTimeInterval(4 * 60 * 60)
    }

    /// Daytime HR window end: bedtime − 1 hour (before winding down) on the
    /// evening the night opens. `overnightWindowStart` is bedtime − 2 hours.
    func daytimeHREnd(relativeTo date: Date) -> Date {
        overnightWindowStart(relativeTo: date).addingTimeInterval(60 * 60)
    }

    /// The last expected wake time strictly before `nightStart`.
    private func wake(before nightStart: Date) -> Date {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: nightStart)
        let wake = calendar.date(bySettingHour: wakeHour, minute: wakeMinute, second: 0, of: dayStart) ?? dayStart
        return wake < nightStart ? wake : (calendar.date(byAdding: .day, value: -1, to: wake) ?? wake)
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
        let end = overnightWindowStart(relativeTo: date) // this night's bedtime − 2h
        // + 4.5h matches overnightWindowEnd's offset — this is exactly where the
        // prior night's overnight window ends, so the nap window clears it and can
        // never claim a morning back-to-sleep that belongs to that night.
        let start = wake(before: end).addingTimeInterval(4.5 * 60 * 60)
        return (start, end)
    }

    /// Check whether a given date falls inside the overnight window
    func isInOvernightWindow(_ date: Date) -> Bool {
        let start = overnightWindowStart(relativeTo: date)
        let end = overnightWindowEnd(relativeTo: date)
        return date >= start && date <= end
    }

    /// Whether a session end time qualifies as a "morning reading": it falls
    /// inside its own night, between that night's window start and its wake
    /// + 4 hours. An afternoon end maps to the coming night, whose window has
    /// not opened yet, so it is not a morning reading.
    func isMorningReading(endDate: Date) -> Bool {
        let nightStart = overnightWindowStart(relativeTo: endDate)
        return endDate >= nightStart && endDate <= morningCutoff(forNightStartingAt: nightStart)
    }

    /// The wake date of the night `date` belongs to: the calendar day of the
    /// first expected wake after that night's window opens. A 23:30 start and
    /// a 00:30 start of the same night share it; it is the key the baseline
    /// uses for "one reading per night".
    func nightKey(for date: Date) -> Date {
        Calendar.current.startOfDay(for: firstWake(after: overnightWindowStart(relativeTo: date)))
    }
}
