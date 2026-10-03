import Foundation

/// User-declared physiological constraint for ambient coaching.
///
/// The user pre-sets one or more thresholds before starting a workout
/// ("don't let HR exceed 135 bpm for >30s", "stay above zone 2 power", "keep
/// pace slower than 9:00/mi"), then puts the phone away with their podcast
/// or audiobook. The voice coach stays silent — the audio session mixes with
/// other audio, so the audiobook keeps playing — until a threshold is
/// breached past its `debounceSec`. At that point the coach speaks the cue
/// over the audiobook (it is not ducked) and goes quiet again.
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
    /// metric, and nothing evaluates it during a workout: such a cue is
    /// stored and listed, but never fires.
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
    /// `metric: .naturalLanguage`. The assistant can read it through the
    /// `workout.live.thresholds.active` fact, but no automatic evaluator
    /// fires it. Ignored when `metric != .naturalLanguage`. Examples: "tell
    /// me when I'm halfway through", "let me know when I get back to the
    /// parking lot."
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

    /// Convenience builder for natural-language thresholds: the user's text
    /// is kept as both the condition and the cue. Nothing evaluates these
    /// during a workout, so they never fire; `parsePlainText` is the path
    /// that turns text into a cue that does.
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
    // recognise the text. `parsePlainText` sets the order they are tried in;
    // the bare "10k" parser has to run after the explicit-unit one or it
    // swallows "10 km".

    /// "30 minutes", "1 hour", "1.5 hr". "every 20 minutes" fires at 20 and
    /// again each 20 minutes after: the breach stays true, so the cooldown
    /// sets the repeat.
    private static func parseElapsed(raw: String, cue: String) -> WorkoutThreshold? {
        let parts = captures(#"(\d+(?:\.\d+)?)\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)\b"#, in: raw)
        guard parts.count >= 3, let n = Double(parts[1]), n > 0 else { return nil }
        let unit = parts[2]
        let secs: Double
        if unit.hasPrefix("hour") || unit.hasPrefix("hr") {
            secs = n * 3600
        } else if unit.hasPrefix("min") {
            secs = n * 60
        } else {
            secs = n
        }
        guard raw.contains("every") else { return milestone(metric: .elapsedSec, value: secs, cue: cue) }
        return WorkoutThreshold(
            metric: .elapsedSec, condition: .greaterThan, value: secs,
            debounceSec: 0, cooldownSec: Int(min(secs, 86_400)), userCue: cue
        )
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

    /// "1000 feet of climb", "300 meters climbed", "climb 300 meters"
    private static func parseElevation(raw: String, cue: String) -> WorkoutThreshold? {
        let after = captures(#"(\d+(?:\.\d+)?)\s*(feet|ft|meters?|m)\b.*\bclim"#, in: raw)
        let parts = after.count >= 3 ? after : captures(#"\bclim\w*\b.*?(\d+(?:\.\d+)?)\s*(feet|ft|meters?|m)\b"#, in: raw)
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
        let parts = captures(#"\b(?:hr|heart\s*rate|bpm)\b.*?(\d+)"#, in: raw)
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

    /// Try to parse a "tell me when …" string into a STRUCTURED threshold
    /// the per-tick engine can evaluate immediately. Nil when the pattern
    /// doesn't match anything we know; the caller then stores it as
    /// `.naturalLanguage`, which nothing fires.
    ///
    /// Patterns recognized (English, case-insensitive), tried in this order
    /// so a keyword-anchored phrase wins over a bare number with a unit:
    ///   "HR over 135" / "heart rate above 140" → heartRateBPM
    ///   "1000 feet of climb" / "climb 300 meters" → elevationGainMeters
    ///   "8 percent" / "10%" grade        → gradePercent
    ///   "30 minutes" / "1 hour"         → elapsedSec ("every 20 minutes" repeats)
    ///   "5 miles" / "1 km"              → distanceMeters
    ///   "10k"                           → distanceMeters
    ///
    /// Deliberately small + regex-driven — no LLM call. Keeps the
    /// happy path on-device + free + instant. Spoken cue echoes the
    /// user's original text so they hear what they asked for.
    static func parsePlainText(_ text: String) -> WorkoutThreshold? {
        let raw = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return parseHeartRate(raw: raw, cue: text)
            ?? parseElevation(raw: raw, cue: text)
            ?? parseGrade(raw: raw, cue: text)
            ?? parseElapsed(raw: raw, cue: text)
            ?? parseDistance(raw: raw, cue: text)
            ?? parseKShorthand(raw: raw, cue: text)
    }

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
            // Free text has no reading to compare; nothing evaluates it.
            return nil
        }
    }

    /// Check whether this threshold is currently breached given a snapshot
    /// of metric values. Returns `nil` for "metric not available right
    /// now" (e.g., HR-zone threshold but no HR yet) so the breach-tracking
    /// state machine can distinguish "not breached" from "no signal".
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
            ?? naturalLanguageText ?? userCue ?? String(localized: "Cue fired", bundle: LanguageManager.appBundle)
    }

    private func heartRateCue(currentValue: Double) -> String? {
        switch metric {
        case .heartRateBPM:
            let bpm = Int(currentValue.rounded())
            return condition == .greaterThan ? String(localized: "HR drifted to \(bpm), ease up", bundle: LanguageManager.appBundle) : String(localized: "HR dropped to \(bpm), pick it up", bundle: LanguageManager.appBundle)
        case .heartRateZone:
            return condition == .greaterThan ? String(localized: "Above target zone, ease back", bundle: LanguageManager.appBundle) : String(localized: "Below target zone, lift the pace", bundle: LanguageManager.appBundle)
        default:
            return nil
        }
    }

    /// Cues about how hard the effort is right now.
    private func intensityCue() -> String? {
        switch metric {
        case .powerWatts:
            return condition == .greaterThan ? String(localized: "Power over \(Int(value)) watts, ease up", bundle: LanguageManager.appBundle) : String(localized: "Power below \(Int(value)) watts, push", bundle: LanguageManager.appBundle)
        case .powerPercentFTP:
            return condition == .greaterThan ? String(localized: "Above \(Int(value))% FTP, back off", bundle: LanguageManager.appBundle) : String(localized: "Below \(Int(value))% FTP, lift the effort", bundle: LanguageManager.appBundle)
        case .paceSecPerKm:
            return condition == .greaterThan ? String(localized: "Pace slipped, pick it up", bundle: LanguageManager.appBundle) : String(localized: "Pace too hot, ease off", bundle: LanguageManager.appBundle)
        case .alpha1:
            return condition == .lessThan ? String(localized: "DFA α1 dropped — you're tipping anaerobic", bundle: LanguageManager.appBundle) : String(localized: "DFA α1 climbing — aerobic floor", bundle: LanguageManager.appBundle)
        case .cadenceSPM:
            return condition == .lessThan ? String(localized: "Cadence dropped — quicker steps", bundle: LanguageManager.appBundle) : String(localized: "Cadence high, settle the rhythm", bundle: LanguageManager.appBundle)
        default:
            return nil
        }
    }

    /// Cues about how far through the workout the athlete is.
    private func progressCue() -> String? {
        switch metric {
        case .distanceMeters:
            return condition == .greaterThan ? String(localized: "Hit \(Int(value)) meters", bundle: LanguageManager.appBundle) : String(localized: "Under \(Int(value)) meters", bundle: LanguageManager.appBundle)
        case .elapsedSec:
            let mins = Int(value / 60)
            return condition == .greaterThan ? String(localized: "\(mins) minutes in", bundle: LanguageManager.appBundle) : String(localized: "Less than \(mins) minutes", bundle: LanguageManager.appBundle)
        case .elevationGainMeters:
            return condition == .greaterThan ? String(localized: "Climbed \(Int(value)) meters", bundle: LanguageManager.appBundle) : String(localized: "Under \(Int(value)) meters of climb", bundle: LanguageManager.appBundle)
        case .gradePercent:
            return condition == .greaterThan ? String(localized: "Steeper than \(Int(value)) percent", bundle: LanguageManager.appBundle) : String(localized: "Grade easing", bundle: LanguageManager.appBundle)
        default:
            return nil
        }
    }
}
