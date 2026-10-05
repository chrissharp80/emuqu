import Foundation

/// The numbers behind one score factor's detail line, stored with the factor
/// so the line is written when it is shown: in the app language and the
/// temperature unit of that moment, not those of the night it was scored.
///
/// `ScoreFactor.detail` still holds the line as written at scoring time. An
/// older build reads that, and a factor scored before these numbers were
/// stored is shown with it.
///
/// Every kind is stored as a string (`note`, `StoredAdjustment.kind`), not as
/// a Codable enum. A kind added by a later build therefore decodes here as an
/// unknown string and the line falls back to the stored text, rather than
/// the whole breakdown failing to decode.
struct ScoreFactorFacts: Codable, Equatable, Sendable {
    var hrv: HRV?
    var sleep: Sleep?
    var vitals: Vitals?
    /// A line that quotes no numbers, as a `Note` raw value.
    var note: String?

    init(hrv: HRV) { self.hrv = hrv }
    init(sleep: Sleep) { self.sleep = sleep }
    init(vitals: Vitals) { self.vitals = vitals }
    init(note: Note) { self.note = note.rawValue }

    /// The line in `NarrativeLanguage`, with any temperature in
    /// `temperatureUnit`. Nil when the facts name a kind this build doesn't
    /// know.
    func line(temperatureUnit: TemperatureUnit) -> String? {
        if let hrv { return hrv.line }
        if let sleep { return sleep.line }
        if let vitals { return VitalsScoring.vitalsLine(vitals, temperatureUnit: temperatureUnit) }
        return note.flatMap(Note.init(rawValue:))?.text
    }

    // MARK: - Lines without numbers

    enum Note: String, Sendable {
        case hrvNoBaseline
        case hrvNoBaselineUsingReadiness
        case hrvWithAssessment
        case noSleepData
        case noVitals

        var text: String {
            switch self {
            case .hrvNoBaseline:
                String(localized: "No baseline yet", bundle: NarrativeLanguage.bundle)
            case .hrvNoBaselineUsingReadiness:
                String(localized: "No baseline yet (using readiness score)", bundle: NarrativeLanguage.bundle)
            case .hrvWithAssessment:
                String(localized: "Baseline HRV + your assessment (recording was unusable)", bundle: NarrativeLanguage.bundle)
            case .noSleepData:
                String(localized: "No sleep data", bundle: NarrativeLanguage.bundle)
            case .noVitals:
                String(localized: "No overnight vitals captured", bundle: NarrativeLanguage.bundle)
            }
        }
    }

    // MARK: - HRV

    /// The night's RMSSD against the baseline, and the adjustments
    /// `calculateTier1` made on top of the base score.
    struct HRV: Codable, Equatable, Sendable {
        let rmssd: Double
        let z: Double
        let baseScore: Int
        let adjustments: [StoredAdjustment]

        init(rmssd: Double, z: Double, baseScore: Int, adjustments: [Adjustment]) {
            self.rmssd = rmssd
            self.z = z
            self.baseScore = baseScore
            self.adjustments = adjustments.map(\.stored)
        }

        /// Nil when an adjustment is of a kind this build doesn't know:
        /// leaving it out would make the shown parts stop adding up.
        var line: String? {
            let known = adjustments.compactMap(Adjustment.init(stored:))
            guard known.count == adjustments.count else { return nil }
            return Self.sentence(rmssd: rmssd, z: z, baseScore: baseScore, adjustments: known)
        }

        /// "42ms — near your average (base score 61). Resting HR lower than
        /// usual (+3)".
        static func sentence(rmssd: Double, z: Double, baseScore: Int, adjustments: [Adjustment]) -> String {
            ScoreDetailBuilder.hrvDetailSentence(
                base: ScoreDetailBuilder.hrvBaseClause(
                    rmssd: NarrativeLanguage.number(rmssd), z: z, baseScore: NarrativeLanguage.integer(baseScore)
                ),
                adjustments: adjustments.map(\.phrase)
            )
        }
    }

    /// One adjustment as stored: its kind and the numbers its phrase quotes.
    struct StoredAdjustment: Codable, Equatable, Sendable {
        let kind: String
        var points: Int?
        var days: Int?
    }

    /// An adjustment to the HRV base score, with the points it moved it by.
    enum Adjustment: Equatable, Sendable {
        /// Positive when resting HR ran lower than usual.
        case restingHR(points: Int)
        /// Positive when autonomic balance tilted toward rest.
        case autonomicBalance(points: Int)
        case staleBaseline(days: Int, points: Int)
        case alphaBalanced
        case alphaStrained
        case alphaReduced
        case variabilityFlat
        case variabilityErratic

        /// The kinds that quote no number of their own.
        private static let fixedKinds: [String: Adjustment] = [
            "alphaBalanced": .alphaBalanced, "alphaStrained": .alphaStrained, "alphaReduced": .alphaReduced,
            "variabilityFlat": .variabilityFlat, "variabilityErratic": .variabilityErratic
        ]

