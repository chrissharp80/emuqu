import Foundation

// MARK: - Training Readiness

/// Training readiness: the ACWR-dampened readiness score, the freshness
/// bonus, and the label/message pair the UI shows for it.
///
/// Split out of `RecoveryScoreCalculator`, alongside
/// `VitalsScoring`, to keep the calculator under the 1500-line limit.
enum ReadinessScoring {
    // MARK: - Training Readiness

    /// A recent workout's TRIMP and elapsed time for acute fatigue decay.
    struct WorkoutLoad {
        let hoursAgo: Double
        let trimp: Double
    }

    /// Training readiness: how much capacity you have to absorb additional load.
    ///
    /// This is INDEPENDENT of recovery score. Recovery measures your morning
    /// physiological state (HRV, sleep, vitals). Readiness measures your capacity
    /// to handle more training based on fitness-fatigue dynamics (Banister 1975).
    /// Both scores are displayed separately on the dashboard.
    ///
    /// ## Model
    ///
    /// The core insight: readiness is about the relationship between what your
    /// body is ADAPTED to handle (CTL) and what it's currently CARRYING (ATL +
    /// acute fatigue from recent exercise). A fit athlete (CTL=60) barely notices
    /// a 6-mile hike. An unfit athlete (CTL=20) is wrecked by the same hike.
    ///
    /// ### 1. Acute fatigue (fast-decay component)
    ///
    /// The 7-day EWMA (ATL) is too slow to capture immediate post-exercise fatigue.
    /// A separate fast-decay term models the neuromuscular fatigue that peaks right
    /// after exercise and largely resolves within 48h:
    ///
    ///   acuteFatigue = Σ TRIMP_i × 0.30 × exp(-hoursAgo_i / 24)
    ///
    /// τ_acute = 24h is consistent with cardiac autonomic recovery timecourse:
    /// - Stanley et al. (2013): moderate-intensity recovery ~24h, high ~48-72h
    /// - Hynynen et al. (2006): parasympathetic reactivation slow phase 24-48h
    /// - Seiler et al. (2007): HRV recovery to baseline 24-48h post-exercise
    ///
    /// This replaces the previous flat same-day penalty (todayTrimp × 0.35) which
    /// created a cliff at midnight — full penalty all day, then zero the next morning.
    /// The exponential decay produces smooth recovery: ~61% at 12h, ~37% at 24h,
    /// ~14% at 48h, ~5% at 72h.
    ///
    /// ### 2. Capacity Ratio (primary signal)
    ///
    /// When CTL ≥ 3.2 (`ctlThreshold`, established training history):
    ///   effectiveLoad = ATL + acuteFatigue
    ///   capacityRatio = effectiveLoad / CTL
    ///
    /// Maps to 0-100 via piecewise linear:
    ///   ratio 0.0  → 100 (fully rested, no fatigue)
    ///   ratio 0.8  → 85  (sweet spot — well managed load)
    ///   ratio 1.0  → 70  (matched — carrying normal fatigue)
    ///   ratio 1.3  → 50  (overreaching — elevated fatigue)
    ///   ratio 1.5  → 30  (sharp recent increase over the chronic base)
    ///   ratio 2.0+ → 10  (extreme overload)
    ///
    /// When CTL < 3.2 (no training history):
    ///   Pure strain-based: any load is novel, readiness drops fast.
    ///   readiness = max(10, 100 - totalLoad × 0.5)
    ///
    /// ### 3. ACWR modifier (load spike detection)
    ///
    /// Above 1.3: graded penalty for acute spikes independent of capacity ratio,
    /// scaled down at low CTL and capped when the recovery score is high.
    /// At or below 1.3 there is no penalty — including below 0.8, where short
    /// rest periods are recovery, not detraining (Impellizzeri et al. 2020,
    /// Coyne et al. 2018).
    ///
    /// ### 4. Fatigue dissipation bonus (intra-day)
    ///
    /// On rest days where ATL has dropped since morning, each ATL unit of
    /// dissipation = 1.5 readiness points. Capped at 20.
    ///
    /// ### 5. Recovery modulation
    ///
    /// When the model reads ABOVE the recovery score, only part of the excess
    /// is kept: result = recovery + gap × trust, where
    /// trust = min(CTL / 40, 1) × 0.55. So:
    ///   CTL=0  → recovery score (no excess kept)
    ///   CTL=20 → recovery + 27.5% of the gap
    ///   CTL≥40 → recovery + 55% of the gap (the ceiling)
    /// When the model reads BELOW recovery, 30% of the gap is given back
    /// toward the recovery score.
    ///
    /// References:
    /// - Banister et al. (1975): Modeling human performance in running. J Appl Physiol.
    /// - Morton et al. (1990): Modeling human performance in running. J Appl Physiol.
    /// - Busso (2003): Variable dose-response relationship. Med Sci Sports Exerc.
    /// - Stanley et al. (2013): Cardiac parasympathetic reactivation following exercise. Sports Med.
    /// - Gabbett (2016): The training-injury prevention paradox. Br J Sports Med.
    /// - Hulin et al. (2014, 2016): Acute workload spikes and injury risk.
    /// - Foster (1998): Monitoring training in athletes with reference to overtraining syndrome.
    ///
    /// - Parameters:
    ///   - recoveryScore: Morning recovery score (0-100). Modulates readiness via asymmetric blending
    ///     (soft ceiling when model overestimates, conservative uplift when model underestimates).
    ///   - todayTrimp: Today's accumulated TRIMP from HealthKit workouts
    ///   - ctl: Chronic Training Load (42-day EWMA) — "fitness"
    ///   - atl: Current (live) Acute Training Load — "fatigue"
    ///   - morningATL: ATL frozen at the time of the morning HRV reading
    ///   - acuteChronicRatio: ATL/CTL ratio, optional
    ///   - recentWorkoutLoads: Workouts from the last 72h with hours-ago and TRIMP.
    ///     When provided, enables smooth exponential fatigue decay instead of flat same-day penalty.
    /// - Returns: Training readiness score 0-100. A non-finite result (a NaN
    ///   or infinite input) degrades to the midpoint, the same fallback
    ///   `tenScaleClamped` uses, never to 100.
    static func calculateReadiness(
        recoveryScore: Double,
        todayTrimp: Double,
        ctl: Double,
        atl: Double = 0,
        morningATL: Double? = nil,
        acuteChronicRatio: Double? = nil,
        recentWorkoutLoads: [WorkoutLoad]? = nil
    ) -> Double {
        let (acuteFatigue, rawAcuteFatigue) = computeAcuteFatigue(
            todayTrimp: todayTrimp, recentWorkoutLoads: recentWorkoutLoads
        )

        var readiness = computeBaseReadiness(
            ctl: ctl, atl: atl, acuteFatigue: acuteFatigue, rawAcuteFatigue: rawAcuteFatigue
        )

        readiness = applyACWRModifier(
            readiness,
            acuteChronicRatio: acuteChronicRatio,
            ctl: ctl,
            recoveryScore: recoveryScore
        )
        readiness = applyFreshnessBonus(readiness, morningATL: morningATL, atl: atl)
        readiness = applyRecoveryModulation(readiness, recoveryScore: recoveryScore, ctl: ctl)

        // `min(100, .nan)` is 100, so a NaN must be caught before the clamp.
        guard readiness.isFinite else { return 50 }
        return max(0, min(100, readiness))
    }

