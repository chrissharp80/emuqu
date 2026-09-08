import Foundation
import os

/// Programmatic hallucination guard for the AI coach (item #9).
///
/// The system-prompt overlay tells the model "don't invent numbers,"
/// but the user has reported the coach quoting metrics that contradict
/// the live snapshot. Prompt-level guardrails are necessary but not
/// sufficient; this module is the runtime backstop.
///
/// **Approach.** Scan the assistant's drafted response for
/// high-confidence numeric patterns (`<int> bpm`, `<int> W`,
/// `<float>% drift`, `α1 at <float>`). For each hit, look up the
/// authoritative value in the current `WorkoutAIContext` snapshot.
/// If the cited number deviates from the snapshot by more than the
/// configured tolerance, emit a `Discrepancy`.
///
/// **Caller responsibility.** This utility never mutates the response
/// — callers decide what to do with the discrepancies (log, strike
/// the offending sentence, replace with `[verified]` annotation,
/// etc.). Today the chat pipeline logs them as warnings so we get
/// observability before deciding on auto-correction policy.
///
/// Pure, sync, isolated to nothing — safe to call from any actor.
enum MetricsVerifier {
    // The regex compiles here must not `try?` and return `[]` on failure:
    // `[]` means "no discrepancies", so a malformed pattern would not
    // disable one check loudly; it would silently PASS every numeric claim
    // the model made about that metric. Verification failing open is worse
    // than no verification, because the surface still reports "verified".
    //
    // They route through `DebugLogger.compiledPattern`, which caches and
    // logs a compile failure instead of swallowing it. `MetricsVerifierPatternTests`
    // compiles every literal pattern in this file so a typo fails the suite.
    struct Discrepancy: Equatable, Sendable {
        /// Short label of the metric ("HR", "power_watts", "alpha1",
        /// "hr_drift_percent"). Stable so callers can group / filter.
        let metric: String
        /// What the AI claimed, in the original textual form.
        let claimed: String
        /// What the snapshot reports, formatted to match `claimed`'s
        /// units. Useful for log output and possible auto-correction.
        let actual: String
        /// Numeric absolute difference between parsed-claim and actual.
        /// Lets callers decide on severity ("trivial 1 bpm rounding"
        /// vs "30 bpm fabrication").
        let absoluteDelta: Double
        /// The character range in the original response where the
        /// claim was located. Lets the caller redact / replace just
        /// the offending span.
        let range: Range<String.Index>
    }

    // MARK: - Per-metric claim checks
    //
    // One function per metric. Each scans the model's text for a claimed value
    // and reports it only when it disagrees with the snapshot by more than that
    // metric's tolerance — the tolerances differ because the metrics do.
    //
    // Each takes a `snapshot`; when the field it needs is nil, verification is
    // skipped for that metric (the AI might be replying about a topic with no
    // live workout in flight).

    /// Claims about heart-rate: "142 bpm" / "142 BPM". The 5 bpm tolerance
    /// covers averaging windows + sample drift without letting a 30-bpm
    /// fabrication slide.
    private static func heartRateDiscrepancies(
        in text: String,
        snapshot: WorkoutAIContext
    ) -> [Discrepancy] {
        guard let hr = snapshot.heartRate else { return [] }
        return claimsMatching(
            in: text, pattern: #"(\b\d{2,3})\s*(?:bpm|BPM)\b"#,
            actual: Double(hr), tolerance: 5, metric: "HR",
            formatter: { "\(Int($0.rounded())) bpm" }
        )
    }

    /// Claims about power: "265 W" / "265 watts" / "265 watt".
    ///
    /// 15 W tolerance — running power is noisy.
    private static func powerDiscrepancies(
        in text: String,
        snapshot: WorkoutAIContext
    ) -> [Discrepancy] {
        guard let actualW = snapshot.powerWatts else { return [] }
        return matches(in: text, pattern: #"(\b\d{2,4})\s*(?:W\b|watts?\b)"#).compactMap {
            powerDiscrepancy($0, in: text, actualW: actualW)
        }
    }

