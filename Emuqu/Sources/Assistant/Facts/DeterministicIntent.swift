import Foundation

/// Deterministic intent shortcut for the highest-frequency voice
/// patterns.
///
/// The research recommendation: ~30–50% of voice turns are repeats of
/// a small set of factual lookups ("what's my recovery", "how did I
/// sleep", "what's my RHR") that don't need an LLM at all. They can
/// be answered by a pattern-match → fact-catalog read → template
/// render path that costs nothing in tokens, runs in <50 ms, and
/// stays on-device. Same approach SiriKit / Rasa / Voiceflow / Home
/// Assistant ship in production.
///
/// **How precision is actually achieved.** There is no numeric
/// confidence score. Precision comes from the patterns being
/// deliberately NARROW: each trigger is a regex-anchored match against
/// a hand-authored, curated set, first match wins, and the path is
/// only served when the matched fact's value is non-nil (otherwise it
/// falls through to the LLM). Ambiguous input, mid-sentence
/// parameters, tool-call needs, and the speculation/medical/web band
/// are excluded by simply having no pattern that matches them — they
/// fall through. `DeterministicIntentTests` guards this with
/// example-based assertions (medical-speculation / advice / tool /
/// web utterances must NOT match, plus the expected-match set).
/// NOTE: there is no confidence gate — `tryMatch` has no confidence
/// computation (first match wins) — and the test suite is example-based
/// rather than a labeled-corpus precision gate. Turning the example
/// tests into a real labeled-precision gate is worthwhile future work.
///
/// **What this module does NOT do.** This is not an NLU framework;
/// it's a curated set of top-N voice queries that map 1:1 to an
/// existing fact-catalog read. Anything ambiguous, anything with
/// mid-sentence parameters, anything that needs a tool call, anything
/// in the speculation/medical/web band — falls through.
///
/// **Privacy.** Strictly on-device. No network. No telemetry off the
/// phone. The pattern set is hand-authored; user input never tunes it.
@MainActor
enum DeterministicIntent {
    // MARK: - Pattern catalog

    /// One handler. The handler is responsible for resolving facts
    /// from the catalog and returning a rendered string, or nil if
    /// the data isn't ready (e.g., baseline still building, no
    /// session today). A nil result also falls through to the LLM.
    /// `utterance` is the normalized user input (lowercased, trimmed) —
    /// useful for handlers that need to inspect verb tense like
    /// "yesterday" vs "today".
    typealias Handler = @MainActor (_ utterance: String, _ context: MatchContext) -> String?

    /// Context the handler receives — current archive snapshot and
    /// timestamp resolution. Kept narrow so handlers can't
    /// accidentally mutate state and so this module doesn't take a
    /// hard dependency on RRCollector's full graph (the call site
    /// only owns `AssistantContextSource.shared`).
    ///
    /// Current patterns only need the archive +
    /// settings. When future patterns need live HealthKit or live
    /// baseline data, route them through `AssistantContextSource`
    /// or extend this struct.
    struct MatchContext {
        let now: Date
        let archive: SessionArchive
        let userSettings: UserSettings
    }

    /// One pattern + handler. `triggers` are case-folded, accent-
    /// normalized, regex-anchored so partial accidental matches
    /// (e.g. "what's my heartburn medication") don't trip the
    /// "what's my heart rate" path.
    struct Pattern {
        let id: String
        let triggers: [String] // each is a regex pattern
        let handler: Handler

        /// Cached regex compilation. Recompiling all triggers on every
        /// `tryMatch` call would cost ~30 NSRegularExpression
        /// compilations per voice turn against the 15-pattern catalog.
        /// One compile per app launch via the enclosing enum's
        /// @MainActor cache.
        @MainActor var compiled: [NSRegularExpression] {
            DeterministicIntent.compiledTriggers(forPatternID: id, triggers: triggers)
        }
    }

    /// Module-level cache keyed by pattern id; cold-init compiles each
    /// trigger once. Reached only via `Pattern.compiled` which is
    /// `@MainActor`, so the dictionary mutation is automatically
    /// serialised on the main actor without an extra lock.
    private static var compiledCache: [String: [NSRegularExpression]] = [:]

    fileprivate static func compiledTriggers(
        forPatternID id: String,
        triggers: [String]
    ) -> [NSRegularExpression] {
        if let hit = compiledCache[id] { return hit }
        let regexes = triggers.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
        compiledCache[id] = regexes
        return regexes
    }

