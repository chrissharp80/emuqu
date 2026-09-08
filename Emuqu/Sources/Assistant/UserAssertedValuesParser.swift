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
/// The previous implementation (`UserAssertedValuesParser`, narrow
/// ATL/CTL/TSB/ACWR scope) was the edge-case patch. This is the
/// general detector: any metric the user explicitly states, plus
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
/// suppress the dashboard cache block, inject a `# User-asserted
/// values (use these)` block, etc. The detector itself is neutral —
/// it only reports observation, not policy.
enum UserCorrectionDetector {
    struct Signals {
        /// Metric name (lowercase) → numeric value the user stated.
        /// Includes everything: atl/ctl/tsb/acwr/hr/rmssd/sdnn/whatever
        /// the user provides with a number.
        var assertedValues: [String: Double] = [:]

        /// The user said the dashboard differs from what we surfaced.
        /// Phrases: "dashboard actually says", "real numbers are",
        /// "the dashboard says", "no it's", "actually it's".
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
    /// connector (is/of/at/=/:/was/being) and a number.
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
    /// Real transcript: a user typed "BSB" and "TSP" for TSB across one
    /// conversation, so the correction was missed until they happened to
    /// spell it right and the AI kept quoting its stale cache value. Value
    /// extraction requires a number adjacent to the token ("tsp is -8.8"),
    /// which makes a teaspoon/typo collision implausible in this context.
    private static let metricAliases: [String: String] = [
        "bsb": "tsb", "tsp": "tsb", "tbs": "tsb",
        "atrl": "atl", "clt": "ctl", "acrw": "acwr"
    ]

    private static func collectAssertedValues(text: String, into signals: inout Signals) {
        for metric in knownMetrics where signals.assertedValues[metric] == nil {
            if let value = extractValue(for: metric, in: text) {
                signals.assertedValues[metric] = value
            }
        }
        // Fold typo/transcription variants into their canonical metric, but
        // never overwrite a value the user stated with the correct spelling.
        for (alias, canonical) in metricAliases where signals.assertedValues[canonical] == nil {
            if let value = extractValue(for: alias, in: text) {
                signals.assertedValues[canonical] = value
            }
        }
    }

    private static func extractValue(for metric: String, in text: String) -> Double? {
        // Escape the metric name for regex, then build a flexible
        // matcher: optional connectors between metric and value,
        // optional leading minus.
        let escaped = NSRegularExpression.escapedPattern(for: metric)
        let pattern = "(?i)\\b\(escaped)\\b\\s*(?:is|of|at|=|:|was|being)?\\s*(-?\\d+(?:\\.\\d+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last, last.numberOfRanges >= 2 else { return nil }
        return Double(ns.substring(with: last.range(at: 1)))
    }

    // MARK: - Intent detection

    private static let dashboardContradictionPhrases: [String] = [
        "dashboard actually says",
        "the dashboard says",
        "real numbers are",
        "actually it's",
        "actually it is",
        "no it's",
        "no it is",
        "wrong, it's",
        "not what the dashboard shows",
        "those aren't the real numbers",
        // Bare-contradiction phrases. Real user
        // transcript: "yes. because you're wrong" / "no. you are
        // wrong" / "no!!! stop saying that" — the user is
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

    private static func isDashboardContradiction(text: String) -> Bool {
        let lower = text.lowercased()
        return dashboardContradictionPhrases.contains { lower.contains($0) }
    }

    private static let explicitOverridePhrases: [String] = [
        "stop calling tools",
        "do not fetch",
        "don't fetch",
        "do not call",
        "don't call",
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
        // Short rejections after the AI quoted a
        // value. These mean "stop reading from wherever you're
        // reading from" even without a fresh value being given.
        // Suppressing the cache block forces the model to either
        // ask a clarifying question or stop quoting it.
        "stop saying that",
        "stop saying",
        "stop telling me",
        "quit saying",
        "knock it off",
        "stop repeating"
    ]

    private static func isExplicitOverride(text: String) -> Bool {
        let lower = text.lowercased()
        return explicitOverridePhrases.contains { lower.contains($0) }
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
            lines += assertedValueLines(signals.assertedValues)
        }
        return lines.joined(separator: "\n")
    }

    /// One `- key: value` line per assertion, in a stable order: the known
    /// metrics first, then anything else alphabetically.
    private static func assertedValueLines(_ values: [String: Double]) -> [String] {
        let prioritized = ["atl", "ctl", "tsb", "acwr", "hr", "rmssd", "recovery", "sleep"]
        var emitted = Set<String>()
        var lines: [String] = []
        for key in prioritized {
            guard let value = values[key] else { continue }
            lines.append("- \(key): \(formatValue(key: key, value: value))")
            emitted.insert(key)
        }
        for key in values.keys.sorted() where !emitted.contains(key) {
            guard let value = values[key] else { continue }
            lines.append("- \(key): \(formatValue(key: key, value: value))")
        }
        return lines
    }

    private static func formatValue(key: String, value: Double) -> String {
        switch key {
        case "tsb": return String(format: "%+.1f", value)
        case "acwr": return String(format: "%.2f", value)
        case "atl", "ctl", "rmssd", "sdnn", "hr", "bpm", "rhr":
            return String(format: "%.1f", value)
        default:
            return String(format: "%g", value)
        }
    }
}

/// Backwards-compatibility alias. The `UserAssertedValuesParser`
/// name + return-shape are preserved for callers that still use them.
/// Internally it delegates to `UserCorrectionDetector`.
enum UserAssertedValuesParser {
    typealias AssertedValues = [String: Double]

    static func parse(userMessages: [String]) -> AssertedValues {
        UserCorrectionDetector.detect(userMessages: userMessages).assertedValues
    }

    static func renderOverrideBlock(_ values: AssertedValues) -> String? {
        // Legacy renderer kept thin; new callers should build their
        // own `Signals` and use `UserCorrectionDetector.renderAssertedBlock`.
        var signals = UserCorrectionDetector.Signals()
        signals.assertedValues = values
        return UserCorrectionDetector.renderAssertedBlock(signals)
    }
}
