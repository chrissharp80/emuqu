import CryptoKit
import Foundation

/// Research-informed, calibrated recovery score calculator using ln(RMSSD) z-scores against
/// a personal baseline
///
/// Three-tier scoring based on available data (v3.oct2026 architecture):
/// - Tier 1 (HRV-only): ln(RMSSD) z-score → SWC band score (z = 0 → 72) + RHR, DFA α1, CV and ANS-balance adjustments
/// - Tier 2 (HRV + Sleep): Weighted composite (HRV 70 / Sleep 30) with double-penalty dampening
/// - Tier 3 (HRV + Sleep + Vitals): Weighted composite HRV 60 / Sleep 25 / Vitals 15
///
/// Comeback mode (21-day window, user-toggled in Settings → Training): on a Tier 3 day the
/// weights shift to HRV 80 / Sleep 20 / Vitals 0 so noisy temperature / breathing readings
/// don't suppress the score while the user re-stabilises after illness, injury, or a long
/// break. Tier 2 has no vitals to silence and keeps its weights. The SpO2 flag below still
/// applies in Comeback mode.
///
/// Training load (ACWR, Foster's Monotony / Strain, TRIMP, CTL/ATL/TSB) is computed and
/// surfaced on the parallel Load & Trajectory page, but does NOT feed the recovery score.
/// Two systematic reviews (Impellizzeri 2020, 2021) showed ACWR is too noisy day-to-day to
/// be a recovery signal — random chronic denominators reproduced its odds ratios. It's
/// retained as a planning lens, not a score input.
///
/// SpO2 is the one vitals signal that bypasses the weighted-factor model: any reading
/// below 95% triggers a flat -10 penalty on the composite. It is a flag rather than a
/// factor — one threshold, no baseline comparison — and the flat penalty is a deliberately
/// conservative product rule.
///
/// 95% is not a clinical safety threshold, and this must not claim it is.
/// Apple states Apple Watch blood-oxygen readings are for general fitness and wellness and
/// are not intended for medical use, and 95% is a rule of thumb that altitude, circulation
/// and measurement error all move. The penalty stands; the justification is honest.
///
/// References:
/// - Plews et al. (2013): ln(RMSSD) for monitoring training adaptation
/// - Buchheit (2014): Individual HRV response thresholds using rolling averages
/// - Kiviniemi et al. (2007): HRV-guided training optimization
/// - Altini & Plews (2021): Wearable HRV for recovery assessment
/// - Doherty / Altini (2025): SWC-band approach to vitals scoring
/// - Impellizzeri et al. (2020, 2021): ACWR critique — chronic denominator carries little signal
enum RecoveryScoreCalculator {
    // MARK: - Score Breakdown

    /// Describes one factor contributing to the composite recovery score
    struct ScoreFactor: Identifiable, Codable {
        let id: UUID
        let label: String
        let detail: String
        let score: Double // 0-100 sub-score
        let weight: Double // 0-1 weight in composite
        let impact: Impact

        enum Impact: String, Codable { case positive, neutral, negative }

        init(label: String, detail: String, score: Double, weight: Double, impact: Impact) {
            id = Self.identity(for: label)
            self.label = label
            self.detail = detail
            self.score = score
            self.weight = weight
            self.impact = impact
        }

        /// Weighted contribution to the composite
        var contribution: Double {
            score * weight
        }

        /// The factor's identity, derived from its label.
        ///
        /// A fresh `UUID()` per initialiser made the same factor a different
        /// element on every rebuild: SwiftUI saw the breakdown list replaced
        /// rather than updated, and two breakdowns of identical numbers never
        /// compared equal. The label is what identifies a factor — there is
        /// one HRV row, one Sleep row, one Vitals row.
        ///
        /// Still a `UUID`, and still encoded, so sessions archived before this
        /// keep decoding unchanged; only the value became a function of the
        /// label rather than of the clock.
        static func identity(for label: String) -> UUID {
            var bytes = Array(SHA256.hash(data: Data(label.utf8)).prefix(16))
            // RFC 4122 name-based (v5) variant and version bits, so the value
            // is a well-formed UUID rather than 16 arbitrary bytes.
            bytes[6] = (bytes[6] & 0x0F) | 0x50
            bytes[8] = (bytes[8] & 0x3F) | 0x80
            return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        }
    }

    /// Full breakdown of how the composite score was computed
    struct ScoreBreakdown: Codable {
        let compositeScore: Double
        let tier: Int // 1, 2, or 3
        let factors: [ScoreFactor]
        let penalties: [String] // vitals penalties, etc.

        /// Which scoring algorithm produced `compositeScore`.
        ///
        /// Defaults to `ScoringVersion.current` when constructed and to
        /// `ScoringVersion.unversioned` when decoded from a record written
        /// before this field existed — see `ScoringVersion` for why those two
        /// defaults differ, and why that difference is the point.
        var scoringVersion: String = ScoringVersion.current

        private enum CodingKeys: String, CodingKey {
            case compositeScore, tier, factors, penalties, scoringVersion
        }

