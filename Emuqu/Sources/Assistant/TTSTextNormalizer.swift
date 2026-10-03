import Foundation

// MARK: - TTSTextNormalizer
//
// Composed text-normalization layer for AVSpeechSynthesizer.
//
// **Why this exists.** AVSpeech reads numbers as integers ("thirty seven
// thousand"), years badly ("two thousand twenty-six"), homograph words
// the wrong way ("live" /lɪv/), and pace strings character-by-character.
// User-facing voice output needs all of these handled or the AI Coach
// sounds broken. There's no
// drop-in Swift Package that solves this — but every primitive we need
// is on-device:
//   • NSDataDetector — entity extraction (phone, address, date, link)
//   • NumberFormatter(.spellOut) — number → words
//   • accessibilitySpeechSpellOut attribute — digit-by-digit pronunciation
//   • accessibilitySpeechIPANotation attribute — homograph IPA hints
//
// This component composes them into a single pipeline. The output is
// an NSAttributedString suitable for AVSpeechUtterance(attributedString:).
// The existing PhoneticOverrides handles the homograph layer (live,
// read, etc.); this normalizer runs BEFORE it so PhoneticOverrides sees
// already-normalized text.
//
// **Pipeline order matters.** Domain abbreviations and pace strings
// have to run before generic year/ZIP/number detection — otherwise
// `NumberFormatter.spellOut` will eat a pace like "8:45" or a ZIP
// like "62704".
//
// **Voice-fallback aware.** Apple silently swaps Siri voices for a
// fallback when AVSpeech runs; Alex doesn't honor attributed text at
// all. Where possible we use IN-LINE substitution (modify the spoken
// text) instead of attributes — that survives every voice. Attributes
// are belt-and-suspenders for voices that DO honor them.

enum TTSTextNormalizer {
    /// Normalize free-form text into an `NSAttributedString` ready for
    /// `AVSpeechUtterance(attributedString:)`. Chains every entity-
    /// specific pass plus the existing homograph layer.
    ///
    /// `english: false` skips the pre-passes, which write English words
    /// ("zone one", "per minute", year read-outs) into the text.
    static func normalize(_ input: String, english: Bool = true) -> NSAttributedString {
        // Pre-passes that mutate the spoken text directly. Order is
        // load-bearing — see comment at top of file.
        var working = input
        if english {
            working = expandDomainAbbreviations(working)
            working = expandPaceStrings(working)
            working = expandYears(working)
        }
        // ZIP expansion + homographs + AI markup all live in
        // PhoneticOverrides and emit an NSAttributedString. Hand the
        // post-pre-pass text to it as the final stage.
        return PhoneticOverrides.speechAttributedString(working)
    }

    /// Display-safe version (no attributes, no respellings) for chat
    /// bubbles and UI. Strips AI `[[word|IPA]]` markup but otherwise
    /// keeps the input intact — the user sees what the AI said, not
    /// what AVSpeech needs.
    static func stripForDisplay(_ input: String) -> String {
        PhoneticOverrides.stripForDisplay(input)
    }

    // MARK: - Domain abbreviations

