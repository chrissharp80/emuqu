import Foundation

// MARK: - Duration formatting
//
// Durations shown to the user go through `LocalizedDuration`
// (NavigationHeader.swift), which follows the app's language. This English
// "1h 23m" form is only its fallback when the system formatter returns nil.

enum DurationFormatter {
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
