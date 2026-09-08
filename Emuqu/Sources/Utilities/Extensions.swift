import Foundation

// MARK: - Duration formatting
//
// The single home for duration formatting. Prefer these over new local
// re-implementations; parallel copies drift.

enum DurationFormatter {
    /// "1h 23m 45s" / "23m 45s" / "45s". Seconds are included whenever
    /// the duration is under an hour and greater than zero so short
    /// intervals are readable ("45s", not empty).
    static func hms(seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return sec > 0 ? "\(h)h \(m)m \(sec)s" : "\(h)h \(m)m"
        }
        if m > 0 {
            return sec > 0 ? "\(m)m \(sec)s" : "\(m)m"
        }
        return "\(sec)s"
    }

    /// "1:23:45" / "23:45" — colon-separated digital clock formatting for
    /// live timers where brevity matters more than readability.
    static func clock(seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }

    /// Accept a TimeInterval (Double seconds) as a convenience.
    static func hms(seconds: TimeInterval) -> String {
        hms(seconds: Int(seconds.rounded()))
    }

    static func clock(seconds: TimeInterval) -> String {
        clock(seconds: Int(seconds.rounded()))
    }

    /// "1h 23m" rounded to whole minutes. For long durations (overnight
    /// sleep, multi-hour rides) where seconds add noise.
    static func hoursMinutes(minutes: Int) -> String {
        let m = max(0, minutes)
        let h = m / 60
        let mm = m % 60
        if h > 0 {
            return mm > 0 ? "\(h)h \(mm)m" : "\(h)h"
        }
        return "\(mm)m"
    }

    static func hoursMinutes(hours: Double) -> String {
        hoursMinutes(minutes: Int((hours * 60).rounded()))
    }
}

// MARK: - Optional Comparisons

extension Optional where Wrapped: Comparable {
    /// Returns true if self is nil or self < value
    func isNilOrLessThan(_ value: Wrapped) -> Bool {
        guard let unwrapped = self else { return true }
        return unwrapped < value
    }

    /// Returns true if self is nil or self > value
    func isNilOrGreaterThan(_ value: Wrapped) -> Bool {
        guard let unwrapped = self else { return true }
        return unwrapped > value
    }

    /// Update self to the minimum of current value and new value
    mutating func updateMin(_ value: Wrapped) {
        if isNilOrGreaterThan(value) {
            self = value
        }
    }

    /// Update self to the maximum of current value and new value
    mutating func updateMax(_ value: Wrapped) {
        if isNilOrLessThan(value) {
            self = value
        }
    }
}

// MARK: - Collection Statistics

extension Collection where Element: BinaryFloatingPoint {
    /// Calculate the average of all elements, or nil if empty
    var average: Element? {
        guard !isEmpty else { return nil }
        let sum = reduce(0, +)
        return sum / Element(count)
    }

    /// Calculate the sum of all elements
    var sum: Element {
        reduce(0, +)
    }
}

// MARK: - Number Formatting

extension Double {
    /// Format with specified decimal places
    func formatted(decimals: Int) -> String {
        String(format: "%.\(decimals)f", self)
    }

    /// Format as percentage (e.g., 0.85 -> "85%")
    var asPercentage: String {
        String(format: "%.0f%%", self * 100)
    }
}

// MARK: - Duration Formatting