        init(compositeScore: Double, tier: Int, factors: [ScoreFactor], penalties: [String],
             scoringVersion: String = ScoringVersion.current) {
            self.compositeScore = compositeScore
            self.tier = tier
            self.factors = factors
            self.penalties = penalties
            self.scoringVersion = scoringVersion
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            compositeScore = try c.decode(Double.self, forKey: .compositeScore)
            tier = try c.decode(Int.self, forKey: .tier)
            factors = try c.decode([ScoreFactor].self, forKey: .factors)
            penalties = try c.decode([String].self, forKey: .penalties)
            // Absent on records written before the stamp existed. Those scores
            // could be v1 or v2 and the archive cannot tell, so they are
            // labelled unknown rather than assumed current.
            scoringVersion = try c.decodeIfPresent(String.self, forKey: .scoringVersion)
                ?? ScoringVersion.unversioned
        }

        /// Factor-aware advice that calls out what's dragging the score
        /// and what's carrying it. Uses individual factor scores, not just
        /// the composite, so the message is never generic.
        /// Also surfaces vitals penalties when they reduce the score.
        var message: String {
            let weakest = factors.min(by: { $0.score < $1.score })
            let strongest = factors.max(by: { $0.score < $1.score })
            if let penalised = vitalsPenaltyMessage(weakest: weakest) { return penalised }
            if let drifted = baselineDriftMessage() { return drifted }
            return bandMessage(weakest: weakest, strongest: strongest)
        }

        /// The gap between the weighted factor average and the composite. A
        /// positive gap means something outside the factors pulled the score down.
        private var gapFromFactors: Double {
            factors.reduce(0.0) { $0 + $1.contribution } - compositeScore
        }

        /// When a penalty is dragging the score below what the factors alone
        /// would give, say which one and by how much. The SpO₂ wording is used
        /// only when the SpO₂ penalty is the one that applied.
        private func vitalsPenaltyMessage(weakest: ScoreFactor?) -> String? {
            guard !penalties.isEmpty, gapFromFactors > 1 else { return nil }
            let points = Int(gapFromFactors)
            let onlySpO2 = penalties.allSatisfy { $0.hasPrefix("Low blood oxygen") }
            if factors.allSatisfy({ $0.score >= 60 }) {
                return onlySpO2
                    ? "Your component scores are strong, but a SpO₂ reading below 95% reduced your score by \(points) points. Check the SpO₂ value in your vitals."
                    : "Your component scores are strong, but \(penaltyList) reduced your score by \(points) points."
            }
            if let w = weakest, w.score < 60 {
                return "Penalties (−\(points)) plus weak \(w.label.lowercased()) are holding your score back."
            }
            return "Good component scores, but penalties reduced your composite by \(points) points."
        }

        /// The penalty names without their point values, lowercased for
        /// mid-sentence use: "low blood oxygen and no sleep data".
        private var penaltyList: String {
            penalties
                .map { $0.components(separatedBy: " (").first ?? $0 }
                .map { $0.prefix(1).lowercased() + $0.dropFirst() }
                .joined(separator: " and ")
        }

        /// A gap between factor scores and composite WITHOUT vitals penalties
        /// happens for legacy sessions where baselines shifted since acceptance.
        /// The factor scores reflect current baselines, but the composite is the
        /// original frozen score — don't claim a penalty that doesn't exist.
        private func baselineDriftMessage() -> String? {
            guard gapFromFactors > 5, penalties.isEmpty,
                  factors.allSatisfy({ $0.score >= 60 }) else { return nil }
            return "Your baselines have improved since this session. Today those same HRV and sleep numbers score higher, but this score reflects how you compared at the time."
        }

        /// The bands are `ScoreVerdict`'s, the word shown above this message:
        /// on 80/60/40 a 82 read "Good — normal training is fine" over "Go
        /// hard", and a 42 read "Low" over the middle band's message.
        private func bandMessage(weakest: ScoreFactor?, strongest: ScoreFactor?) -> String {
            let shown = compositeScore.rounded()
            if shown >= 75 { return strongBandMessage(weakest: weakest) }
            if shown >= 60 {
                return decentBandMessage(weakest: weakest, strongest: strongest)
            }
            if shown >= 45 { return mediocreBandMessage(weakest: weakest) }
            return lowBandMessage(weakest: weakest)
        }

        /// Everything is strong (the Good and Excellent verdicts), and no
        /// vitals penalties applied. "Go hard" is for Excellent only.
        ///
        /// A composite ≥ 80 can be carried by sleep and vitals while HRV
        /// itself sits under baseline (seen live: HRV 71 at −19 % vs
        /// baseline, sleep 95, vitals 96 → 81, "Go hard" two lines above
        /// "Below your baseline — pay attention"). HRV is the primary signal,
        /// so the HRV factor must be at or above its baseline score (72, the
        /// flat z = 0 band) for either of the all-clear lines. Only the
        /// factors this tier actually has are named.
        private func strongBandMessage(weakest: ScoreFactor?) -> String {
            if let w = weakest, w.score < 60 {
                return "Strong overall, but \(w.label.lowercased()) is holding you back. Fix that and you're flying."
            }
            let others = factors.filter { $0.label != "HRV" }.map { $0.label.lowercased() }
            if let hrv = factors.first(where: { $0.label == "HRV" }), hrv.score < 72, !others.isEmpty {
                let carriers = Self.sentenceCase(Self.listPhrase(others))
                let verb = others.count > 1 ? "are" : "is"
                return "\(carriers) \(verb) carrying the score while HRV sits under its usual level. A good day for normal training, not a green light to go hard."
            }
            let all = Self.listPhrase(factors.map { $0.label == "HRV" ? "HRV" : $0.label.lowercased() })
            let verb = factors.count > 1 ? "are all" : "is"
            guard compositeScore.rounded() >= 90 else {
                return "\(Self.sentenceCase(all)) \(verb) in a good place. Normal training is fine."
            }
            return "Everything is clicking — \(all) \(verb) dialed in. Go hard."
        }

