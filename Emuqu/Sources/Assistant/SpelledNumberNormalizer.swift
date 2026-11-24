import Foundation

/// Rewrites spelled-out numbers in a reply to digits, for the regex checks
/// in `MetricsVerifier` and `UserAssertedValuesParser`.
///
/// The verifier's main regexes look for digit characters
/// (`\d+(?:\.\d+)?`). In voice mode the AI replies conversationally
/// — "TSB negative thirty-one point seven" — and zero digits appear.
/// Without this, every wrong metric in voice mode is invisible to the verifier.
/// This normaliser converts the common patterns the AI emits into
/// digit form BEFORE the regexes scan the text: 0–999 ("one hundred
/// and sixty", "a hundred five"), the spoken "one-sixty" form of a heart
/// rate (one or two, a hyphen, a tens word), and any number of decimal
/// digits after "point" ("point seven five" is .75).
///
/// Every spelled number in the reply is rewritten, "this one" included.
/// That only affects matching: corrections are mapped back and applied
/// to the original text, and a rewritten word is a claim only where a
/// metric's claim shape surrounds it.
///
/// Pure, sync, isolated to nothing — safe to call from any actor.
enum SpelledNumberNormalizer {
    private static let onesAndTeens: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]

    /// One spelled-number rewrite: the words it replaced in the original and
    /// the digits it became in the normalized text.
    struct Rewrite {
        let original: NSRange
        let normalized: NSRange
    }

    /// The normalized text plus every rewrite, in order, so a range found in
    /// the normalized text can be mapped back to the original.
    static func normalizeWithRewrites(_ text: String) -> (text: String, rewrites: [Rewrite]) {
        guard let regex = DebugLogger.compiledPattern(spelledNumberPattern) else {
            return (text, [])
        }
        let ns = text as NSString
        let output = NSMutableString()
        var rewrites: [Rewrite] = []
        var cursor = 0
        for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            guard let rep = spelledNumberReplacement(ns.substring(with: match.range)) else { continue }
            output.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let digits = NSRange(location: output.length, length: (rep as NSString).length)
            rewrites.append(Rewrite(original: match.range, normalized: digits))
            output.append(rep)
            cursor = NSMaxRange(match.range)
        }
        output.append(ns.substring(from: cursor))
        return (output as String, rewrites)
    }

    /// Where a normalized-text offset falls in the original. Text outside any
    /// rewrite is identical in both, shifted by the rewrites before it; an
    /// offset inside a rewrite snaps to that rewrite's original start or end.
    static func originalOffset(of offset: Int, rewrites: [Rewrite], snapToEnd: Bool) -> Int {
        var shift = 0
        for rewrite in rewrites {
            if offset >= NSMaxRange(rewrite.normalized) {
                shift = NSMaxRange(rewrite.original) - NSMaxRange(rewrite.normalized)
                continue
            }
            if offset > rewrite.normalized.location {
                return snapToEnd ? NSMaxRange(rewrite.original) : rewrite.original.location
            }
            break
        }
        return offset + shift
    }

    /// One spelled number, in this order of alternatives so the longest
    /// reading wins: a hundreds form ("a hundred", "one hundred and sixty"),
    /// the hyphenated "one-sixty" form, a tens word with an optional ones
    /// word ("thirty-one"), a ones or teens word. Optional leading
    /// "negative", optional "point" followed by digit words. The value is
    /// read from the matched words by `spelledNumberReplacement`.
    ///
    /// Alternations are sorted longest-first so "ten" can't match the start
    /// of "tenth".
    ///
    /// A normal `"..."` string with standard interpolation, NOT a
    /// raw-string + concat (the `\#"#` delimiter dance). The raw-string
    /// form silently produces an unused-variable warning because `\#"#`
    /// is parsed as literal characters rather than exit-raw-string +
    /// re-enter, so the `onesAlts` / `tensAlts` / `digits`
    /// interpolations are never actually inserted. The resulting regex
    /// has empty alternation groups and never matches anything — the
    /// normaliser becomes a silent no-op and voice-mode hallucinations
    /// slip past the verifier.
    private static var spelledNumberPattern: String {
        let onesAlts = onesAndTeens.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let tensAlts = tens.keys.joined(separator: "|")
        let digits = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
            .joined(separator: "|")
        let belowHundred = "(?:(?:\(tensAlts))(?:[-\\s]+(?:\(digits)))?|(?:\(onesAlts)))"
        let hundreds = "(?:a|\(digits))[-\\s]+hundred(?:(?:\\s+and)?[-\\s]+\(belowHundred))?"
        let colloquial = "(?:one|two)-(?:\(tensAlts))(?:-(?:\(digits)))?"
        return "(?i)\\b(?:negative\\s+)?(?:\(hundreds)|\(colloquial)|\(belowHundred))(?:\\s+point(?:\\s+(?:\(digits)))+)?\\b"
    }

    /// The digit string a matched phrase stands for: "negative thirty-one
    /// point seven" is "-31.7". Nil when a word is not a number word
    /// (shouldn't happen given the pattern).
    private static func spelledNumberReplacement(_ phrase: String) -> String? {
        let words = phrase.lowercased().split { $0.isWhitespace || $0 == "-" }.map(String.init)
        let body = words.filter { $0 != "negative" && $0 != "and" }
        let point = body.firstIndex(of: "point") ?? body.endIndex
        guard let integer = spelledInteger(body[..<point]) else { return nil }
        let fraction = body[point...].dropFirst().compactMap { onesAndTeens[$0] }.map(String.init).joined()
        let digits = fraction.isEmpty ? String(integer) : "\(integer).\(fraction)"
        return words.first == "negative" ? "-" + digits : digits
    }

    /// The integer part. "hundred" multiplies what came before it ("a" is
    /// one); a tens word after a lone ones word is the "one-sixty" form and
    /// makes it the hundreds digit; everything else adds.
    private static func spelledInteger(_ words: ArraySlice<String>) -> Int? {
        guard !words.isEmpty else { return nil }
        var value = 0
        var sawHundred = false
        for word in words {
            if word == "hundred" {
                value = max(value, 1) * 100
                sawHundred = true
            } else if word == "a" {
                value = 1
            } else if let ten = tens[word] {
                value = !sawHundred && (1...9).contains(value) ? value * 100 + ten : value + ten
            } else if let one = onesAndTeens[word] {
                value += one
            } else {
                return nil
            }
        }
        return value
    }
}