    // MARK: - Top-20 pattern catalog
    //
    // Ordered by expected frequency in voice. Precision-first — when
    // in doubt, fall through to the LLM.

    static let patterns: [Pattern] = [
        // Recovery score / verdict — the single most-frequent voice query
        Pattern(
            id: "recovery_score_today",
            triggers: [
                #"^\s*(what(?:['']s| is)?(?:\smy)?|how(?:['']s| is)?\s+my)?\s*recovery(?:\s+score)?(?:\s+today)?\??\s*$"#,
                #"^\s*how\s+(?:am|are)\s+(?:i|we)\s+doing(?:\s+today)?\??\s*$"#,
                #"^\s*recovery\??\s*$"#
            ],
            handler: { _, ctx in
                // Find today's frozen score from the most recent
                // overnight session.
                let recent = Self.todaysOvernightEntry(now: ctx.now, archive: ctx.archive)
                guard let entry = recent, let score = entry.recoveryScore else { return nil }
                // `recoveryScore` is stored 0–10; the user-facing score and
                // `ScoreVerdict` are both 0–100 (see DashboardSessionPolicy).
                // Without the ×10 every voice answer read "8 — Very low".
                let score100 = score * 10
                let verdict = ScoreVerdict(score: score100).word
                return "Your recovery is \(Int(score100.rounded())) — \(verdict)."
            }
        ),

        // Resting heart rate — frequent, single number
        Pattern(
            id: "resting_hr_today",
            triggers: [
                #"^\s*(what(?:['']s| is)?(?:\smy)?|how(?:['']s| is)?\s+my)?\s*(?:resting\s+)?(?:heart\s+rate|hr|rhr|pulse)(?:\s+today)?\??\s*$"#,
                #"^\s*rhr\??\s*$"#
            ],
            handler: { _, ctx in
                let recent = Self.todaysOvernightEntry(now: ctx.now, archive: ctx.archive)
                guard let entry = recent,
                      let session = try? ctx.archive.retrieve(entry.sessionId),
                      let rhr = session.vitalsSnapshot?.restingHeartRate
                else { return nil }
                return "Your resting heart rate this morning was \(Int(rhr.rounded())) beats per minute."
            }
        ),

        // HRV (RMSSD) — single number, very frequent
        Pattern(
            id: "hrv_rmssd_today",
            triggers: [
                #"^\s*(what(?:['']s| is)?(?:\smy)?)?\s*(?:rmssd|hrv)(?:\s+today)?\??\s*$"#
            ],
            handler: { _, ctx in
                let recent = Self.todaysOvernightEntry(now: ctx.now, archive: ctx.archive)
                guard let entry = recent, let rmssd = entry.meanRMSSD else { return nil }
                return "Your HRV this morning was \(Int(rmssd.rounded())) milliseconds."
            }
        ),

        // Sleep duration — very frequent
        Pattern(
            id: "sleep_duration_last_night",
            triggers: [
                #"^\s*(?:how\s+(?:did|was)\s+(?:i|my)\s+sleep|how\s+much\s+sleep|sleep(?:\s+last\s+night)?)\??\s*$"#,
                #"^\s*how\s+long\s+did\s+i\s+sleep(?:\s+last\s+night)?\??\s*$"#
            ],
            handler: { _, ctx in
                let recent = Self.todaysOvernightEntry(now: ctx.now, archive: ctx.archive)
                guard let entry = recent,
                      let session = try? ctx.archive.retrieve(entry.sessionId),
                      let sleep = session.sleepSnapshot
                else { return nil }
                let hours = Double(sleep.nightSleepMinutes) / 60.0
                // `sleepEfficiency` is already a 0–100 percentage — the prior
                // ×100 produced "9200 percent efficiency".
                let efficiency = Int(sleep.sleepEfficiency.rounded())
                return "You slept \(String(format: "%.1f", hours)) hours with \(efficiency) percent efficiency."
            }
        ),

        // Last workout summary
        Pattern(
            id: "last_workout_summary",
            triggers: [
                #"^\s*(?:tell\s+me\s+about\s+)?(?:my\s+)?last\s+workout\??\s*$"#,
                #"^\s*how\s+(?:was|did)\s+(?:my\s+)?last\s+workout(?:\s+go)?\??\s*$"#
            ],
            handler: { _, ctx in
                guard let last = ctx.archive.entries
                    .first(where: { $0.sessionType == .workout })
                else { return nil }
                let durationMin = last.endDate.map { Int($0.timeIntervalSince(last.date) / 60) } ?? 0
                let dayLabel = relativeDay(last.date, now: ctx.now)
                if durationMin > 0 {
                    return "Your last workout was \(dayLabel) — \(durationMin) minutes."
                }
                return "Your last workout was \(dayLabel)."
            }
        ),

        // Did I train yesterday / today
        Pattern(
            id: "trained_recently",
            triggers: [
                #"^\s*did\s+i\s+(?:train|work\s*out|run|ride|cycle)\s+(?:yesterday|today)\??\s*$"#,
                #"^\s*(?:any\s+)?workouts?\s+(?:yesterday|today)\??\s*$"#
            ],
            handler: { utterance, ctx in
                let isYesterday = utterance.contains("yesterday")
                let target = dayStart(isYesterday: isYesterday, now: ctx.now)
                let match = ctx.archive.entries
                    .first {
                        $0.sessionType == .workout
                            && Calendar.current.isDate($0.date, inSameDayAs: target)
                    }
                if let m = match {
                    let mins = m.endDate.map { Int($0.timeIntervalSince(m.date) / 60) } ?? 0
                    return mins > 0
                        ? "Yes — you did a \(mins)-minute workout."
                        : "Yes — you logged a workout."
                }
                return "No workout recorded \(isYesterday ? "yesterday" : "today yet")."
            }
        ),

        // Should I train today (heuristic, not LLM-quality)
        // — DELIBERATELY OMITTED. This is exactly the kind of question
        // that needs context and reasoning; it goes to the cloud.
        // Listed here for documentation: do not add a deterministic
        // handler for "should I train today" / similar advice queries.

        // Score breakdown — read frozen breakdown
        Pattern(
            id: "score_breakdown_today",
            triggers: [
                #"^\s*(?:what(?:['']s| is)?\s+)?(?:my\s+)?score\s+breakdown(?:\s+today)?\??\s*$"#,
                #"^\s*why\s+(?:is\s+)?my\s+score(?:\s+\w+)?\??\s*$"# // "why is my score this"
            ],
            handler: { _, ctx in
                guard let entry = Self.todaysOvernightEntry(now: ctx.now, archive: ctx.archive),
                      let session = try? ctx.archive.retrieve(entry.sessionId),
                      let breakdown = session.scoreBreakdown
                else { return nil }
                // ScoreBreakdown stores per-factor sub-scores in
                // `factors: [ScoreFactor]`. Render each factor with its
                // 0-100 sub-score so the user hears "HRV 78, sleep 82, …"
                // as one short sentence.
                let summary = breakdown.factors.map { factor in
                    "\(factor.label) \(Int(factor.score.rounded()))"
                }.joined(separator: ", ")
                return "\(summary). Composite \(ScoreVerdict.safeDisplayScore(breakdown.compositeScore))."
            }
        ),

        // Sleep stage breakdown — deep / REM / light / awake
        Pattern(
            id: "sleep_stages_last_night",
            triggers: [
                #"^\s*(?:how\s+much\s+)?(?:deep\s+sleep|rem\s+sleep|light\s+sleep)(?:\s+(?:did\s+i\s+get|last\s+night))?\??\s*$"#,
                #"^\s*sleep\s+stages\??\s*$"#,
                #"^\s*sleep\s+breakdown\??\s*$"#
            ],
            handler: { _, ctx in
                guard let entry = Self.todaysOvernightEntry(now: ctx.now, archive: ctx.archive),
                      let session = try? ctx.archive.retrieve(entry.sessionId),
                      let sleep = session.sleepSnapshot
                else { return nil }
                let totalH = Double(sleep.nightSleepMinutes) / 60.0
                // A night estimated from heart rate has no stages. Saying
                // "deep 0.0" would report a measurement that never happened.
                guard let deepMin = sleep.deepSleepMinutes, let remMin = sleep.remSleepMinutes else {
                    return "Total \(String(format: "%.1f", totalH)) hours. No sleep stage data for that night."
                }
                let deepH = Double(deepMin) / 60.0
                let remH = Double(remMin) / 60.0
                return "Total \(String(format: "%.1f", totalH)) hours: deep \(String(format: "%.1f", deepH)), REM \(String(format: "%.1f", remH))."
            }
        ),

        // Body weight — single number from settings
        Pattern(
            id: "body_weight",
            triggers: [
                #"^\s*(?:what(?:['']s| is)?\s+)?(?:my\s+)?(?:body\s+)?weight\??\s*$"#,
                #"^\s*how\s+(?:much\s+)?(?:do\s+)?(?:i\s+)?weigh(?:\s+now)?\??\s*$"#
            ],
            handler: { _, ctx in
                guard let kg = ctx.userSettings.bodyWeightKg else { return nil }
                // Resolve units: `auto` reads device locale; explicit
                // imperial / metric overrides. Imperial is US/UK/Liberia/
                // Myanmar default; the rest of the world is metric.
                let pref = UnitsPreferenceStore.current
                let usesImperial: Bool = {
                    switch pref {
                    case .imperial: return true
                    case .metric: return false
                    case .auto:
                        return Locale.current.region?.identifier == "US"
                            || Locale.current.region?.identifier == "GB"
                    }
                }()
                if usesImperial {
                    let lbs = kg * 2.20462
                    return "Your weight is \(Int(lbs.rounded())) pounds."
                }
                return "Your weight is \(String(format: "%.1f", kg)) kilograms."
            }
        ),

        // Max HR — single number from settings
        Pattern(
            id: "max_hr",
            triggers: [
                #"^\s*(?:what(?:['']s| is)?\s+)?(?:my\s+)?max(?:imum)?\s+(?:heart\s+rate|hr)\??\s*$"#,
                #"^\s*max\s+hr\??\s*$"#
            ],
            handler: { _, ctx in
                guard let max = ctx.userSettings.maxHR else { return nil }
                return "Your max heart rate is \(max) beats per minute."
            }
        ),

        // Lactate threshold HR — single number from settings
        Pattern(
            id: "lthr",
            triggers: [
                #"^\s*(?:what(?:['']s| is)?\s+)?(?:my\s+)?(?:lthr|lactate\s+threshold(?:\s+hr)?)\??\s*$"#
            ],
            handler: { _, ctx in
                guard let lthr = ctx.userSettings.lactateThresholdHR else { return nil }
                return "Your lactate threshold heart rate is \(lthr) beats per minute."
            }
        ),

        // Sleep latency — minutes to fall asleep
        Pattern(
            id: "sleep_latency",
            triggers: [
                #"^\s*(?:how\s+long\s+did\s+(?:it\s+take\s+(?:me\s+)?)?(?:i\s+)?(?:to\s+)?fall\s+asleep|sleep\s+latency)\??\s*$"#,
                #"^\s*time\s+to\s+(?:fall\s+)?asleep\??\s*$"#
            ],
            handler: { _, ctx in
                guard let entry = Self.todaysOvernightEntry(now: ctx.now, archive: ctx.archive),
                      let session = try? ctx.archive.retrieve(entry.sessionId),
                      let sleep = session.sleepSnapshot,
                      let inBedStart = sleep.inBedStart,
                      let sleepStart = sleep.sleepStart
                else { return nil }
                let mins = Int(sleepStart.timeIntervalSince(inBedStart) / 60)
                guard mins >= 0 else { return nil }
                return "It took you \(mins) minutes to fall asleep."
            }
        ),

        // Sleep efficiency — single percentage
        Pattern(
            id: "sleep_efficiency",
            triggers: [
                #"^\s*(?:what(?:['']s| was)?\s+)?(?:my\s+)?sleep\s+efficiency\??\s*$"#
            ],
            handler: { _, ctx in
                guard let entry = Self.todaysOvernightEntry(now: ctx.now, archive: ctx.archive),
                      let session = try? ctx.archive.retrieve(entry.sessionId),
                      let sleep = session.sleepSnapshot
                else { return nil }
                // `sleepEfficiency` is already 0–100 — no ×100 (that read "9200 percent").
                return "Your sleep efficiency was \(Int(sleep.sleepEfficiency.rounded())) percent."
            }
        ),

        // Total session count — for "how many readings have I done"
        Pattern(
            id: "total_session_count",
            triggers: [
                #"^\s*how\s+many\s+(?:readings|sessions|workouts)\s+(?:have\s+i\s+)?(?:done|recorded|logged)\??\s*$"#,
                #"^\s*(?:total\s+)?session\s+count\??\s*$"#
            ],
            handler: { _, ctx in
                let total = ctx.archive.entries.count
                let workouts = ctx.archive.entries.filter { $0.sessionType == .workout }.count
                let overnight = ctx.archive.entries.filter { $0.sessionType == .overnight }.count
                return "\(total) total — \(overnight) overnight, \(workouts) workouts."
            }
        )
    ]

