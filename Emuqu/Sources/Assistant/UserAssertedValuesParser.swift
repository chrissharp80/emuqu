import Foundation

/// Detects user-correction signals from recent conversation turns.
///
/// # The pattern this codifies
///
/// Voice-assistant research (Cuadra et al. 2024 *An Analysis of Dialogue
/// Repair in Virtual Voice Assistants*; Home Assistant community
/// *Trust the User, Not the State*; STALE benchmark *Agents Fail to
/// Reject Stale Memories*) all converge on one rule:
///
/// > When the user's spoken statement contradicts cached / injected
/// > context, the user wins. The cache is stale by definition the
/// > moment the user contradicts it. Don't argue the cache back at
/// > them; remove the stale block from the context entirely and
/// > re-anchor on what the user just said.
///
/// This is a general detector, not limited to ATL/CTL/TSB/ACWR: any
/// metric the user explicitly states, plus
/// imperative-override phrases ("stop calling tools", "use these
/// numbers"), plus dashboard-contradiction signals. The composer
/// then either suppresses the matching context block or rewrites
/// it with a "user has corrected this" attribution.
///
/// # Output
///
/// A `Signals` struct, with three independent flags + a value bag:
/// - `assertedValues`: every "metric = value" assertion in the user's
///   recent text. Keys are lowercased metric names; not limited to the
///   training-load set.
/// - `dashboardContradicted`: user said the dashboard differs from
///   what the system claimed ("dashboard actually says X", "real
///   numbers are Y").
/// - `explicitOverrideRequested`: user explicitly asked the AI to
///   stop relying on cached / tool data and use their stated values
///   ("stop calling tools", "use these", "I don't care what the
///   dashboard says").
///
/// The composer reads `Signals` and decides what to do per block:
/// suppress the dashboard cache block, inject a `# User-stated
/// values (authoritative — fresher than any cache)` block, etc. The detector itself is neutral —
/// it only reports observation, not policy.
enum UserCorrectionDetector {
    struct Signals {
        /// Metric name (lowercase) → numeric value the user stated.
        /// Includes everything: atl/ctl/tsb/acwr/hr/rmssd/sdnn/whatever
        /// the user provides with a number.
        var assertedValues: [String: Double] = [:]

        /// The unit the user gave with a pace or distance ("8:30 per mile",
        /// "10 km"), as "mi", "km" or "m"; the rendered value keeps it.
        var units: [String: String] = [:]

        /// The user said the dashboard differs from what we surfaced.
        /// Phrases: "dashboard actually says", "real numbers are",
        /// "the dashboard says", "you're wrong", and a sentence opening
        /// "no it's" / "actually it's" followed by a number or negation.
        var dashboardContradicted: Bool = false

        /// The user explicitly told the AI to stop using cached /
        /// tool data for this conversation. Phrases: "stop calling
        /// tools", "do not fetch", "don't use", "use these numbers",
        /// "use the data I gave you", "I don't care what the
        /// dashboard says".
        var explicitOverrideRequested: Bool = false

        /// True when ANY correction signal is present.
        var hasAnyCorrection: Bool {
            !assertedValues.isEmpty || dashboardContradicted || explicitOverrideRequested
        }
    }

    /// Scan the recent user messages (most-recent last) for correction
    /// signals. Pass the last ~6 user messages.
    static func detect(userMessages: [String]) -> Signals {
        var signals = Signals()
        // Walk newest → oldest; assertions are recorded once per metric
        // (latest wins).
        for raw in userMessages.reversed() {
            // Normalise spelled-out numbers first so the regex catches
            // "negative thirteen point seven" the same as "-13.7".
            let text = MetricsVerifier.normalizeSpelledNumbers(raw)
            collectAssertedValues(text: text, into: &signals)
            if isDashboardContradiction(text: text) {
                signals.dashboardContradicted = true
            }
            if isExplicitOverride(text: text) {
                signals.explicitOverrideRequested = true
            }
        }
        return signals
    }

    // MARK: - Value extraction