        init?(stored: StoredAdjustment) {
            if let fixed = Self.fixedKinds[stored.kind] {
                self = fixed
                return
            }
            guard let points = stored.points else { return nil }
            switch stored.kind {
            case "restingHR": self = .restingHR(points: points)
            case "autonomicBalance": self = .autonomicBalance(points: points)
            case "staleBaseline":
                guard let days = stored.days else { return nil }
                self = .staleBaseline(days: days, points: points)
            default: return nil
            }
        }

        var stored: StoredAdjustment {
            switch self {
            case let .restingHR(points): StoredAdjustment(kind: "restingHR", points: points)
            case let .autonomicBalance(points): StoredAdjustment(kind: "autonomicBalance", points: points)
            case let .staleBaseline(days, points): StoredAdjustment(kind: "staleBaseline", points: points, days: days)
            case .alphaBalanced: StoredAdjustment(kind: "alphaBalanced")
            case .alphaStrained: StoredAdjustment(kind: "alphaStrained")
            case .alphaReduced: StoredAdjustment(kind: "alphaReduced")
            case .variabilityFlat: StoredAdjustment(kind: "variabilityFlat")
            case .variabilityErratic: StoredAdjustment(kind: "variabilityErratic")
            }
        }

        /// The phrase in `NarrativeLanguage`, lowercase-initial for use
        /// after the base clause.
        ///
        /// DFA α1 reads "autonomic regulation {balanced, strained,
        /// reduced}", not "heart rhythm {well-organized, stress,
        /// irregular}". α1 measures autonomic complexity, not cardiac
        /// rhythm pathology; rhythm copy implies rhythm assessment
        /// ("irregular" sounds AFib-adjacent), which App Review 1.4.1 and
        /// the FDA wellness boundary rule out.
        var phrase: String {
            switch self {
            case let .restingHR(points): Self.restingHRPhrase(points)
            case let .autonomicBalance(points): Self.autonomicBalancePhrase(points)
            case let .staleBaseline(days, points):
                String(localized: "baseline data is \(days) days old (−\(NarrativeLanguage.integer(points)))", bundle: NarrativeLanguage.bundle)
            case .alphaBalanced: String(localized: "autonomic regulation balanced (+5)", bundle: NarrativeLanguage.bundle)
            case .alphaStrained: String(localized: "autonomic regulation strained (−5)", bundle: NarrativeLanguage.bundle)
            case .alphaReduced: String(localized: "autonomic regulation reduced (−3)", bundle: NarrativeLanguage.bundle)
            case .variabilityFlat: String(localized: "day-to-day HRV unusually flat (−5)", bundle: NarrativeLanguage.bundle)
            case .variabilityErratic: String(localized: "day-to-day HRV erratic (−3)", bundle: NarrativeLanguage.bundle)
            }
        }

        private static func restingHRPhrase(_ points: Int) -> String {
            let shown = NarrativeLanguage.integer(points)
            return points > 0
                ? String(localized: "resting HR lower than usual (+\(shown))", bundle: NarrativeLanguage.bundle)
                : String(localized: "resting HR higher than usual (\(shown))", bundle: NarrativeLanguage.bundle)
        }

        private static func autonomicBalancePhrase(_ points: Int) -> String {
            let shown = NarrativeLanguage.integer(points)
            return points > 0
                ? String(localized: "autonomic balance tilted toward rest (+\(shown))", bundle: NarrativeLanguage.bundle)
                : String(localized: "autonomic balance tilted toward stress (\(shown))", bundle: NarrativeLanguage.bundle)
        }
    }

    // MARK: - Sleep

    /// The night the sleep sentence describes. `score` picks the sentence;
    /// the rest are `ScoreDetailBuilder.SleepDetailInputs`.
    struct Sleep: Codable, Equatable, Sendable {
        let score: Double
        let hours: Double
        let creditedHours: Double
        let efficiency: Double?
        let target: Double

        var line: String {
            ScoreDetailBuilder.sleepSentence(
                score: score,
                ScoreDetailBuilder.SleepDetailInputs(
                    hours: hours, creditedHours: creditedHours, eff: efficiency, target: target
                )
            )
        }
    }

    // MARK: - Vitals

    /// Each vital the Vitals factor averaged, with the sub-score it got. A
    /// nil reading is one the night didn't have; a reading with a nil
    /// sub-score had nothing to be compared against.
    struct Vitals: Codable, Equatable, Sendable {
        var sleepHR: Double?
        /// Sleep HR minus the personal baseline; nil without a baseline.
        var sleepHRDelta: Double?
        var sleepHRScore: Double?
        var respiratoryDeviation: Double?
        var respiratoryRate: Double?
        var respiratoryScore: Double?
        /// Deviation from the personal wrist-temperature baseline, in °C.
        var temperatureDeviationCelsius: Double?
        var temperatureScore: Double?
        /// The Vitals factor's score: the average of the sub-scores.
        var average: Double
    }
}

// MARK: - Display

extension RecoveryScoreCalculator.ScoreFactor {
    /// The detail line to show, in the app language and `temperatureUnit`:
    /// written now from `facts`, or the line stored at scoring time when the
    /// factor carries no facts this build can read.
    func displayDetail(temperatureUnit: TemperatureUnit) -> String {
        facts?.line(temperatureUnit: temperatureUnit) ?? detail
    }
}