    // MARK: - Match entry point

    /// Try to match the user's utterance against the deterministic
    /// catalog. Returns nil to fall through to the LLM. The caller
    /// MUST treat nil as "send to LLM" and never as "no answer."
    ///
    /// The matcher fast-paths: lowercased + whitespace-trimmed +
    /// punctuation-stripped at the edges, then regex-anchored against
    /// each pattern's triggers. First match wins.
    static func tryMatch(_ utterance: String, in context: MatchContext) -> String? {
        let normalized = normalize(utterance)
        guard !normalized.isEmpty else { return nil }
        guard let pattern = patterns.first(where: { matches($0, normalized) }) else { return nil }
        guard let answer = pattern.handler(normalized, context) else {
            // Pattern matched but data not ready — fall through.
            debugLog("[DeterministicIntent] match=\(pattern.id) but no data; falling through to LLM")
            return nil
        }
        debugLog("[DeterministicIntent] match=\(pattern.id) — served")
        return answer
    }

    private static func matches(_ pattern: Pattern, _ normalized: String) -> Bool {
        let range = NSRange(normalized.startIndex..., in: normalized)
        return pattern.compiled.contains { $0.firstMatch(in: normalized, options: [], range: range) != nil }
    }

    // MARK: - Helpers

    private static func normalize(_ utterance: String) -> String {
        utterance
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!,"))
    }