        /// "a", "a and b", "a, b, and c".
        private static func listPhrase(_ items: [String]) -> String {
            guard items.count > 1, let last = items.last else { return items.first ?? "" }
            let head = items.dropLast()
            return head.count == 1 ? "\(head.first ?? "") and \(last)" : head.joined(separator: ", ") + ", and \(last)"
        }

        private static func sentenceCase(_ text: String) -> String {
            text.prefix(1).uppercased() + text.dropFirst()
        }

        /// Composite is decent but something is weak.
        ///
        /// When the weakest factor is training load, the
        /// "Address that to break through" template is misleading: a heavy week
        /// of training legitimately depresses TSB and the right action is to
        /// RESPECT the fatigue, not "address" it (a beta user saw "training
        /// load is dragging the score down" on a normal training-block
        /// morning). Other factors keep the actionable wording — they
        /// ARE actionable.
        private func decentBandMessage(weakest: ScoreFactor?, strongest: ScoreFactor?) -> String {
            if let w = weakest, w.score < 45, let s = strongest {
                if w.label == "Training Load" {
                return "\(s.label) is carrying you, but you're carrying real training fatigue — that's expected during a build. Take it easier today and let the load come off."
                }
                return "\(s.label) is carrying you but \(w.label.lowercased()) is dragging the score down. Address that to break through."
            }
            return "Decent recovery overall. Check the component scores — the lowest one is your bottleneck."
        }

        private func mediocreBandMessage(weakest: ScoreFactor?) -> String {
            if let w = weakest, w.score < 40 {
                if w.label == "Training Load" {
                return "You're heavily fatigued from recent training. Today's an easy day — short walk or full rest, not intervals."
                }
                return "Your \(w.label.lowercased()) score is pulling your recovery down. That's what needs to change."
            }
            return "Incomplete recovery. Multiple factors are mediocre — no single fix, focus on the weakest."
        }

        private func lowBandMessage(weakest: ScoreFactor?) -> String {
            if let w = weakest, w.score < 30 {
            return "\(w.label) is critically low and tanking your score. Prioritize that above everything."
            }
        return "Recovery is poor across the board. Rest and recover before pushing anything."
        }
    }

    // MARK: - Configuration (injected by caller, not read from global state)

    /// Settings the calculator needs from the caller. Built at the boundary
    /// (View / ViewModel / RRCollector) from SettingsManager — never accessed here.
    struct ScoringConfiguration {
        let enableTrainingLoadIntegration: Bool
        let isOnTrainingBreak: Bool
        let enableSleepIntegration: Bool
        let penalizeMissingSleep: Bool
        let userAge: Int?
        /// When true, the recovery score uses the
        /// Comeback weighting (HRV 80% / Sleep 20% / Vitals 0%) instead of
        /// the standard 60/25/15. Vitals are still computed and surfaced
        /// for the breakdown — they just don't contribute weight, because
        /// a returning user's RR/RHR/temp can stay noisy for weeks after
        /// illness or injury and shouldn't penalise the score.
        let isComebackModeActive: Bool

        /// Build from the current user settings — single source of truth so every
        /// call site doesn't have to repeat the field mapping.
        init(from settings: UserSettings) {
            enableTrainingLoadIntegration = settings.enableTrainingLoadIntegration
            isOnTrainingBreak = settings.isOnTrainingBreak
            enableSleepIntegration = settings.enableSleepIntegration
            penalizeMissingSleep = settings.penalizeMissingSleep
            userAge = settings.age
            isComebackModeActive = settings.isComebackModeActive
        }

        /// Memberwise initializer (for tests and custom configurations)
        init(
            enableTrainingLoadIntegration: Bool,
            isOnTrainingBreak: Bool,
            enableSleepIntegration: Bool,
            penalizeMissingSleep: Bool,
            userAge: Int?,
            isComebackModeActive: Bool = false
        ) {
            self.enableTrainingLoadIntegration = enableTrainingLoadIntegration
            self.isOnTrainingBreak = isOnTrainingBreak
            self.enableSleepIntegration = enableSleepIntegration
            self.penalizeMissingSleep = penalizeMissingSleep
            self.userAge = userAge
            self.isComebackModeActive = isComebackModeActive
        }
    }

    // MARK: - Z-Score Mapping

    /// Map z-score to 0–100 via the normal CDF (percentile of your own data).
    /// z = 0 → 50 (your average), z = +1 → 84 (84th percentile), z = −1 → 16
    /// This is the mathematically correct interpretation of a z-score:
    /// it tells you what fraction of your own readings you're above.
    /// NOTE: Not used for recovery scoring — see zToRecoveryScore.
    static func zToPercentileScore(_ z: Double) -> Double {
        guard !z.isNaN else { return ScoringBounds.neutralScore }
        let clamped = max(-3.0, min(3.0, z))
        return 0.5 * (1.0 + erf(clamped / sqrt(2.0))) * 100.0
    }

