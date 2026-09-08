import AVFoundation
import Foundation

/// Homograph / mispronunciation overrides for AVSpeechSynthesizer.
///
/// AVSpeech defaults "live" to the verb /lɪv/ ("I live in Tennessee"),
/// which is wrong every time Emuqu mentions live HR, live pace,
/// or a live session. This module fixes that by letting the assistant
/// attach IPA hints to trouble words, delivered to the synthesiser via
/// `NSAttributedString` with `.accessibilitySpeechIPANotation`.
///
/// Two sources feed the hint list:
///
/// 1. **AI-authored markup.** The assistant can wrap any word that it
///    predicts will be mis-said: `[[live|laɪv]]`, `[[read|rɛd]]`,
///    `[[tear|tɛər]]`. The system prompt's voice overlay documents this.
///
/// 2. **Domain defaults.** Patterns specific to a fitness/recovery app
///    (`live data`, `live HR`, `your live`, `going live`) get the
///    adjective pronunciation automatically — so even if the AI forgets
///    the markup, common phrases don't regress.
///
/// **Respelling fallback.** Several Apple voices —
/// notably Ava, Aaron, and the newer Siri voices — silently ignore
/// `.accessibilitySpeechIPANotation`. Domain rules can therefore carry
/// an optional `respelling` that we *substitute into the spoken text*
/// (display text is unaffected). For "live" we substitute "lyve",
/// which every voice we tested pronounces /laɪv/ via default
/// letter-to-sound rules. Belt and braces: voices that honour IPA still
/// see the IPA hint; voices that don't get the right phonemes from the
/// respelling.
///
/// The module exposes plain-text stripping for the chat bubble (visible
/// text never shows `[[foo|bar]]`) and an attributed-string build for
/// TTS.
enum PhoneticOverrides {
    // MARK: - AI-authored markup

    /// Matches `[[word|IPA]]`. Word is anything non-`|]`, IPA anything
    /// non-`]`. Intentionally two-bracket so it can't collide with the
    /// markdown link syntax `[label](url)` that AssistantCitationResolver
    /// emits, nor with plain single-bracket text the AI sometimes uses.
    private static let markupPattern = #"\[\[([^|\]]+)\|([^\]]+)\]\]"#

    // MARK: - Domain defaults
    //
    // Word: base word we want to override. Pattern: the full phrase that
    // identifies the usage. Replacement: we overlay IPA on just the base
    // word inside the matched phrase, not the whole match. So "live HR"
    // still says "HR" normally — only "live" gets the /laɪv/ override.
    private struct DomainRule {
        let word: String          // e.g. "live"
        let ipa: String           // e.g. "laɪv"
        /// Full phrase regex. Case-insensitive. Must contain `word` as
        /// a substring (matched separately) so we can locate the overlay
        /// range inside the full match.
        let phrasePattern: String
        /// Optional respelling substituted into the resolved (TTS-bound)
        /// text. Belt-and-braces with the IPA hint: many Apple voices
        /// (Ava, Aaron, newer Siri) silently ignore
        /// `.accessibilitySpeechIPANotation`, so we also rewrite the word
        /// to a spelling whose default letter-to-sound rules produce the
        /// right phonemes. MUST be the same UTF-16 length as `word` —
        /// keeps NSRange bookkeeping trivial. Display text is unaffected
        /// (chat bubble uses `stripForDisplay`).
        let respelling: String?
    }