    /// The overnight session that belongs to the local day containing `now`,
    /// by the midpoint-in-day rule (spec §2.2, same as `OvernightArchive.byDate`
    /// and every async by-date fact).
    ///
    /// Overnight sessions are dated the evening they *start*, so the old
    /// `startOfDay(entry.date) == today` predicate missed last night's session
    /// every single morning — an overnight begun 23:00 Monday has `date` =
    /// Monday, which never equals Tuesday. That made the most common morning
    /// voice queries ("what's my recovery / HRV / RHR / how'd I sleep") silently
    /// skip this instant local path and fall through to the LLM. Matching by
    /// midpoint (which lands in the morning) fixes it.
    /// Start-of-day for "today" or "yesterday", relative to `now`, in the
    /// current calendar.
    ///
    /// Separate from the `trained_recently` handler so the
    /// DST edge is testable in isolation (the handler itself needs a seeded
    /// `SessionArchive`, which a unit test should not have to stand up).
    ///
    /// Yesterday must not be computed as
    /// `now.addingTimeInterval(-86400)`. A fixed 86 400 s is not "one day"
    /// across a daylight-saving transition. The local day containing a
    /// spring-forward is only 23 h long, so on the following morning between
    /// 00:00 and 01:00 local, subtracting a rigid 24 h lands in the day
    /// *before* yesterday — and "did I train yesterday?" answered about the
    /// wrong day. `Calendar.date(byAdding: .day,...)` is transition-aware and
    /// is already the idiom used in `AppFactResolver.swift`.
    ///
    /// Falls back to the un-shifted day start if the calendar cannot produce
    /// the offset date, which it cannot for any real Gregorian input.
    static func dayStart(isYesterday: Bool, now: Date, calendar: Calendar = .current) -> Date {
        let base = calendar.startOfDay(for: now)
        guard isYesterday else { return base }
        return calendar.date(byAdding: .day, value: -1, to: base) ?? base
    }

    static func todaysOvernightEntry(now: Date, archive: SessionArchive) -> SessionArchiveEntry? {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        // The instant voice path ("what's my recovery/HRV today")
        // must not answer from an `.insufficient`/`.preSleep` partial; the index
        // mirrors the quality flag. Falls through to the LLM if today's only
        // overnight is untrustworthy — correct, rather than voicing a bogus number.
        return archive.entries
            .filter { $0.sessionType == .overnight && $0.isReliableForHRVAggregates }
            .sorted { $0.date > $1.date }
            .first { entry in
                let duration = (entry.endDate ?? entry.date).timeIntervalSince(entry.date)
                let midpoint = entry.date.addingTimeInterval(duration / 2)
                return midpoint >= dayStart && midpoint < dayEnd
            }
    }

    private static func relativeDay(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInYesterday(date) { return "yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day {
            if days < 7 { return "\(days) days ago" }
            if days < 14 { return "a week ago" }
        }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}