    /// Set of metric-name patterns the detector recognises. This is
    /// deliberately broad — any metric the AI might quote should be
    /// parseable here, not only ATL/CTL/TSB. The set is
    /// alphanumeric tokens (case-insensitive) followed by an optional
    /// connector (is/of/=/:/was/being) and a number.
    private static let knownMetrics: [String] = [
        // Training load
        "atl", "ctl", "tsb", "acwr", "trimp", "hrtss", "powertss",
        // HRV
        "rmssd", "sdnn", "pnn50", "dfa", "alpha1", "lf", "hf", "lfhf",
        // Heart rate
        "hr", "bpm", "resting hr", "rhr", "max hr",
        // Recovery
        "recovery", "recovery score", "readiness",
        // Sleep
        "sleep", "sleep score",
        // Workout
        "pace", "distance", "calories", "power", "watts", "cadence",
        "elevation", "spo2", "temperature"
    ]

    /// Common misspellings / voice-transcription variants → canonical key.
    /// Users type and dictate "BSB" or "TSP" for TSB; without these the
    /// correction is missed and the AI keeps quoting its stale cache value. Value
    /// extraction requires a number adjacent to the token ("tsp is -8.8"),
    /// which makes a teaspoon/typo collision implausible in this context.
    private static let metricAliases: [String: String] = [
        "bsb": "tsb", "tsp": "tsb", "tbs": "tsb",
        "atrl": "atl", "clt": "ctl", "acrw": "acwr",
        // The app's HRV is RMSSD, and "my HRV is 38" is how people say it.
        "hrv": "rmssd"
    ]

    /// Words that also appear next to numbers the user is only quoting or
    /// describing ("sleep 8 hours?", "recovery 45 seems low"): these count
    /// as an assertion only with an explicit connector ("recovery is 45").
    private static let connectorRequiredMetrics: Set<String> = ["sleep", "recovery"]

    /// Longest names first, so "max hr 190" is claimed by `max hr` and the
    /// match is blanked before `hr` is tried.
    private static let metricsLongestFirst = knownMetrics.sorted { $0.count > $1.count }

    /// Names that double as units, so a number right before them is that
    /// unit's quantity and the number after belongs to something else:
    /// "slept 7 hr 30 min" (hours), "160 bpm 30 minutes later". These are
    /// read as a metric name only when no number precedes them.
    private static let unitLikeMetrics: Set<String> = ["hr", "bpm", "watts", "calories"]

    /// Only statements count: a question ("what was my hr at 5 am?") quotes
    /// no value the user is asserting.
    private static func collectAssertedValues(text: String, into signals: inout Signals) {
        var remaining = statementsOnly(text)
        for metric in metricsLongestFirst {
            let needsConnector = connectorRequiredMetrics.contains(metric)
            guard let found = extractValue(for: metric, in: remaining, connectorRequired: needsConnector) else {
                continue
            }
            remaining = found.remainder
            record(found, as: metric, into: &signals)
        }
        // Fold typo/transcription variants into their canonical metric, but
        // never overwrite a value the user stated with the correct spelling.
        for (alias, canonical) in metricAliases {
            if let found = extractValue(for: alias, in: remaining) { record(found, as: canonical, into: &signals) }
        }
    }

    /// Keeps the first value found for a metric (messages are read newest
    /// first), with its unit when it has one.
    private static func record(_ found: ExtractedValue, as metric: String, into signals: inout Signals) {
        guard signals.assertedValues[metric] == nil else { return }
        signals.assertedValues[metric] = found.value
        if let unit = found.unit { signals.units[metric] = unit }
    }

    /// A sentence about another time or a plan, not today's value: a past
    /// reading ("last month my rhr was 48", "195 back in 2019"), a goal ("I'm
    /// aiming for a ctl of 80") or a workout prescription ("do 5x1km at hr
    /// 170"). The numbers in it are not a correction of today's data. "Last
    /// night" is left out: last night's recording is today's numbers.
    private static let otherTimeMarker = "(?i)\\b(?:" + [
        #"yesterday|last\s+(?:week|month|year|season|time|run|ride|race|workout)|ago|back\s+in|in\s+(?:19|20)\d{2}|used\s+to"#,
        #"aim(?:ing|s)?|target\w*|goal\w*|want\w*|plan\w*|hop(?:e|ing)|tomorrow|next\s+(?:week|month|time|run|ride|race)"#,
        #"do\s+\d+(?:\s*x\s*\d+)?(?:k?m|mi)?|\d+\s*x\s*\d+(?:k?m|mi)?|at\s+(?:an?\s+)?(?:hr|heart\s+rate|pace)"#
    ].joined(separator: "|") + ")\\b"