    /// Scoring parameters live in a versioned
    /// value type so (a) the bands aren't a magic literal buried inside a
    /// function, (b) tests / diagnostics can capture *which* parameter set
    /// produced a given score, and (c) future tuning passes can ship a `.v2`
    /// without rewriting the function — the only place the live params are
    /// referenced is `defaultScoringParameters`.
    struct ScoringParameters: Equatable {
        /// Stable identifier for the parameter snapshot. Bump when bands
        /// change so analytics / breakdown serializations can disambiguate.
        let version: String
        /// Piecewise-linear breakpoints for `zToRecoveryScore`. Must be
        /// monotonically increasing in `z` and produce a valid 0–100 range
        /// at the endpoints (callers clamp anyway, but the contract is the
        /// expected shape).
        let zScoreBands: [(z: Double, score: Double)]

        static func == (lhs: ScoringParameters, rhs: ScoringParameters) -> Bool {
            lhs.version == rhs.version
                && lhs.zScoreBands.count == rhs.zScoreBands.count
                && zip(lhs.zScoreBands, rhs.zScoreBands).allSatisfy { $0.z == $1.z && $0.score == $1.score }
        }

        /// The invariant the doc comment above states, made checkable.
        ///
        /// "Must be monotonically increasing in `z`" needs enforcing,
        /// not just documenting: a non-monotonic table makes
        /// `zToRecoveryScore`'s interpolation factor negative or unbounded, and
        /// the function relies on its caller to clamp. Asserted by
        /// `RecoveryScoreCalculatorTests.testShippedScoringParametersAreMonotonic`
        /// for every parameter set the app can bind to.
        var isMonotonicInZ: Bool {
            zip(zScoreBands, zScoreBands.dropFirst()).allSatisfy { $0.z < $1.z }
        }

        /// Endpoints must land inside the 0...100 range the rest of the model
        /// assumes, so a band table can never widen the score range by itself.
        var hasScoresInRange: Bool {
            zScoreBands.allSatisfy { $0.score >= ScoringBounds.minScore && $0.score <= ScoringBounds.maxScore }
        }
    }

    /// Calibrated so an average day (z≈0, decent sleep, balanced training)
    /// lands in the mid-70s. Genuinely good days reach the 80s, excellent
    /// days the high 80s / low 90s. Previous z=0→80 mapping compressed the
    /// upper range and inflated average-day composites to 80+.
    static let scoringParametersV1 = ScoringParameters(
        version: "v1.2026-05-01",
        zScoreBands: [
            (-3.0, 5.0),
            (-1.5, 25.0),
            (-0.5, 58.0),
            (0.0, 72.0),
            (0.5, 80.0),
            (1.5, 90.0)
        ]
    )

    /// SWC deadband. The v1 bands are piecewise-
    /// linear straight through z=0 with NO flat region, so within-noise
    /// variation (e.g. a z=-0.5 night that is *not* a real change per the
    /// Plews/Buchheit Smallest-Worthwhile-Change framework this calculator
    /// cites) drops the base score ~14 points (72 → 58) — a swing the
    /// physiology does not support. The SWC framework treats ln(RMSSD)
    /// within ±0.5 SD of the rolling mean as "stable / no change"; only
    /// deviations beyond ~0.75 SD are actionable. v2 therefore:
    ///   • flattens the band z ∈ [-0.5, +0.5] at the neutral 72 (no change),
    ///   • starts the meaningful drop below -0.75 SD (z=-0.75 → 64),
    ///   • keeps the steep below-baseline slope and the above-baseline
    ///     plateau (above baseline is ambiguous per the references).
    /// Endpoints (z=-3 → 5, z=1.5 → 90) are unchanged so the dynamic range
    /// and asymmetry the rest of the model assumes are preserved. Monotonic
    /// and clamped 0–100 by `zToRecoveryScore`.
    /// Smallest Worthwhile Change = 0.5·SD of rolling ln(RMSSD) — Plews et al.
    /// 2013; Buchheit, Front Physiol 2014;5:73.
    static let scoringParametersV2 = ScoringParameters(
        version: "v2.2026-06-22",
        zScoreBands: [
            (-3.0, 5.0),
            (-1.5, 25.0),
            (-0.75, 64.0),
            (-0.5, 72.0),
            (0.5, 72.0),
            (1.5, 90.0)
        ]
    )

    /// The parameter set the live app uses. Single-source-of-truth pointer
    /// — re-bind to `scoringParametersV2` (etc.) in the same release that
    /// rolls out a band tweak.
    static let defaultScoringParameters: ScoringParameters = scoringParametersV2