    // MARK: - Readiness Helpers

    /// Compute acute fatigue from recent workouts or today's TRIMP fallback.
    private static func computeAcuteFatigue(
        todayTrimp: Double,
        recentWorkoutLoads: [WorkoutLoad]?
    ) -> (scaled: Double, raw: Double) {
        if let loads = recentWorkoutLoads, !loads.isEmpty {
            let tauHours = RecoveryScoreConstants.Readiness.acuteFatigueTauHours
            let raw = loads.reduce(0.0) { sum, load in
                sum + load.trimp * exp(-load.hoursAgo / tauHours)
            }
            return (raw * RecoveryScoreConstants.Readiness.acuteFatigueCoefficient, raw)
        }
        return (todayTrimp * RecoveryScoreConstants.Readiness.acuteFatigueFallbackCoefficient, todayTrimp)
    }

    /// Compute base readiness from capacity ratio (CTL >= threshold) or novel load model.
    private static func computeBaseReadiness(
        ctl: Double, atl: Double, acuteFatigue: Double, rawAcuteFatigue: Double
    ) -> Double {
        let effectiveLoad = atl + acuteFatigue

        guard ctl >= RecoveryScoreConstants.Readiness.ctlThreshold else {
            let totalLoad = atl + rawAcuteFatigue
            return max(
                RecoveryScoreConstants.Readiness.readinessFloor,
                RecoveryScoreConstants.Readiness.readinessAtZero - totalLoad * RecoveryScoreConstants.Readiness.novelLoadStrainCoefficient
            )
        }

        return mapCapacityRatioToReadiness(effectiveLoad / ctl)
    }

