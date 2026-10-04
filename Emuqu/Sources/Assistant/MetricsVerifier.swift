import Foundation
import os

/// Programmatic hallucination guard for the AI coach (item #9).
///
/// The system-prompt overlay tells the model "don't invent numbers,"
/// but the user has reported the coach quoting metrics that contradict
/// the live snapshot. Prompt-level guardrails are necessary but not
/// sufficient; this module is the runtime backstop.
///
/// **Approach.** Scan the assistant's drafted response for claims about
/// the CURRENT value of a metric ("your HR is 142 bpm", "TSB -17.2").
/// For each hit, look up the authoritative value in the current
/// `WorkoutAIContext` snapshot (or app state). If the cited number deviates
/// by more than the metric's tolerance, emit a `Discrepancy`.
///
/// **What is not a claim.** A number is only checked when the text says it
/// is the value now. Targets ("keep it under 150 bpm"), other metrics
/// ("your resting HR was 52 bpm"), history ("recovery 3 days ago was 55"),
/// durations ("CTL 42-day window") and comparisons are skipped, because
/// rewriting them to the live value would make a true sentence false.
///
/// **Caller responsibility.** This type never mutates the response it is
/// given. `Discrepancy.range` covers only the claimed value and its unit,
/// never the metric's label, so a caller that replaces that span with
/// `Discrepancy.actual` keeps the sentence intact. The voice pipeline does
/// exactly that before TTS, and also applies `verifyAppStateClaims`'s
/// `correctedText` to each spoken chunk; the chat pipeline applies
/// `correctedText` to the saved turn.
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
    // logs a compile failure instead of swallowing it.
    // `RedactionPatternTests.testEveryLiteralPatternInFailOpenSourcesCompiles`
    // compiles every raw-string pattern in this file, so each one is written
    // as a complete pattern rather than assembled from fragments.
    //
    // Every claim pattern names two groups: `value`, the number checked, and
    // `claim`, the span a correction replaces (the number plus its unit).
    struct Discrepancy: Equatable, Sendable {
        /// Short label of the metric ("HR", "power_watts", "alpha1",
        /// "hr_drift_percent"). Stable so callers can group / filter.
        let metric: String
        /// What the AI claimed, formatted like `actual`.
        let claimed: String
        /// What the snapshot reports, formatted to replace the claimed span.
        let actual: String
        /// Numeric absolute difference between parsed-claim and actual.
        /// Lets callers decide on severity ("trivial 1 bpm rounding"
        /// vs "30 bpm fabrication").
        let absoluteDelta: Double
        /// The claimed value and its unit in the text that was verified.
        /// Excludes the metric's label, so replacing it with `actual`
        /// leaves "your HR is 162 bpm", not "162 bpm".
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
    //
    // The live patterns require the "your <metric> is" / "<metric> right now"
    // shape. A bare "150 bpm" is usually a target or a different metric.

    /// "your HR is 142 bpm" / "heart rate right now 142 bpm". The 5 bpm
    /// tolerance covers averaging windows + sample drift without letting a
    /// 30-bpm fabrication slide.
    private static func heartRateDiscrepancies(
        in text: String,
        snapshot: WorkoutAIContext
    ) -> [Discrepancy] {
        guard let hr = snapshot.heartRate else { return [] }
        return claimsMatching(
            in: text,
            pattern: #"\b(?:your\s+(?:current\s+|live\s+)?(?:HR|heart\s+rate)(?:\s+is|['’]s)?|(?:HR|heart\s+rate)\s+(?:is\s+)?(?:right\s+now|currently|now))(?:\s+(?:is|now|currently|right\s+now|sitting|at|around|about))*\s+(?<claim>(?<value>\d{2,3})\s*bpm)\b"#,
            check: ClaimCheck(actual: Double(hr), tolerance: 5, metric: "HR") { "\(Int($0.rounded())) bpm" }
        )
    }

    /// "your power is 265 W" / "power right now 265 watts".
    ///
    /// 15 W tolerance — running power is noisy.
    private static func powerDiscrepancies(
        in text: String,
        snapshot: WorkoutAIContext
    ) -> [Discrepancy] {
        guard let watts = snapshot.powerWatts else { return [] }
        return claimsMatching(
            in: text,
            pattern: #"\b(?:your\s+(?:current\s+|live\s+)?(?:power|wattage)(?:\s+is|['’]s)?|(?:power|wattage)\s+(?:is\s+)?(?:right\s+now|currently|now))(?:\s+(?:is|now|currently|right\s+now|sitting|at|around|about))*\s+(?<claim>(?<value>\d{2,4})\s*(?:W|watts?))\b"#,
            check: ClaimCheck(actual: Double(watts), tolerance: 15, metric: "power_watts") { "\(Int($0.rounded())) W" }
        )
    }

    /// "your α1 is 0.72" / "your DFA alpha1 sitting at 0.65" / "α1 right
    /// now 1.05". A threshold ("α1 below 0.75") is not a claim about now.
    /// The 0.10 tolerance is the smallest physiologically meaningful
    /// difference.
    private static func alpha1Discrepancies(
        in text: String,
        snapshot: WorkoutAIContext
    ) -> [Discrepancy] {
        guard let actual = snapshot.alpha1 else { return [] }
        return claimsMatching(
            in: text,
            pattern: #"(?:\byour\s+(?:current\s+|live\s+)?(?:DFA\s*)?(?:α1|alpha\s*1)(?:\s+is|['’]s)?|(?:DFA\s*)?(?:α1|alpha\s*1)\s+(?:is\s+)?(?:right\s+now|currently|now))(?:\s+(?:is|now|currently|right\s+now|sitting|at|around|about))*\s+(?<claim>(?<value>\d+\.\d+))"#,
            check: ClaimCheck(actual: actual, tolerance: 0.10, metric: "alpha1") { String(format: "%.2f", $0) }
        )
    }

    /// "your HR drift is 8.5%" / "drift right now 6%".
    private static func hrDriftDiscrepancies(
        in text: String,
        snapshot: WorkoutAIContext
    ) -> [Discrepancy] {
        guard let actual = snapshot.liveHRDriftPercent else { return [] }
        return claimsMatching(
            in: text,
            pattern: #"\b(?:your\s+(?:current\s+|live\s+)?(?:HR\s+|heart[-\s]rate\s+)?drift(?:\s+is|['’]s)?|(?:HR\s+|heart[-\s]rate\s+)?drift\s+(?:is\s+)?(?:right\s+now|currently|now))(?:\s+(?:is|now|currently|right\s+now|sitting|at|around|about))*\s+(?<claim>(?<value>\d+(?:\.\d+)?)\s*%)"#,
            check: ClaimCheck(actual: actual, tolerance: 1.5, metric: "hr_drift_percent") { String(format: "%.1f%%", $0) }
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

    /// Result of an app-state verification pass.
    ///
    /// The checks run on a NORMALIZED copy of the text, where
    /// `normalizeSpelledNumbers` has rewritten "negative thirty-one point
    /// seven" to "-31.7". Each discrepancy's range is mapped back to the
    /// ORIGINAL text before it is returned, and `correctedText` is the
    /// original with only those claimed spans replaced: every other spelled
    /// number ("this one", "two sessions") stays as the model wrote it.
    struct AppStateVerifyResult {
        /// Ranges are in the original text passed to `verifyAppStateClaims`.
        let discrepancies: [Discrepancy]
        /// The original text with each claimed span replaced by the actual
        /// value. nil when no discrepancies were detected (caller keeps
        /// original text).
        let correctedText: String?
    }

    /// Verify training-load + overnight HRV claims against the
    /// app's source-of-truth values (`TrainingLoadRegistry` for ATL /
    /// CTL / TSB / ACWR; latest reliable overnight for RMSSD /
    /// recovery score). Catches the model quoting TSB values across turns
    /// that range from −9 to −29 while the dashboard showed a single
    /// stable value. Same Discrepancy shape + `recordCorrections` flow as
    /// `verify(_:against:)`.
    ///
    /// Reads from MainActor state — assumes caller is on main
    /// (matches the existing AssistantViewModel + voice pipeline).
    ///
    /// Spelled-out numbers are normalised to digits BEFORE matching. The
    /// regexes capture digits, and in VOICE mode the AI replies
    /// conversationally ("TSB negative thirty-one point seven"), so without
    /// the normaliser every wrong value would escape the verifier.
    @MainActor
    static func verifyAppStateClaims(_ text: String) -> AppStateVerifyResult {
        let normalized = normalizeWithRewrites(text)
        let found = trainingLoadDiscrepancies(in: normalized.text) + overnightDiscrepancies(in: normalized.text)
        let mapped = found.compactMap {
            remap($0, from: normalized.text, to: text, rewrites: normalized.rewrites)
        }
        return AppStateVerifyResult(
            discrepancies: mapped,
            correctedText: correctedText(from: text, applying: mapped)
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
    /// 29", "TSB 7". Every pattern refuses a number that is a quantity of
    /// something else ("CTL 42-day window", "TSB 7 days").
    @MainActor
    private static func trainingLoadDiscrepancies(in text: String) -> [Discrepancy] {
        guard let load = TrainingLoadRegistry.live() else { return [] }
        var found = claimsMatching(
            in: text,
            pattern: #"\bTSB\s+(?<claim>(?:negative\s+)?(?<value>-?\d+(?:\.\d+)?))(?!\d|\.\d|\s*%|\s*-?\s*(?:days?|d|hours?|hrs?|h|weeks?|wks?|nights?|mins?|minutes?|sessions?|workouts?)\b)"#,
            check: ClaimCheck(actual: load.tsb, tolerance: 2.0, metric: "TSB", negateOnSpelled: true) { String(format: "%+.1f", $0) }
        )
        found += claimsMatching(
            in: text,
            pattern: #"\bATL\s+(?<claim>(?<value>\d+(?:\.\d+)?))(?!\d|\.\d|\s*%|\s*-?\s*(?:days?|d|hours?|hrs?|h|weeks?|wks?|nights?|mins?|minutes?|sessions?|workouts?)\b)"#,
            check: ClaimCheck(actual: load.atl, tolerance: 3.0, metric: "ATL") { String(format: "%.1f", $0) }
        )
        found += claimsMatching(
            in: text,
            pattern: #"\bCTL\s+(?<claim>(?<value>\d+(?:\.\d+)?))(?!\d|\.\d|\s*%|\s*-?\s*(?:days?|d|hours?|hrs?|h|weeks?|wks?|nights?|mins?|minutes?|sessions?|workouts?)\b)"#,
            check: ClaimCheck(actual: load.ctl, tolerance: 3.0, metric: "CTL") { String(format: "%.1f", $0) }
        )
        return found + acwrDiscrepancies(in: text, acwr: load.acwr)
    }

    /// ACWR, when the registry has one.
    private static func acwrDiscrepancies(in text: String, acwr: Double?) -> [Discrepancy] {
        guard let acwr else { return [] }
        return claimsMatching(
            in: text,
            pattern: #"\bACWR\s+(?<claim>(?<value>\d+(?:\.\d+)?))(?!\d|\.\d|\s*%|\s*-?\s*(?:days?|d|hours?|hrs?|h|weeks?|wks?|nights?|mins?|minutes?|sessions?|workouts?)\b)"#,
            check: ClaimCheck(actual: acwr, tolerance: 0.15, metric: "ACWR") { String(format: "%.2f", $0) }
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
                in: text,
                pattern: #"\bRMSSD\s+(?:of\s+)?(?<claim>(?<value>\d+(?:\.\d+)?)(?:\s*ms\b)?)(?!\d|\.\d|\s*%|\s*-?\s*(?:days?|d|hours?|hrs?|h|weeks?|wks?|nights?|mins?|minutes?|sessions?|workouts?)\b)"#,
                check: ClaimCheck(actual: rmssd, tolerance: 8.0, metric: "RMSSD") { String(format: "%.0f ms", $0) }
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

    /// "Recovery 9.1 of 10" / "Recovery 91" — both the 0–10 and
    /// the 0–100 scale are reasonable, so a claim that matches the 0–10 form
    /// within tolerance is a different scale, not a lie. "Recovery 48 hours"
    /// is a duration, not a score.
    private static func recoveryScoreClaims(in text: String, score10: Double) -> [Discrepancy] {
        claimsMatching(
            in: text,
            pattern: #"\brecovery\s+(?<claim>(?<value>\d+(?:\.\d+)?))\b(?!\.\d|\s*%|\s*-?\s*(?:days?|d|hours?|hrs?|h|weeks?|wks?|nights?|mins?|minutes?|sessions?|workouts?)\b)"#,
            check: ClaimCheck(actual: score10 * 10, tolerance: 4.0, metric: "recovery_score") { // assume 0-100 form first
                $0.rounded() == $0 ? String(format: "%.0f", $0) : String(format: "%.1f", $0)
            }
        ).compactMap { onTheClaimsScale($0, score10: score10) }
    }

    /// A claim within tolerance on the 0–10 scale is the same score, so it is
    /// dropped. A wrong claim of 10 or under is a 0–10 claim and is corrected
    /// on that scale: "Recovery 5 out of 10" must become "9.1 out of 10", not
    /// "91 out of 10".
    private static func onTheClaimsScale(_ d: Discrepancy, score10: Double) -> Discrepancy? {
        guard let claimed = Double(d.claimed) else { return d }
        let delta10 = abs(claimed - score10)
        guard delta10 > 1.0 else { return nil }
        guard claimed <= 10 else { return d }
        let actual10 = score10.rounded() == score10 ? String(format: "%.0f", score10) : String(format: "%.1f", score10)
        return Discrepancy(metric: d.metric, claimed: d.claimed, actual: actual10, absoluteDelta: delta10, range: d.range)
    }

    /// Splice the actual values into `text` using ranges that index into it.
    /// Applied back-to-front so earlier ranges stay valid as later ones
    /// change length.
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
        var negateOnSpelled = false
        let formatter: (Double) -> String
    }

    /// Generic claim matcher. Pulls the `value` group, parses it, applies
    /// the negate-on-spelled rule when the claim reads "negative N", skips
    /// claims whose sentence is about another time or a target, then
    /// compares against the actual value with the check's tolerance.
    private static func claimsMatching(in text: String, pattern: String, check: ClaimCheck) -> [Discrepancy] {
        guard let regex = DebugLogger.compiledPattern(pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = text as NSString
        let all = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return all.compactMap { discrepancy(from: $0, in: text, ns: ns, check: check) }
    }

    /// One regex match as a Discrepancy, or nil when it doesn't parse, lands
    /// inside tolerance, or is not a claim about the current value.
    private static func discrepancy(
        from match: NSTextCheckingResult,
        in text: String,
        ns: NSString,
        check: ClaimCheck
    ) -> Discrepancy? {
        let valueRange = match.range(withName: "value")
        let claimRange = match.range(withName: "claim")
        guard valueRange.location != NSNotFound, claimRange.location != NSNotFound,
              var claimed = Double(ns.substring(with: valueRange)),
              isAboutTheCurrentValue(match.range, in: ns) else { return nil }
        if check.negateOnSpelled, ns.substring(with: claimRange).lowercased().contains("negative") {
            claimed = -abs(claimed)
        }
        let delta = abs(claimed - check.actual)
        guard delta > check.tolerance, let r = Range(claimRange, in: text) else { return nil }
        return Discrepancy(
            metric: check.metric, claimed: check.formatter(claimed),
            actual: check.formatter(check.actual), absoluteDelta: delta, range: r
        )
    }

    /// False when the sentence holding the claim places it in the past, in a
    /// comparison, or in a target: "recovery 3 days ago was 55", "your
    /// average HR is 140 bpm", "keep your HR 150 bpm or lower". Every check
    /// compares against the latest value only, so those sentences would be
    /// rewritten into something false.
    private static func isAboutTheCurrentValue(_ range: NSRange, in ns: NSString) -> Bool {
        let sentence = sentenceRange(containing: range, in: ns)
        return ![timeMarkers, targetMarkers].contains { pattern in
            DebugLogger.compiledPattern(pattern, options: [.caseInsensitive])?
                .firstMatch(in: ns as String, range: sentence) != nil
        }
    }

    /// Another time than now: "3 days ago", "yesterday", "last week".
    private static let timeMarkers =
        #"\b(?:ago|yesterday|last\s+(?:week|month|year|time|monday|tuesday|wednesday|thursday|friday|saturday|sunday)|previous(?:ly)?|earlier|before|on\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b"#

    /// A summary, target, hypothetical or comparison rather than the value
    /// now: "average", "keep it", "if", "higher than".
    private static let targetMarkers =
        #"\b(?:average|avg|mean|baseline|typical(?:ly)?|usual(?:ly)?|normally|target|goal|aim|keep|stay|peak|max(?:imum)?|min(?:imum)?|lowest|highest|best|worst|trend|would|could|if|should|threshold|under|below|above|over|between|range|higher|lower|than)\b"#

    /// The sentence that holds `range`, by Foundation's sentence rules (which
    /// do not split "17.2"). Falls back to the match itself.
    private static func sentenceRange(containing range: NSRange, in ns: NSString) -> NSRange {
        var found = range
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.bySentences, .substringNotRequired]) { _, sentence, _, stop in
            guard NSLocationInRange(range.location, sentence) else { return }
            found = NSUnionRange(sentence, range)
            stop.pointee = true
        }
        return found
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
    // Process-local; cleared on app launch. Lock-guarded since
    // both the speaker thread (writes) and the AssistantViewModel
    // dispatch path (reads) hit it.

    private static let pendingCorrections = OSAllocatedUnfairLock<[Discrepancy]>(initialState: [])

    /// Record discrepancies caught by the hallucination guard so the
    /// next AI turn's system prompt can warn the model. Caps at 4
    /// entries to keep the reminder short — a model fabricating > 4
    /// numbers in one turn has bigger problems than this hint can
    /// fix. In voice mode the same claim is caught twice — in the spoken
    /// chunk and in the saved chat turn — so a correction already pending
    /// for the same metric, claim and value is not added again.
    static func recordCorrections(_ discrepancies: [Discrepancy]) {
        guard !discrepancies.isEmpty else { return }
        pendingCorrections.withLock { pending in
            for d in discrepancies where !pending.contains(where: {
                $0.metric == d.metric && $0.claimed == d.claimed && $0.actual == d.actual
            }) {
                pending.append(d)
            }
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
                Your previous response contained numbers that contradicted live data. The saved reply was corrected, but the user may already have read or heard the wrong number — if it matters, correct it briefly. For any of these metrics next \
                turn, CALL the appropriate tool (get_workout_live for HR / pace / location, get_training_load for TSB / ATL / CTL / ACWR, lookup_fact for resting HR / HRV) and quote what comes back — never estimate or interpolate.
                """
        ]
        for d in corrections {
            lines.append("• You said \(d.metric)=\(d.claimed) — actual was \(d.actual).")
        }
        return lines.joined(separator: "\n")
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
        normalizeWithRewrites(text).text
    }

    /// One spelled-number rewrite: the words it replaced in the original and
    /// the digits it became in the normalized text.
    private struct SpelledRewrite {
        let original: NSRange
        let normalized: NSRange
    }

    /// The normalized text plus every rewrite, in order, so a range found in
    /// the normalized text can be mapped back to the original.
    private static func normalizeWithRewrites(_ text: String) -> (text: String, rewrites: [SpelledRewrite]) {
        guard let regex = DebugLogger.compiledPattern(spelledNumberPattern) else {
            return (text, [])
        }
        let ns = text as NSString
        let output = NSMutableString()
        var rewrites: [SpelledRewrite] = []
        var cursor = 0
        for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            guard let rep = spelledNumberReplacement(for: match, in: ns) else { continue }
            output.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let digits = NSRange(location: output.length, length: (rep as NSString).length)
            rewrites.append(SpelledRewrite(original: match.range, normalized: digits))
            output.append(rep)
            cursor = NSMaxRange(match.range)
        }
        output.append(ns.substring(from: cursor))
        return (output as String, rewrites)
    }

    /// `discrepancy` with its range moved from the normalized text to the
    /// original. A claim that covers a rewritten number covers all of the
    /// words it came from, so "negative thirty-one point seven" is replaced
    /// whole.
    private static func remap(
        _ discrepancy: Discrepancy,
        from normalized: String,
        to original: String,
        rewrites: [SpelledRewrite]
    ) -> Discrepancy? {
        let inNormalized = NSRange(discrepancy.range, in: normalized)
        let start = originalOffset(of: inNormalized.location, rewrites: rewrites, snapToEnd: false)
        let end = originalOffset(of: NSMaxRange(inNormalized), rewrites: rewrites, snapToEnd: true)
        guard let range = Range(NSRange(location: start, length: end - start), in: original) else { return nil }
        return Discrepancy(
            metric: discrepancy.metric, claimed: discrepancy.claimed, actual: discrepancy.actual,
            absoluteDelta: discrepancy.absoluteDelta, range: range
        )
    }

    /// Where a normalized-text offset falls in the original. Text outside any
    /// rewrite is identical in both, shifted by the rewrites before it; an
    /// offset inside a rewrite snaps to that rewrite's original start or end.
    private static func originalOffset(of offset: Int, rewrites: [SpelledRewrite], snapToEnd: Bool) -> Int {
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