    /// Map z-score to 0–100 recovery score using SWC band model (Plews/Buchheit).
    ///
    /// Based on the Smallest Worthwhile Change framework: HRV at your personal
    /// baseline indicates good recovery, not mediocre. Above-baseline readings
    /// are ambiguous (parasympathetic rebound, possible overtraining) and plateau
    /// rather than continuing to climb. Below-baseline drops steeply because
    /// under-recovery is actionable.
    ///
    /// Default `parameters` is the live `defaultScoringParameters` (the v2
    /// bands). Tests and diagnostics can
    /// pass an alternate parameter set to verify a future re-tune.
    ///
    /// References:
    /// - Plews et al. (2013) SWC = ±0.5 SD of rolling ln(RMSSD) mean
    /// - Buchheit (2014) stability within SWC is the training goal
    /// - HRV4Training normal-range model (deviations outside range trigger concern)
    /// - Circulation (2001) non-monotonic HRV–parasympathetic relationship
    static func zToRecoveryScore(_ z: Double, parameters: ScoringParameters = defaultScoringParameters) -> Double {
        let bands = parameters.zScoreBands

        guard let lowest = bands.first, let highest = bands.last else { return ScoringBounds.neutralScore }
        // A non-finite z fails BOTH endpoint guards and every
        // `z <= hi.z` band test, so control would fall through to
        // `return highest.score`: NaN mapped to the MAXIMUM recovery score.
        // `FiniteHRVInputs` keeps NaN off the production path, but this function
        // is `internal static` and the failure direction was the wrong one.
        // "We do not know" degrades to the midpoint, never to "excellent".
        // NaN only: +/-infinity IS a well-ordered value ("infinitely above /
        // below baseline") and the endpoint guards below give it the honest
        // answer. NaN has no ordering, which is exactly why it fell through.
        guard !z.isNaN else { return ScoringBounds.neutralScore }
        if z <= lowest.z { return lowest.score }
        if z >= highest.z { return highest.score }
        return interpolate(z, in: bands) ?? highest.score
    }

    /// Linear interpolation between the two bands that bracket `z`.
    /// Nil only when no band brackets it, which the endpoint guards above
    /// already exclude.
    private static func interpolate(_ z: Double, in bands: [(z: Double, score: Double)]) -> Double? {
        // The endpoint guards in the caller imply a non-empty band table,
        // but this must not trap if a future table is ever empty.
        for i in 0 ..< max(0, bands.count - 1) where z <= bands[i + 1].z {
            let lo = bands[i]
            let hi = bands[i + 1]
            let t = (z - lo.z) / (hi.z - lo.z)
            return lo.score + t * (hi.score - lo.score)
        }
        return nil
    }

    /// The physiological readings one scoring pass works from.
    ///
    /// The four scoring entry points would otherwise each take the same ten
    /// arguments, tripping `function_parameter_count` at every one. Eight of
    /// the ten are this single group: what the night measured, what the user's
    /// baseline looks like, and how long they normally sleep. Only the training
    /// snapshot and the configuration vary between overloads, so grouping the
    /// readings leaves each entry point naming exactly what distinguishes it.
    struct ScoreInputs {
        let hrvReadiness: Double?
        let rmssd: Double?
        let meanHR: Double?
        let dfaAlpha1: Double?
        let baselineStats: BaselineTracker.RecoveryBaselineStats?
        let sleepData: SleepData?
        let vitals: RecoveryVitals?
        let typicalSleepHours: Double

        /// The same inputs with the four HRV readings replaced.
        ///
        /// The `useBaselineHRV` overload substitutes a user's baseline for a
        /// recording that was itself unusable; everything else about the night —
        /// sleep, vitals, the baseline stats — is unchanged, so this copies
        /// rather than rebuilds.
        fileprivate func substitutingHRV(_ hrv: FiniteHRVInputs) -> ScoreInputs {
            ScoreInputs(
                hrvReadiness: hrv.readiness, rmssd: hrv.rmssd, meanHR: hrv.meanHR,
                dfaAlpha1: hrv.dfaAlpha1, baselineStats: baselineStats, sleepData: sleepData,
                vitals: vitals, typicalSleepHours: typicalSleepHours
            )
        }

        /// The same inputs with wrist temperature re-expressed as tonight's
        /// deviation from the user's own baseline — see
        /// `wristTemperatureAgainstPersonalBaseline`.
        fileprivate func scoringWristTemperatureAgainstBaseline() -> ScoreInputs {
            ScoreInputs(
                hrvReadiness: hrvReadiness, rmssd: rmssd, meanHR: meanHR, dfaAlpha1: dfaAlpha1,
                baselineStats: baselineStats, sleepData: sleepData,
                vitals: vitals.map(RecoveryScoreCalculator.wristTemperatureAgainstPersonalBaseline),
                typicalSleepHours: typicalSleepHours
            )
        }
    }