    /// Piecewise linear mapping: capacity ratio -> readiness (0-100).
    private static func mapCapacityRatioToReadiness(_ capacityRatio: Double) -> Double {
        let r = RecoveryScoreConstants.Readiness.self
        let breakpoints: [(ratio: Double, readiness: Double)] = [
            (0.0, r.readinessAtZero),
            (r.capacityRatioBreak1, r.readinessAtBreak1),
            (r.capacityRatioBreak2, r.readinessAtBreak2),
            (r.capacityRatioBreak3, r.readinessAtBreak3),
            (r.capacityRatioBreak4, r.readinessAtBreak4),
            (r.capacityRatioBreak5, r.readinessAtBreak5)
        ]
        guard capacityRatio > 0 else { return r.readinessAtZero }

        // empty-range-ok: `breakpoints` is a literal table declared just above
        // with a fixed set of entries; it cannot be empty.
        for i in 1 ..< breakpoints.count where capacityRatio <= breakpoints[i].ratio {
            let prev = breakpoints[i - 1]
            let curr = breakpoints[i]
            let t = (capacityRatio - prev.ratio) / (curr.ratio - prev.ratio)
            return prev.readiness - t * (prev.readiness - curr.readiness)
        }
        return r.readinessAtBreak5
    }

    /// ACWR modifier: damp readiness when recent load has jumped sharply
    /// relative to the chronic base (ACWR > 1.3).
    ///
    /// This is NOT a "dangerous load spike" / injury-risk detector, and is
    /// not described as one. "Above 1.3 is hazardous" is not a separate
    /// finding that survives Impellizzeri — 1.3 is one edge of the very band
    /// those papers dismantled, and this file's own doc comment (below) cites
    /// them to reject the OTHER edge at 0.8.
    ///
    /// Note for the Help Center: the ratio does not feed the Recovery Score
    /// (`ScoringWeights` has no training term), but it is NOT inert — this
    /// function multiplies READINESS, which the user reads as a verdict.
    ///
    /// The damper is kept because it is heavily dampened already (see below),
    /// and removing it would change every user's readiness on no better
    /// evidence than it was added with. It is described as what it is — a
    /// conservative response to an abrupt change in workload, on the general
    /// principle that bodies absorb gradual change better than abrupt change.
    ///
    /// The detraining penalty (ACWR < 0.8) has been removed. Multiple
    /// meta-analyses found no evidence for the 0.8-1.3 "sweet spot"
    /// (Impellizzeri et al. 2020, Coyne et al. 2018, BJSM 2021 editorial).
    /// ACWR < 0.8 during short rest periods (2-7 days) reflects normal
    /// recovery, not detraining. Real detraining risk comes from rapid
    /// reloading after extended breaks (2+ weeks), which is better
    /// detected via CTL trend monitoring.
    ///
    /// Two dampeners stop ACWR from steamrolling
    /// the readout when the underlying ratio is unreliable or other
    /// signals contradict it:
    ///
    ///   1. **Low-CTL confidence ramp.** Gabbett's ACWR research was on
    ///      pro athletes with CTL 60–90. At CTL=16 a single 40-TRIMP
    ///      walk swings the ratio by ~0.2 — the signal is mathematically
    ///      noisy. Confidence ramps linearly from 0 (CTL=0) to 1.0
    ///      (CTL ≥ 50). Penalty is multiplied by confidence.
    ///   2. **Autonomic-state rescue.** When the user's overall
    ///      recovery score is high (HRV/PNS clearly say "recovered"),
    ///      cap the ACWR penalty at a low ceiling. ACWR is an
    ///      indirect bookkeeping proxy; HRV is the direct
    ///      physiological measurement. The proxy shouldn't override
    ///      the measurement when they disagree on a clearly-recovered
    ///      morning.
    ///
    /// Real tester case: CTL=16, ACWR=1.63 undampened produces
    /// a 21.5% raw penalty, dragging readiness to 3.6/10 "Fatigued"
    /// while the HRV-Readiness pill simultaneously shows 10.0/10 "Ready".
    /// With the dampeners: confidence factor = 16/50 = 0.32,
    /// recovery score 73 → autonomic cap engages, effective penalty
    /// shrinks to ~0.07 (7% reduction instead of 21.5%).
    private static func applyACWRModifier(
        _ readiness: Double,
        acuteChronicRatio: Double?,
        ctl: Double,
        recoveryScore: Double
    ) -> Double {
        guard let acr = acuteChronicRatio,
              acr > RecoveryScoreConstants.Readiness.acwrOverreachingThreshold
        else { return readiness } // No penalty at or below 1.3 — see doc comment.
        return readiness * (1.0 - dampenedACWRPenalty(acr: acr, ctl: ctl, recoveryScore: recoveryScore))
    }