    private static func powerDiscrepancy(
        _ match: NSTextCheckingResult,
        in text: String,
        actualW: Int
    ) -> Discrepancy? {
        let claimedStr = (text as NSString).substring(with: match.range(at: 1))
        guard let claimed = Int(claimedStr) else { return nil }
        let delta = abs(claimed - actualW)
        guard delta > 15, let r = Range(match.range, in: text) else { return nil }
        return Discrepancy(
            metric: "power_watts",
            claimed: "\(claimed) W",
            actual: "\(actualW) W",
            absoluteDelta: Double(delta),
            range: r
        )
    }

    /// Claims about DFA α1: "α1 at 0.72" / "DFA α1 of 0.65" / "alpha1 = 1.05".
    /// Matches either the Greek α or the spelled-out "alpha", followed by an
    /// optional "1", a small connector, and a decimal value. The 0.10
    /// tolerance is the smallest physiologically meaningful difference.
    private static func alpha1Discrepancies(
        in text: String,
        snapshot: WorkoutAIContext
    ) -> [Discrepancy] {
        guard let actual = snapshot.alpha1 else { return [] }
        return claimsMatching(
            in: text,
            pattern: #"(?:α1|alpha\s*1?|DFA\s*α1)\s*(?:at|of|=|is|sat at|sitting at)?\s*(\d+\.\d+)"#,
            actual: actual, tolerance: 0.10, metric: "alpha1",
            formatter: { String(format: "%.2f", $0) }
        )
    }

    /// Claims about HR-drift: "drifted 8.5%" / "8% HR drift" / "HR drift 6%".
    private static func hrDriftDiscrepancies(
        in text: String,
        snapshot: WorkoutAIContext
    ) -> [Discrepancy] {
        guard let actual = snapshot.liveHRDriftPercent else { return [] }
        return claimsMatching(
            in: text,
            pattern: #"(?:HR\s*drift(?:ed)?(?:\s*by)?\s*|drift(?:ed)?\s*by\s*)(\d+(?:\.\d+)?)\s*%"#,
            actual: actual, tolerance: 1.5, metric: "hr_drift_percent",
            formatter: { String(format: "%.1f%%", $0) }
        )
    }

    static func verify(_ text: String, against snapshot: WorkoutAIContext?) -> [Discrepancy] {
        guard let snapshot else { return [] }
        var found: [Discrepancy] = []

        found += heartRateDiscrepancies(in: text, snapshot: snapshot)
        found += powerDiscrepancies(in: text, snapshot: snapshot)
        found += alpha1Discrepancies(in: text, snapshot: snapshot)
        found += hrDriftDiscrepancies(in: text, snapshot: snapshot)

        return found
    }

    /// Verify training-load + overnight HRV claims against the
    /// app's source-of-truth values (TrainingMetricsCache for ATL /
    /// CTL / TSB; latest archived overnight session for RMSSD /
    /// recovery score). Catches the lying class that hits the user
    /// hardest on a walk: the model quoting TSB values
    /// across turns that range from −9 to −29 while the dashboard
    /// showed a single stable value. Same Discrepancy shape +
    /// recordCorrections flow as `verify(_:against:)` so the
    /// existing TTS substitution + next-turn-warning pipeline picks
    /// these up uniformly.
    ///
    /// Result of an app-state verification pass.
    ///
    /// Not a bare `[Discrepancy]`: the Discrepancy ranges are in
    /// the NORMALIZED text (after `normalizeSpelledNumbers` rewrites
    /// "negative thirty-one point seven" → "-31.7"), so callers can't
    /// apply those ranges to the ORIGINAL text without producing
    /// garbled output (e.g. "-24.8ive thirteen point seven" — a real
    /// user-visible bug in voice-chat transcripts). The
    /// result carries `correctedText` directly so the caller
    /// substitutes the whole string atomically rather than trying to
    /// splice ranges that don't line up with the source.
    struct AppStateVerifyResult {
        let discrepancies: [Discrepancy]
        /// Fully-substituted text in normalized (digit) form. nil when
        /// no discrepancies were detected (caller keeps original text).
        let correctedText: String?
    }