    /// Wrist temperature as the score reads it: tonight's reading minus the
    /// user's baseline from the nights before.
    ///
    /// The Help Center, the report and Flo all describe the temperature part
    /// as a deviation from the person's own baseline. The stored reading is
    /// not one: `VitalsHealthQueries` normalises HealthKit's absolute value by
    /// a population constant, so scoring it directly compared every night with
    /// 36.5 °C and a fever in a cool sleeper could still read "normal". The
    /// reading and its baseline carry the same normalisation, so their
    /// difference is the personal deviation. Without a baseline there is no
    /// personal deviation to score, and the temperature part is dropped like
    /// any other missing vitals input. The result carries a zero baseline, so
    /// applying this twice changes nothing.
    static func wristTemperatureAgainstPersonalBaseline(_ vitals: RecoveryVitals) -> RecoveryVitals {
        let deviation: Double? = if let temp = vitals.wristTemperature, let baseline = vitals.wristTemperatureBaseline {
            temp - baseline
        } else {
            nil
        }
        return RecoveryVitals(
            respiratoryRate: vitals.respiratoryRate, respiratoryRateBaseline: vitals.respiratoryRateBaseline,
            oxygenSaturation: vitals.oxygenSaturation, oxygenSaturationMin: vitals.oxygenSaturationMin,
            wristTemperature: deviation, wristTemperatureBaseline: deviation == nil ? nil : 0,
            restingHeartRate: vitals.restingHeartRate
        )
    }

    /// Calculate composite score AND return a breakdown of what contributed.
    /// Configuration is provided by the caller — no global state access.
    ///
    /// Training metrics are
    /// accepted as a parameter for API stability and so callers can keep
    /// passing the same value, but they do not contribute to the
    /// recovery score itself. Training load lives on the parallel
    /// Load & Trajectory surface, not in this composite. See the
    /// `ScoringWeights` doc-comment for the rationale (Impellizzeri 2020/
    /// 2021, Doherty/Altini 2025).
    static func calculateWithBreakdown(
        _ inputs: ScoreInputs,
        trainingMetrics: HealthKitManager.TrainingMetrics?,
        config: ScoringConfiguration,
        ansBalance: Double? = nil,
        referenceDate: Date = Date()
    ) -> ScoreBreakdown {
        // Training metrics are still computed for the parallel Load &
        // Trajectory surface (see TrainingMetricsCache + TrainingDetailView)
        // but do not feed the recovery composite. _ = silences the
        // unused-warning while keeping the parameter on the public surface.
        _ = trainingMetrics
        return computeBreakdown(inputs, config: config, ansBalance: ansBalance, referenceDate: referenceDate)
    }

    /// Convenience overload using TrainingContext instead of TrainingMetrics.
    /// TrainingContext is a frozen snapshot without daily TRIMP history, so
    /// Foster's Monotony/Strain cannot be computed from it.
    /// Configuration is provided by the caller — no global state access.
    ///
    /// `trainingContext` is preserved on the signature
    /// for caller stability and for the parallel Load & Trajectory surface,
    /// but is not wired into the recovery composite — same as
    /// the TrainingMetrics overload. See `ScoringWeights` doc-comment.
    static func calculateWithBreakdown(
        _ inputs: ScoreInputs,
        trainingContext: TrainingContext?,
        config: ScoringConfiguration,
        useBaselineHRV: Bool = false,
        perceivedReadiness: Double? = nil,
        ansBalance: Double? = nil,
        referenceDate: Date = Date()
    ) -> ScoreBreakdown {
        _ = trainingContext // see doc comment above
        let effective = FiniteHRVInputs(
            readiness: inputs.hrvReadiness, rmssd: inputs.rmssd, meanHR: inputs.meanHR, dfaAlpha1: inputs.dfaAlpha1
        ).substitutingBaseline(useBaselineHRV ? inputs.baselineStats : nil)
        let breakdown = computeBreakdown(
            inputs.substitutingHRV(effective), config: config, ansBalance: ansBalance, referenceDate: referenceDate
        )
        guard useBaselineHRV, let perceived = perceivedReadiness else { return breakdown }
        return blendingPerceivedReadiness(
            perceived, vitals: inputs.vitals,
            missingSleep: missingSleepPenaltyApplies(inputs, tier: breakdown.tier, config: config),
            into: breakdown
        )
    }

    /// The four HRV inputs, with non-finite values already coerced to missing.
    ///
    /// A short/degenerate reading can produce a NaN metric, most
    /// often DFA α1 on a ~5-min quick reading where there isn't enough data for
    /// the detrended-fluctuation fit. Left alone, NaN propagates through the
    /// weighted composite, and the score ring then does `Int(score)` and
    /// `.trim(CGFloat(score)/100)`, both of which HARD-CRASH on NaN (the
    /// min/max clamps downstream do NOT sanitize NaN). These inputs are already
    /// optional, so coercing a non-finite value to nil yields a finite,
    /// sensible score instead of crashing the report. Fixes the TestFlight
    /// "View full report → flashed up → crash" after a quick reading.
    fileprivate struct FiniteHRVInputs {
        let readiness: Double?
        let rmssd: Double?
        let meanHR: Double?
        let dfaAlpha1: Double?

        init(readiness: Double?, rmssd: Double?, meanHR: Double?, dfaAlpha1: Double?) {
            self.readiness = readiness.flatMap { $0.isFinite ? $0 : nil }
            self.rmssd = rmssd.flatMap { $0.isFinite ? $0 : nil }
            self.meanHR = meanHR.flatMap { $0.isFinite ? $0 : nil }
            self.dfaAlpha1 = dfaAlpha1.flatMap { $0.isFinite ? $0 : nil }
        }

        private init(readiness: Double?, rmssd: Double?, meanHR: Double?, dfaAlpha1: Double?, unchecked: Void) {
            self.readiness = readiness
            self.rmssd = rmssd
            self.meanHR = meanHR
            self.dfaAlpha1 = dfaAlpha1
        }

        /// When the recording itself was unusable (pre-sleep, insufficient
        /// overlap), stand in the baseline and drop the session-specific
        /// modifiers — the HRV factor lands near the at-baseline band score
        /// (72), less any variability or staleness deduction.
        func substitutingBaseline(_ stats: BaselineTracker.RecoveryBaselineStats?) -> FiniteHRVInputs {
            guard let stats else { return self }
            return FiniteHRVInputs(
                readiness: nil,                       // No ANS readiness from a bad recording
                rmssd: exp(stats.lnRmssdMean),        // Baseline ln(RMSSD) back to RMSSD
                meanHR: stats.meanHRBaseline,
                dfaAlpha1: nil,                       // No DFA from a bad recording
                unchecked: ()
            )
        }
    }