    /// The raw overreaching penalty, scaled by the low-CTL confidence ramp and
    /// capped by the autonomic-state rescue — see `applyACWRModifier`.
    /// `internal` rather than `private` so it can be tested directly.
    /// The dampener is a fix for a named user-facing bug
    /// (tester report: CTL 16 / ACWR 1.63 read "Fatigued" while the
    /// HRV pill read "Ready") and a mutation can delete it with a green suite.
    /// It cannot be isolated through `calculateReadiness`, because
    /// `applyRecoveryModulation` runs afterwards and its `modelTrust` term is
    /// ALSO CTL-dependent and larger — so a test that goes through the public
    /// entry point measures the wrong thing. Testing the unit directly is the
    /// only way to pin the unit.
    static func dampenedACWRPenalty(acr: Double, ctl: Double, recoveryScore: Double) -> Double {
        let r = RecoveryScoreConstants.Readiness.self
        let excess = acr - r.acwrOverreachingThreshold
        var penaltyPct = min(
            r.acwrOverreachingPenaltyBase + excess * r.acwrOverreachingPenaltySlope,
            r.acwrOverreachingPenaltyCap
        )
        // Low-CTL confidence ramp: 0 at CTL=0, 1.0 at CTL >= 50.
        penaltyPct *= min(max(ctl, 0) / r.acwrFullConfidenceCTL, 1.0)
        // Autonomic-state rescue: when the user is clearly recovered, cap the
        // penalty so the proxy doesn't override the direct HRV signal.
        if recoveryScore >= r.acwrRescueRecoveryThreshold {
            penaltyPct = min(penaltyPct, r.acwrPenaltyAutonomicRescueCap)
        }
        return penaltyPct
    }

    /// Fatigue dissipation bonus: each ATL unit drop since morning = 1.5 readiness points, capped at 20.
    /// `internal` for the same reason as `dampenedACWRPenalty`: the cap is
    /// invisible from `calculateReadiness` because the recovery-modulation
    /// stage rescales the result afterwards, so removing the cap left the
    /// suite green until it was tested directly.
    static func applyFreshnessBonus(_ readiness: Double, morningATL: Double?, atl: Double) -> Double {
        guard let morningATL, morningATL > 0 else { return readiness }
        let atlDrop = max(0, morningATL - atl)
        let freshnessGain = min(atlDrop * RecoveryScoreConstants.Readiness.freshnessGainMultiplier, RecoveryScoreConstants.Readiness.freshnessGainCap)
        return readiness + freshnessGain
    }

    /// Recovery modulation: asymmetric blending with HRV-based recovery score.
    private static func applyRecoveryModulation(_ readiness: Double, recoveryScore: Double, ctl: Double) -> Double {
        if readiness > recoveryScore {
            let gap = readiness - recoveryScore
            let modelTrust = min(max(ctl, 0) / RecoveryScoreConstants.Readiness.modelTrustDivisor, 1.0) * RecoveryScoreConstants.Readiness.modelTrustCeiling
            return recoveryScore + gap * modelTrust
        } else if readiness < recoveryScore {
            let gap = recoveryScore - readiness
            return readiness + gap * RecoveryScoreConstants.Readiness.recoveryUpliftFraction
        }
        return readiness
    }

    /// The readiness band as a stable English identifier ("Ready",
    /// "Moderate", "Fatigued", "Rest") that code switches on
    /// (`PostExerciseCopy`). Screens show `displayReadinessLabel(for:)`.
    ///
    /// Expects 0-10 scale input, but "expects" is not enough of a contract:
    /// `calculateReadiness` returns 0-100, so a caller that forgets
    /// `toTenScale` would get "Ready" for every value at or above 7 out of
    /// 100. Every call site converts first, so this is a latent trap rather
    /// than a live defect — but the signature invites it.
    ///
    /// The input is clamped to its documented domain, so an un-converted
    /// 0-100 value cannot masquerade as a maximal 0-10 one, and the
    /// thresholds are pinned by `ReadinessCalculationTests`.
    static func readinessLabel(for score: Double) -> String {
        let s = tenScaleClamped(score)
        if s >= RecoveryScoreConstants.ReadinessLabels.readyThreshold { return "Ready" }
        if s >= RecoveryScoreConstants.ReadinessLabels.moderateThreshold { return "Moderate" }
        if s >= RecoveryScoreConstants.ReadinessLabels.fatiguedThreshold { return "Fatigued" }
        return "Rest"
    }

