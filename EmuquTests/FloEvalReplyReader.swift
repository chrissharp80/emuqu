@testable import Emuqu
import Foundation

/// The values a reply states, read the ways a person writes them: plain
/// numbers, durations ("6h 56m", "6:56", "416 minutes"), clock times
/// ("10:50 pm", "22:50"), paces ("5:23 /km", "8:40 per mile") and dates
/// (a month name and day, a yyyy-MM-dd day, or month/day).
struct FloEvalReplyReader {
    let text: String
    private let lowered: String

    init(_ text: String) {
        self.text = text
        lowered = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    static let kmPerMile = 1.609344

    // MARK: - Numbers

    /// Every plain number, the parts of "6:56" and "5:23" included.
    var numbers: [Double] {
        matches(#"(?<![\d.])-?\d+(?:\.\d+)?"#).compactMap { Double($0[0]) }
    }

    /// Durations in minutes: "6h 56m", "6 hours and 56 minutes", "6.9 hours",
    /// "416 minutes", "6:56" read as hours and minutes, and "42:13" or
    /// "0:42:13" read as a workout's minutes and seconds.
    var durationMinutes: [Double] {
        let compound = matches(#"(\d+)\s*h(?:ours?|rs?)?\.?\s*(?:and\s*)?(\d+)\s*m"#).compactMap { pair($0).map { $0 * 60 + $1 } }
        let hours = matches(#"(\d+(?:\.\d+)?)\s*(?:hours?|hrs?|h)\b"#).compactMap { Double($0[1]).map { $0 * 60 } }
        let minutes = matches(#"(\d+(?:\.\d+)?)\s*(?:minutes?|mins?|m)\b"#).compactMap { Double($0[1]) }
        let colon = matches(#"(?<![\d:])(\d{1,2}):(\d{2})(?![\d:])"#).compactMap { pair($0) }.flatMap { [$0 * 60 + $1, $0 + $1 / 60] }
        let long = matches(#"(\d{1,2}):(\d{2}):(\d{2})"#).compactMap(threeParts).map { $0 * 60 + $1 + $2 / 60 }
        return compound + hours + minutes + colon + long
    }

    /// Clock times as minutes after midnight, 12-hour times converted.
    var clockMinutes: [Double] {
        let colon = matches(#"(\d{1,2}):(\d{2})\s*(a\.?m\.?|p\.?m\.?)?"#).compactMap { clock(hour: $0[1], minute: $0[2], marker: $0[3]) }
        let bare = matches(#"(?<![\d:])(\d{1,2})\s*(a\.?m\.?|p\.?m\.?)"#).compactMap { clock(hour: $0[1], minute: "0", marker: $0[2]) }
        return colon + bare
    }

    /// Paces as seconds per kilometre; a pace per mile is converted.
    var paceSecondsPerKm: [Double] {
        let pattern = #"(\d{1,2}):(\d{2})\s*(?:min(?:utes)?\s*)?(?:/|per)\s*(km|kilomet|k\b|mi|mile)"#
        return matches(pattern).compactMap { groups in
            guard let parts = pair(groups) else { return nil }
            let seconds = parts.0 * 60 + parts.1
            return groups[3].hasPrefix("m") ? seconds / Self.kmPerMile : seconds
        }
    }

    // MARK: - Dates

    /// Every month and day named, as "MM-dd".
    var monthDays: Set<String> {
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let named = matches(#"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b"#)
            .compactMap { monthDay(month: months.firstIndex(of: $0[1]), day: $0[2]) }
        let dayFirst = matches(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)"#)
            .compactMap { monthDay(month: months.firstIndex(of: $0[2]), day: $0[1]) }
        let iso = matches(#"\b\d{4}-(\d{2})-(\d{2})\b"#).compactMap { monthDay(month: Int($0[1]).map { $0 - 1 }, day: $0[2]) }
        let slash = matches(#"(?<![\d/])(\d{1,2})/(\d{1,2})(?![\d/])"#).compactMap { monthDay(month: Int($0[1]).map { $0 - 1 }, day: $0[2]) }
        return Set(named + dayFirst + iso + slash)
    }

    /// Whether the reply names this `yyyy-MM-dd` day.
    func names(day iso: String) -> Bool {
        monthDays.contains(String(iso.suffix(5)))
    }

    // MARK: - Words

    func contains(any words: [String]) -> Bool {
        words.contains { lowered.contains($0) }
    }

    // MARK: - Matching

    /// Each match's capture groups; group 0 is the whole match, and a group
    /// that did not take part is "".
    func matches(_ pattern: String) -> [[String]] {
        guard let regex = DebugLogger.compiledPattern(pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(lowered.startIndex..., in: lowered)
        return regex.matches(in: lowered, range: range).map { match in
            (0 ..< match.numberOfRanges).map { index in
                Range(match.range(at: index), in: lowered).map { String(lowered[$0]) } ?? ""
            }
        }
    }

    private func pair(_ groups: [String]) -> (Double, Double)? {
        guard groups.count > 2, let first = Double(groups[1]), let second = Double(groups[2]) else { return nil }
        return (first, second)
    }

    private func threeParts(_ groups: [String]) -> (Double, Double, Double)? {
        guard groups.count > 3, let first = Double(groups[1]), let second = Double(groups[2]), let third = Double(groups[3]) else { return nil }
        return (first, second, third)
    }

    private func clock(hour: String, minute: String, marker: String) -> Double? {
        guard var hours = Double(hour), let minutes = Double(minute), hours < 24, minutes < 60 else { return nil }
        if marker.hasPrefix("p"), hours < 12 { hours += 12 }
        if marker.hasPrefix("a"), hours == 12 { hours = 0 }
        return hours * 60 + minutes
    }

    private func monthDay(month: Int?, day: String) -> String? {
        guard let month, (0 ..< 12).contains(month), let day = Int(day), (1 ... 31).contains(day) else { return nil }
        return String(format: "%02d-%02d", month + 1, day)
    }
}
