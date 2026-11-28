import Foundation

/// Number and date answers.
enum FloEvalNumberRules {
    static func number(_ expected: EvalJSON, reply: FloEvalReplyReader) -> FloEvalGrade {
        guard let value = expected["value"]?.number else { return FloEvalGrade(outcome: .needsReview, detail: "expected value is not a number") }
        let table = FloEvalTolerance.table(expected["tolerance"])
        let unit = expected["unit"]?.string ?? ""
        let found = FloEvalTolerance.within(
            value, of: candidates(unit: unit, reply: reply), tolerance: table["%"] ?? table[""] ?? 0, relative: table["%"] != nil
        )
        let missing = alsoRequiredMissing(expected["also_required"], reply: reply)
        let note = missing.isEmpty ? "" : "; also_required not stated: \(missing.joined(separator: ", "))"
        return FloEvalGrade(outcome: found ? .pass : .fail, detail: (found ? "value stated within tolerance" : "value not stated within tolerance") + note)
    }

    /// The reply's numbers in the expected unit: durations as minutes, and
    /// distances converted between kilometres and miles.
    static func candidates(unit: String, reply: FloEvalReplyReader) -> [Double] {
        let unit = unit.lowercased()
        let plain = reply.numbers
        if unit.contains("minute") { return plain + reply.durationMinutes }
        if unit == "km" { return plain + plain.map { $0 * FloEvalReplyReader.kmPerMile } }
        if unit.contains("mile") { return plain + plain.map { $0 / FloEvalReplyReader.kmPerMile } }
        return plain
    }

    static func date(_ expected: EvalJSON, reply: FloEvalReplyReader) -> FloEvalGrade {
        let days: [String] = switch expected["value"] {
        case let .string(day)?: [day]
        case let .array(items)?: items.compactMap(\.string)
        default: []
        }
        let missingDays = days.filter { !reply.names(day: $0) }
        let missingValues = alsoRequiredMissing(expected["also_required"], reply: reply)
        let passed = !days.isEmpty && missingDays.isEmpty && missingValues.isEmpty
        let detail = "dates not named: \(missingDays.count) of \(days.count); also_required not stated: \(missingValues.joined(separator: ", "))"
        return FloEvalGrade(outcome: passed ? .pass : .fail, detail: detail)
    }

    /// The `also_required` keys the reply does not state, its `tolerance` /
    /// `tolerance_s` entries read as the tolerance of the rest.
    static func alsoRequiredMissing(_ also: EvalJSON?, reply: FloEvalReplyReader) -> [String] {
        guard case let .object(fields)? = also else { return [] }
        let tolerance = fields["tolerance"]?.number ?? fields["tolerance_s"]?.number
        let table = tolerance.map { ["": $0, "s": $0, "ms": $0, "min": $0, "bpm": $0] } ?? [:]
        return fields.filter { !$0.key.hasPrefix("tolerance") }
            .filter { FloEvalLeaf(key: $0.key, value: $0.value).isStated(in: reply, table: table) != true }
            .map(\.key).sorted()
    }
}

/// Text and not-recorded answers.
enum FloEvalTextRules {
    /// The best grade over the expected value and its listed alternates.
    static func text(_ expected: EvalJSON, reply: FloEvalReplyReader) -> FloEvalGrade {
        let table = FloEvalTolerance.table(expected["tolerance"])
        var readings = [expected["value"]].compactMap { $0 }
        if case let .array(alternates)? = expected["alternates"] { readings += alternates }
        let grades = readings.map { grade($0, reply: reply, table: table) }
        return grades.max { $0.outcome < $1.outcome } ?? FloEvalGrade(outcome: .needsReview, detail: "no expected value")
    }

    /// Pass when every fact is stated and every fact could be checked, fail
    /// when none of the checkable facts is stated, review otherwise.
    private static func grade(_ value: EvalJSON, reply: FloEvalReplyReader, table: [String: Double]) -> FloEvalGrade {
        let results = FloEvalLeaf.leaves(of: value).map { $0.isStated(in: reply, table: table) }
        let checked = results.compactMap { $0 }
        let found = checked.filter { $0 }.count
        let unchecked = results.count - checked.count
        let detail = "stated \(found) of \(checked.count) checkable facts; \(unchecked) left for review"
        if checked.isEmpty { return FloEvalGrade(outcome: .needsReview, detail: detail) }
        if found == checked.count, unchecked == 0 { return FloEvalGrade(outcome: .pass, detail: detail) }
        return FloEvalGrade(outcome: found == 0 ? .fail : .needsReview, detail: detail)
    }

    /// Pass when the reply says the data is not recorded and states no
    /// value; review when it says so but states numbers beside it, which may
    /// be clearly labelled nearby data; fail otherwise.
    static func notRecorded(_ expected: EvalJSON, reply: FloEvalReplyReader, text: String) -> FloEvalGrade {
        guard reply.contains(any: refusalPhrases) else { return FloEvalGrade(outcome: .fail, detail: "does not say it is not recorded") }
        if !reply.matches(#"(calorie|kcal|vo2|steps|cadence|spm)[^.\n]{0,30}?\d|\d[\d,.]*\s*(kcal|calories|steps|spm)\b"#).isEmpty {
            return FloEvalGrade(outcome: .fail, detail: "gives a value for the thing not recorded")
        }
        let stated = FloEvalGraderNumbers.statedCount(text)
        return stated == 0
            ? FloEvalGrade(outcome: .pass, detail: "says it is not recorded and states no value")
            : FloEvalGrade(outcome: .needsReview, detail: "says it is not recorded, and states \(stated) numbers beside it")
    }