    private static let domainRules: [DomainRule] = [
        // "live" as adjective — by far the most common mispronunciation
        // in this app. AVSpeech defaults to the verb /lɪv/. Respelling
        // "lyve" reliably yields /laɪv/ (long-i) on every Apple voice we
        // tested, so even when the IPA hint is dropped, the right
        // pronunciation comes through.
        //
        // The pattern covers:
        //   1. HRV (`HR\b` alone doesn't match inside "HRV"
        //      because `\b` requires a non-word char after, and `V`
        //      is a word char).
        //   2. Post-expansion abbreviation forms produced by
        //      `TTSTextNormalizer.expandDomainAbbreviations`:
        //      "HR V" / "H R V" / "B P M" / "alpha one". The
        //      normalizer runs BEFORE PhoneticOverrides, so by the
        //      time these rules fire, "HRV" has been spelled out and
        //      the original pattern no longer matches.
        //   3. "live" + measurement nouns the AI commonly speaks
        //      (steps, distance, miles, kilometers, calories, kcal,
        //      power, watts, cadence, training, zone(s)).
        DomainRule(
            word: "live",
            ipa: "laɪv",
            phrasePattern: #"""
            (?i)\blive\s+(?:data|HRV?|H\s?R\s?V?|heart\s*rate|pace|workout|session|feed|alpha(?:-?1)?|alpha\s+one|update|status|numbers?|readings?|stats|values?\#
            |metrics?|map|track|splits?|steps?|distance|miles?|kilometers?|km|calor(?:ies?|ic)|kcal|power|watts?|B\s?P\s?M|cadence|training|zones?)\b
            """#,
            respelling: "lyve"
        ),
        DomainRule(
            word: "live",
            ipa: "laɪv",
            phrasePattern: #"(?i)(?:your|you're|you\s+are|going|right\s+now[^.]*|currently)\s+live\b"#,
            respelling: "lyve"
        ),
        DomainRule(
            word: "live",
            ipa: "laɪv",
            phrasePattern: #"(?i)\blive\s+(?:now|right\s+now|view|screen|tracking|recording)\b"#,
            respelling: "lyve"
        )
    ]

    // MARK: - Public API

    /// Plain text suitable for display. Strips `[[word|IPA]]` markup
    /// down to `word`. Domain rules don't affect display — they're
    /// pronunciation-only.
    static func stripForDisplay(_ text: String) -> String {
        text.replacingOccurrences(
            of: markupPattern,
            with: "$1",
            options: .regularExpression
        )
    }

    /// Build an AVSpeech-ready attributed string. Starts from the
    /// display-safe text, then layers IPA attributes onto any ranges
    /// we have hints for (AI markup first, then domain defaults —
    /// AI-authored wins on overlap).
    ///
    /// Applied in order; a later rule that overlaps an earlier one
    /// overwrites the attribute, which is fine — `resolve()` already put AI
    /// hints first so domain rules can't clobber them.
    static func speechAttributedString(_ text: String) -> NSAttributedString {
        let (plain, hints) = resolve(text)
        let attr = NSMutableAttributedString(string: plain)
        for hint in hints where isApplicable(hint, attrLength: attr.length) {
            attr.addAttribute(.accessibilitySpeechIPANotation, value: hint.ipa, range: hint.range)
        }
        return attr
    }

    /// `NSMutableAttributedString.addAttribute` raises an Obj-C
    /// exception (which Swift can't catch) if the range is malformed.
    /// Validate exhaustively before each call: location and length
    /// both non-negative, NOT NSNotFound, and the end stays within
    /// the string's UTF-16 length. Any failure is logged and skipped
    /// so a single bad hint can't take the process down — which has
    /// come up with mixed-script (e.g. Japanese + English) input
    /// where the resolved-string indexing got out of step with the
    /// hint NSRange. Empty ranges are no-ops, so they're skipped silently.
    private static func isApplicable(_ hint: Hint, attrLength: Int) -> Bool {
        let r = hint.range
        guard r.location != NSNotFound, r.location >= 0, r.length > 0,
              r.location <= attrLength, r.location + r.length <= attrLength
        else {
            debugLog("[PhoneticOverrides] skipping out-of-bounds hint: range=\(r), attrLength=\(attrLength), source=\(hint.source)", level: .warning)
            return false
        }
        return true
    }

    // MARK: - Resolution

    struct Hint {
        let range: NSRange   // range in the RESOLVED plain string
        let ipa: String
        let source: Source
        enum Source { case authored, domain }
    }

    /// Extract hints and return the display-safe text together with the
    /// hint ranges tied to that text. Exposed for tests.
    ///
    /// The pre-pass expands US ZIP codes from numeric
    /// ("37090") to spaced-digit form ("3 7 0 9 0") so AVSpeech
    /// reads them digit-by-digit instead of as a number
    /// ("thirty seven thousand ninety"). User report: "it always
    /// says 'thirty seven thousand' for my zip code."
    static func resolve(_ input: String) -> (plain: String, hints: [Hint]) {
        var (out, hints) = stripAuthoredMarkup(expandZipCodes(input))
        for rule in domainRules {
            applyDomainRule(rule, to: &out, hints: &hints)
        }
        return (out, hints)
    }

    /// Pass 1: strip AI-authored markup and record where each replacement
    /// ended up in the output string. We walk the input left-to-right,
    /// appending to `out` as we go, so we can compute NSRanges against the
    /// RESOLVED string (what TTS will see). NSRange is UTF-16 based, so
    /// lengths come from `NSString` to match NSAttributedString's indexing.
    private static func stripAuthoredMarkup(_ input: String) -> (String, [Hint]) {
        guard let regex = try? NSRegularExpression(pattern: markupPattern) else { return (input, []) }
        var hints: [Hint] = []
        var out = ""
        var cursor = input.startIndex
        let ns = input as NSString
        for match in regex.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges == 3,
                  let fullRange = Range(match.range, in: input),
                  let wordRange = Range(match.range(at: 1), in: input),
                  let ipaRange = Range(match.range(at: 2), in: input)
            else { continue }
            out += input[cursor ..< fullRange.lowerBound] // everything up to the match
            let word = String(input[wordRange])
            let location = (out as NSString).length
            out += word
            let range = NSRange(location: location, length: (word as NSString).length)
            hints.append(Hint(range: range, ipa: String(input[ipaRange]), source: .authored))
            cursor = fullRange.upperBound
        }
        return (out + input[cursor...], hints)
    }

    /// Pass 2: domain defaults scan the RESOLVED text. A domain hit
    /// that falls inside an authored range gets skipped so the
    /// assistant's explicit choice wins.
    ///
    /// Re-scans `out` for each rule because earlier rules may have
    /// substituted respellings into it. Substituted words no longer match the
    /// original word boundary, which is what we want — it keeps a single rule
    /// from firing twice on the same span via different surface forms.
    private static func applyDomainRule(_ rule: DomainRule, to out: inout String, hints: inout [Hint]) {
        guard let ruleRegex = try? NSRegularExpression(pattern: rule.phrasePattern) else { return }
        let nsScan = out as NSString
        let phraseMatches = ruleRegex.matches(in: out, range: NSRange(location: 0, length: nsScan.length))
        for phraseMatch in phraseMatches {
            guard let absoluteRange = wordRange(of: rule, in: phraseMatch.range, scanning: nsScan),
                  !overlapsAuthored(absoluteRange, hints) else { continue }
            applyRespelling(rule, at: absoluteRange, to: &out)
            hints.append(Hint(range: absoluteRange, ipa: rule.ipa, source: .domain))
        }
    }

    /// Find the rule's word inside the matched phrase so we overlay just that
    /// span, not the whole phrase. Every bound is re-checked against the
    /// scanned string: even if the arithmetic produced something off (say, a
    /// mixed-script substring length anomaly), we must not hand
    /// NSAttributedString an out-of-bounds range.
    private static func wordRange(
        of rule: DomainRule,
        in phraseRange: NSRange,
        scanning nsScan: NSString
    ) -> NSRange? {
        let outLength = nsScan.length
        guard phraseRange.location != NSNotFound, phraseRange.location >= 0,
              phraseRange.length > 0,
              phraseRange.location + phraseRange.length <= outLength else { return nil }
        let phraseText = nsScan.substring(with: phraseRange)
        guard let wordSubRange = phraseText.range(of: rule.word, options: [.caseInsensitive]) else { return nil }
        let wordNSRange = NSRange(wordSubRange, in: phraseText)
        guard wordNSRange.location != NSNotFound, wordNSRange.location >= 0,
              wordNSRange.length > 0 else { return nil }
        let absoluteLoc = phraseRange.location + wordNSRange.location
        guard absoluteLoc + wordNSRange.length <= outLength else { return nil }
        return NSRange(location: absoluteLoc, length: wordNSRange.length)
    }

    /// True when an AI-authored hint already covers this span.
    private static func overlapsAuthored(_ range: NSRange, _ hints: [Hint]) -> Bool {
        hints.contains { $0.source == .authored && NSIntersectionRange($0.range, range).length > 0 }
    }

    /// Where a rule has a `respelling`, we ALSO mutate `out` to substitute the
    /// matched word — this guards against voices that ignore
    /// `.accessibilitySpeechIPANotation`. The respelling must be the same
    /// UTF-16 length as the matched word so the absolute ranges we record stay
    /// valid for every later hint and rule pass; length-mismatched respellings
    /// are skipped (with a log) because shifting later ranges would silently
    /// corrupt every other hint we've recorded.
    private static func applyRespelling(_ rule: DomainRule, at range: NSRange, to out: inout String) {
        guard let respelling = rule.respelling else { return }
        let respellNSLen = (respelling as NSString).length
        guard respellNSLen == range.length else {
            debugLog("[PhoneticOverrides] skipping respelling for '\(rule.word)' — length \(respellNSLen) != \(range.length)", level: .warning)
            return
        }
        let mutable = NSMutableString(string: out)
        // Preserve the case of the leading character so "Live data" → "Lyve
        // data", not "lyve data".
        let original = (mutable as NSString).substring(with: range)
        mutable.replaceCharacters(in: range, with: matchLeadingCase(of: respelling, to: original))
        out = mutable as String
    }

    /// Expand US ZIP codes ("37090") to spaced-digit form ("3 7 0 9 0")
    /// so AVSpeech pronounces each digit individually instead of
    /// reading the number as a whole ("thirty seven thousand ninety").
    /// Two contexts trigger expansion:
    ///   1. Preceded by "zip", "zip code", or "postal code"
    ///   2. The second token in a "<state code> <ZIP>" pattern
    ///      (e.g. "Lebanon, TN 37090")
    /// ZIP+4 ("37090-1234") gets the same treatment, with the dash
    /// preserved as a pause.
    static func expandZipCodes(_ input: String) -> String {
        // Pattern A: explicit ZIP context ("zip 37090", "ZIP code 37090",
        // "postal code 37090"). Capture group 1 = label run-up so we
        // can preserve it; group 2 = the digits.
        let explicitPattern = #"(?i)(\b(?:zip(?:\s*code)?|postal\s*code)\b\s*:?\s*)(\d{5})(?:(-\d{4}))?\b"#
        // Pattern B: 2-letter state + 5-digit ZIP. The state code must
        // be uppercase to avoid false-positives on words like "as"
        // followed by a number.
        let statePattern = #"\b([A-Z]{2})\s+(\d{5})(?:(-\d{4}))?\b"#
        var out = input
        for pattern in [explicitPattern, statePattern] {
            out = expandZips(in: out, pattern: pattern)
        }
        return out
    }

    /// One pattern's worth of expansion. Iterates matches RIGHT-TO-LEFT so
    /// each replacement doesn't invalidate earlier match ranges — Apple's
    /// `replacingMatches(in:options:range:withTemplate:)` doesn't exist, so we
    /// iterate manually.
    private static func expandZips(in text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        let ns = out as NSString
        let matches = regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            guard let (range, replacement) = zipReplacement(for: match, in: ns) else { continue }
            out = (out as NSString).replacingCharacters(in: range, with: replacement)
        }
        return out
    }

    /// The span to replace and the spaced-digit text to put there, or nil when
    /// the match isn't a well-formed ZIP. A ZIP+4 suffix is preserved as
    /// "dash 1 2 3 4" and folded into the same replacement span.
    private static func zipReplacement(for match: NSTextCheckingResult, in ns: NSString) -> (NSRange, String)? {
        guard match.numberOfRanges >= 3 else { return nil }
        let zipRange = match.range(at: 2)
        guard zipRange.location != NSNotFound, zipRange.length == 5,
              zipRange.location + zipRange.length <= ns.length else { return nil }
        let spaced = spacedDigits(ns.substring(with: zipRange))
        guard match.numberOfRanges >= 4 else { return (zipRange, spaced) }
        let suffixRange = match.range(at: 3)
        guard suffixRange.location != NSNotFound, suffixRange.length == 5 else {
            return (zipRange, spaced)
        }
        // The suffix starts with "-"; spell the remaining digits.
        let suffixDigits = spacedDigits(String(ns.substring(with: suffixRange).dropFirst()))
        let combined = NSRange(location: zipRange.location, length: zipRange.length + suffixRange.length)
        return (combined, spaced + " dash " + suffixDigits)
    }

    /// "37090" → "3 7 0 9 0".
    private static func spacedDigits(_ s: String) -> String {
        s.map { String($0) }.joined(separator: " ")
    }

    /// Copy the leading-character case from `original` onto `replacement`.
    /// Keeps "Live data" → "Lyve data" instead of "lyve data" when the
    /// AI emits sentence-initial capitalisation. Only the first character
    /// is adjusted — multi-letter casing patterns aren't worth the cost
    /// for our current respellings.
    private static func matchLeadingCase(of replacement: String, to original: String) -> String {
        guard let firstOriginal = original.first,
              let firstReplacement = replacement.first
        else { return replacement }
        if firstOriginal.isUppercase, firstReplacement.isLowercase {
            return firstReplacement.uppercased() + replacement.dropFirst()
        }
        return replacement
    }
}
