import Foundation

/// Calendar periods named by their dates, so a question about a past stretch
/// ("last February", "Feb 1 to Feb 20", "since March") reads only that
/// stretch instead of a rolling window ending now.
///
/// Accepted forms (local days, Gregorian calendar, ASCII digits):
///   • `YYYY-MM`                  that calendar month
///   • `YYYY`                     that calendar year
///   • `YYYY-MM-DD`               that one local day
///   • `YYYY-MM-DD..YYYY-MM-DD`   both days inclusive
///   • `since_YYYY-MM-DD`         from that day's start until now
///
/// Each interval ends at the start of the day after its last day, so
/// `DateInterval.containsBeforeEnd` keeps the last day and nothing after.
extension PeriodParser {
    /// The interval an explicit form names, or nil when `key` is not one.
    static func explicitInterval(_ key: String, now: Date) -> DateInterval? {
        if key.hasPrefix("since_") {
            guard let start = day(String(key.dropFirst("since_".count))), start <= now else { return nil }
            return DateInterval(start: start, end: now)
        }
        if let separator = key.range(of: "..") {
            return dayRange(String(key[..<separator.lowerBound]), String(key[separator.upperBound...]))
        }
        if key.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil { return dayRange(key, key) }
        if key.wholeMatch(of: #/\d{4}-\d{2}/#) != nil { return span(of: .month, startingOn: key + "-01") }
        if key.wholeMatch(of: #/\d{4}/#) != nil { return span(of: .year, startingOn: key + "-01-01") }
        return nil
    }

    /// First to last day inclusive; nil when either is not a date or the
    /// last comes before the first.
    private static func dayRange(_ first: String, _ last: String) -> DateInterval? {
        guard let start = day(first), let lastDay = day(last), start <= lastDay,
              let end = localDayCalendar.date(byAdding: .day, value: 1, to: lastDay)
        else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// The month or year that begins on `firstDay`.
    private static func span(of component: Calendar.Component, startingOn firstDay: String) -> DateInterval? {
        guard let start = day(firstDay), let end = localDayCalendar.date(byAdding: component, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// The start of a `yyyy-MM-dd` local day; nil for anything else.
    private static func day(_ iso: String) -> Date? {
        let trimmed = iso.trimmingCharacters(in: .whitespaces)
        guard trimmed.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil,
              let parsed = FactLocalDay.formatter().date(from: trimmed)
        else { return nil }
        return localDayCalendar.startOfDay(for: parsed)
    }

    /// The calendar `FactLocalDay` parses with, in the device's time zone.
    private static var localDayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}
