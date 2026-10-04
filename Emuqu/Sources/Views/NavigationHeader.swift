import Foundation

// MARK: - Localized duration

/// Locale-aware "1h 23m" / "45 min" formatting for the
/// view layer. The shared `DurationFormatter` in Utilities hardcodes
/// English "h"/"m"/"min"; that file is owned elsewhere, so the View
/// surfaces route through `DateComponentsFormatter`, which renders the
/// unit abbreviations in the user's language automatically.
enum LocalizedDuration {
    /// "1h 23m" (or "23m"), rounded to whole minutes. Falls back to the
    /// non-localized form only if the formatter returns nil.
    static func hoursMinutes(minutes: Int) -> String {
        let secs = TimeInterval(max(0, minutes) * 60)
        return formatter([.hour, .minute]).string(from: secs) ?? DurationFormatter.hoursMinutes(minutes: minutes)
    }

    /// "45 min" — minutes only, spelled with a localized abbreviation.
    static func minutes(_ minutes: Int) -> String {
        let secs = TimeInterval(max(0, minutes) * 60)
        return formatter([.minute]).string(from: secs) ?? "\(max(0, minutes)) min"
    }

    /// "7h" — whole hours only.
    static func hours(_ hours: Int) -> String {
        formatter([.hour]).string(from: TimeInterval(max(0, hours) * 3600)) ?? "\(max(0, hours))h"
    }

    /// Built per call, in the app language rather than the phone's: a cached
    /// formatter kept whichever locale it first saw.
    private static func formatter(_ units: NSCalendar.Unit) -> DateComponentsFormatter {
        let f = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = LanguageManager.appLocale
        f.calendar = calendar
        f.allowedUnits = units
        f.unitsStyle = .abbreviated // "1h 23m" — units localized by the OS
        f.zeroFormattingBehavior = .dropLeading
        return f
    }
}