    /// Blends subjective readiness into the HRV factor when HRV came from the
    /// baseline: 70% baseline + 30% subjective. Sleep and vitals are untouched.
    ///
    /// Rebuilding the composite as the bare
    /// weighted factor sum would silently drop BOTH tails that
    /// `computeBreakdown` applies after weighting: the `min(100, max(0, ...))`
    /// clamp and `applyVitalsOverrides` (the flat SpO2 penalty). A user whose
    /// recording was unusable (`useBaselineHRV`), who answered the perceived-
    /// readiness prompt, and whose watch recorded SpO2 below 95% would get a
    /// score 10 points higher than the model specifies — with the penalty still
    /// listed in `penalties` but neither applied nor explained, because
    /// `vitalsPenaltyMessage` keys on `gapFromFactors > 1` and the rebuild makes
    /// that gap exactly zero.
    ///
    /// The recomposition tail now goes through `composeFinalScore`, which is the
    /// single place either code path is allowed to turn weighted factors into a
    /// composite. The missing-sleep deduction travels with it, for the same
    /// reason: it is listed in `penalties`, so it must also be applied.
    private static func blendingPerceivedReadiness(
        _ perceived: Double,
        vitals: RecoveryVitals?,
        missingSleep: Bool,
        into breakdown: ScoreBreakdown
    ) -> ScoreBreakdown {
        let updatedFactors = blendedFactors(perceived, in: breakdown)
        return ScoreBreakdown(
            compositeScore: composeFinalScore(
                weightedSum: updatedFactors.reduce(0.0) { $0 + $1.contribution },
                vitals: vitals, missingSleep: missingSleep
            ),
            tier: breakdown.tier,
            factors: updatedFactors,
            penalties: breakdown.penalties
        )
    }

    /// The factor list with the HRV factor re-scored as 70% baseline / 30%
    /// subjective. `perceived` is clamped to its documented 0...1 domain first —
    /// see `subjectiveScore(from:)`.
    private static func blendedFactors(_ perceived: Double, in breakdown: ScoreBreakdown) -> [ScoreFactor] {
        let subjective = subjectiveScore(from: perceived)
        return breakdown.factors.map { factor -> ScoreFactor in
            guard factor.label == "HRV" else { return factor }
            return ScoreFactor(
                label: factor.label,
                // Raw English on purpose: every other `ScoreFactor.detail` is
                // built the same way (`buildVitalsDetail`, `buildSleepDetail`)
                // and the whole breakdown is routed through
                // `NarrativeTranslator` at the view boundary rather than the
                // string catalogue.
                detail: "Baseline HRV + your assessment (recording was unusable)",
                score: factor.score * ScoringWeights.PerceivedReadiness.baseline
                    + subjective * ScoringWeights.PerceivedReadiness.subjective,
                weight: factor.weight,
                impact: factor.impact
            )
        }
    }

    /// Map a perceived-readiness answer (documented domain 0.0...1.0) onto the
    /// 0...100 sub-score scale.
    ///
    /// The clamp is not decoration. The UI that produces this
    /// value is bounded (`SubjectiveReadinessCard` divides a slider by 10), but
    /// `SessionMetadata.init(from:)` decodes it from persisted JSON and the field
    /// round-trips through CloudKit, so a malformed or future-schema record can
    /// reach here unvalidated. Without the clamp, `perceivedReadiness = 100`
    /// produced a composite of 3050.4 and `-5` produced -99.6, both of which then
    /// feed `Int(score)` and `.trim(CGFloat(score) / 100)`.
    static func subjectiveScore(from perceived: Double) -> Double {
        guard perceived.isFinite else { return ScoringBounds.neutralSubjectiveScore }
        return min(1.0, max(0.0, perceived)) * 100.0
    }

    /// Turn a weighted factor sum into the composite the user sees.
    ///
    /// Deduct the missing-sleep penalty, clamp, then apply the post-composite
    /// vitals overrides — the order `computeBreakdown` has always used,
    /// extracted here so the perceived-readiness path cannot diverge from it
    /// again. Every deduction made here is one the breakdown's `penalties` lists, so
    /// the breakdown names each point taken off.
    private static func composeFinalScore(
        weightedSum: Double,
        vitals: RecoveryVitals?,
        missingSleep: Bool
    ) -> Double {
        let deduction = missingSleep ? RecoveryScoreConstants.missingSleepPenalty : 0
        let clamped = min(ScoringBounds.maxScore, max(ScoringBounds.minScore, weightedSum - deduction))
        return applyVitalsOverrides(score: clamped, vitals: vitals)
    }