    static let refusalPhrases = [
        "not recorded", "isn't recorded", "wasn't recorded", "weren't recorded", "no recording", "no recorded", "not tracked", "doesn't track",
        "don't track", "does not track", "isn't tracked", "no data", "don't have", "do not have", "doesn't have", "does not have", "not available",
        "isn't available", "unavailable", "nothing recorded", "didn't record", "did not record", "no overnight", "no workout", "not stored",
        "doesn't record", "does not record", "doesn't measure", "does not measure", "isn't measured", "not measured", "can't find", "couldn't find",
        "could not find", "no record", "there's no", "there is no", "there was no", "there were no", "wasn't any", "weren't any", "only records",
        "only recorded", "not captured", "isn't captured", "doesn't capture", "does not capture", "no such", "missing", "not logged", "wasn't logged",
        "doesn't collect", "does not collect", "not collected", "no reading", "not part of", "isn't something", "not something"
    ]
}

/// One expected fact: a key path and its value.
struct FloEvalLeaf {
    let key: String
    let value: EvalJSON

    /// Every fact in an expected value. A Fahrenheit or miles twin of a
    /// Celsius or kilometre fact is left out: either unit states the fact.
    static func leaves(of value: EvalJSON, key: String = "") -> [FloEvalLeaf] {
        switch value {
        case let .object(fields):
            return fields.filter { !isUnitTwin($0.key, in: fields) }.sorted { $0.key < $1.key }
                .flatMap { leaves(of: $0.value, key: key.isEmpty ? $0.key : key + "." + $0.key) }
        case let .array(items):
            return items.flatMap { leaves(of: $0, key: key) }
        case .null:
            return []
        default:
            return [FloEvalLeaf(key: key, value: value)]
        }
    }

    private static func isUnitTwin(_ key: String, in fields: [String: EvalJSON]) -> Bool {
        (key.hasSuffix("_f") && fields[String(key.dropLast(2)) + "_c"] != nil) || (key == "miles" && fields["km"] != nil)
    }

    /// Whether the reply states this fact; nil when it cannot be checked in words.
    func isStated(in reply: FloEvalReplyReader, table: [String: Double]) -> Bool? {
        switch value {
        case let .number(number):
            let tolerance = FloEvalTolerance.forKey(key, in: table, value: number)
            return FloEvalTolerance.within(number, of: Self.candidates(key: key, reply: reply), tolerance: tolerance)
        case let .string(text):
            return FloEvalWords.isStated(text, key: key, reply: reply, table: table)
        case let .bool(flag):
            return flag ? reply.contains(any: [key.split(separator: ".").last.map(String.init) ?? key]) : nil
        default:
            return nil
        }
    }

    /// The reply's numbers read in this fact's unit.
    static func candidates(key: String, reply: FloEvalReplyReader) -> [Double] {
        let key = key.lowercased()
        let plain = reply.numbers
        if key.contains("pace") || key.contains("s_per_km") { return reply.paceSecondsPerKm + plain }
        if key.contains("min") || key.contains("sleep") || key.contains("duration") { return plain + reply.durationMinutes }
        if key.contains("temp") { return plain + plain.map { ($0 - 32) * 5 / 9 } + plain.map { $0 * 9 / 5 + 32 } }
        if key.contains("km") { return plain + plain.map { $0 * FloEvalReplyReader.kmPerMile } }
        return plain
    }
}

/// String facts: clock times, paces, durations, dates and words.
enum FloEvalWords {
    static func isStated(_ text: String, key: String, reply: FloEvalReplyReader, table: [String: Double]) -> Bool? {
        let probe = FloEvalReplyReader(text)
        if text.wholeMatch(of: #/\d{1,2}:\d{2}/#) != nil, let target = probe.clockMinutes.first {
            return reply.clockMinutes.contains { clockDistance($0, target) <= (table["min"] ?? table[""] ?? 5) + 1e-9 }
        }
        if let pace = probe.paceSecondsPerKm.first {
            return FloEvalTolerance.within(pace, of: reply.paceSecondsPerKm, tolerance: table["s"] ?? table[""] ?? 3)
        }
        if text.wholeMatch(of: #/\d+:\d{2}:\d{2}/#) != nil, let minutes = probe.durationMinutes.first {
            return FloEvalTolerance.within(minutes, of: reply.durationMinutes, tolerance: 0.5)
        }
        if text.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil { return reply.names(day: text) }
        return words(text, reply: reply)
    }

    /// A word fact: a direction, a factor, a tag, a month or a short name.
    /// A sentence-long fact ("HRV was not 85") is left for review.
    private static func words(_ text: String, reply: FloEvalReplyReader) -> Bool? {
        let lowered = text.lowercased()
        if let synonyms = synonyms[lowered] { return reply.contains(any: synonyms) }
        let parts = lowered.replacingOccurrences(of: "_", with: " ").split(separator: " ").map(String.init)
        guard parts.count <= 2 else { return nil }
        return parts.allSatisfy { reply.contains(any: [$0]) }
    }

    private static let synonyms: [String: [String]] = [
        "up": ["up", "increas", "rose", "rising", "higher", "improv", "climb"],
        "down": ["down", "decreas", "fell", "falling", "lower", "dropped", "declin"],
        "hrv_vs_baseline_points": ["hrv", "rmssd", "heart rate variability"],
        "resting_hr_vs_baseline_points": ["resting"],
        "sleep_duration_points": ["sleep"],
        "prior_day_training_load_points": ["training", "load", "workout"],
        "sick": ["sick", "ill"],
        "stress": ["stress"]
    ]

    /// Minutes between two clock times, the shorter way round midnight.
    static func clockDistance(_ first: Double, _ second: Double) -> Double {
        let gap = abs(first - second).truncatingRemainder(dividingBy: 1440)
        return min(gap, 1440 - gap)
    }
}
