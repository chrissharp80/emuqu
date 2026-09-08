import Foundation

/// User-declared physiological constraint for ambient coaching.
///
/// The user pre-sets one or more thresholds before starting a workout
/// ("don't let HR exceed 135 bpm for >30s", "stay above zone 2 power", "keep
/// pace slower than 9:00/mi"), then puts the phone away with their podcast
/// or audiobook. The voice coach stays silent — the audio session is
/// configured `.mixWithOthers + .duckOthers`, so the audiobook keeps
/// playing — until a threshold is breached past its `debounceSec`. At that
/// point the coach ducks the audiobook, speaks the cue, and returns control.
///
/// Reactive coaching becomes predictive: the user states intent up front,
/// the app keeps watch.
///
/// `debounceSec` keeps the coach from firing on a single noisy beat or GPS
/// glitch. `cooldownSec` prevents the coach from chiming every second once
/// the breach is sustained — fire once, stay quiet for a while.
struct WorkoutThreshold: Codable, Identifiable, Equatable, Hashable {
    let id: UUID

    /// Physiological / mechanical metric this threshold watches. Each metric
    /// has a natural unit; `value` carries the magnitude in that unit.
    /// `naturalLanguage` is special — see `naturalLanguageText` on the
    /// outer struct; the `value`/`condition` fields are ignored for that
    /// metric and the cue is fired by an AI evaluator path instead.
    enum Metric: String, Codable, CaseIterable {
        case heartRateBPM = "hr_bpm"
        case heartRateZone = "hr_zone"          // 1...5
        case powerWatts = "power_watts"
        case powerPercentFTP = "power_pct_ftp"  // 0...200, % of FTP
        case paceSecPerKm = "pace_sec_per_km"   // higher = slower
        case alpha1                  // DFA α1 — aerobic vs anaerobic
        case cadenceSPM = "cadence_spm"
        case distanceMeters = "distance_m"      // "tell me when I hit 5 miles"
        case elapsedSec = "elapsed_sec"         // "tell me when 1 hour has passed"
        case elevationGainMeters = "elev_gain_m" // "tell me when I've climbed 1000 ft"
        case gradePercent = "grade_pct"         // "tell me when I'm climbing more than 8%"
        case naturalLanguage = "natural_language"
    }

    /// The breach predicate. `greaterThan` fires when the metric is ABOVE
    /// `value`; `lessThan` when BELOW. There's intentionally no `=`
    /// operator — physiological signals are noisy and equality is silly
    /// at sample resolution.
    enum Condition: String, Codable {
        case greaterThan = "gt"
        case lessThan = "lt"
    }

    let metric: Metric
    let condition: Condition
    /// The threshold magnitude in the metric's natural unit (bpm, watts, %, …).
    let value: Double
    /// How many CONSECUTIVE seconds the breach must persist before the
    /// coach speaks. Default 30s — long enough that a noisy beat or one
    /// sprint surge doesn't trigger a cue, short enough that the user gets
    /// the warning while it still matters.
    let debounceSec: Int
    /// Minimum seconds between successive cues from this same threshold.
    /// 120s default — if you're sustained over your HR cap, you don't need
    /// to be told every 30 seconds.
    let cooldownSec: Int
    /// Optional user-supplied cue ("ease up", "stay in Z2"). If empty, the
    /// coach generates one from the metric + breach amount.
    let userCue: String?

    /// Free-text condition the user typed when picking
    /// `metric: .naturalLanguage`. Evaluated periodically by the AI
    /// (Apple Intelligence by default — free + on-device) against the
    /// live workout snapshot. Ignored when `metric != .naturalLanguage`.
    /// Examples: "tell me when I'm halfway through", "remind me to
    /// drink water every 20 minutes", "let me know when I get back to
    /// the parking lot."
    let naturalLanguageText: String?

    init(
        id: UUID = UUID(),
        metric: Metric,
        condition: Condition,
        value: Double,
        debounceSec: Int = 30,
        cooldownSec: Int = 120,
        userCue: String? = nil,
        naturalLanguageText: String? = nil
    ) {
        self.id = id
        self.metric = metric
        self.condition = condition
        self.value = value
        self.debounceSec = max(0, debounceSec)
        self.cooldownSec = max(10, cooldownSec)
        self.userCue = userCue
        self.naturalLanguageText = naturalLanguageText
    }

