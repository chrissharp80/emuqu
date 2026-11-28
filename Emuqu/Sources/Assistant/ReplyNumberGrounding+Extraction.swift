import Foundation

/// The numbers a reply states, without the ones that are not measurements:
/// clock times, dates, years, ordinals, model names and small counts.
extension ReplyNumberGrounding {
    /// "4h12m", "4 h 12 min", "7 hours 30 minutes": one duration, in minutes.
    private static let compoundDuration = #"(\d+)\s*h(?:rs?|ours?)?\s*(\d+)\s*m(?:in(?:ute)?s?)?\b"#
    /// A number not glued to a letter, digit, dot, colon or slash before it.
    private static let statedNumberPattern = #"(?<![\p{L}\d.:/\-])\d+(?:\.\d+)?(?![\d:/]|\.\d)"#
    /// Units after a small number that make it a measurement, not a count.
    private static let measurementUnit = #"^\s*(?:%|percent|bpm|ms|km|mi|miles?|kilomet|met|m\b|ft|feet|kg|lb|°|degrees|w\b|watts|kcal|cal|breaths|beats|min|minutes|hours?|h\b|sec|seconds|points?)"#
    private static let nonMeasurementAfter = #"^(?:\s*(?:am|pm|a\.m\.|p\.m\.)\b|st\b|nd\b|rd\b|th\b|-\d)"#
    private static let monthName = #"(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?"#

    static func statedNumbers(in reply: String) -> [StatedNumber] {
        let durations = compoundDurations(in: reply)
        let taken = durations.map(\.range)
        let plain = plainMatches(in: reply).filter { match in !taken.contains { $0.overlaps(match) } }
        return durations.map(\.number) + plain.compactMap { statedNumber(at: $0, in: reply) }
    }

    private static func compoundDurations(in reply: String) -> [(range: Range<String.Index>, number: StatedNumber)] {
        guard let regex = DebugLogger.compiledPattern(compoundDuration, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: reply, range: NSRange(reply.startIndex..., in: reply)).compactMap { match in
            guard let whole = Range(match.range, in: reply), let hours = capture(1, of: match, in: reply),
                  let minutes = capture(2, of: match, in: reply) else { return nil }
            let total = hours * 60 + minutes
            let number = StatedNumber(text: String(reply[whole]), value: total, halfStep: 0.5, alternates: [total / 60, total * 60])
            return (whole, number)
        }
    }

    private static func capture(_ index: Int, of match: NSTextCheckingResult, in text: String) -> Double? {
        Range(match.range(at: index), in: text).flatMap { Double(text[$0]) }
    }

    private static func plainMatches(in reply: String) -> [Range<String.Index>] {
        guard let regex = DebugLogger.compiledPattern(statedNumberPattern) else { return [] }
        return regex.matches(in: reply, range: NSRange(reply.startIndex..., in: reply)).compactMap { Range($0.range, in: reply) }
    }

    /// The number at `range`, or nil when it is not a measurement.
    private static func statedNumber(at range: Range<String.Index>, in reply: String) -> StatedNumber? {
        let text = String(reply[range])
        guard let value = Double(text) else { return nil }
        let after = String(reply[range.upperBound...].prefix(14)).lowercased()
        let before = String(reply[..<range.lowerBound].suffix(12)).lowercased()
        if isNotAMeasurement(value: value, text: text, before: before, after: after) { return nil }
        let decimals = text.split(separator: ".").dropFirst().first?.count ?? 0
        return StatedNumber(text: text, value: value, halfStep: 0.5 * pow(10, -Double(decimals)), alternates: [], unit: unitWord(after: after))
    }

    private static func isNotAMeasurement(value: Double, text: String, before: String, after: String) -> Bool {
        if matches(nonMeasurementAfter, after) || matches(monthName + #"\s*$"#, before) || matches(#"^\s*"# + monthName, after) { return true }
        let wholeNumber = !text.contains(".")
        if wholeNumber, (1900 ... 2100).contains(value), !matches(measurementUnit, after) { return true }
        return wholeNumber && value <= 12 && !matches(measurementUnit, after)
    }

    /// The unit written right after a number: "mi" in "3.96 mi", "%" in "92%".
    private static func unitWord(after text: String) -> String {
        let trimmed = text.drop { $0 == " " }
        if trimmed.first == "%" { return "%" }
        return String(trimmed.prefix { $0.isLetter || $0 == "°" })
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = DebugLogger.compiledPattern(pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