    /// Core breakdown logic shared by both calculateWithBreakdown() overloads.
    ///
    /// Training does not contribute to the recovery composite; the vitals
    /// score is the 15% factor; comeback mode lets the tier composer apply the
    /// HRV-80 / Sleep-20 / Vitals-0 weighting when the user has flagged a
    /// return from illness or injury.
    ///
    /// Wrist temperature is scored as tonight's deviation from the user's own
    /// baseline, which is what the Help Center and the report describe; see
    /// `scoringWristTemperatureAgainstBaseline`.
    private static func computeBreakdown(
        _ rawInputs: ScoreInputs,
        config: ScoringConfiguration,
        ansBalance: Double?,
        referenceDate: Date
    ) -> ScoreBreakdown {
        let inputs = rawInputs.scoringWristTemperatureAgainstBaseline()
        let vitalsScore = calculateVitalsScore(vitals: inputs.vitals, baselineStats: inputs.baselineStats)
        let (composite, tier, factors) = buildTierComposite(tierInputs(
            inputs, vitalsScore: vitalsScore, config: config, ansBalance: ansBalance, referenceDate: referenceDate
        ))
        let missingSleep = missingSleepPenaltyApplies(inputs, tier: tier, config: config)
        let finalComposite = composeFinalScore(weightedSum: composite, vitals: inputs.vitals, missingSleep: missingSleep)
        logScoreTriage(tier: tier, composite: finalComposite, hasHRV: inputs.rmssd != nil, hasSleep: inputs.sleepData != nil, hasVitals: vitalsScore != nil, comebackModeActive: config.isComebackModeActive)
        return ScoreBreakdown(
            compositeScore: finalComposite, tier: tier, factors: factors,
            penalties: vitalsPenaltyDescriptions(inputs.vitals) + (missingSleep ? [missingSleepPenaltyDescription] : [])
        )
    }

    /// Every signal the tier ladder needs for one scoring pass.
    private static func tierInputs(
        _ inputs: ScoreInputs,
        vitalsScore: Double?,
        config: ScoringConfiguration,
        ansBalance: Double?,
        referenceDate: Date
    ) -> TierInputs {
        TierInputs(
            tier1: calculateTier1(
                rmssd: inputs.rmssd ?? 0, meanHR: inputs.meanHR, dfaAlpha1: inputs.dfaAlpha1,
                baselineStats: inputs.baselineStats, readiness: inputs.hrvReadiness,
                ansBalance: ansBalance, referenceDate: referenceDate
            ),
            sleepScore: config.enableSleepIntegration ? calculateSleepScore(sleepData: inputs.sleepData, typicalSleepHours: inputs.typicalSleepHours, userAge: config.userAge) : nil,
            vitalsScore: vitalsScore, vitals: inputs.vitals, baselineStats: inputs.baselineStats,
            hrvDetail: buildHRVDetail(
                rmssd: inputs.rmssd, baselineStats: inputs.baselineStats, meanHR: inputs.meanHR,
                dfaAlpha1: inputs.dfaAlpha1, hrvReadiness: inputs.hrvReadiness, ansBalance: ansBalance, referenceDate: referenceDate
            ),
            sleepData: inputs.sleepData, rmssd: inputs.rmssd, typicalSleepHours: inputs.typicalSleepHours,
            comebackModeActive: config.isComebackModeActive
        )
    }

    /// Tier 1 with sleep integration on, the missing-sleep penalty on, and no
    /// sleep data: the night is scored on HRV alone, minus
    /// `missingSleepPenalty`.
    private static func missingSleepPenaltyApplies(_ inputs: ScoreInputs, tier: Int, config: ScoringConfiguration) -> Bool {
        tier == 1 && config.enableSleepIntegration && config.penalizeMissingSleep && inputs.sleepData == nil
    }

    /// Listed with the penalties so the breakdown explains the points
    /// `composeFinalScore` takes off when sleep data is missing.
    static let missingSleepPenaltyDescription = "No sleep data (−\(Int(RecoveryScoreConstants.missingSleepPenalty)))"

    /// Without this a user reporting "score seems
    /// wrong" can't be triaged: we can't tell whether sleep was missing, or
    /// which inputs the composite actually saw.
    ///
    /// Gated to DEBUG. The dashboard re-evaluates `body` many
    /// times during a normal launch and each fires this log; Release builds
    /// don't need the per-render echo.
    ///
    /// Training is not part of the composite, so
    /// the line reports the active tier, vitals presence, and Comeback-mode
    /// status.
    private static func logScoreTriage(
        tier: Int,
        composite: Double,
        hasHRV: Bool,
        hasSleep: Bool,
        hasVitals: Bool,
        comebackModeActive: Bool
    ) {
        #if DEBUG
        debugLog(
            "[Score] tier=\(tier) composite=\(composite) hasHRV=\(hasHRV) hasSleep=\(hasSleep) hasVitals=\(hasVitals) comeback=\(comebackModeActive)",
            level: .info
        )
        #endif
    }
}