extension TimeInterval {
    /// Format as hours and minutes (e.g., "7h 30m")
    var asHoursMinutes: String {
        let totalMinutes = Int(self / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

extension Int {
    /// Format minutes as hours and minutes (e.g., 450 -> "7h 30m")
    var minutesAsHoursMinutes: String {
        let hours = self / 60
        let minutes = self % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - Safe Array Access

extension Array {
    /// Safely access element at index, returning nil if out of bounds
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Date Helpers

extension Date {
    /// Start of day for this date
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    /// Add hours to date
    func addingHours(_ hours: Int) -> Date {
        Calendar.current.date(byAdding: .hour, value: hours, to: self) ?? self
    }

    /// Add days to date
    func addingDays(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: self) ?? self
    }

    /// Add minutes to date
    func addingMinutes(_ minutes: Int) -> Date {
        Calendar.current.date(byAdding: .minute, value: minutes, to: self) ?? self
    }

    /// Hour component of the date
    var hour: Int {
        Calendar.current.component(.hour, from: self)
    }

    /// Check if date is in the overnight window based on user's sleep schedule.
    /// Prefer using SleepSchedule.isInOvernightWindow(_:) directly when available.
    func isInOvernightWindow(schedule: SleepSchedule) -> Bool {
        schedule.isInOvernightWindow(self)
    }
}

// MARK: - String Helpers

extension String {
    /// Truncate to specified length with ellipsis
    func truncated(to length: Int) -> String {
        if count <= length {
            return self
        }
        return String(prefix(length - 1)) + "…"
    }
}

// MARK: - Shared Date Formatters

/// Shared DateFormatter instances to avoid repeated allocations.
/// Call `updateLocale(_:)` after an in-app language change so that
/// locale-sensitive formats (month names, AM/PM) refresh immediately.
enum SharedDateFormatters {
    /// Time format: "h:mm a" (e.g., "10:30 PM")
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    /// Debug timestamp format: "yyyy-MM-dd HH:mm:ss.SSS"
    static let debugFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Short date format: "MMM d" (e.g., "Jan 15")
    static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    /// Full date format: "MMMM d, yyyy" (e.g., "January 15, 2026")
    static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    /// Date and time format: "MMM d, h:mm a" (e.g., "Jan 15, 10:30 PM")
    static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()

    /// Hour only format: "ha" (e.g., "10PM")
    static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "ha"
        return formatter
    }()

    /// Update the locale on all cached formatters after an in-app language change.
    static func updateLocale(_ locale: Locale) {
        timeFormatter.locale = locale
        shortDateFormatter.locale = locale
        fullDateFormatter.locale = locale
        dateTimeFormatter.locale = locale
        hourFormatter.locale = locale
        // debugFormatter intentionally excluded — it uses fixed-width fields
    }
}

extension Date {
    /// Format as time string (e.g., "10:30 PM")
    var asTimeString: String {
        SharedDateFormatters.timeFormatter.string(from: self)
    }

    /// Format as short date (e.g., "Jan 15")
    var asShortDate: String {
        SharedDateFormatters.shortDateFormatter.string(from: self)
    }

    /// Format as full date (e.g., "January 15, 2026")
    var asFullDate: String {
        SharedDateFormatters.fullDateFormatter.string(from: self)
    }

    /// Format as date and time (e.g., "Jan 15, 10:30 PM")
    var asDateTime: String {
        SharedDateFormatters.dateTimeFormatter.string(from: self)
    }
}

// MARK: - Sleep Duration Helpers

extension Int {
    /// Convert total minutes to hours (Double)
    var minutesAsHours: Double {
        Double(self) / 60.0
    }
}

// MARK: - Tag Lookup

extension Set<ReadingTag> {
    /// Check if the set contains a tag with the given name
    /// - Parameter name: The name to search for (case-sensitive)
    /// - Returns: true if a tag with that name exists
    func contains(tagNamed name: String) -> Bool {
        contains(where: { $0.name == name })
    }

    /// Get the tag with the given name, if it exists
    /// - Parameter name: The name to search for (case-sensitive)
    /// - Returns: The tag, or nil if not found
    func tag(named name: String) -> ReadingTag? {
        first(where: { $0.name == name })
    }
}

// MARK: - Bundle Extensions

extension Bundle {
    /// App version string (e.g., "1.0.0")
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    /// App build number (e.g., "42")
    var appBuild: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    /// Combined version and build string (e.g., "1.0.0 (42)")
    var appVersionString: String {
        "\(appVersion) (\(appBuild))"
    }
}

// MARK: - HRV Session Extensions

extension [HRVSession] {
    /// Filter to only valid completed sessions with analysis results
    var validSessions: [HRVSession] {
        filter { $0.state == .complete && $0.analysisResult != nil }
    }

    /// Extract RMSSD values from valid sessions
    var rmssdValues: [Double] {
        compactMap(\.rmssd)
    }
}