    /// Reads from MainActor singletons — assumes caller is on main
    /// (matches the existing AssistantViewModel + voice pipeline).
    ///
    /// Normalise spelled-out numbers to digits BEFORE
    /// matching. The regexes use `\d+`-based capture groups, which means in
    /// VOICE mode (where the AI replies with conversational spelled-out
    /// numbers — "TSB negative thirty-one point seven") every wrong value
    /// would escape the verifier. User report: Grok said TSB -31.7 / ATL 66.8
    /// while Dashboard had TSB -18.6 / ATL 54.0; the verifier logged no
    /// discrepancy because the text contained zero digits to match against.
    /// The normaliser converts "negative thirty-one point seven" → "-31.7"
    /// so the same regex catches both forms.
    @MainActor
    static func verifyAppStateClaims(_ text: String) -> AppStateVerifyResult {
        let normalized = normalizeSpelledNumbers(text)
        let found = trainingLoadDiscrepancies(in: normalized) + overnightDiscrepancies(in: normalized)
        return AppStateVerifyResult(
            discrepancies: found,
            correctedText: correctedText(from: normalized, applying: found)
        )
    }

    /// Training load — ATL / CTL / TSB / ACWR.
    ///
    /// Source of truth is `TrainingLoadRegistry.live()`,
    /// the same accessor the Dashboard, AI live block, and AI tools
    /// (`training.load.*`, `workout.live.today_readiness`) use. Reading
    /// `cache.sampleOn(today)` directly can lag
    /// `cache.current` by up to ~4 s during refresh — meaning the
    /// verifier would sometimes flag the AI's correct answer as a
    /// discrepancy. Routing through the registry makes verifier +
    /// model + dashboard share one truth.
    ///
    /// Tolerances match the dashboard's own rounding: no more than ±2 units
    /// for TSB, ±3 for ATL/CTL.
    ///
    /// The TSB pattern matches both an explicit minus and the spelled-out
    /// "negative N" the model sometimes emits: "TSB -17.2", "TSB negative
    /// 29", "TSB 7".
    @MainActor
    private static func trainingLoadDiscrepancies(in text: String) -> [Discrepancy] {
        guard let load = TrainingLoadRegistry.live() else { return [] }
        var found = claimsMatching(
            in: text, pattern: #"\bTSB\s+(?:negative\s+)?(-?\d+(?:\.\d+)?)"#,
            actual: load.tsb, tolerance: 2.0, metric: "TSB",
            negateOnSpelled: true, formatter: { String(format: "%+.1f", $0) }
        )
        found += claimsMatching(
            in: text, pattern: #"\bATL\s+(\d+(?:\.\d+)?)"#, actual: load.atl,
            tolerance: 3.0, metric: "ATL", formatter: { String(format: "%.1f", $0) }
        )
        found += claimsMatching(
            in: text, pattern: #"\bCTL\s+(\d+(?:\.\d+)?)"#, actual: load.ctl,
            tolerance: 3.0, metric: "CTL", formatter: { String(format: "%.1f", $0) }
        )
        guard let acwr = load.acwr else { return found }
        return found + claimsMatching(
            in: text, pattern: #"\bACWR\s+(\d+(?:\.\d+)?)"#, actual: acwr,
            tolerance: 0.15, metric: "ACWR", formatter: { String(format: "%.2f", $0) }
        )
    }

    /// Overnight HRV — RMSSD + recovery score. Source of truth: the latest
    /// archived overnight session.
    @MainActor
    private static func overnightDiscrepancies(in text: String) -> [Discrepancy] {
        let session = latestReliableOvernight()
        var found: [Discrepancy] = []
        if let rmssd = session?.analysisResult?.timeDomain.rmssd {
            // "RMSSD 68 ms" / "RMSSD 76" / "RMSSD of 68"
            found += claimsMatching(
                in: text, pattern: #"\bRMSSD\s+(?:of\s+)?(\d+(?:\.\d+)?)\s*(?:ms)?"#,
                actual: rmssd, tolerance: 8.0, metric: "RMSSD",
                negateOnSpelled: false, formatter: { String(format: "%.0f ms", $0) }
            )
        }
        if let score10 = session?.recoveryScore {
            found += recoveryScoreClaims(in: text, score10: score10)
        }
        return found
    }