    enum CodingKeys: String, CodingKey {
        case id, metric, condition, value, debounceSec, cooldownSec, userCue, naturalLanguageText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(UUID.self, .id, or: UUID())
        metric = c.value(Metric.self, .metric, or: .heartRateBPM)
        condition = c.value(Condition.self, .condition, or: .greaterThan)
        value = c.value(Double.self, .value, or: 0)
        debounceSec = max(0, c.value(Int.self, .debounceSec, or: 30))
        cooldownSec = max(10, c.value(Int.self, .cooldownSec, or: 120))
        userCue = c.optionalValue(String.self, .userCue)
        naturalLanguageText = c.optionalValue(String.self, .naturalLanguageText)
    }

    /// Convenience builder for natural-language thresholds. Caller types
    /// "tell me when …" → we wrap as a fire-once cue with a long debounce
    /// (so the AI poll only happens every ~60 s) and the user's text
    /// becomes the spoken cue when it fires.
    static func naturalLanguage(
        text: String,
        userCue: String? = nil,
        debounceSec: Int = 60,
        cooldownSec: Int = 300
    ) -> WorkoutThreshold {
        WorkoutThreshold(
            metric: .naturalLanguage,
            condition: .greaterThan,
            value: 0,
            debounceSec: debounceSec,
            cooldownSec: cooldownSec,
            userCue: userCue ?? text,
            naturalLanguageText: text
        )
    }

    /// Try to parse a "tell me when …" string into a STRUCTURED threshold
    /// the per-tick engine can evaluate immediately. Falls back to nil
    /// when the pattern doesn't match anything we know — caller stores as
    /// `.naturalLanguage` instead, which the AI can introspect via the
    /// `workout.live.thresholds.active` fact even though no automatic
    /// firing path exists yet.
    ///
    /// Patterns recognized (English, case-insensitive):
    ///   "30 minutes" / "1 hour"         → elapsedSec
    ///   "5 miles" / "10k" / "1 km"      → distanceMeters
    ///   "1000 feet" / "300 meters" of climb → elevationGainMeters
    ///   "8 percent" / "10%" grade        → gradePercent
    ///   "HR over 135" / "heart rate above 140" → heartRateBPM
    ///
    /// Deliberately small + regex-driven — no LLM call. Keeps the
    /// happy path on-device + free + instant. Spoken cue echoes the
    /// user's original text so they hear what they asked for.
    /// Capture groups for the first match of `pattern` in `raw`, group 0 first.
    /// Empty when the pattern does not compile or does not match.
    private static func captures(_ pattern: String, in raw: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(raw.startIndex..., in: raw)
        guard let m = regex.firstMatch(in: raw, range: range) else { return [] }
        var out: [String] = []
        for i in 0 ..< m.numberOfRanges {
            if let r = Range(m.range(at: i), in: raw) {
                out.append(String(raw[r]))
            }
        }
        return out
    }

    /// True when the phrasing asks for a floor rather than a ceiling.
    private static func isBelowPhrasing(_ raw: String, extraTerms: [String] = []) -> Bool {
        (["less", "below", "under"] + extraTerms).contains { raw.contains($0) }
    }

    /// A one-shot milestone: fires once when passed, then never again.
    private static func milestone(
        metric: Metric,
        value: Double,
        cue: String
    ) -> WorkoutThreshold {
        WorkoutThreshold(
            metric: metric,
            condition: .greaterThan,
            value: value,
            debounceSec: 0,
            cooldownSec: 999_999,
            userCue: cue
        )
    }

    // MARK: Plain-text parsers
    //
    // Six independent phrasing families, each returning nil when it does not
    // recognise the text. They were one 106-line function; the order below is
    // the order they were tried in and must stay that way — the bare "10k"
    // parser has to run after the explicit-unit one or it swallows "10 km".