    private static func describesAnotherTime(_ sentence: String) -> Bool {
        sentence.range(of: otherTimeMarker, options: .regularExpression) != nil
    }

    /// The text with every sentence about another time or a plan
    /// (`describesAnotherTime`) removed, and every question reduced to the
    /// statements before it (`statementsBeforeTheQuestion`).
    private static func statementsOnly(_ text: String) -> String {
        var kept: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            let isQuestion = trimmed.hasSuffix("?") || trimmed.hasSuffix("？")
            if !isQuestion, !describesAnotherTime(trimmed) { kept.append(sentence) }
            if isQuestion { kept.append(statementsBeforeTheQuestion(trimmed)) }
        }
        return kept.joined(separator: " ")
    }

    /// A question quotes no value ("what was my hr at 5 am?"), but a
    /// statement can come first in the same sentence: "my hrv is 38, why
    /// does the app say 45?" states 38. The clauses before the last one are
    /// kept unless they open with a question word; the last clause, the
    /// question itself, never is.
    private static func statementsBeforeTheQuestion(_ question: String) -> String {
        let clauses = question.components(separatedBy: CharacterSet(charactersIn: ",;"))
        return clauses.dropLast()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: questionOpener, options: [.regularExpression, .caseInsensitive]) == nil && !describesAnotherTime($0) }
            .joined(separator: ". ")
    }

    private static let questionOpener =
        #"^(?:what|why|how|when|where|which|who|is|are|was|were|do|does|did|can|could|should|would|will|am)\b"#

    /// The value of the last "metric [connector] number" in `text`, plus the
    /// text with every such match blanked out. A number that is a clock time
    /// ("5 am", "11 pm", "5:30") is not a value; "at" is not a connector for
    /// the same reason ("sleep at 11"). Pace alone also takes min:sec
    /// ("pace was 5:30" → 5.5 minutes). With `connectorRequired`, the number
    /// must follow one of the connectors ("recovery is 45", not "recovery 45").
    private static func extractValue(
        for metric: String, in text: String, connectorRequired: Bool = false
    ) -> ExtractedValue? {
        let pattern = valuePattern(for: metric, connectorRequired: connectorRequired)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last, last.numberOfRanges >= 2,
              let value = parseValue(ns.substring(with: last.range(at: 1))) else { return nil }
        let remainder = regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length), withTemplate: " "
        )
        return ExtractedValue(value: value, unit: unitKey(of: last, in: ns), remainder: remainder)
    }

    /// One "metric [connector] number" match: the number, the unit given
    /// with it (pace and distance only) and the text with the matches blanked.
    private struct ExtractedValue {
        let value: Double
        let unit: String?
        let remainder: String
    }

    /// Metrics whose number means nothing without its unit: 8:30 per mile
    /// is not 8:30 per kilometer.
    private static let unitBearingMetrics: Set<String> = ["pace", "distance"]

    /// The optional unit after a pace or distance number, as group 2.
    private static let unitSuffix = #"(?:\s*(?:min(?:utes)?\s*)?(?:/|per\s)\s*|\s*)(mi|miles?|km|kilomet(?:er|re)s?|k|m|meters?|metres?)\b"#

    /// The unit of a match as "mi", "km" or "m"; nil when it gave none.
    private static func unitKey(of match: NSTextCheckingResult, in ns: NSString) -> String? {
        guard match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound else { return nil }
        let raw = ns.substring(with: match.range(at: 2)).lowercased()
        if raw.hasPrefix("mi") { return "mi" }
        return raw.hasPrefix("k") ? "km" : "m"
    }

    /// The "metric [connector] number" regex for one metric. A unit-like name
    /// (`unitLikeMetrics`) must not follow a number; `pace` also accepts a
    /// min:sec number.
    private static func valuePattern(for metric: String, connectorRequired: Bool) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: metric)
        let notAfterNumber = unitLikeMetrics.contains(metric) ? "(?<![\\d.])(?<![\\d.]\\s)(?<![\\d.]\\s\\s)" : ""
        let digits = metric == "pace" ? "(\\d{1,2}:[0-5]\\d|-?\\d+(?:\\.\\d+)?)" : "(-?\\d+(?:\\.\\d+)?)"
        let number = digits + "(?!\\.?\\d)(?!:\\d)(?!\\s*(?:(?:am|pm|o'clock)\\b|a\\.m\\.|p\\.m\\.))" + (durationMetrics.contains(metric) ? "" : notADuration)
        let connector = "(?:is|of|=|:|was|being)" + (connectorRequired ? "" : "?")
        let unit = unitBearingMetrics.contains(metric) ? "(?:" + unitSuffix + ")?" : ""
        return "(?i)" + notAfterNumber + "\\b\(escaped)\\b\\s*" + connector + "\\s*" + number + unit
    }

    /// Metrics whose value is itself a length of time ("sleep was 7.5").
    private static let durationMetrics: Set<String> = ["sleep", "pace"]

    /// A number followed by a time unit is a duration, not the metric's
    /// value: "my recovery was 3 days", "hr 150 for 20 minutes" keeps 150.
    private static let notADuration =
        #"(?!\s*(?:days?|hours?|hrs?|h|weeks?|wks?|nights?|minutes?|mins?|seconds?|secs?|months?|years?)\b)"#

    /// A captured number as a Double; "m:ss" becomes minutes (5:30 → 5.5).
    private static func parseValue(_ raw: String) -> Double? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2 else { return Double(raw) }
        guard let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
        return minutes + seconds / 60
    }

    // MARK: - Intent detection

    private static let dashboardContradictionPhrases: [String] = [
        "dashboard actually says",
        "the dashboard says",
        "real numbers are",
        "wrong, it's",
        "not what the dashboard shows",
        "those aren't the real numbers",
        // Bare-contradiction phrases ("yes. because you're wrong" /
        // "no. you are wrong" / "no!!! stop saying that"): the user is
        // unambiguously contradicting the AI's last metric quote
        // without providing a fresh value. We treat these as a
        // contradiction signal so the cache block is suppressed
        // next turn (model can't keep re-quoting a block that
        // isn't there).
        "you're wrong",
        "you are wrong",
        "you're incorrect",
        "you are incorrect",
        "that's wrong",
        "that is wrong",
        "wrong number",
        "wrong value",
        "those are wrong",
        "that's incorrect"
    ]

    /// Lowercased, with the typographic apostrophe (U+2019, iOS smart
    /// punctuation) folded to "'" so "don’t" matches the phrase lists.
    private static func foldedLowercase(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private static func isDashboardContradiction(text: String) -> Bool {
        let lower = foldedLowercase(text)
        return dashboardContradictionPhrases.contains { lower.contains($0) }
            || startsWithCorrectionReply(lower)
    }

    /// "No it's 62", "Actually it's different", "no, it is not that":
    /// a sentence that opens with no/actually + "it's" and goes on to give a
    /// number or a negation / comparison. Matched only at the start of a
    /// sentence and only with that continuation, so ordinary openers such as
    /// "Actually it's been a rough week" are not read as a correction.
    private static let correctionReplyOpeners: [String] = [
        "no it's ", "no, it's ", "no it is ", "no, it is ",
        "actually it's ", "actually, it's ", "actually it is ", "actually, it is "
    ]

    private static let correctionReplyWords: Set<String> = [
        "not", "different", "wrong", "higher", "lower", "more", "less"
    ]

    private static func startsWithCorrectionReply(_ lower: String) -> Bool {
        var found = false
        lower.enumerateSubstrings(in: lower.startIndex..., options: .bySentences) { sentence, _, _, stop in
            guard let sentence, isCorrectionReply(sentence.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return
            }
            found = true
            stop = true
        }
        return found
    }

    /// One lowercased sentence: an opener from `correctionReplyOpeners`
    /// followed by a word from `correctionReplyWords` or a number.
    private static func isCorrectionReply(_ sentence: String) -> Bool {
        guard let opener = correctionReplyOpeners.first(where: { sentence.hasPrefix($0) }),
              let next = sentence.dropFirst(opener.count).split(separator: " ").first
        else { return false }
        let word = next.trimmingCharacters(in: .punctuationCharacters)
        if correctionReplyWords.contains(word) { return true }
        return next.first.map { $0.isNumber || $0 == "-" || $0 == "+" } ?? false
    }

    private static let explicitOverridePhrases: [String] = [
        "stop calling tools",
        "do not fetch",
        "don't fetch",
        "do not call the tool",
        "do not call tools",
        "do not call any tool",
        "don't call the tool",
        "don't call tools",
        "don't call any tool",
        "use these numbers",
        "use those numbers",
        "use the data i gave you",
        "use the numbers i gave you",
        "use the numbers i provided",
        "i don't care what the dashboard",
        "i don't care what the cache",
        "i don't care what the live",
        "stop using that data",
        "stop using the live",
        "stop going after that data",
        "those are the real numbers",
        "the real numbers are",
        "knock it off"
    ]

    /// A short rejection of a value the AI quoted ("stop saying my tsb is
    /// -20", "stop telling me it's 45", "quit repeating those numbers"): it
    /// means "stop reading from wherever you're reading from" even without a
    /// fresh value, so the cache block is left out and the model has to ask
    /// or stop quoting it. Only with data after it, or as the whole reply
    /// ("stop saying that", "stop repeating yourself"): "stop telling me to
    /// slow down" is about coaching, not the numbers.
    private static let valueRejections = [
        #"\b(?:stop|quit)\s+(?:saying|telling\s+me|repeating)\s+(?:that\s+)?(?:(?:my|the|those|these|that|your)\s+)?(?:it'?s\s+|i'?m\s+(?:at\s+)?)?"#
            + #"(?:[-+]?\d|numbers?|data|values?|scores?|figures?|readings?|stats|metrics?|atl|ctl|tsb|acwr|hrv|rmssd|hr|rhr|recovery|readiness|load|training\s+load|heart\s+rate)"#,
        #"\b(?:stop|quit)\s+(?:saying|repeating)\s+(?:that|it|this|yourself)[\s.!]*$"#
    ]

    private static func isExplicitOverride(text: String) -> Bool {
        let lower = foldedLowercase(text)
        return explicitOverridePhrases.contains { lower.contains($0) }
            || valueRejections.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: - Rendering

    /// User-asserted-values block. Lists everything the user has
    /// stated so the AI can re-anchor on those numbers and treat
    /// them as fresher than anything in the system context. Returns
    /// nil when there are no assertions to render.
    static func renderAssertedBlock(_ signals: Signals) -> String? {
        guard signals.hasAnyCorrection else { return nil }
        var lines = ["# User-stated values (authoritative — fresher than any cache)"]
        if signals.dashboardContradicted || signals.explicitOverrideRequested {
            lines.append("")
            lines.append("The user has explicitly told you the system's cached / injected data is stale or wrong. Honour the correction:")
        }
        if !signals.assertedValues.isEmpty {
            lines.append("")
            lines.append("Values the user just stated — use these as authoritative. State them plainly; you don't need to append \"you told me\" every time (once is plenty if it helps clarity):")
            lines += assertedValueLines(signals)
        }
        return lines.joined(separator: "\n")
    }

    /// One `- key: value` line per assertion, in a stable order: the known
    /// metrics first, then anything else alphabetically.
    private static func assertedValueLines(_ signals: Signals) -> [String] {
        let prioritized = ["atl", "ctl", "tsb", "acwr", "hr", "rmssd", "recovery", "sleep"]
        let values = signals.assertedValues
        let rest = values.keys.sorted().filter { !prioritized.contains($0) }
        return (prioritized + rest).compactMap { key -> String? in
            guard let value = values[key] else { return nil }
            return "- \(key): " + formatValue(key: key, value: value) + unitText(key: key, unit: signals.units[key])
        }
    }

    /// The unit a pace or distance was given in: " min/mi", " km".
    private static func unitText(key: String, unit: String?) -> String {
        guard let unit else { return "" }
        return key == "pace" ? " min/\(unit)" : " \(unit)"
    }

    private static func formatValue(key: String, value: Double) -> String {
        switch key {
        case "tsb": return String(format: "%+.1f", value)
        case "acwr": return String(format: "%.2f", value)
        case "atl", "ctl", "rmssd", "sdnn", "hr", "bpm", "rhr":
            return String(format: "%.1f", value)
        case "pace" where value >= 0:
            let totalSeconds = Int((value * 60).rounded())
            return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
        default:
            return String(format: "%g", value)
        }
    }
}
