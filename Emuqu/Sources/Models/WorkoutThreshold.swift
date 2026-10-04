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
        // A metric this build does not know (from a newer version) becomes a
        // natural-language cue — kept and listed, never fired — rather than
        // a heart-rate cue that would read its value as bpm.
        let knownMetric = c.optionalValue(Metric.self, .metric)
        metric = knownMetric ?? .naturalLanguage
        condition = c.value(Condition.self, .condition, or: .greaterThan)
        value = c.value(Double.self, .value, or: 0)
        debounceSec = max(0, c.value(Int.self, .debounceSec, or: 30))
        cooldownSec = max(10, c.value(Int.self, .cooldownSec, or: 120))
        userCue = c.optionalValue(String.self, .userCue)
        let text = c.optionalValue(String.self, .naturalLanguageText)
        naturalLanguageText = knownMetric == nil ? (text ?? userCue) : text
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

    /// Capture groups for the first match of `pattern` in `raw`, group 0 first.
    /// Empty when the pattern does not compile or does not match.
    private static func captures(_ pattern: String, in raw: String) -> [String] {
        allCaptures(pattern, in: raw).first ?? []
    }

    /// Capture groups for every match of `pattern` in `raw`. Empty when the
    /// pattern does not compile (logged) or does not match.
    private static func allCaptures(_ pattern: String, in raw: String) -> [[String]] {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            debugLog("[WorkoutThreshold] cue pattern did not compile: \(error)", level: .error)
            return []
        }
        return regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).map { groups(of: $0, in: raw) }
    }

    private static func groups(of match: NSTextCheckingResult, in raw: String) -> [String] {
        (0 ..< match.numberOfRanges).compactMap { Range(match.range(at: $0), in: raw).map { String(raw[$0]) } }
    }

    /// The text being parsed, and the app language whose words it may use
    /// alongside English.
    private struct CueText {
        let raw: String
        let cue: String
        let language: String?

        func words(_ concept: CueLexicon.Concept, leading: Bool = false) -> String {
            CueLexicon.pattern(concept, languageCode: language, leading: leading)
        }

        func mentions(_ concept: CueLexicon.Concept) -> Bool {
            !WorkoutThreshold.captures(words(concept, leading: true), in: raw).isEmpty
        }

        /// The condition the phrasing asks to be warned about. "Under 120"
        /// warns below 120; "keep it under 150" sets a ceiling and warns
        /// above it, and "stay above 120" a floor that warns below.
        var condition: Condition {
            let below = mentions(.below)
            return mentions(.keep) != below ? .lessThan : .greaterThan
        }
    }

    /// A number written with either decimal separator.
    private static let number = #"(\d+(?:[.,]\d+)?)"#

    private static func value(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    // MARK: Plain-text parsers
    //
    // Independent phrasing families, each returning nil when it does not
    // recognise the text. `parsePlainText` sets the order they are tried in;
    // the bare "10k" parser has to run after the explicit-unit one or it
    // swallows "10 km".

    /// "30 minutes", "1 hour", "1 hr 30 min". "every 20 minutes" fires at 20
    /// and again each 20 minutes after: the breach stays true, so the
    /// cooldown sets the repeat.
    private static func parseElapsed(_ text: CueText) -> WorkoutThreshold? {
        let units = [(text.words(.hours), 3600.0), (text.words(.minutes), 60.0), (text.words(.seconds), 1.0)]
        let pattern = number + #"\s*("# + units.map(\.0).joined(separator: "|") + ")"
        let secs = allCaptures(pattern, in: text.raw).reduce(0.0) { total, parts in
            guard parts.count >= 3, let n = value(parts[1]) else { return total }
            let scale = units.first { !captures("^" + $0.0 + "$", in: parts[2]).isEmpty }?.1 ?? 1
            return total + n * scale
        }
        guard secs > 0 else { return nil }
        guard text.mentions(.every) else { return milestone(metric: .elapsedSec, value: secs, cue: text.cue) }
        return WorkoutThreshold(
            metric: .elapsedSec, condition: .greaterThan, value: secs,
            debounceSec: 0, cooldownSec: Int(min(secs, 86_400)), userCue: text.cue
        )
    }

    /// "5 miles", "1 km", "800 meters"
    private static func parseDistance(_ text: CueText) -> WorkoutThreshold? {
        let units = [(text.words(.miles), 1609.344), (text.words(.kilometers), 1_000.0), (text.words(.meters), 1.0)]
        let parts = captures(number + #"\s*("# + units.map(\.0).joined(separator: "|") + ")", in: text.raw)
        guard parts.count >= 3, let n = value(parts[1]) else { return nil }
        let scale = units.first { !captures("^" + $0.0 + "$", in: parts[2]).isEmpty }?.1 ?? 1
        return milestone(metric: .distanceMeters, value: n * scale, cue: text.cue)
    }

    /// "10k" run shorthand, matched separately so it cannot collide with the
    /// metres case above.
    private static func parseKShorthand(_ text: CueText) -> WorkoutThreshold? {
        let parts = captures(#"(\d+)\s*k\b(?!m)"#, in: text.raw)
        guard parts.count >= 2, let n = Double(parts[1]) else { return nil }
        return milestone(metric: .distanceMeters, value: n * 1_000, cue: text.cue)
    }

    /// "1000 feet of climb", "300 meters climbed", "climb 300 meters"
    private static func parseElevation(_ text: CueText) -> WorkoutThreshold? {
        guard text.mentions(.climb) else { return nil }
        let feet = text.words(.feet)
        let parts = captures(number + #"\s*("# + feet + "|" + text.words(.meters) + ")", in: text.raw)
        guard parts.count >= 3, let n = value(parts[1]) else { return nil }
        let isFeet = !captures("^" + feet + "$", in: parts[2]).isEmpty
        return milestone(metric: .elevationGainMeters, value: isFeet ? n * 0.3048 : n, cue: text.cue)
    }

    /// "over 90% of FTP", "FTP above 85 percent" — power, not grade.
    private static func parsePowerFTP(_ text: CueText) -> WorkoutThreshold? {
        guard text.raw.contains("ftp") else { return nil }
        let parts = captures(number + #"\s*"# + text.words(.percent), in: text.raw)
        guard parts.count >= 2, let n = value(parts[1]) else { return nil }
        return WorkoutThreshold(
            metric: .powerPercentFTP, condition: text.condition, value: n,
            debounceSec: 30, cooldownSec: 120, userCue: text.cue
        )
    }

    /// "8 percent grade", "10%", "more than 6 percent"
    private static func parseGrade(_ text: CueText) -> WorkoutThreshold? {
        let parts = captures(number + #"\s*"# + text.words(.percent), in: text.raw)
        guard parts.count >= 2, let n = value(parts[1]) else { return nil }
        return WorkoutThreshold(
            metric: .gradePercent, condition: text.condition, value: n,
            debounceSec: 10, cooldownSec: 180, userCue: text.cue
        )
    }

    /// "HR over 135", "heart rate above 140", "under 90 bpm". The number is
    /// a heart rate only when no time unit or percent follows it, and an
    /// "hr" straight after a number is hours ("1 hr 30 min"), not heart rate.
    private static func parseHeartRate(_ text: CueText) -> WorkoutThreshold? {
        let notQuantity = #"(?![\d.,])(?!\s*(?:"# + [text.words(.hours), text.words(.minutes), text.words(.seconds), text.words(.percent)].joined(separator: "|") + "))"
        let keyword = #"(?<!\d)(?<!\d\s)(?:"# + text.words(.heartRate, leading: true) + "|" + text.words(.beatsPerMinute, leading: true) + ")"
        let afterKeyword = captures(keyword + #"\D{0,40}?(\d{2,3})"# + notQuantity, in: text.raw)
        let parts = afterKeyword.count >= 2 ? afterKeyword : captures(#"(\d{2,3})\s*"# + text.words(.beatsPerMinute), in: text.raw)
        guard parts.count >= 2, let n = Double(parts[1]) else { return nil }
        return WorkoutThreshold(
            metric: .heartRateBPM, condition: text.condition, value: n,
            debounceSec: 30, cooldownSec: 120, userCue: text.cue
        )
    }

    /// Try to parse a "tell me when …" string into a STRUCTURED threshold
    /// the per-tick engine can evaluate immediately. Nil when the pattern
    /// doesn't match anything we know; the caller then rejects the text.
    ///
    /// Patterns recognized (case-insensitive, in English and in the app's
    /// language — see `CueLexicon`), tried in this order so a
    /// keyword-anchored phrase wins over a bare number with a unit:
    ///   "HR over 135" / "under 90 bpm"   → heartRateBPM
    ///   "over 90% of FTP"               → powerPercentFTP
    ///   "1000 feet of climb" / "climb 300 meters" → elevationGainMeters
    ///   "8 percent" / "10%" grade        → gradePercent
    ///   "30 minutes" / "1 hr 30 min"    → elapsedSec ("every 20 minutes" repeats)
    ///   "5 miles" / "1 km"              → distanceMeters
    ///   "10k"                           → distanceMeters
    /// "keep / stay under" sets a ceiling (warns above), "stay above" a floor.
    ///
    /// Deliberately small + regex-driven — no LLM call. Keeps the
    /// happy path on-device + free + instant. Spoken cue echoes the
    /// user's original text so they hear what they asked for.
    static func parsePlainText(
        _ text: String,
        languageCode: String? = LanguageManager.appLocale.language.languageCode?.identifier
    ) -> WorkoutThreshold? {
        let raw = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let cueText = CueText(raw: raw, cue: text, language: languageCode)
        let parsers: [(CueText) -> WorkoutThreshold?] = [
            parseHeartRate, parsePowerFTP, parseElevation, parseGrade, parseElapsed, parseDistance, parseKShorthand
        ]
        return parsers.lazy.compactMap { $0(cueText) }.first
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
    /// `.naturalLanguage` cues never fire, so they never reach this; for
    /// them it echoes the user's text, as the cue list shows it.
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

// MARK: - Cue lexicon

/// The words the plain-text cue parser understands: English always, plus the
/// app language's own, so a cue typed the way the localized example reads is
/// understood. One language at a time because the same word means different
/// things across them (Italian "alle" is "at the", Finnish "alle" is "below";
/// Scandinavian "mil" is ten kilometres).
enum CueLexicon {
    enum Concept: CaseIterable {
        case hours, minutes, seconds, kilometers, meters, miles, feet
        case heartRate, beatsPerMinute, percent, below, every, climb, keep
    }

    /// English plus the language of `languageCode`, lower-cased.
    static func words(_ concept: Concept, languageCode: String?) -> [String] {
        let own = languageCode.flatMap { byLanguage[$0]?[concept] } ?? []
        return (english[concept] ?? []) + own
    }

    /// A regex group matching any of the concept's words, longest first so
    /// "minutes" wins over "min". A word in a script that separates words
    /// with spaces must not run on into another letter; a CJK word stands
    /// inside a run of letters, so it gets no such boundary. `leading` also
    /// requires the word not to continue a word or number before it.
    static func pattern(_ concept: Concept, languageCode: String?, leading: Bool = false) -> String {
        let alternatives = words(concept, languageCode: languageCode)
            .sorted { $0.count > $1.count }
            .map { word in
                let escaped = NSRegularExpression.escapedPattern(for: word)
                guard !isCJK(word) else { return escaped }
                return (leading ? #"(?<![\p{L}\p{N}])"# : "") + escaped + #"(?![\p{L}])"#
            }
        return "(?:" + alternatives.joined(separator: "|") + ")"
    }

    private static func isCJK(_ word: String) -> Bool {
        word.unicodeScalars.first.map { $0.properties.isIdeographic || (0xAC00 ... 0xD7AF).contains($0.value) || (0x3040 ... 0x30FF).contains($0.value) } ?? false
    }

    static let english: [Concept: [String]] = [
        .hours: ["hours", "hour", "hrs", "hr", "h"],
        .minutes: ["minutes", "minute", "mins", "min"],
        .seconds: ["seconds", "second", "secs", "sec"],
        .kilometers: ["kilometers", "kilometer", "kilometres", "kilometre", "km"],
        .meters: ["meters", "meter", "metres", "metre", "m"],
        .miles: ["miles", "mile", "mi"],
        .feet: ["feet", "foot", "ft"],
        .heartRate: ["heart rate", "heartrate", "hr", "pulse"],
        .beatsPerMinute: ["bpm"],
        .percent: ["percent", "%"],
        .below: ["less", "below", "under", "lower"],
        .every: ["every", "each"],
        .climb: ["climb", "ascent", "elevation"],
        .keep: ["keep", "stay", "hold", "remain", "maintain"]
    ]

    static let byLanguage: [String: [Concept: [String]]] = [
        "de": [
            .hours: ["stunden", "stunde", "std"], .minutes: ["minuten", "minute"], .seconds: ["sekunden", "sekunde", "sek"],
            .kilometers: ["kilometern", "kilometer"], .meters: ["metern", "meter"], .miles: ["meilen", "meile"], .feet: ["fuß"],
            .heartRate: ["herzfrequenz", "puls"], .beatsPerMinute: ["schläge"], .percent: ["prozent"],
            .below: ["unter", "unterhalb", "weniger"], .every: ["alle", "jede", "jeden"],
            .climb: ["höhenmeter", "anstieg", "aufstieg", "steigung"], .keep: ["halte", "halt", "bleib", "bleibe", "behalte"]
        ],
        "fr": [
            .hours: ["heures", "heure"], .minutes: ["minutes", "minute"], .seconds: ["secondes", "seconde"],
            .kilometers: ["kilomètres", "kilomètre"], .meters: ["mètres", "mètre"], .miles: ["milles"], .feet: ["pieds", "pied"],
            .heartRate: ["fréquence cardiaque", "pouls"], .percent: ["pour cent", "pourcent"],
            .below: ["sous", "moins", "en dessous", "inférieure", "inférieur"], .every: ["chaque", "toutes les", "tous les"],
            .climb: ["dénivelé", "montée", "grimpé"], .keep: ["garde", "reste", "maintiens"]
        ],
        "es": [
            .hours: ["horas", "hora"], .minutes: ["minutos", "minuto"], .seconds: ["segundos", "segundo"],
            .kilometers: ["kilómetros", "kilómetro"], .meters: ["metros", "metro"], .miles: ["millas", "milla"], .feet: ["pies"],
            .heartRate: ["frecuencia cardíaca", "frecuencia cardiaca", "pulso", "fc"], .beatsPerMinute: ["lpm", "ppm"],
            .percent: ["por ciento"], .below: ["menos", "debajo", "bajo", "inferior"], .every: ["cada"],
            .climb: ["desnivel", "subida", "ascenso"], .keep: ["mantén", "mantener", "quédate", "mantente"]
        ],
        "it": [
            .hours: ["ore", "ora"], .minutes: ["minuti", "minuto"], .seconds: ["secondi", "secondo"],
            .kilometers: ["chilometri", "chilometro"], .meters: ["metri", "metro"], .miles: ["miglia", "miglio"], .feet: ["piedi"],
            .heartRate: ["frequenza cardiaca", "battito", "pulsazioni"], .percent: ["per cento", "percento"],
            .below: ["sotto", "meno", "inferiore"], .every: ["ogni"],
            .climb: ["dislivello", "salita"], .keep: ["mantieni", "resta", "tieni"]
        ],
        "pt": [
            .hours: ["horas", "hora"], .minutes: ["minutos", "minuto"], .seconds: ["segundos", "segundo"],
            .kilometers: ["quilômetros", "quilômetro", "quilómetros"], .meters: ["metros", "metro"], .miles: ["milhas", "milha"], .feet: ["pés"],
            .heartRate: ["frequência cardíaca", "batimentos", "pulso", "fc"], .percent: ["por cento"],
            .below: ["abaixo", "menos", "inferior"], .every: ["cada", "a cada"],
            .climb: ["subida", "desnível", "escalada"], .keep: ["mantenha", "mantém", "fique", "manter"]
        ],
        "nl": [
            .hours: ["uren", "uur"], .minutes: ["minuten", "minuut"], .seconds: ["seconden", "seconde"],
            .kilometers: ["kilometer"], .meters: ["meter"], .miles: ["mijlen", "mijl"], .feet: ["voet"],
            .heartRate: ["hartslag", "hartfrequentie"], .beatsPerMinute: ["spm"], .percent: ["procent"],
            .below: ["onder", "lager", "minder"], .every: ["elke", "iedere"],
            .climb: ["hoogtemeters", "klim", "stijging"], .keep: ["houd", "hou", "blijf"]
        ],
        "sv": [
            .hours: ["timmar", "timme", "tim"], .minutes: ["minuter", "minut"], .seconds: ["sekunder", "sekund"],
            .kilometers: ["kilometer"], .meters: ["meter"], .feet: ["fot"],
            .heartRate: ["hjärtfrekvens", "puls"], .beatsPerMinute: ["slag"], .percent: ["procent"],
            .below: ["under", "lägre", "mindre"], .every: ["varje", "var"],
            .climb: ["höjdmeter", "stigning", "klättring"], .keep: ["håll", "stanna", "behåll"]
        ],
        "da": [
            .hours: ["timer", "time"], .minutes: ["minutter", "minut"], .seconds: ["sekunder", "sekund"],
            .kilometers: ["kilometer"], .meters: ["meter"], .feet: ["fod"],
            .heartRate: ["puls"], .beatsPerMinute: ["slag"], .percent: ["procent"],
            .below: ["under", "lavere", "mindre"], .every: ["hvert", "hver"],
            .climb: ["højdemeter", "stigning"], .keep: ["hold", "bliv", "behold"]
        ],
        "nb": [
            .hours: ["timer", "time"], .minutes: ["minutter", "minutt"], .seconds: ["sekunder", "sekund"],
            .kilometers: ["kilometer"], .meters: ["meter"], .feet: ["fot"],
            .heartRate: ["puls"], .beatsPerMinute: ["slag"], .percent: ["prosent"],
            .below: ["under", "lavere", "mindre"], .every: ["hvert", "hver"],
            .climb: ["høydemeter", "stigning"], .keep: ["hold", "bli", "behold"]
        ],
        "fi": [
            .hours: ["tuntia", "tunnin", "tunti"], .minutes: ["minuuttia", "minuutin", "minuutti"], .seconds: ["sekuntia", "sekunnin", "sekunti"],
            .kilometers: ["kilometriä", "kilometrin", "kilometri"], .meters: ["metriä", "metrin", "metri"], .feet: ["jalkaa"],
            .heartRate: ["syke", "sykkeen", "sykettä"], .percent: ["prosenttia", "prosentin", "prosentti"],
            .below: ["alle", "alempi", "vähemmän"], .every: ["joka", "välein"],
            .climb: ["nousua", "nousu", "nousumetrit"], .keep: ["pidä", "pysy", "pysyttele"]
        ],
        "is": [
            .hours: ["klukkustundir", "klukkustund", "klst"], .minutes: ["mínútur", "mínútu", "mínúta"], .seconds: ["sekúndur", "sekúnda", "sekúndu"],
            .kilometers: ["kílómetrar", "kílómetra", "kílómetri"], .meters: ["metrar", "metra", "metri"], .feet: ["fet"],
            .heartRate: ["hjartsláttur", "púls"], .beatsPerMinute: ["slög"], .percent: ["prósent"],
            .below: ["undir", "minna", "lægri"], .every: ["hverjar", "hverja", "hverjum", "fresti"],
            .climb: ["hækkun", "klifur"], .keep: ["haltu", "vertu"]
        ],
        "ru": [
            .hours: ["часов", "часа", "час", "ч"], .minutes: ["минут", "минуты", "минуту", "мин"], .seconds: ["секунд", "секунды", "секунду", "сек"],
            .kilometers: ["километров", "километра", "километр", "км"], .meters: ["метров", "метра", "метр", "м"],
            .miles: ["миль", "мили", "миля"], .feet: ["футов", "фута", "фут"],
            .heartRate: ["пульс", "чсс"], .beatsPerMinute: ["уд/мин", "уд./мин"], .percent: ["процентов", "процента", "процент"],
            .below: ["ниже", "меньше", "под"], .every: ["каждые", "каждую", "каждый", "каждых"],
            .climb: ["набор высоты", "подъём", "подъем", "набор"], .keep: ["держи", "держите", "оставайся", "сохраняй"]
        ],
        "ar": [
            .hours: ["ساعات", "ساعة"], .minutes: ["دقائق", "دقيقة"], .seconds: ["ثوان", "ثوانٍ", "ثانية"],
            .kilometers: ["كيلومترات", "كيلومتر", "كم"], .meters: ["أمتار", "متر", "م"], .miles: ["أميال", "ميل"], .feet: ["أقدام", "قدم"],
            .heartRate: ["معدل ضربات القلب", "ضربات القلب", "النبض", "نبض"], .beatsPerMinute: ["نبضة"], .percent: ["بالمئة", "في المئة"],
            .below: ["أقل", "تحت", "دون"], .every: ["كل"],
            .climb: ["صعود", "تسلق", "ارتفاع"], .keep: ["حافظ", "ابق", "أبق"]
        ],
        "ja": [
            .hours: ["時間"], .minutes: ["分"], .seconds: ["秒"],
            .kilometers: ["キロメートル", "キロ"], .meters: ["メートル"], .miles: ["マイル"], .feet: ["フィート"],
            .heartRate: ["心拍数", "心拍"], .percent: ["パーセント"],
            .below: ["以下", "未満", "下回"], .every: ["ごと", "毎"],
            .climb: ["獲得標高", "登り", "上昇"], .keep: ["キープ", "保"]
        ],
        "ko": [
            .hours: ["시간"], .minutes: ["분"], .seconds: ["초"],
            .kilometers: ["킬로미터", "킬로"], .meters: ["미터"], .miles: ["마일"], .feet: ["피트"],
            .heartRate: ["심박수", "심박"], .percent: ["퍼센트"],
            .below: ["이하", "미만", "아래"], .every: ["마다"],
            .climb: ["오르막", "상승", "등반"], .keep: ["유지"]
        ],
        "zh": [
            .hours: ["小时", "小時"], .minutes: ["分钟", "分鐘", "分"], .seconds: ["秒"],
            .kilometers: ["公里", "千米"], .meters: ["米"], .miles: ["英里"], .feet: ["英尺"],
            .heartRate: ["心率"], .percent: ["百分"],
            .below: ["低于", "以下", "少于"], .every: ["每"],
            .climb: ["爬升", "爬坡", "上升"], .keep: ["保持"]
        ]
    ]
}