    /// Hand-curated set of fitness/recovery abbreviations that AVSpeech
    /// gets wrong by default. Each entry is `(pattern, replacement)`:
    ///   • Pattern matches the abbreviation in word-boundary context.
    ///   • Replacement is the spoken expansion. Keep it pronounceable
    ///     by every voice — don't rely on IPA hints.
    /// Covers the most common clashes the
    /// Coach speaks. Extend as the user reports more.
    private static let domainAbbreviations: [(pattern: String, replacement: String)] = [
        // VO2 → "V O 2" (default reading: "vee oh two" works on most
        // voices but inconsistent). Spaced is reliable.
        (#"\bVO2\b"#, "V O two"),
        (#"\bVO2max\b"#, "V O two max"),
        // Heart rate variability — every voice gets right but
        // sometimes reads "HRV" as "huh-rivv".
        (#"\bHRV\b"#, "H R V"),
        (#"\bRHR\b"#, "resting heart rate"),
        // BPM — most voices say "B P M" correctly but some read it
        // "bee pee em" (correct) or just "bpm" mumbled. Force the
        // canonical reading.
        (#"\bBPM\b"#, "B P M"),
        (#"\bbpm\b"#, "B P M"),
        // Per-minute units in pace contexts — AVSpeech sometimes
        // reads "/min" as "slash min". Substitute.
        (#"/min\b"#, " per minute"),
        // RPE — "rate of perceived exertion" is a bit long for voice;
        // spell it out.
        (#"\bRPE\b"#, "R P E"),
        // PR (personal record) — easy to confuse with "pee arr" /
        // "public relations" / etc. Spell out.
        (#"\bPR\b"#, "P R"),
        // TSB / ATL / CTL training-load metrics. Spell out.
        (#"\bTSB\b"#, "T S B"),
        (#"\bATL\b"#, "A T L"),
        (#"\bCTL\b"#, "C T L"),
        // α1 (alpha-1) — Greek letter only some voices speak. Use
        // the spelled name.
        (#"\bα1\b"#, "alpha one"),
        (#"\bα-1\b"#, "alpha one"),
        (#"\balpha-1\b"#, "alpha one"),
        // DFA — spell out (otherwise read as "duh-fuh").
        (#"\bDFA\b"#, "D F A"),
        // Z1..Z5 zone abbreviations — read as "zone one" etc. instead
        // of "zee one".
        (#"\bZ1\b"#, "zone one"),
        (#"\bZ2\b"#, "zone two"),
        (#"\bZ3\b"#, "zone three"),
        (#"\bZ4\b"#, "zone four"),
        (#"\bZ5\b"#, "zone five")
    ]

    static func expandDomainAbbreviations(_ input: String) -> String {
        var out = input
        for (pattern, replacement) in domainAbbreviations {
            out = out.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return out
    }

    // MARK: - Pace strings

    /// Convert pace strings like "8:45/mi", "5:30 min/km", "8:45 per mi"
    /// into spoken form. AVSpeech otherwise reads "8:45/mi" as "eight
    /// colon forty-five slash em eye" or similar mangled output.
    ///
    /// Patterns handled:
    ///   • `(\d+):(\d{2})\s*/(mi|km)` — "8:45/mi"
    ///   • `(\d+):(\d{2})\s+min/(mi|km)` — "8:45 min/mi"
    ///   • `(\d+):(\d{2})\s+per\s+(mile|km|kilometer|mi)` — "8:45 per mile"
    ///   • Bare `(\d+):(\d{2})\b` is NOT touched — could be a clock
    ///     time, a duration, etc. Only the unit suffix triggers the
    ///     transform.
    static func expandPaceStrings(_ input: String) -> String {
        var out = input
        for pattern in Self.pacePatterns {
            out = expandPaces(in: out, pattern: pattern)
        }
        return out
    }

    /// The three surface forms, all producing the same spoken output.
    private static let pacePatterns = [
        #"(\d{1,2}):(\d{2})\s*/\s*(mi|km|mile|kilometer)\b"#,
        #"(\d{1,2}):(\d{2})\s+min\s*/\s*(mi|km|mile|kilometer)\b"#,
        #"(\d{1,2}):(\d{2})\s+per\s+(mi|km|mile|kilometer)\b"#
    ]

    /// Rewrite every match of one pattern. Iterates in reverse so the
    /// remaining match ranges stay valid as the string shrinks and grows.
    private static func expandPaces(in text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        let ns = out as NSString
        for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard match.numberOfRanges == 4,
                  let mins = Int(ns.substring(with: match.range(at: 1))),
                  let secs = Int(ns.substring(with: match.range(at: 2)))
            else { continue }
            let unitWord = unitWordFor(ns.substring(with: match.range(at: 3)).lowercased())
            let spoken = "\(numberAsWords(mins)) \(secsAsWords(secs)) per \(unitWord)"
            out = (out as NSString).replacingCharacters(in: match.range, with: spoken)
        }
        return out
    }

    private static func unitWordFor(_ raw: String) -> String {
        switch raw.lowercased() {
        case "mi", "mile": return "mile"
        case "km", "kilometer": return "kilometer"
        default: return raw
        }
    }

    /// English words whatever the device language: the surrounding text
    /// ("per mile", "oh five", "flat") is English, so the numbers must be too.
    private static func numberAsWords(_ n: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .spellOut
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Pronounce ":45" / ":05" — leading-zero seconds need to read as
    /// "oh five" / "forty-five" naturally. Match the pattern users
    /// say aloud: "eight forty-five" not "eight zero-zero forty-five".
    private static func secsAsWords(_ secs: Int) -> String {
        guard (0 ... 59).contains(secs) else { return "\(secs)" }
        if secs == 0 { return "flat" }
        if secs < 10 { return "oh \(numberAsWords(secs))" }
        return numberAsWords(secs)
    }

    // MARK: - Years (special case)
    //
    // `NumberFormatter(.spellOut)` reads `2026` as "two thousand
    // twenty-six" — technically correct, conversationally wrong. Users
    // expect "twenty twenty-six". Split into halves and spellOut each.
    //
    // Special cases:
    //   • 2000–2009 — "two thousand X" sounds natural ("two thousand four")
    //   • 2010–2099 — "twenty X" or "twenty-XX"
    //   • 1100–1999 — "<first-half> <second-half>" ("nineteen ninety")
    //   • 1000–1099 — "ten oh X" sounds odd; emit "one thousand X"
    //
    // Match years only in non-numeric context: preceded/followed by
    // word boundary, NOT by another digit / decimal / colon. Avoids
    // touching prices ($1990), pace strings (8:45), step counts, etc.

    static func expandYears(_ input: String) -> String {
        // Match a 4-digit year 1100-2099 in non-numeric context.
        // Lookbehind/ahead reject `\d`, `.`, `:`, `,`, `$` so prices
        // ($1990), decimals (1990.5), times (12:1990), and grouped
        // numerics (12,1990) all pass through unchanged.
        let pattern = #"(?<![\d.,:$])\b(1[1-9]\d{2}|20\d{2})\b(?![\d.,:])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return input
        }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        var out = input
        for match in matches.reversed() {
            let yearStr = ns.substring(with: match.range)
            guard let year = Int(yearStr) else { continue }
            let replacement = spokenYear(year)
            out = (out as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return out
    }

    /// How a year is read aloud: "two thousand four", "twenty twenty six",
    /// "nineteen ninety", "nineteen oh four", "nineteen hundred". Outside the
    /// range we trust, it's spelled as a plain number.
    private static func spokenYear(_ year: Int) -> String {
        if year >= 2000, year <= 2009 { return "two thousand \(numberAsWords(year - 2000))" }
        if year >= 2010, year <= 2099 { return "twenty \(numberAsWords(year - 2000))" }
        guard year >= 1100, year <= 1999 else { return numberAsWords(year) }
        return splitCenturyYear(year)
    }

    /// Generic "<first-half> <second-half>" for 1100–1999.
    private static func splitCenturyYear(_ year: Int) -> String {
        let firstHalf = numberAsWords(year / 100)
        let secondHalf = year % 100
        if secondHalf == 0 { return "\(firstHalf) hundred" }
        if secondHalf < 10 { return "\(firstHalf) oh \(numberAsWords(secondHalf))" }
        return "\(firstHalf) \(numberAsWords(secondHalf))"
    }
}