    /// The AI's numeric-claim verifier must validate against a
    /// trustworthy overnight, not an `.insufficient`/`.preSleep` partial
    /// (see isReliableForHRVAggregates); the full session carries the flag.
    @MainActor
    private static func latestReliableOvernight() -> HRVSession? {
        let archive = AppDependencies.current.storage.sessionArchive
        return archive.entries
            .filter { $0.sessionType == .overnight }
            .sorted { $0.date > $1.date }
            .lazy
            .compactMap { archive.retrieveLightweightOrLog($0.sessionId) }
            .first { ($0.analysisResult != nil || $0.recoveryScore != nil) && $0.isReliableForHRVAggregates }
    }

    /// "Recovery 9.1 of 10" / "Recovery 91" / "score 8.2" — both the 0–10 and
    /// the 0–100 scale are reasonable, so a claim that matches the 0–10 form
    /// within tolerance is a different scale, not a lie.
    private static func recoveryScoreClaims(in text: String, score10: Double) -> [Discrepancy] {
        claimsMatching(
            in: text, pattern: #"(?:Recovery|recovery)\s+(\d+(?:\.\d+)?)\b"#,
            actual: score10 * 10, // assume 0-100 form first
            tolerance: 4.0, metric: "recovery_score",
            negateOnSpelled: false, formatter: { String(format: "%.1f", $0) }
        ).filter { d in
            guard let claimedNum = Double(d.claimed.split(separator: " ").first ?? "") else { return true }
            return abs(claimedNum - score10) > 1.0
        }
    }

    /// Splice the actual values into the NORMALIZED text using
    /// the ranges captured from it. Crucially: the ranges only line up with
    /// the normalized version, NOT the original. Apply back-to-front so
    /// earlier ranges stay valid as later ones shrink the string.
    private static func correctedText(from text: String, applying found: [Discrepancy]) -> String? {
        guard !found.isEmpty else { return nil }
        var corrected = text
        for d in found.sorted(by: { $0.range.lowerBound > $1.range.lowerBound })
        where d.range.lowerBound >= corrected.startIndex && d.range.upperBound <= corrected.endIndex {
            corrected.replaceSubrange(d.range, with: d.actual)
        }
        return corrected
    }

    /// What one claim is checked against: the true value, how far off a claim
    /// may be before it counts, and how to render both for the user.
    private struct ClaimCheck {
        let actual: Double
        let tolerance: Double
        let metric: String
        /// True when the regex can match a spelled-out "negative N" form, in
        /// which case the captured magnitude has to be negated by hand.
        let negateOnSpelled: Bool
        let formatter: (Double) -> String
    }

    /// Generic helper for App-state claim matching. Pulls the captured
    /// numeric group, parses it, applies the negate-on-spelled rule
    /// when the regex matched a "negative N" form, then compares
    /// against `actual` with `tolerance`. Emits a Discrepancy when the
    /// claim exceeds tolerance.
    private static func claimsMatching(
        in text: String,
        pattern: String,
        actual: Double,
        tolerance: Double,
        metric: String,
        negateOnSpelled: Bool = false,
        formatter: @escaping (Double) -> String
    ) -> [Discrepancy] {
        guard let regex = DebugLogger.compiledPattern(pattern, options: [.caseInsensitive]) else {
            return []
        }
        let check = ClaimCheck(
            actual: actual, tolerance: tolerance, metric: metric,
            negateOnSpelled: negateOnSpelled, formatter: formatter
        )
        let ns = text as NSString
        let all = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return all.compactMap { discrepancy(from: $0, in: text, ns: ns, check: check) }
    }

