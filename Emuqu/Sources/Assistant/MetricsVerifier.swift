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
            pattern: #"\b(?:your\s+(?:current\s+|live\s+)?(?:HR|heart\s+rate)(?:\s+is|['’]s)?|(?:HR|heart\s+rate)\s+(?:is\s+)?(?:right\s+now|currently|now))(?:\s+(?:is|now|currently|right\s+now|sitting|at|around|about))*\s+(?<claim>(?<value>\d{2,3})(?:\s*(?:bpm|beats\s+per\s+minute))?)\b(?!\s*(?:%|[-–/]|\.\d)|\s*(?:percent|seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?)\b)"#,
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
            pattern: #"\b(?:your\s+(?:current\s+|live\s+)?(?:power|wattage)(?:\s+is|['’]s)?|(?:power|wattage)\s+(?:is\s+)?(?:right\s+now|currently|now))(?:\s+(?:is|now|currently|right\s+now|sitting|at|around|about))*\s+(?<claim>(?<value>\d{2,4})(?:\s*(?:W|watts?))?)\b(?!\s*(?:%|[-–/]|\.\d)|\s*(?:percent|seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?)\b)"#,
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

    /// Live-workout claims (HR, power, α1, drift) against the recorder's
    /// snapshot. Used by the voice pipeline before TTS.
    static func verify(_ text: String, against snapshot: WorkoutAIContext?) -> [Discrepancy] {
        guard let snapshot else { return [] }
        return verifyLive(text, values: LiveValues(
            heartRate: snapshot.heartRate, powerWatts: snapshot.powerWatts,
            alpha1: snapshot.alpha1, hrDriftPercent: snapshot.liveHRDriftPercent
        ))
    }

    /// Live-workout claims (HR, power, α1) against the broker's snapshot,
    /// for a caller that has no recorder at hand (the typed-chat pipeline).
    /// The broker carries no drift, so drift claims are not checked here.
    static func verify(_ text: String, againstLive live: AssistantContext.LiveWorkoutSnapshot?) -> [Discrepancy] {
        guard let live else { return [] }
        return verifyLive(text, values: LiveValues(
            heartRate: live.heartRate, powerWatts: live.powerWatts, alpha1: live.alpha1, hrDriftPercent: nil
        ))
    }

    /// Runs the live checks on the spelled-number-normalised text, so a
    /// voice reply's "one hundred sixty" is checked like "160", and maps
    /// each range back to `text`. Ranges index `text`, which is what the
    /// voice pipeline splices into.
    private static func verifyLive(_ text: String, values: LiveValues) -> [Discrepancy] {
        let normalized = normalizeWithRewrites(text)
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
    static func verifyAppStateClaims(_ text: String) -> AppStateVerifyResult {
        acknowledgeDeliveredCorrections()
        let normalized = normalizeWithRewrites(text)
        let found = trainingLoadDiscrepancies(in: normalized.text) + overnightDiscrepancies(in: normalized.text)
            + lastNightSleepDiscrepancies(in: normalized.text)
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
    /// 29", "TSB 7", and the phrasings the prompt itself uses: "TSB is -8.8",
    /// "TSB of", "TSB at", "TSB: ". Every pattern refuses a number that is a
    /// quantity of something else ("CTL 42-day window", "TSB 7 days").
    ///
    /// Skipped while training load is paused: the prompt leaves the load
    /// numbers out then, as the screens do, so there is no value to correct to.
    @MainActor
    private static func trainingLoadDiscrepancies(in text: String) -> [Discrepancy] {
        guard !TrainingLoadVisibility.isPaused(AppDependencies.current.app.settingsManager.settings),
              let load = TrainingLoadRegistry.live() else { return [] }
        var found = claimsMatching(
            in: text,
            pattern: #"\bTSB(?:\s+(?:is|of|at|now|currently|today|sitting|sits|reads|stands\s+at|right\s+now))*(?:\s*[:=]\s*|\s+)(?<claim>(?:negative\s+)?(?<value>-?\d+(?:\.\d+)?))(?!\d|\.\d|\s*%|\s*-?\s*(?:days?|d|hours?|hrs?|h|weeks?|wks?|nights?|mins?|minutes?|sessions?|workouts?)\b)"#,
            check: ClaimCheck(actual: load.tsb, tolerance: 2.0, metric: "TSB", negateOnSpelled: true) { String(format: "%+.1f", $0) }
        )
        found += claimsMatching(
            in: text,
            pattern: #"\bATL(?:\s+(?:is|of|at|now|currently|today|sitting|sits|reads|stands\s+at|right\s+now))*(?:\s*[:=]\s*|\s+)(?<claim>(?<value>\d+(?:\.\d+)?))(?!\d|\.\d|\s*%|\s*-?\s*(?:days?|d|hours?|hrs?|h|weeks?|wks?|nights?|mins?|minutes?|sessions?|workouts?)\b)"#,
            check: ClaimCheck(actual: load.atl, tolerance: 3.0, metric: "ATL") { String(format: "%.1f", $0) }
        )
        found += claimsMatching(
            in: text,
            pattern: #"\bCTL(?:\s+(?:is|of|at|now|currently|today|sitting|sits|reads|stands\s+at|right\s+now))*(?:\s*[:=]\s*|\s+)(?<claim>(?<value>\d+(?:\.\d+)?))(?!\d|\.\d|\s*%|\s*-?\s*(?:days?|d|hours?|hrs?|h|weeks?|wks?|nights?|mins?|minutes?|sessions?|workouts?)\b)"#,
            check: ClaimCheck(actual: load.ctl, tolerance: 3.0, metric: "CTL") { String(format: "%.1f", $0) }
        )
        return found + acwrDiscrepancies(in: text, acwr: load.acwr)
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
    private static func overnightDiscrepancies(in text: String) -> [Discrepancy] {
        let archive = AppDependencies.current.storage.sessionArchive
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

    /// "RMSSD 68 ms" / "RMSSD 76" / "RMSSD of 68" / "RMSSD is 48".
    private static func rmssdClaims(in text: String, rmssd: Double) -> [Discrepancy] {
        claimsMatching(
            in: text,
            pattern: #"\bRMSSD(?:\s+(?:is|of|at|now|currently|today|sitting|sits|reads|stands\s+at|right\s+now))*(?:\s*[:=]\s*|\s+)(?<claim>(?<value>\d+(?:\.\d+)?)(?:\s*ms\b)?)(?!\d|\.\d|\s*%|\s*-?\s*(?:days?|d|hours?|hrs?|h|weeks?|wks?|nights?|mins?|minutes?|sessions?|workouts?)\b)"#,
            check: ClaimCheck(actual: rmssd, tolerance: 8.0, metric: "RMSSD") { String(format: "%.0f ms", $0) }
        )
    }

    /// "Recovery 9.1 of 10" / "Recovery 91" / "your recovery score is 72" /
    /// "recovery score of 72" — both the 0–10 and the 0–100 scale are
    /// reasonable, so a claim that matches the 0–10 form within tolerance is a
    /// different scale, not a lie. "Recovery 48 hours" is a duration, not a
    /// score. A 0–100 correction is the integer the dashboard shows
    /// (`RecoveryScoreCalculator.displayScore`), not the raw score × 10.
    private static func recoveryScoreClaims(in text: String, score10: Double) -> [Discrepancy] {
        claimsMatching(
            in: text,
            pattern: #"\brecovery(?:\s+score)?(?:\s+(?:is|of|at|now|currently|today|sitting|sits|reads|stands\s+at|right\s+now))*(?:\s*[:=]\s*|\s+)(?<claim>(?<value>\d+(?:\.\d+)?))\b(?!\.\d|\s*%|\s*-?\s*(?:days?|d|hours?|hrs?|h|weeks?|wks?|nights?|mins?|minutes?|sessions?|workouts?)\b)"#,
            check: ClaimCheck(
                actual: Double(RecoveryScoreCalculator.displayScore(score10 * 10)), tolerance: 4.0, metric: "recovery_score"
            ) { // assume 0-100 form first
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

    // MARK: - Last night's sleep

    /// Sleep duration and efficiency. Source of truth: the session
    /// `get_sleep` "latest" answers from (`OvernightArchive.latest`), read the
    /// way the Recovery Score detail and Flo's own context read it
    /// (`nightSleepMinutes`, `measuredSleepEfficiency`), so a correction puts
    /// back the number the user sees on screen and the model was given. The
    /// archive is read only when the text talks about sleep.
    @MainActor
    private static func lastNightSleepDiscrepancies(in text: String) -> [Discrepancy] {
        guard text.range(of: #"\b(?:sleep|slept|asleep|efficien)"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let sleep = latestOvernightSleep() else { return [] }
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
    private static func latestOvernightSleep() -> SleepData? {
        let archive = AppDependencies.current.storage.sessionArchive
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
        return sleepDurationPatterns
            .compactMap { DebugLogger.compiledPattern($0, options: [.caseInsensitive]) }
            .flatMap { $0.matches(in: text, range: whole) }
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
              isAboutTheCurrentValue(match.range, in: ns),
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
        let check = ClaimCheck(actual: efficiency, tolerance: 1.0, metric: "sleep_efficiency") { "\(Int($0.rounded()))%" }
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

    private static func sentence(containing range: Range<String.Index>, in text: String, matches pattern: String) -> Bool {
        let ns = text as NSString
        let span = sentenceRange(containing: NSRange(range, in: text), in: ns)
        return DebugLogger.compiledPattern(pattern, options: [.caseInsensitive])?
            .firstMatch(in: text, range: span) != nil
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
    ///
    /// Only the sentence up to the end of the claim's own clause is read. A
    /// marker in a later clause is about another number: the prompt's own
    /// headline "Recovery 72, slightly down from 76 yesterday" states today's
    /// value first and must still be checked. A marker before the claim
    /// ("Yesterday, recovery was 55") still applies to it.
    private static func isAboutTheCurrentValue(_ range: NSRange, in ns: NSString) -> Bool {
        let sentence = sentenceRange(containing: range, in: ns)
        let scope = NSRange(location: sentence.location, length: clauseEnd(after: range, in: sentence, ns: ns) - sentence.location)
        return ![timeMarkers, targetMarkers].contains { pattern in
            DebugLogger.compiledPattern(pattern, options: [.caseInsensitive])?
                .firstMatch(in: ns as String, range: scope) != nil
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
    // corrections forward so the next turn's system prompt can
    // include "you fabricated HR=72 last turn — actual was 91; call
    // get_workout_live for HR, don't guess."
    //
    // A correction is retired only once a reply to a prompt that carried
    // it has come back, not when the prompt is composed: a send that
    // fails and is re-composed for a fallback provider must carry the
    // reminder again. `pendingCorrectionsBlock` moves pending entries to
    // `delivered` without dropping them; `verifyAppStateClaims`, which
    // every caller runs on each reply the model produces, retires the
    // delivered ones. A single fabrication still produces one reminder
    // per reply, not a perpetual one.
    //
    // Process-local; cleared on app launch. Lock-guarded since
    // both the speaker thread (writes) and the AssistantViewModel
    // dispatch path (reads) hit it.

    private struct CorrectionBuffer {
        /// Recorded, not yet put in a prompt.
        var pending: [Discrepancy] = []
        /// Put in a prompt whose reply has not come back yet.
        var delivered: [Discrepancy] = []
    }

    private static let corrections = OSAllocatedUnfairLock<CorrectionBuffer>(initialState: CorrectionBuffer())

    /// Record discrepancies caught by the hallucination guard so the
    /// next AI turn's system prompt can warn the model. Caps at 4
    /// entries to keep the reminder short — a model fabricating > 4
    /// numbers in one turn has bigger problems than this hint can
    /// fix. In voice mode the same claim is caught twice — in the spoken
    /// chunk and in the saved chat turn — so a correction already pending
    /// for the same metric, claim and value is not added again.
    static func recordCorrections(_ discrepancies: [Discrepancy]) {
        guard !discrepancies.isEmpty else { return }
        corrections.withLock { buffer in
            for d in discrepancies where !buffer.pending.contains(where: {
                $0.metric == d.metric && $0.claimed == d.claimed && $0.actual == d.actual
            }) {
                buffer.pending.append(d)
            }
            if buffer.pending.count > 4 { buffer.pending = Array(buffer.pending.suffix(4)) }
        }
    }

    /// The reminder for the prompt being composed: every correction not yet
    /// answered by a reply, or nil when there is none. Called by
    /// `AssistantSystemPrompt.compose` for every send. Does not retire
    /// anything, so a re-composed prompt (fallback provider, a test
    /// composing a prompt) carries the same reminder.
    static func pendingCorrectionsBlock() -> String? {
        let shown = corrections.withLock { buffer in
            buffer.delivered = Array((buffer.delivered + buffer.pending).suffix(4))
            buffer.pending = []
            return buffer.delivered
        }
        return correctionsBlock(shown)
    }

    /// Render every correction and empty the buffer, delivered or not.
    /// Returns nil when there's nothing to surface. The one-shot form,
    /// for a caller that owns the whole cycle (tests resetting state).
    static func consumePendingCorrectionsBlock() -> String? {
        let drained = corrections.withLock { buffer in
            defer { buffer = CorrectionBuffer() }
            return Array((buffer.delivered + buffer.pending).suffix(4))
        }
        return correctionsBlock(drained)
    }

    /// A reply has come back, so the model has seen every delivered
    /// reminder: retire them. Pending ones (recorded after the prompt was
    /// composed) wait for the next prompt.
    private static func acknowledgeDeliveredCorrections() {
        corrections.withLock { $0.delivered = [] }
    }

    /// One short system-prompt section: the rule, then one line per
    /// correction. Nil for none.
    private static func correctionsBlock(_ list: [Discrepancy]) -> String? {
        guard !list.isEmpty else { return nil }
        var lines: [String] = [
            "# Last turn correction — DO NOT FABRICATE",
            """
                Your previous response contained numbers that contradicted live data. The saved reply was corrected, but the user may already have read or heard the wrong number — if it matters, correct it briefly. For any of these metrics next \
                turn, CALL the appropriate tool (get_workout_live for HR / pace / location, get_training_load for TSB / ATL / CTL / ACWR, get_sleep for sleep duration / efficiency, lookup_fact for resting HR / HRV) and quote what comes back — never estimate or interpolate.
                """
        ]
        for d in list {
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
    // digit form BEFORE the regexes scan the text: 0–999 ("one hundred
    // and sixty", "a hundred five"), the spoken "one-sixty" form of a heart
    // rate (one or two, a hyphen, a tens word), and any number of decimal
    // digits after "point" ("point seven five" is .75).
    //
    // Every spelled number in the reply is rewritten, "this one" included.
    // That only affects matching: corrections are mapped back and applied
    // to the original text, and a rewritten word is a claim only where a
    // metric's claim shape surrounds it.

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
            guard let rep = spelledNumberReplacement(ns.substring(with: match.range)) else { continue }
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
        guard let range = Range(NSRange(location: start, length: end - start), in: original) else {
            debugLog("[MetricsVerifier] dropped a \(discrepancy.metric) correction: its range did not map back to the reply", level: .warning)
            return nil
        }
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
