import Foundation
import os

/// Programmatic hallucination guard for the AI coach.
///
/// The system-prompt overlay tells the model "don't invent numbers,"
/// but the coach can still quote metrics that contradict
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
    // and reports it only when it disagrees with the live value by more than
    // that metric's tolerance — the tolerances differ because the metrics do.
    //
    // Each takes the live value; when it is nil, verification is skipped for
    // that metric (the AI might be replying about a topic with no live
    // workout in flight).
    //
    // The live patterns require the "your <metric> is" / "<metric> right now"
    // shape. A bare "150 bpm" is usually a target or a different metric. The
    // unit is optional after that shape, because the prompt's own example is
    // "Your HR is 150"; a number followed by a range dash, a percent or a time
    // unit is not a reading.

    /// The live values one verification pass checks against. Both live
    /// sources (the recorder's `WorkoutAIContext` and the broker's
    /// `LiveWorkoutSnapshot`) reduce to this.
    private struct LiveValues {
        let heartRate: Int?
        let powerWatts: Int?
        let alpha1: Double?
        let hrDriftPercent: Double?
    }

    /// "your HR is 142 bpm" / "heart rate right now 142". The 5 bpm
    /// tolerance covers averaging windows + sample drift without letting a
    /// 30-bpm fabrication slide.
    private static func heartRateDiscrepancies(in text: String, actual: Int?) -> [Discrepancy] {
        guard let hr = actual else { return [] }
        return claimsMatching(
            in: text,
            pattern: #"\b(?:your\s+(?:current\s+|live\s+)?(?:HR|heart\s+rate)(?:\s+is|['’]s)?|(?:HR|heart\s+rate)\s+(?:is\s+)?(?:right\s+now|currently|now))(?:\s+(?:is|now|currently|right\s+now|sitting|at|around|about))*"#
                + #"\s+(?<claim>(?<value>\d{2,3})(?:\s*(?:bpm|beats\s+per\s+minute))?)\b(?!\s*(?:%|[-–/]|\.\d)|\s*(?:percent|seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?)\b)"#,
            check: ClaimCheck(actual: Double(hr), tolerance: 5, metric: "HR") { "\(Int($0.rounded())) bpm" }
        )
    }

    /// "your power is 265 W" / "power right now 265 watts".
    ///
    /// 15 W tolerance — running power is noisy.
    private static func powerDiscrepancies(in text: String, actual: Int?) -> [Discrepancy] {
        guard let watts = actual else { return [] }
        return claimsMatching(
            in: text,
            pattern: #"\b(?:your\s+(?:current\s+|live\s+)?(?:power|wattage)(?:\s+is|['’]s)?|(?:power|wattage)\s+(?:is\s+)?(?:right\s+now|currently|now))(?:\s+(?:is|now|currently|right\s+now|sitting|at|around|about))*"#
                + #"\s+(?<claim>(?<value>\d{2,4})(?:\s*(?:W|watts?))?)\b(?!\s*(?:%|[-–/]|\.\d)|\s*(?:percent|seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?)\b)"#,
            check: ClaimCheck(actual: Double(watts), tolerance: 15, metric: "power_watts") { "\(Int($0.rounded())) W" }
        )
    }

    /// "your α1 is 0.72" / "your DFA alpha1 sitting at 0.65" / "α1 right
    /// now 1.05". A threshold ("α1 below 0.75") is not a claim about now.
    /// The 0.10 tolerance is the smallest physiologically meaningful
    /// difference.
    private static func alpha1Discrepancies(in text: String, actual: Double?) -> [Discrepancy] {
        guard let actual else { return [] }
        return claimsMatching(
            in: text,
            pattern: #"(?:\byour\s+(?:current\s+|live\s+)?(?:DFA\s*)?(?:α1|alpha\s*1)(?:\s+is|['’]s)?|(?:DFA\s*)?(?:α1|alpha\s*1)\s+(?:is\s+)?(?:right\s+now|currently|now))(?:\s+(?:is|now|currently|right\s+now|sitting|at|around|about))*\s+(?<claim>(?<value>\d+\.\d+))"#,
            check: ClaimCheck(actual: actual, tolerance: 0.10, metric: "alpha1") { String(format: "%.2f", $0) }
        )
    }

    /// "your HR drift is 8.5%" / "drift right now 6%".
    private static func hrDriftDiscrepancies(in text: String, actual: Double?) -> [Discrepancy] {
        guard let actual else { return [] }
        return claimsMatching(
            in: text,
            pattern: #"\b(?:your\s+(?:current\s+|live\s+)?(?:HR\s+|heart[-\s]rate\s+)?drift(?:\s+is|['’]s)?|(?:HR\s+|heart[-\s]rate\s+)?drift\s+(?:is\s+)?(?:right\s+now|currently|now))(?:\s+(?:is|now|currently|right\s+now|sitting|at|around|about))*\s+(?<claim>(?<value>\d+(?:\.\d+)?)\s*%)"#,
            check: ClaimCheck(actual: actual, tolerance: 1.5, metric: "hr_drift_percent") { String(format: "%.1f%%", $0) }
        )
    }

    /// Live-workout claims (HR, power, α1, drift) against a recorder
    /// context. The pipelines check against the broker instead
    /// (`verifyReply`); this form reads the same fields from the recorder's
    /// own context.
    static func verify(_ text: String, against snapshot: WorkoutAIContext?) -> [Discrepancy] {
        guard let snapshot else { return [] }
        return verifyLive(text, values: LiveValues(
            heartRate: snapshot.heartRate, powerWatts: snapshot.powerWatts,
            alpha1: snapshot.alpha1, hrDriftPercent: snapshot.liveHRDriftPercent
        ))
    }

    /// Live-workout claims (HR, power, α1, drift) against the broker's
    /// snapshot: the values the model's live tools return, and the one live
    /// source both the chat and the voice pipelines check against
    /// (`verifyReply`), so a spoken number and a saved one cannot come from
    /// two readings.
    static func verify(_ text: String, againstLive live: AssistantContext.LiveWorkoutSnapshot?) -> [Discrepancy] {
        guard let live else { return [] }
        return verifyLive(text, values: LiveValues(
            heartRate: live.heartRate, powerWatts: live.powerWatts, alpha1: live.alpha1, hrDriftPercent: live.liveHRDriftPercent
        ))
    }

    /// Runs the live checks on the spelled-number-normalised text, so a
    /// voice reply's "one hundred sixty" is checked like "160", and maps
    /// each range back to `text`. Ranges index `text`, which is what the
    /// voice pipeline splices into.
    private static func verifyLive(_ text: String, values: LiveValues) -> [Discrepancy] {
        let normalized = SpelledNumberNormalizer.normalizeWithRewrites(text)
        let found = heartRateDiscrepancies(in: normalized.text, actual: values.heartRate)
            + powerDiscrepancies(in: normalized.text, actual: values.powerWatts)
            + alpha1Discrepancies(in: normalized.text, actual: values.alpha1)
            + hrDriftDiscrepancies(in: normalized.text, actual: values.hrDriftPercent)
        return found.compactMap { remap($0, from: normalized.text, to: text, rewrites: normalized.rewrites) }
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

    /// The app's own values `verifyAppStateClaims` checks claims against.
    struct AppState {
        /// The settings in force, for whether training load is paused.
        let settings: UserSettings
        let trainingMetricsCache: TrainingMetricsCache
        let archive: SessionArchive
        /// The live workout broker's snapshot, nil while no workout records.
        var liveWorkout: AssistantContext.LiveWorkoutSnapshot?
    }

    /// Every check a reply gets, in one pass, for every pipeline that shows
    /// or speaks one: live-workout claims against `state.liveWorkout`, then
    /// training-load, overnight and sleep claims on the live-corrected text.
    /// `correctedText` is nil when nothing changed. Each discrepancy's range
    /// indexes the text its own pass read, so callers use the ranges only
    /// through `correctedText`.
    ///
    /// `preceding` is the part of the same reply already shown or spoken.
    /// A streamed reply is checked piece by piece, and a piece's meaning can
    /// be set by an earlier one: the heading "Night before (Nov 25)" in one
    /// piece makes "- Recovery score: 55" in the next a past night's value.
    /// So the whole reply so far is read, and only claims in `text` are
    /// checked; `correctedText` is `text` alone.
    @MainActor
    static func verifyReply(_ text: String, after preceding: String = "", against state: AppState) -> AppStateVerifyResult {
        guard mayHoldAClaim(text) else {
            acknowledgeDeliveredCorrections()
            return AppStateVerifyResult(discrepancies: [], correctedText: nil)
        }
        let whole = preceding + text
        let start = (preceding as NSString).length
        let live = claims(verify(whole, againstLive: state.liveWorkout), from: start, in: whole)
        let liveCorrected = correctedText(from: whole, applying: live) ?? whole
        let appState = claims(appStateDiscrepancies(liveCorrected, against: state), from: start, in: liveCorrected)
        let corrected = correctedText(from: liveCorrected, applying: appState) ?? (live.isEmpty ? nil : liveCorrected)
        return AppStateVerifyResult(
            discrepancies: live + appState,
            correctedText: corrected.map { ($0 as NSString).substring(from: start) }
        )
    }

    /// Whether `text` has a number in it, written or spelled; one without
    /// has no claim to check, however much reply precedes it.
    private static func mayHoldAClaim(_ text: String) -> Bool {
        SpelledNumberNormalizer.normalizeWithRewrites(text).text.contains { $0.isNumber }
    }

    /// The discrepancies whose claim starts at or after UTF-16 offset `start`
    /// of `text`: the ones in the piece being checked.
    private static func claims(_ found: [Discrepancy], from start: Int, in text: String) -> [Discrepancy] {
        found.filter { NSRange($0.range, in: text).location >= start }
    }

    /// Verify training-load, overnight HRV and last night's sleep claims
    /// against the app's source-of-truth values (`TrainingLoadRegistry` for
    /// ATL / CTL / TSB / ACWR, unless training load is paused; today's
    /// reliable overnight for RMSSD / recovery score, the night
    /// `recovery_score_today` in the prompt names; the session `get_sleep`
    /// "latest" answers from for sleep duration and efficiency). Catches the
    /// model quoting TSB values across turns that range from −9 to −29 while
    /// the dashboard showed a single stable value. Same Discrepancy shape +
    /// `recordCorrections` flow as `verify(_:against:)`.
    ///
    /// Every caller runs this on a reply the model has just produced, so it
    /// also acknowledges the correction reminders the prompt for that reply
    /// carried (see `acknowledgeDeliveredCorrections`).
    ///
    /// Reads from MainActor state — assumes caller is on main
    /// (matches the existing AssistantViewModel + voice pipeline).
    ///
    /// Spelled-out numbers are normalised to digits BEFORE matching. The
    /// regexes capture digits, and in VOICE mode the AI replies
    /// conversationally ("TSB negative thirty-one point seven"), so without
    /// the normaliser every wrong value would escape the verifier.
    @MainActor
    static func verifyAppStateClaims(_ text: String, against state: AppState) -> AppStateVerifyResult {
        let mapped = appStateDiscrepancies(text, against: state)
        return AppStateVerifyResult(
            discrepancies: mapped,
            correctedText: correctedText(from: text, applying: mapped)
        )
    }

    /// `verifyAppStateClaims`'s discrepancies, ranges in `text`.
    @MainActor
    private static func appStateDiscrepancies(_ text: String, against state: AppState) -> [Discrepancy] {
        acknowledgeDeliveredCorrections()
        let normalized = SpelledNumberNormalizer.normalizeWithRewrites(text)
        let found = trainingLoadDiscrepancies(in: normalized.text, state: state)
            + overnightDiscrepancies(in: normalized.text, archive: state.archive)
            + lastNightSleepDiscrepancies(in: normalized.text, archive: state.archive)
        return found.compactMap {
            remap($0, from: normalized.text, to: text, rewrites: normalized.rewrites)
        }
    }

    /// Training load — ATL / CTL / TSB / ACWR.
    ///
    /// Source of truth is `TrainingLoadRegistry.live(from:)`,
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
    /// 29", "TSB 7", and the phrasings the prompt itself uses: "TSB is -8.8",
    /// "TSB of", "TSB at", "TSB: ". Every pattern refuses a number that is a
    /// quantity of something else ("CTL 42-day window", "TSB 7 days").
    ///
    /// Skipped while training load is paused: the prompt leaves the load
    /// numbers out then, as the screens do, so there is no value to correct to.
    @MainActor
    private static func trainingLoadDiscrepancies(in text: String, state: AppState) -> [Discrepancy] {
        guard !TrainingLoadVisibility.isPaused(state.settings),
              let load = TrainingLoadRegistry.live(from: state.trainingMetricsCache) else { return [] }
        return trainingLoadClaims(in: text, tsb: load.tsb, atl: load.atl, ctl: load.ctl, acwr: load.acwr)
    }

    /// TSB, ATL, CTL and ACWR claims in `text` that disagree with the given
    /// values.
    static func trainingLoadClaims(in text: String, tsb: Double, atl: Double, ctl: Double, acwr: Double?) -> [Discrepancy] {
        var found = claimsMatching(
            in: text,
            pattern: #"\bTSB(?:\s+(?:is|of|at|now|currently|today|sitting|sits|reads|stands\s+at|right\s+now))*(?:\s*[:=]\s*|\s+)"#
                + #"(?<claim>(?:(?:negative|minus)\s+)?(?<value>[-−]?\d+(?:\.\d+)?))(?!\d|\.\d|\s*%|\s*-?\s*(?:days?|d|hours?|hrs?|h|weeks?|wks?|nights?|mins?|minutes?|sessions?|workouts?)\b)"#,
            check: ClaimCheck(actual: tsb, tolerance: 2.0, metric: "TSB", negateOnSpelled: true) { String(format: "%+.1f", $0) }
        )
        found += claimsMatching(
            in: text,
            pattern: #"\bATL(?:\s+(?:is|of|at|now|currently|today|sitting|sits|reads|stands\s+at|right\s+now))*(?:\s*[:=]\s*|\s+)(?<claim>(?<value>\d+(?:\.\d+)?))(?!\d|\.\d|\s*%|\s*-?\s*(?:days?|d|hours?|hrs?|h|weeks?|wks?|nights?|mins?|minutes?|sessions?|workouts?)\b)"#,
            check: ClaimCheck(actual: atl, tolerance: 3.0, metric: "ATL") { String(format: "%.1f", $0) }
        )
        found += claimsMatching(
            in: text,
            pattern: #"\bCTL(?:\s+(?:is|of|at|now|currently|today|sitting|sits|reads|stands\s+at|right\s+now))*(?:\s*[:=]\s*|\s+)(?<claim>(?<value>\d+(?:\.\d+)?))(?!\d|\.\d|\s*%|\s*-?\s*(?:days?|d|hours?|hrs?|h|weeks?|wks?|nights?|mins?|minutes?|sessions?|workouts?)\b)"#,
            check: ClaimCheck(actual: ctl, tolerance: 3.0, metric: "CTL") { String(format: "%.1f", $0) }
        )
        return found + acwrDiscrepancies(in: text, acwr: acwr)
    }

    /// ACWR, when the registry has one.
    private static func acwrDiscrepancies(in text: String, acwr: Double?) -> [Discrepancy] {
        guard let acwr else { return [] }
        return claimsMatching(
            in: text,
            pattern: #"\bACWR(?:\s+(?:is|of|at|now|currently|today|sitting|sits|reads|stands\s+at|right\s+now))*(?:\s*[:=]\s*|\s+)(?<claim>(?<value>\d+(?:\.\d+)?))(?!\d|\.\d|\s*%|\s*-?\s*(?:days?|d|hours?|hrs?|h|weeks?|wks?|nights?|mins?|minutes?|sessions?|workouts?)\b)"#,
            check: ClaimCheck(actual: acwr, tolerance: 0.15, metric: "ACWR") { String(format: "%.2f", $0) }
        )
    }

    /// Overnight HRV — RMSSD + recovery score. Source of truth: today's
    /// reliable overnight (`DeterministicIntent.todaysOvernightEntry`), the
    /// night whose recovery score the prompt gives as `recovery_score_today`.
    /// With no such night nothing is checked: an older night's numbers are
    /// not what the model was given. The recovery score comes from the
    /// archive index; the session file is decoded only when the text names
    /// RMSSD.
    @MainActor
    private static func overnightDiscrepancies(in text: String, archive: SessionArchive) -> [Discrepancy] {
        guard let entry = DeterministicIntent.todaysOvernightEntry(now: Date(), archive: archive) else { return [] }
        var found: [Discrepancy] = []
        if text.range(of: "rmssd", options: .caseInsensitive) != nil,
           let rmssd = archive.retrieveLightweightOrLog(entry.sessionId)?.analysisResult?.timeDomain.rmssd {
            found += rmssdClaims(in: text, rmssd: rmssd)
        }
        if let score10 = entry.recoveryScore {
            found += recoveryScoreClaims(in: text, score10: score10)
        }
        return found
    }

    /// "RMSSD 68 ms" / "RMSSD 76" / "RMSSD of 68" / "RMSSD is 48". A log
    /// RMSSD ("ln RMSSD 3.9") is another scale and is not checked.
    static func rmssdClaims(in text: String, rmssd: Double) -> [Discrepancy] {
        claimsMatching(
            in: text,
            pattern: #"(?<!\bln\s)(?<!\blog\s)\bRMSSD(?:\s+(?:is|of|at|now|currently|today|sitting|sits|reads|stands\s+at|right\s+now))*(?:\s*[:=]\s*|\s+)"#
                + #"(?<claim>(?<value>\d+(?:\.\d+)?)(?:\s*ms\b)?)(?!\d|\.\d|\s*%|\s*-?\s*(?:days?|d|hours?|hrs?|h|weeks?|wks?|nights?|mins?|minutes?|sessions?|workouts?)\b)"#,
            check: ClaimCheck(actual: rmssd, tolerance: 8.0, metric: "RMSSD", isOvernight: true) { String(format: "%.0f ms", $0) }
        )
    }

    /// "Recovery 9.1 of 10" / "Recovery 91" / "your recovery score is 72" /
    /// "recovery score of 72" / "recovery 85/100", the form the prompt's own
    /// live state uses — both the 0–10 and the 0–100 scale are
    /// reasonable, so a claim that matches the 0–10 form within tolerance is a
    /// different scale, not a lie, unless the claim names its scale ("/100",
    /// "out of 100"). "Recovery 48 hours" is a duration, not a
    /// score. A 0–100 correction is the integer the dashboard shows
    /// (`RecoveryScoreCalculator.displayScore`), not the raw score × 10.
    ///
    /// In a workout prescription "recovery" is the rest between reps: "a
    /// recovery of 200 m jog", "recovery of 90 s", "recovery at 130 bpm". A
    /// number with a distance, time, heart-rate, power or rep unit after it is
    /// that, not a score, and is left alone.
    static func recoveryScoreClaims(in text: String, score10: Double) -> [Discrepancy] {
        claimsMatching(
            in: text,
            pattern: notTheScoreBefore + #"\brecovery(?:\s+score)?(?:\s+(?:is|of|at|now|currently|today|sitting|sits|reads|stands\s+at|right\s+now))*(?:\s*[:=]\s*|\s+)(?<claim>(?<value>\d+(?:\.\d+)?))"#
                + #"\b(?!\.\d|\s*%|\s*-?\s*(?:days?|d|hours?|hrs?|h|weeks?|wks?|nights?|mins?|minutes?|sessions?|workouts?|m|meters?|metres?|km|kilometers?|kilometres?|k|mi|miles?|yd|yards?|ft|feet|s|secs?|seconds?|bpm|beats?|w|watts?|laps?|reps?|x|sets?|rounds?|strides?|steps?|times)\b)"#,
            check: ClaimCheck(
                actual: Double(RecoveryScoreCalculator.displayScore(score10 * 10)), tolerance: 4.0, metric: "recovery_score",
                isOvernight: true
            ) { // assume 0-100 form first
                $0.rounded() == $0 ? String(format: "%.0f", $0) : String(format: "%.1f", $0)
            }
        ).compactMap { onTheClaimsScale($0, score10: score10, stated: statedScale(after: $0.range, in: text)) }
    }

    /// The scale written right after a claimed score: 10 for "/10", "of 10"
    /// or "out of 10", 100 for the same with 100, nil when none is written.
    private static func statedScale(after range: Range<String.Index>, in text: String) -> Int? {
        let tail = String(text[range.upperBound...].prefix(16))
        let whole = NSRange(location: 0, length: (tail as NSString).length)
        guard let match = DebugLogger.compiledPattern(#"^\s*(?:/|(?:out\s+)?of)\s*(10|100)\b"#, options: [.caseInsensitive])?
            .firstMatch(in: tail, range: whole) else { return nil }
        return Int((tail as NSString).substring(with: match.range(at: 1)))
    }

    /// "Heart rate recovery", "HR recovery", "HRR" and "cardiac recovery" are
    /// the beats per minute shed after effort, not the recovery score.
    private static let notTheScoreBefore = #"(?<!\brate\s)(?<!\bHRR?\s)(?<!\bcardiac\s)"#

    /// A claim within tolerance on the 0–10 scale is the same score, so it is
    /// dropped. A wrong claim of 10 or under is a 0–10 claim and is corrected
    /// on that scale: "Recovery 5 out of 10" must become "9.1 out of 10", not
    /// "91 out of 10". A number above 100 is on neither scale ("recovery at
    /// 140" is a heart rate), so it is not a score claim. A claim that writes
    /// its scale is read on that scale only: "8/100" is not 8 out of 10.
    private static func onTheClaimsScale(_ d: Discrepancy, score10: Double, stated: Int?) -> Discrepancy? {
        guard let claimed = Double(d.claimed) else { return d }
        guard claimed <= 100 else { return nil }
        guard stated != 10 || claimed <= 10 else { return nil }
        if stated == 100 { return d }
        let delta10 = abs(claimed - score10)
        guard delta10 > 1.0 else { return nil }
        guard claimed <= 10 else { return d }
        let actual10 = score10.rounded() == score10 ? String(format: "%.0f", score10) : String(format: "%.1f", score10)
        return Discrepancy(metric: d.metric, claimed: d.claimed, actual: actual10, absoluteDelta: delta10, range: d.range)
    }

    // MARK: - Last night's sleep

    /// Sleep duration and efficiency. Source of truth: the session
    /// `get_sleep` "latest" answers from (`OvernightArchive.latest`), read the
    /// way the Recovery Score detail and Flo's own context read it
    /// (`nightSleepMinutes`, `measuredSleepEfficiency`), so a correction puts
    /// back the number the user sees on screen and the model was given. The
    /// archive is read only when the text talks about sleep.
    @MainActor
    private static func lastNightSleepDiscrepancies(in text: String, archive: SessionArchive) -> [Discrepancy] {
        guard text.range(of: #"\b(?:sleep|slept|asleep|efficien)"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let sleep = latestOvernightSleep(in: archive) else { return [] }
        return sleepDiscrepancies(
            in: text, nightMinutes: sleep.nightSleepMinutes, efficiency: sleep.measuredSleepEfficiency
        )
    }

    /// The frozen sleep of the night `get_sleep` "latest" answers about, or
    /// nil. Never an older night: when that night has no frozen snapshot yet
    /// (not accepted, or sleep synced after acceptance) `get_sleep` answers
    /// from a live HealthKit read this cannot see, so nothing is checked. A
    /// nap or quick reading is not last night.
    @MainActor
    private static func latestOvernightSleep(in archive: SessionArchive) -> SleepData? {
        guard let session = OvernightArchive.latest(archive), session.sessionType == .overnight,
              let sleep = session.sleepSnapshot, sleep.nightSleepMinutes > 0 else { return nil }
        return sleep
    }

    /// Claims about last night's sleep that disagree with `nightMinutes` and
    /// `efficiency` (percent, nil when the night's wake was not measured).
    /// Only claims in a sentence about the user's own sleep now are checked:
    /// "you slept 7 hours and 5 minutes", "sleep efficiency of 95%", "6h 55m
    /// of sleep". Advice and norms ("adults need 7 to 9 hours of sleep"),
    /// other nights and averages are not.
    static func sleepDiscrepancies(in text: String, nightMinutes: Int, efficiency: Double?) -> [Discrepancy] {
        var found = sleepDurationDiscrepancies(in: text, nightMinutes: nightMinutes)
        if let efficiency {
            found += sleepEfficiencyDiscrepancies(in: text, efficiency: efficiency)
        }
        var kept: [Discrepancy] = []
        for d in found where !isNotAboutLastNight(d.range, in: text) && !kept.contains(where: { $0.range.overlaps(d.range) }) {
            kept.append(d)
        }
        return kept
    }

    /// A duration said three ways: after "slept", after a "sleep" label, and
    /// before "of sleep". Each names `hours`, optional `minutes`, and `claim`.
    private static let sleepDurationPatterns = [
        #"\bslept\s+(?:for\s+)?(?:(?:about|around|roughly|nearly|almost|just)\s+)?(?<claim>(?<hours>\d{1,2}(?:\.\d+)?)\s*(?:h|hrs?|hours?)\b(?:,?\s*(?:and\s+)?(?<minutes>\d{1,2})\s*(?:m|mins?|minutes?)\b)?)"#,
        #"\bsleep(?:\s+(?:duration|time|total))?(?:\s*:|\s+(?:was|is|of|at|came\s+in\s+at|totall?ed))+\s*(?:(?:about|around|roughly|nearly|almost|just)\s+)?(?<claim>(?<hours>\d{1,2}(?:\.\d+)?)\s*(?:h|hrs?|hours?)\b(?:,?\s*(?:and\s+)?(?<minutes>\d{1,2})\s*(?:m|mins?|minutes?)\b)?)"#,
        #"(?<![\d.\-–])(?<claim>(?<hours>\d{1,2}(?:\.\d+)?)\s*(?:h|hrs?|hours?)\b(?:,?\s*(?:and\s+)?(?<minutes>\d{1,2})\s*(?:m|mins?|minutes?)\b)?)\s+of\s+(?:(?:total|actual|night(?:time)?)\s+)?sleep\b"#
    ]

    private static func sleepDurationDiscrepancies(in text: String, nightMinutes: Int) -> [Discrepancy] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let masked = maskedForMatching(text)
        return sleepDurationPatterns
            .compactMap { DebugLogger.compiledPattern($0, options: [.caseInsensitive]) }
            .flatMap { $0.matches(in: masked, range: whole) }
            .compactMap { durationDiscrepancy(from: $0, in: text, nightMinutes: nightMinutes) }
    }

    /// One duration match as a Discrepancy. A claim with minutes or decimal
    /// hours is held to 5 minutes; whole hours ("about 7 hours") to 30, the
    /// precision the claim itself has.
    private static func durationDiscrepancy(
        from match: NSTextCheckingResult,
        in text: String,
        nightMinutes: Int
    ) -> Discrepancy? {
        let ns = text as NSString
        let claimRange = match.range(withName: "claim")
        guard claimRange.location != NSNotFound,
              let claimed = claimedSleepMinutes(match, in: ns),
              isAboutTheCurrentValue(match.range, in: ns, overnight: true),
              !isRangeOrDelta(after: claimRange, in: ns),
              let range = Range(claimRange, in: text) else { return nil }
        let delta = abs(claimed.minutes - Double(nightMinutes))
        guard delta > (claimed.isPrecise ? 5 : 30) else { return nil }
        let longForm = ns.substring(with: claimRange).lowercased().contains("hour")
        return Discrepancy(
            metric: "sleep_duration", claimed: sleepDurationText(claimed.minutes, longForm: longForm),
            actual: sleepDurationText(Double(nightMinutes), longForm: longForm), absoluteDelta: delta, range: range
        )
    }

    /// The claimed total in minutes, and whether it is stated finer than a
    /// whole hour.
    private static func claimedSleepMinutes(
        _ match: NSTextCheckingResult,
        in ns: NSString
    ) -> (minutes: Double, isPrecise: Bool)? {
        let hoursText = ns.substring(with: match.range(withName: "hours"))
        guard let hours = Double(hoursText) else { return nil }
        let minutesRange = match.range(withName: "minutes")
        let minutes = minutesRange.location == NSNotFound ? 0 : Double(ns.substring(with: minutesRange)) ?? 0
        return (hours * 60 + minutes, minutesRange.location != NSNotFound || hoursText.contains("."))
    }

    /// "6 hours and 55 minutes" when the claim spelled its units out, else
    /// "6h 55m".
    static func sleepDurationText(_ minutes: Double, longForm: Bool) -> String {
        let total = Int(minutes.rounded())
        let (hours, rest) = (total / 60, total % 60)
        guard longForm else { return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m" }
        let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
        guard rest > 0 else { return hourText }
        return hourText + (rest == 1 ? " and 1 minute" : " and \(rest) minutes")
    }

    /// "sleep efficiency of 95%", "efficiency was 95%", "95% sleep
    /// efficiency", "95% efficient". The bare forms count only in a sentence
    /// about sleep. Held to 1 point: the screen shows whole percents.
    private static func sleepEfficiencyDiscrepancies(in text: String, efficiency: Double) -> [Discrepancy] {
        let check = ClaimCheck(actual: efficiency, tolerance: 1.0, metric: "sleep_efficiency", isOvernight: true) { "\(Int($0.rounded()))%" }
        let found = claimsMatching(
            in: text,
            pattern: #"\b(?:sleep\s+)?efficiency(?:\s+(?:of|was|is|at|came\s+in\s+at|reached|hit))*\s*:?\s+(?:(?:about|around|roughly|nearly|almost|just)\s+)?(?<claim>(?<value>\d{1,3}(?:\.\d+)?)\s*%)"#,
            check: check
        ) + claimsMatching(
            in: text,
            pattern: #"(?<claim>(?<value>\d{1,3}(?:\.\d+)?)\s*%)\s+(?:sleep\s+)?efficien(?:cy|t)\b"#,
            check: check
        )
        return found.filter { isInSleepSentence($0.range, in: text) }
    }

    /// True when the sentence holding `range` is about sleep.
    private static func isInSleepSentence(_ range: Range<String.Index>, in text: String) -> Bool {
        sentence(containing: range, in: text, matches: #"\b(?:sleep|slept|asleep)\b"#)
    }

    /// True when the sentence holding `range` states a norm or advice, or
    /// names another night, rather than describing last night: "adults need
    /// 7 to 9 hours", "7-9 hours a night", "the recommended 85%", "on
    /// September 3 you slept 6 hours", "over the past 3 nights".
    private static func isNotAboutLastNight(_ range: Range<String.Index>, in text: String) -> Bool {
        sentence(containing: range, in: text, matches: generalSleepMarkers)
            || sentence(containing: range, in: text, matches: otherNightMarkers)
    }

    private static let generalSleepMarkers =
        #"\b(?:need|needs|recommend(?:s|ed|ation)?|adults?|most\s+people|guidelines?|per\s+night|a\s+night|each\s+night|every\s+night|nightly|to\s+\d)\b|\d\s*[-–]\s*\d"#

    /// Dates, weekdays and spans of nights. "May" is left out: as a verb it
    /// is far more common than the month.
    private static let otherNightMarkers =
        #"\b(?:january|february|march|april|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept?|oct|nov|dec|monday|tuesday|wednesday|thursday|friday|saturday|sunday|night\s+of|that\s+night|nights|weeks?|month)\b|\d{1,2}/\d{1,2}|\d{4}-\d{2}-\d{2}"#

    /// Whether `pattern` matches in the sentence holding `range` or in the
    /// structure around it (`enclosingStructure`): a "## Sleep on Nov 25"
    /// heading places the bullets under it as that night's sleep.
    private static func sentence(containing range: Range<String.Index>, in text: String, matches pattern: String) -> Bool {
        let claim = NSRange(range, in: text)
        let structure = enclosingStructure(of: claim, in: text as NSString)
        let span = sentenceRange(containing: claim, in: structure.text)
        return anyMatches([pattern], in: structure.text, scopes: [span] + structure.scopes)
    }

    /// Splice the actual values into `text` using ranges that index into it.
    /// Applied back-to-front so earlier ranges stay valid as later ones
    /// change length. A range that overlaps one already applied is skipped:
    /// two checks can claim the same span, and splicing the second into
    /// text the first has rewritten would use stale indices.
    static func correctedText(from text: String, applying found: [Discrepancy]) -> String? {
        guard !found.isEmpty else { return nil }
        var corrected = text
        var appliedFrom = text.endIndex
        for d in found.sorted(by: { $0.range.lowerBound > $1.range.lowerBound })
        where d.range.lowerBound >= text.startIndex && d.range.upperBound <= appliedFrom {
            corrected.replaceSubrange(d.range, with: d.actual)
            appliedFrom = d.range.lowerBound
        }
        return corrected
    }

    /// What one claim is checked against: the true value, how far off a claim
    /// may be before it counts, and how to render both for the user.
    private struct ClaimCheck {
        let actual: Double
        let tolerance: Double
        let metric: String
        /// True when the regex can match a spelled-out "negative N" or
        /// "minus N" form, in which case the captured magnitude has to be
        /// negated by hand.
        var negateOnSpelled = false
        /// True for a value measured overnight (RMSSD, recovery, sleep), for
        /// which "last night" is the current value rather than another time.
        var isOvernight = false
        let formatter: (Double) -> String
    }

    /// Generic claim matcher. Pulls the `value` group, parses it, applies
    /// the negate-on-spelled rule when the claim reads "negative N", skips
    /// claims whose sentence is about another time or a target, then
    /// compares against the actual value with the check's tolerance. The
    /// pattern runs on the text with markdown markup masked
    /// (`maskedForMatching`), so a bold label or a table cell is matched as
    /// plain text; everything else reads the text as written.
    private static func claimsMatching(in text: String, pattern: String, check: ClaimCheck) -> [Discrepancy] {
        guard let regex = DebugLogger.compiledPattern(pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = text as NSString
        let all = regex.matches(in: maskedForMatching(text), range: NSRange(location: 0, length: ns.length))
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
        let claimRange = match.range(withName: "claim")
        guard let claimed = claimedValue(match, ns: ns, check: check),
              isAboutTheCurrentValue(match.range, in: ns, overnight: check.isOvernight),
              !isRangeOrDelta(after: claimRange, in: ns) else { return nil }
        let delta = abs(claimed - check.actual)
        guard delta > check.tolerance, let r = Range(claimRange, in: text) else { return nil }
        return Discrepancy(
            metric: check.metric, claimed: check.formatter(claimed),
            actual: check.formatter(check.actual), absoluteDelta: delta, range: r
        )
    }

    /// The number a match claims: the `value` group, with a typographic minus
    /// read as a minus and a spelled "negative" or "minus" applied. Nil when a
    /// group is missing or does not parse.
    private static func claimedValue(_ match: NSTextCheckingResult, ns: NSString, check: ClaimCheck) -> Double? {
        let valueRange = match.range(withName: "value")
        let claimRange = match.range(withName: "claim")
        guard valueRange.location != NSNotFound, claimRange.location != NSNotFound,
              let value = Double(ns.substring(with: valueRange).replacingOccurrences(of: "\u{2212}", with: "-")) else { return nil }
        let spelledSign = ns.substring(with: claimRange).range(
            of: #"\b(?:negative|minus)\b"#, options: [.regularExpression, .caseInsensitive]
        ) != nil
        return check.negateOnSpelled && spelledSign ? -abs(value) : value
    }

    /// True when the words right after a claim make its number one end of a
    /// range, a clock time, a minute mark or a difference rather than a
    /// reading: "TSB -10 to -30", "ACWR 0.8-1.3", "recovery of 2:00",
    /// "recovery 2' jog", "your HR is 12 bpm higher", "your power is 20 W
    /// down on the first rep", "you slept 1 hour longer". Correcting such a
    /// number to the live value would make the sentence false. A slash before
    /// 10 or 100 names the score's scale ("recovery 85/100"), not the other
    /// end of a range, so that claim is still checked.
    private static func isRangeOrDelta(after claim: NSRange, in ns: NSString) -> Bool {
        let tail = NSRange(location: NSMaxRange(claim), length: ns.length - NSMaxRange(claim))
        return DebugLogger.compiledPattern(notAReadingAfter, options: [.caseInsensitive])?
            .firstMatch(in: ns as String, options: [.anchored], range: tail) != nil
    }

    private static let notAReadingAfter = "(?:" + [
        #"\s*(?:[-–—]|/(?!\s*10{1,2}\b)|to|or)\s*[-−+]?\d"#,
        #"\s*:\d"#,
        #"\s*['’′″"]"#,
        #"(?:\s*(?:points?|pts?|bpm|beats?|ms|w|watts?|%|percent|h|hrs?|hours?|m|mins?|minutes?))?"#
            + #"\s+(?:higher|lower|more|less|fewer|better|worse|faster|slower|longer|shorter|above|below|ahead|behind|times)\b"#,
        #"(?:\s*(?:points?|pts?|bpm|beats?|ms|w|watts?|%|percent|h|hrs?|hours?|m|mins?|minutes?))?"#
            + #"\s+(?:up|down)(?=\s+(?:from|on|over|vs|versus|compared|since|by)\b|\s*[.,;!?]|\s*$)"#
    ].joined(separator: "|") + ")"

    /// False when the sentence holding the claim places it in the past, in a
    /// comparison, or in a target: "recovery 3 days ago was 55", "your
    /// average HR is 140 bpm", "keep your HR 150 bpm or lower". Every check
    /// compares against the latest value only, so those sentences would be
    /// rewritten into something false.
    ///
    /// Only the sentence up to the end of the claim's own clause is read. A
    /// marker in a later clause is about another number: the prompt's own
    /// headline "Recovery 72, slightly down from 76 yesterday" states today's
    /// value first and must still be checked. A marker before the claim
    /// ("Yesterday, recovery was 55") still applies to it.
    ///
    /// For an overnight value "last night" is now: "your RMSSD last night was
    /// 48 ms" and "last night you slept 6 hours" are claims about the night
    /// the check reads.
    ///
    /// The clause must also be about the entity the check reads. A nap, a
    /// quick or live reading, or a workout has its own RMSSD and its own
    /// sleep, so a number placed on one of them is not the overnight value;
    /// sleep or rest is not the live workout; and a value the user reported
    /// or another device showed is theirs to state. When the clause names
    /// another referent the claim is left as written.
    ///
    /// The sentence is not the whole of what places a claim. The structure
    /// around it does too (`enclosingStructure`): the heading or bold label
    /// over it, the lead-in its list or table hangs from, the items it is
    /// nested under, its table column's header and row label, and the line
    /// before when a sentence wraps. A marker in any of them leaves the claim
    /// as written: "Night before (Nov 25)" over "- Recovery score: 55" says
    /// the 55 is not today's.
    private static func isAboutTheCurrentValue(_ range: NSRange, in ns: NSString, overnight: Bool = false) -> Bool {
        let structure = enclosingStructure(of: range, in: ns)
        let sentence = sentenceRange(containing: range, in: structure.text)
        let clause = NSRange(location: sentence.location, length: clauseEnd(after: range, in: sentence, ns: structure.text) - sentence.location)
        let markers = overnight ? [earlierTimeMarkers, targetMarkers] : [earlierTimeMarkers, lastNightMarker, targetMarkers]
        let referents = [overnight ? notTheOvernightMarkers : notTheWorkoutMarkers, reportedElsewhereMarkers]
        return !anyMatches(markers + referents, in: structure.text, scopes: [clause] + structure.scopes)
    }

    /// Whether any of `patterns` matches inside any of `scopes` of `ns`.
    private static func anyMatches(_ patterns: [String], in ns: NSString, scopes: [NSRange]) -> Bool {
        patterns.contains { pattern in
            guard let regex = DebugLogger.compiledPattern(pattern, options: [.caseInsensitive]) else { return false }
            return scopes.contains { regex.firstMatch(in: ns as String, range: $0) != nil }
        }
    }

    /// Where the clause holding `range` ends: the first clause separator
    /// after it in `sentence`, else the sentence end.
    private static func clauseEnd(after range: NSRange, in sentence: NSRange, ns: NSString) -> Int {
        let tail = NSRange(location: NSMaxRange(range), length: max(0, NSMaxRange(sentence) - NSMaxRange(range)))
        let separator = DebugLogger.compiledPattern(clauseSeparators, options: [.caseInsensitive])?
            .firstMatch(in: ns as String, range: tail)
        return separator?.range.location ?? NSMaxRange(sentence)
    }

    /// Punctuation and words that open a new clause after a claim:
    /// "Recovery 72, down from 76", "RMSSD 48 ms vs 41 ms yesterday".
    private static let clauseSeparators =
        #"[,;(—–]|\s-\s|\b(?:vs\.?|versus|compared|but|while|whereas|from)\b"#

    /// Another time than now: "3 days ago", "yesterday", "last week", and a
    /// day named by date or weekday, as in a list of past nights ("Nov 24:
    /// recovery 55", "11/24 recovery 55", "Monday: recovery 61"), or a span
    /// ("this week", "over the past 7 days"). A number placed on another day
    /// is not checked: leaving one unchecked is harmless, while correcting a
    /// past value to today's writes a false history.
    /// Each part is a complete pattern so the compile check that reads this
    /// file's raw literals can compile every one of them.
    private static let earlierTimeMarkers = "\\b(?:" + [
        #"ago|yesterday|last\s+(?:week|month|year|time)|previous(?:ly)?|earlier|before"#,
        #"(?:this|past|each|every|per)\s+(?:week|month|year|day|night)s?|over\s+the\s+(?:last|past)"#,
        "(?:mon|tues?|wed(?:nes)?|thu(?:rs?)?|fri|sat(?:ur)?|sun)(?:day)?",
        #"(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?"#,
        #"\d{1,2}(?:st|nd|rd|th)?\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*"#,
        #"\d{1,4}[/-]\d{1,2}(?:[/-]\d{2,4})?|(?:on\s+)?the\s+\d{1,2}(?:st|nd|rd|th)"#
    ].joined(separator: "|") + ")\\b"

    /// "Last night" is another time for a live or training-load value.
    private static let lastNightMarker = #"\blast\s+night\b"#

    /// Another reading than the night's overnight: a nap, a quick or live
    /// reading, a breathing session, a workout. "During the night" is still
    /// the night, so "during" counts only before one of those.
    private static let notTheOvernightMarkers = "\\b(?:" + [
        #"nap(?:s|ped|ping)?|quick\s+(?:reading|check|measurement|test|session)s?|spot[-\s]?checks?|live|real[-\s]?time|right\s+now|at\s+the\s+moment"#,
        #"this\s+reading|breath(?:e|ing)\s+(?:session|exercise)s?|watch\s+breathe|workouts?|exercis(?:e|ing)|mid[-\s]?(?:run|ride|workout|session)"#,
        #"during\s+(?:your|the|this|that|a)\s+(?:nap|workout|run|ride|session|reading|exercise)"#,
        #"(?:your|the|this|that|today['’]s)\s+(?:run|ride|swim|walk|hike|session|intervals?|reps?)"#
    ].joined(separator: "|") + ")\\b"

    /// Another state than the live workout: asleep, at rest, a nap, the
    /// night.
    private static let notTheWorkoutMarkers =
        #"\b(?:overnight|asleep|sleep(?:ing)?|nap(?:s|ped|ping)?|at\s+rest|resting|while\s+(?:lying|sitting)|in\s+bed|this\s+morning)\b"#

    /// A value someone else stated: the user ("you said 38", "you told me
    /// your TSB is -8") or another device ("your Garmin shows 52"). The
    /// prompt treats a value the user states as theirs, so rewriting it to
    /// the app's would contradict them.
    private static let reportedElsewhereMarkers = "\\b(?:" + [
        #"you\s+(?:said|say|told|tell|mentioned|reported|noted|wrote|gave|saw|see|are\s+seeing)|you['’](?:re|ve)\s+(?:seeing|said|told|mentioned|reported)"#,
        #"according\s+to\s+(?:you|your)|what\s+you\s+(?:told|said|gave|reported)|your\s+(?:own\s+)?(?:number|figure|reading)\s+of"#,
        #"(?:your|the)\s+(?:watch|garmin|whoop|oura|polar\s+flow|elite\s?hrv|kubios|apple\s+watch|other\s+app|ring)\s+(?:says|said|shows|showed|reads|read|gave|reports|reported)"#
    ].joined(separator: "|") + ")\\b"

    /// A summary, target, hypothetical, plan, negation or comparison rather
    /// than the value now: "average", "keep it", "if", "higher than",
    /// "tonight you'll want 8 hours of sleep", "you didn't get 8 hours".
    private static let targetMarkers = "\\b(?:" + [
        #"average|avg|mean|baseline|typical(?:ly)?|usual(?:ly)?|normally|target|goal|aim|keep|stay"#,
        #"peak|max(?:imum)?|min(?:imum)?|lowest|highest|best|worst|trend|would|could|if|should|threshold"#,
        #"under|below|above|over|between|range|higher|lower|than"#,
        #"will|tonight|tomorrow|next|plan(?:ned)?|try|want|expect(?:ed)?|predict(?:ed)?|project(?:ed)?|not|never|without"#
    ].joined(separator: "|") + ")\\b" + #"|[’']ll\b|n[’']t\b"#

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

    // MARK: - Spelled-number normalisation (voice-mode discrepancy capture)
    //
    // The verifier's main regexes look for digit characters
    // (`\d+(?:\.\d+)?`). In voice mode the AI replies conversationally
    // — "TSB negative thirty-one point seven" — and zero digits appear, so
    // the checks run on `SpelledNumberNormalizer`'s digit-form copy of the
    // reply and each correction is mapped back to the original text.

    /// Returns `text` with sequences like "negative thirty-one point
    /// seven" rewritten to "-31.7" (`SpelledNumberNormalizer`). Idempotent:
    /// digit-form text passes through unchanged. Case-insensitive.
    static func normalizeSpelledNumbers(_ text: String) -> String {
        SpelledNumberNormalizer.normalizeWithRewrites(text).text
    }

    /// `discrepancy` with its range moved from the normalized text to the
    /// original. A claim that covers a rewritten number covers all of the
    /// words it came from, so "negative thirty-one point seven" is replaced
    /// whole.
    private static func remap(
        _ discrepancy: Discrepancy,
        from normalized: String,
        to original: String,
        rewrites: [SpelledNumberNormalizer.Rewrite]
    ) -> Discrepancy? {
        let inNormalized = NSRange(discrepancy.range, in: normalized)
        let start = SpelledNumberNormalizer.originalOffset(of: inNormalized.location, rewrites: rewrites, snapToEnd: false)
        let end = SpelledNumberNormalizer.originalOffset(of: NSMaxRange(inNormalized), rewrites: rewrites, snapToEnd: true)
        guard let range = Range(NSRange(location: start, length: end - start), in: original) else {
            debugLog("[MetricsVerifier] dropped a \(discrepancy.metric) correction: its range did not map back to the reply", level: .warning)
            return nil
        }
        return Discrepancy(
            metric: discrepancy.metric, claimed: discrepancy.claimed, actual: discrepancy.actual,
            absoluteDelta: discrepancy.absoluteDelta, range: range
        )
    }
}