    /// One regex match as a Discrepancy, or nil when it doesn't parse or
    /// lands inside tolerance.
    private static func discrepancy(
        from match: NSTextCheckingResult,
        in text: String,
        ns: NSString,
        check: ClaimCheck
    ) -> Discrepancy? {
        guard match.numberOfRanges >= 2,
              var claimed = Double(ns.substring(with: match.range(at: 1))) else { return nil }
        if check.negateOnSpelled, ns.substring(with: match.range).lowercased().contains("negative") {
            claimed = -abs(claimed)
        }
        let delta = abs(claimed - check.actual)
        guard delta > check.tolerance, let r = Range(match.range, in: text) else { return nil }
        return Discrepancy(
            metric: check.metric, claimed: check.formatter(claimed),
            actual: check.formatter(check.actual), absoluteDelta: delta, range: r
        )
    }

    /// Format a list of discrepancies for a single warning log line.
    /// Stable representation so log scrapers can grep for them.
    static func formatForLog(_ discrepancies: [Discrepancy]) -> String {
        guard !discrepancies.isEmpty else { return "" }
        let parts = discrepancies.map { d in
            "\(d.metric)=claimed:\(d.claimed) actual:\(d.actual) Δ\(String(format: "%.1f", d.absoluteDelta))"
        }
        return "[Hallucination guard] \(parts.joined(separator: " | "))"
    }

    // MARK: - Pending corrections (cross-turn feedback)
    //
    // From a real user log: the hallucination guard caught two HR
    // fabrications on consecutive turns ("claimed:72 actual:91",
    // "claimed:71 actual:88"). The guard substituted the correct
    // number into the spoken output but the MODEL kept doing it
    // because nothing told it not to. This buffer carries
    // unconsumed corrections forward so the next turn's system
    // prompt can include "you fabricated HR=72 last turn — actual
    // was 91; call get_workout_live for HR, don't guess." The buffer
    // is consumed (cleared) when the system prompt reads it, so a
    // single fabrication produces ONE reminder, not a perpetual one.
    //
    // Process-local; cleared on app launch. NSLock-guarded since
    // both the speaker thread (writes) and the AssistantViewModel
    // dispatch path (reads) hit it.

    private static let pendingCorrections = OSAllocatedUnfairLock<[Discrepancy]>(initialState: [])

    /// Record discrepancies caught by the hallucination guard so the
    /// next AI turn's system prompt can warn the model. Caps at 4
    /// entries to keep the reminder short — a model fabricating > 4
    /// numbers in one turn has bigger problems than this hint can
    /// fix.
    static func recordCorrections(_ discrepancies: [Discrepancy]) {
        guard !discrepancies.isEmpty else { return }
        pendingCorrections.withLock { pending in
            pending.append(contentsOf: discrepancies)
            if pending.count > 4 { pending = Array(pending.suffix(4)) }
        }
    }