    /// "30 minutes", "1 hour", "1.5 hr"
    private static func parseElapsed(raw: String, cue: String) -> WorkoutThreshold? {
        let parts = captures(#"(\d+(?:\.\d+)?)\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)"#, in: raw)
        guard parts.count >= 3, let n = Double(parts[1]) else { return nil }
        let unit = parts[2]
        let secs: Double
        if unit.hasPrefix("hour") || unit.hasPrefix("hr") {
            secs = n * 3600
        } else if unit.hasPrefix("min") {
            secs = n * 60
        } else {
            secs = n
        }
        return milestone(metric: .elapsedSec, value: secs, cue: cue)
    }

    /// "5 miles", "1 km", "800 meters"
    private static func parseDistance(raw: String, cue: String) -> WorkoutThreshold? {
        let parts = captures(#"(\d+(?:\.\d+)?)\s*(miles?|mi|kilometers?|km|meters?|m)\b"#, in: raw)
        guard parts.count >= 3, let n = Double(parts[1]) else { return nil }
        let unit = parts[2]
        let meters: Double
        if unit.hasPrefix("mi") {
            meters = n * 1609.344
        } else if unit.hasPrefix("km") || unit.hasPrefix("kilo") {
            meters = n * 1_000
        } else {
            meters = n
        }
        return milestone(metric: .distanceMeters, value: meters, cue: cue)
    }

    /// "10k" run shorthand, matched separately so it cannot collide with the
    /// metres case above.
    private static func parseKShorthand(raw: String, cue: String) -> WorkoutThreshold? {
        let parts = captures(#"(\d+)\s*k\b(?!m)"#, in: raw)
        guard parts.count >= 2, let n = Double(parts[1]) else { return nil }
        return milestone(metric: .distanceMeters, value: n * 1_000, cue: cue)
    }

    /// "1000 feet of climb", "300 meters climbed"
    private static func parseElevation(raw: String, cue: String) -> WorkoutThreshold? {
        let parts = captures(#"(\d+(?:\.\d+)?)\s*(feet|ft|meters?|m)\b.*\bclim"#, in: raw)
        guard parts.count >= 3, let n = Double(parts[1]) else { return nil }
        let meters = parts[2].hasPrefix("f") ? n * 0.3048 : n
        return milestone(metric: .elevationGainMeters, value: meters, cue: cue)
    }

    /// "8 percent grade", "10%", "more than 6 percent"
    private static func parseGrade(raw: String, cue: String) -> WorkoutThreshold? {
        let parts = captures(#"(\d+(?:\.\d+)?)\s*(?:percent|%)"#, in: raw)
        guard parts.count >= 2, let n = Double(parts[1]) else { return nil }
        return WorkoutThreshold(
            metric: .gradePercent,
            condition: isBelowPhrasing(raw) ? .lessThan : .greaterThan,
            value: n,
            debounceSec: 10,
            cooldownSec: 180,
            userCue: cue
        )
    }

    /// "HR over 135", "heart rate above 140", "bpm under 90"
    private static func parseHeartRate(raw: String, cue: String) -> WorkoutThreshold? {
        let parts = captures(#"(?:hr|heart\s*rate|bpm).*?(\d+)"#, in: raw)
        guard parts.count >= 2, let n = Double(parts[1]) else { return nil }
        return WorkoutThreshold(
            metric: .heartRateBPM,
            condition: isBelowPhrasing(raw) ? .lessThan : .greaterThan,
            value: n,
            debounceSec: 30,
            cooldownSec: 120,
            userCue: cue
        )
    }

    static func parsePlainText(_ text: String) -> WorkoutThreshold? {
        let raw = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return parseElapsed(raw: raw, cue: text)
            ?? parseDistance(raw: raw, cue: text)
            ?? parseKShorthand(raw: raw, cue: text)
            ?? parseElevation(raw: raw, cue: text)
            ?? parseGrade(raw: raw, cue: text)
            ?? parseHeartRate(raw: raw, cue: text)
    }

    /// Check whether this threshold is currently breached given a snapshot
    /// of metric values. Returns `nil` for "metric not available right
    /// now" (e.g., HR-zone threshold but no HR yet) so the breach-tracking
    /// state machine can distinguish "not breached" from "no signal".
    /// One tick's worth of sensor readings.
    ///
    /// `evaluate` takes these as eleven separate parameters for its callers'
    /// convenience; bundling them here lets the metric-to-value mapping — which
    /// is where the branching lives — be a function of one argument instead of
    /// eleven.
    struct Readings {
        let hrBPM: Int?
        let hrZone: Int?
        let powerWatts: Int?
        let ftpWatts: Int?
        let paceSecPerKm: Double?
        let alpha1: Double?
        let cadenceSPM: Double?
        let distanceMeters: Double?
        let elapsedSec: Int?
        let elevationGainMeters: Double?
        let gradePercent: Double?
    }

    /// Pick the reading this threshold is about. Pure lookup with one derived
    /// case (%FTP), and one deliberate nil.
    private func observedValue(from r: Readings) -> Double? {
        switch metric {
        case .heartRateBPM: return r.hrBPM.map(Double.init)
        case .heartRateZone: return r.hrZone.map(Double.init)
        case .powerWatts: return r.powerWatts.map(Double.init)
        case .powerPercentFTP:
            guard let watts = r.powerWatts, let ftp = r.ftpWatts, ftp > 0 else { return nil }
            return Double(watts) / Double(ftp) * 100.0
        case .paceSecPerKm: return r.paceSecPerKm
        case .alpha1: return r.alpha1
        case .cadenceSPM: return r.cadenceSPM
        case .distanceMeters: return r.distanceMeters
        case .elapsedSec: return r.elapsedSec.map(Double.init)
        case .elevationGainMeters: return r.elevationGainMeters
        case .gradePercent: return r.gradePercent
        case .naturalLanguage:
            // Evaluated by a separate AI-driven path on a slower schedule
            // (~60s), not the per-tick engine. Always nil here so the
            // structured evaluator ignores it.
            return nil
        }
    }

    func evaluate(
        hrBPM: Int?,
        hrZone: Int?,
        powerWatts: Int?,
        ftpWatts: Int?,
        paceSecPerKm: Double?,
        alpha1: Double?,
        cadenceSPM: Double?,
        distanceMeters: Double? = nil,
        elapsedSec: Int? = nil,
        elevationGainMeters: Double? = nil,
        gradePercent: Double? = nil
    ) -> Bool? {
        let readings = Readings(
            hrBPM: hrBPM,
            hrZone: hrZone,
            powerWatts: powerWatts,
            ftpWatts: ftpWatts,
            paceSecPerKm: paceSecPerKm,
            alpha1: alpha1,
            cadenceSPM: cadenceSPM,
            distanceMeters: distanceMeters,
            elapsedSec: elapsedSec,
            elevationGainMeters: elevationGainMeters,
            gradePercent: gradePercent
        )
        guard let observed = observedValue(from: readings) else { return nil }
        switch condition {
        case .greaterThan: return observed > value
        case .lessThan: return observed < value
        }
    }

    /// Default coach phrasing when `userCue` is nil. Specific by metric so
    /// the cue says something useful: "HR drifted to 142, ease up" reads
    /// better than a generic "threshold breached".
    ///
    /// For `.naturalLanguage` the caller (AI evaluator) supplies the speakable
    /// cue from the user's text; the fallback here is only ever used if cue
    /// text is missing, in which case echo the user's intent verbatim.
    func defaultCue(currentValue: Double) -> String {
        heartRateCue(currentValue: currentValue)
            ?? intensityCue()
            ?? progressCue()
            ?? naturalLanguageText ?? userCue ?? "Cue fired"
    }

    private func heartRateCue(currentValue: Double) -> String? {
        switch metric {
        case .heartRateBPM:
            let dir = condition == .greaterThan ? "drifted to" : "dropped to"
            return "HR \(dir) \(Int(currentValue.rounded())), \(condition == .greaterThan ? "ease up" : "pick it up")"
        case .heartRateZone:
            return condition == .greaterThan ? "Above target zone, ease back" : "Below target zone, lift the pace"
        default:
            return nil
        }
    }

    /// Cues about how hard the effort is right now.
    private func intensityCue() -> String? {
        switch metric {
        case .powerWatts:
            return condition == .greaterThan ? "Power over \(Int(value)) watts, ease up" : "Power below \(Int(value)) watts, push"
        case .powerPercentFTP:
            return condition == .greaterThan ? "Above \(Int(value))% FTP, back off" : "Below \(Int(value))% FTP, lift the effort"
        case .paceSecPerKm:
            return condition == .greaterThan ? "Pace slipped, pick it up" : "Pace too hot, ease off"
        case .alpha1:
            return condition == .lessThan ? "DFA α1 dropped — you're tipping anaerobic" : "DFA α1 climbing — aerobic floor"
        case .cadenceSPM:
            return condition == .lessThan ? "Cadence dropped — quicker steps" : "Cadence high, settle the rhythm"
        default:
            return nil
        }
    }

    /// Cues about how far through the workout the athlete is.
    private func progressCue() -> String? {
        switch metric {
        case .distanceMeters:
            return condition == .greaterThan ? "Hit \(Int(value)) meters" : "Under \(Int(value)) meters"
        case .elapsedSec:
            let mins = Int(value / 60)
            return condition == .greaterThan ? "\(mins) minutes in" : "Less than \(mins) minutes"
        case .elevationGainMeters:
            return condition == .greaterThan ? "Climbed \(Int(value)) meters" : "Under \(Int(value)) meters of climb"
        case .gradePercent:
            return condition == .greaterThan ? "Steeper than \(Int(value)) percent" : "Grade easing"
        default:
            return nil
        }
    }
}

private extension Array {
    /// `[]` is never a useful "match found" signal in regex parsing.
    /// This makes optional-binding chains read cleanly.
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