    /// The band, held to "Moderate" when the training advice gate says to
    /// ease off, so the label never reads "Ready" beside a message that
    /// asks for a lighter session. The number and the zone bar are the
    /// score's; only the word follows the advice.
    static func readinessLabel(for score: Double, load: TrainingAdviceGate.Load?) -> String {
        let label = readinessLabel(for: score)
        guard label == "Ready", TrainingAdviceGate.level(load) == .easier else { return label }
        return "Moderate"
    }

    /// `readinessLabel(for:)` in `NarrativeLanguage`.
    static func displayReadinessLabel(for score: Double) -> String {
        displayLabel(readinessLabel(for: score))
    }

    /// `readinessLabel(for:load:)` in `NarrativeLanguage`.
    static func displayReadinessLabel(for score: Double, load: TrainingAdviceGate.Load?) -> String {
        displayLabel(readinessLabel(for: score, load: load))
    }

    private static func displayLabel(_ label: String) -> String {
        switch label {
        case "Ready": String(localized: "Ready", bundle: NarrativeLanguage.bundle)
        case "Moderate": String(localized: "Moderate", bundle: NarrativeLanguage.bundle)
        case "Fatigued": String(localized: "Fatigued", bundle: NarrativeLanguage.bundle)
        default: String(localized: "Rest", bundle: NarrativeLanguage.bundle)
        }
    }

    /// Clamp a value onto the 0...10 readiness display scale.
    /// Non-finite degrades to the midpoint rather than to "Ready".
    static func tenScaleClamped(_ score: Double) -> Double {
        guard score.isFinite else { return RecoveryScoreConstants.ReadinessLabels.tenScaleMax / 2 }
        return min(RecoveryScoreConstants.ReadinessLabels.tenScaleMax, max(0, score))
    }

    /// Short coaching message based on readiness level (expects 0-10 scale
    /// input), in `NarrativeLanguage`.
    ///
    /// Does not surface the literal ACWR number in the
    /// coaching copy. ACWR is a sports-science term, not user-friendly,
    /// and per Impellizzeri 2020/2021 the ratio's signal value is weaker
    /// than the original Gabbett framing claimed. The function still
    /// consults the ratio to decide messaging; the display string
    /// describes the state rather than exposing the raw number.
    static func readinessMessage(for rawReadiness: Double, acuteChronicRatio: Double? = nil) -> String {
        readinessMessage(for: rawReadiness, load: acuteChronicRatio.map { TrainingAdviceGate.Load(acwr: $0) })
    }

    /// The message with the whole load the training advice gate reads: the
    /// ratio (trusted once the chronic load is established), the form and
    /// the monotony. A load reason always outranks the score's message.
    static func readinessMessage(for rawReadiness: Double, load: TrainingAdviceGate.Load?) -> String {
        if let loadMessage = recentLoadMessage(TrainingAdviceGate.assess(load), acwr: load?.acwr) { return loadMessage }
        // Same 0-10 domain as `readinessLabel`, clamped for the same reason.
        let readiness = tenScaleClamped(rawReadiness)
        if readiness >= RecoveryScoreConstants.ReadinessLabels.highCapacity {
            return String(localized: "Well within your capacity — great day for intense training", bundle: NarrativeLanguage.bundle)
        }
        if readiness >= RecoveryScoreConstants.ReadinessLabels.goodCapacity {
            return String(localized: "Good capacity available — you can push today", bundle: NarrativeLanguage.bundle)
        }
        if readiness >= RecoveryScoreConstants.ReadinessLabels.moderateCapacity {
            return String(localized: "Moderate load relative to your fitness — adjust intensity as needed", bundle: NarrativeLanguage.bundle)
        }
        if readiness >= RecoveryScoreConstants.ReadinessLabels.significantFatigue {
            return String(localized: "Carrying significant fatigue — consider a lighter session", bundle: NarrativeLanguage.bundle)
        }
        return String(localized: "Load is high relative to your fitness — prioritize recovery", bundle: NarrativeLanguage.bundle)
    }

    /// When the gate finds a load reason, that is surfaced as observational
    /// context — without the raw ACWR number or risk-prediction language.
    /// A ratio past `acwrSevere` asks for recovery outright. Nil when the
    /// load is clear.
    private static func recentLoadMessage(_ assessment: TrainingAdviceGate.Assessment, acwr: Double?) -> String? {
        if assessment.reasons.contains(.sharpIncrease), let acr = acwr, acr > RecoveryScoreConstants.ReadinessLabels.acwrSevere {
            return String(localized: "Recent load is well above your usual range — prioritize recovery today.", bundle: NarrativeLanguage.bundle)
        }
        return assessment.reasonLine(bundle: NarrativeLanguage.bundle)
    }
}