    /// Render any pending corrections as a single short system-prompt
    /// reminder, clearing the buffer. Returns nil when there's
    /// nothing to surface. Called by `AssistantSystemPrompt.compose`
    /// for every send so the reminder lands on the very next turn
    /// after a fabrication.
    static func consumePendingCorrectionsBlock() -> String? {
        let corrections = pendingCorrections.withLock { pending in
            defer { pending = [] }
            return pending
        }
        guard !corrections.isEmpty else { return nil }
        // Compact format: one line per correction, leading rule.
        var lines: [String] = [
            "# Last turn correction — DO NOT FABRICATE",
            """
                Your previous response contained numbers that contradicted live data. The values were silently corrected before TTS so the user heard the right number, but you SAID the wrong one. For any of these metrics next turn, CALL the appropriate \
                live tool (get_workout_live for HR / pace / location, lookup_fact for resting HR / HRV) and quote what comes back — never estimate or interpolate.
                """
        ]
        for d in corrections {
            lines.append("• You said \(d.metric)=\(d.claimed) — actual was \(d.actual).")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    private static func matches(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> [NSTextCheckingResult] {
        guard let regex = DebugLogger.compiledPattern(pattern, options: options) else {
            return []
        }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    }

    // MARK: - Spelled-number normalisation (voice-mode discrepancy capture)
    //
    // The verifier's main regexes look for digit characters
    // (`\d+(?:\.\d+)?`). In voice mode the AI replies conversationally
    // — "TSB negative thirty-one point seven" — and zero digits appear.
    // Every wrong metric in voice mode was invisible to the verifier.
    // This normaliser converts the common patterns the AI emits into
    // digit form BEFORE the regexes scan the text. Conservative: only
    // handles 0–99 with an optional decimal-place digit after "point",
    // which is the range every HRV / load metric uses.

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

    /// Returns `text` with sequences like "negative thirty-one point
    /// seven" rewritten to "-31.7". Idempotent: digit-form text passes
    /// through unchanged. Case-insensitive.
    static func normalizeSpelledNumbers(_ text: String) -> String {
        guard let regex = DebugLogger.compiledPattern(spelledNumberPattern) else {
            return text
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        // Reverse iteration so range indices stay valid as we splice.
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            guard let rep = spelledNumberReplacement(for: match, in: ns) else { continue }
            mutable.replaceCharacters(in: match.range, with: rep)
        }
        return mutable as String
    }

    /// Capture groups:
    ///  1: optional "negative" (sign)
    ///  2: ones-or-teen word     (e.g. "seventeen")  — primary value path A
    ///  3: tens word             (e.g. "thirty")     — primary value path B
    ///  4: ones suffix after tens (e.g. "one" in "thirty-one")
    ///  5: digit word after "point" (e.g. "seven" in "point seven")
    ///
    /// Alternations are sorted longest-first so "ten" can't match the start
    /// of "tenth".
    ///
    /// A normal `"..."` string with standard interpolation, NOT a
    /// raw-string + concat (the `\#"#` delimiter dance). The raw-string
    /// form silently produces an unused-variable warning because `\#"#`
    /// is parsed as literal characters rather than exit-raw-string +
    /// re-enter, so the `onesAlts` / `tensAlts` / `singleDigitWords`
    /// interpolations are never actually inserted. The resulting regex
    /// has empty alternation groups and never matches anything — the
    /// normaliser becomes a silent no-op and voice-mode hallucinations
    /// slip past the verifier.
    private static var spelledNumberPattern: String {
        let onesAlts = onesAndTeens.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let tensAlts = tens.keys.joined(separator: "|")
        let digits = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
            .joined(separator: "|")
        return "(?i)\\b(negative\\s+)?(?:(\(onesAlts))|(\(tensAlts))(?:[-\\s]+(\(digits)))?)(?:\\s+point\\s+(\(digits)))?\\b"
    }

    /// The digit string one match should become, or nil when no value word
    /// actually matched (shouldn't happen given the pattern).
    private static func spelledNumberReplacement(for match: NSTextCheckingResult, in ns: NSString) -> String? {
        guard let integer = spelledInteger(from: match, in: ns) else { return nil }
        var rep = String(integer)
        let pointRange = match.range(at: 5)
        if pointRange.location != NSNotFound {
            rep += ".\(onesAndTeens[ns.substring(with: pointRange).lowercased()] ?? 0)"
        }
        return match.range(at: 1).location != NSNotFound ? "-" + rep : rep
    }

    /// The integer part: either a ones/teens word on its own, or a tens word
    /// with an optional ones suffix ("thirty-one").
    private static func spelledInteger(from match: NSTextCheckingResult, in ns: NSString) -> Int? {
        let onesRange = match.range(at: 2)
        if onesRange.location != NSNotFound {
            return onesAndTeens[ns.substring(with: onesRange).lowercased()] ?? 0
        }
        let tensRange = match.range(at: 3)
        guard tensRange.location != NSNotFound else { return nil }
        var value = tens[ns.substring(with: tensRange).lowercased()] ?? 0
        let suffixRange = match.range(at: 4)
        if suffixRange.location != NSNotFound {
            value += onesAndTeens[ns.substring(with: suffixRange).lowercased()] ?? 0
        }
        return value
    }
}
