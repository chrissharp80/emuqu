import Foundation

// MARK: - Daily Loop Analysis
//
// Single source of truth for the "today, in one glance" loop story —
// shared by the Holistic Daily Report PDF and the Dashboard
// "Today's Loop" SwiftUI card. Both consume the same analysis so the
// in-app glance and the downloadable PDF can never drift apart.
//
// Inputs are value-typed snapshots — no live HealthKit, no
// SettingsManager fetch — so an instance can be safely passed across
// actors and rendered on any thread.
//
// The "loop" framing comes from WHOOP's monthly performance assessment
// + Garmin Training Readiness: the integrative judgement is whether
// today's training stress and today's recovery state are moving
// together (adapting) or against each other (high strain). Five
// states cover the cross-product:
//
//                    │  Easy Load    Mid Load    Hard Load
//   ─────────────────┼──────────────────────────────────────
//   High recovery    │  underloading  absorbing   absorbing
//   Mid  recovery    │  sustainable   sustainable sustainable
//   Low  recovery    │  backedOff     highStrain  highStrain
//
// `undetermined` is the cold-start case where there's no overnight
// reading or no baseline yet to anchor the read.

struct DailyLoopAnalysis {
    // MARK: Inputs

    let workoutSession: HRVSession?
    let overnightSession: HRVSession?
    let recentOvernightSessions: [HRVSession]
    let userMaxHR: Int

    // MARK: Loop classification

    enum LoopState {
        /// High recovery, real load — body adapting to the training stimulus.
        case absorbing
        /// High recovery, easy session — capacity for more if planned.
        case underloading
        /// Mid recovery + mid load — balanced rhythm.
        case sustainable
        /// Low recovery, easy session — backed off appropriately.
        case backedOff
        /// Low recovery, hard session — pushing the edge.
        case highStrain
        /// No overnight, no baseline, or no workout — cold-start state.
        case undetermined
    }

    enum IntensityClass { case easy, moderate, hard }

    /// The integrative judgement. Three buckets per axis × cross-product.
    ///
    /// Load-aware guard. Looking only at this morning's HRV vs
    /// baseline and today's
    /// workout intensity fails: with the user at TSB −10 ("Sharp jump") and
    /// a fresh +21 % HRV bounce, the classifier called
    /// `.underloading` ("room to push") — directly contradicting the
    /// Training Load card, which was screaming Sharp jump in the
    /// adjacent row. The HRV bounce is exactly what you'd expect
    /// from a body finally getting space to recover; treating it as
    /// "primed to push" stacks more load on a system that's
    /// absorbing.
    ///
    /// Fix: when TSB ≤ −5 OR ACWR ≥ 1.3 (i.e. the user is genuinely
    /// loaded by the cumulative model), refuse the `.underloading`
    /// verdict no matter how high HRV is today. The body's job today
    /// is absorption; fall back to `.absorbing` (positive, but
    /// reframed as "let the work land" rather than "go again").
    var loopState: LoopState {
        guard workoutSession != nil else { return .undetermined }
        switch (isRecoveryAboveBaseline, isRecoveryBelowBaseline, workoutIntensity) {
        case (true, false, .easy):
            // The single regression class the cumulative-load guard exists for.
            return isCumulativelyLoaded ? .absorbing : .underloading
        case (true, false, .moderate), (true, false, .hard):
            return .absorbing
        case (false, false, _):
            return .sustainable
        case (false, true, .easy):
            return .backedOff
        case (false, true, .moderate), (false, true, .hard):
            return .highStrain
        default:
            return .undetermined
        }
    }

    /// Cumulative-load guard. Reading from the workout's training snapshot keeps
    /// this purely value-typed (no actor hop). The −5 TSB / 1.3 ACWR thresholds
    /// match the values the Tomorrow line uses to nudge an easy/rest day, so the
    /// verdict and the recommendation can't disagree.
    private var isCumulativelyLoaded: Bool {
        let snap = workoutSession?.trainingSnapshot
        if let tsb = snap?.tsb, tsb <= -5 { return true }
        if let acwr = snap?.acuteChronicRatio, acwr >= 1.3 { return true }
        return false
    }

    /// One-word label + supporting blurb. Used for the hero badge.
    var verdict: (label: String, blurb: String) {
        switch loopState {
        case .absorbing:
            absorbingVerdict
        case .underloading:
            ("Underloading — room to push",
             "HRV came in above baseline and today's session was easy. Body's primed for a quality session if your plan calls for one.")
        case .sustainable:
            ("Sustainable rhythm",
             "Recovery and load are in balance. Body's keeping up with the training stimulus — keep going.")
        case .backedOff:
            ("Wisely backed off",
             "Recovery was below baseline and you kept it light. That's the right call — let the autonomic system catch up before the next quality session.")
        case .highStrain:
            ("Pushing the edge",
             "Recovery came in low and you trained hard anyway. One day is fine; if this pattern repeats for 3+ days, you're stacking load on top of accumulated fatigue — listen to your body.")
        case .undetermined:
            ("Not enough data yet",
             "Need a few more sessions of overnight HRV, or a workout today, to call the loop.")
        }
    }

    /// Split the `.absorbing` copy by today's intensity. When today
    /// was actually hard, the "you put real work into the system" line
    /// lands. When we're in this state because cumulative load (TSB / ACWR)
    /// tipped us out of `.underloading` despite an easy day, the body is
    /// absorbing PAST work, not today's — calling an easy walk "real work" was
    /// the user-visible bug.
    private var absorbingVerdict: (label: String, blurb: String) {
        guard workoutIntensity == .easy else {
            return ("Absorbing the load",
                    "Strong morning recovery and you put real work into the system. Body's adapting — this is what training looks like when it's working.")
        }
        return ("Absorbing the load",
                "HRV came in above baseline because the body needed it — your acute load is still elevated against your fitness. Today's easy session was the right call. Let the past work land before adding more.")
    }

    /// Color-bucket for tinting the hero / badge / accents. Caller maps
    /// to the platform-specific color value (UIColor for PDF, Color for
    /// SwiftUI). Three buckets keep the visual vocabulary tight.
    enum VerdictTone { case positive, neutral, caution }
    var verdictTone: VerdictTone {
        switch loopState {
        case .absorbing, .underloading, .sustainable: return .positive
        case .backedOff: return .neutral
        case .highStrain: return .caution
        case .undetermined: return .neutral
        }
    }

    // MARK: Workout intensity

    /// α1 + peak HR fused classification. Mirrors the verdict logic in
    /// WorkoutPDFReport but isolated here so the SwiftUI card and the
    /// PDF can't disagree.
    var workoutIntensity: IntensityClass {
        guard let meta = workoutSession?.workoutMetadata else { return .easy }
        let alphas = (meta.samples ?? []).compactMap(\.alpha1)
        let avgAlpha = alphas.isEmpty ? nil : alphas.reduce(0, +) / Double(alphas.count)
        let peakHR = meta.samples?.compactMap { $0.heartRate }.max()
        let pctMax = peakHR.map { Double($0) / Double(userMaxHR) } ?? 0
        if let a = avgAlpha, a >= 0.75, pctMax < 0.75 { return .easy }
        if let a = avgAlpha, a < 0.50 { return .hard }
        if pctMax >= 0.85 { return .hard }
        if pctMax >= 0.70 { return .moderate }
        return .easy
    }

    // MARK: Recovery vs baseline

    // Uses the log / Smallest-Worthwhile-Change method
    // the recovery score itself uses (Plews et al. 2013; Buchheit 2014; the
    // same method as BaselineTracker + HRVDetailV2View). RMSSD is
    // log-normally distributed, so an ARITHMETIC mean of raw RMSSD
    // plus a fixed ±5% threshold is statistically wrong on two counts: the
    // arithmetic mean is biased upward, and a raw percentage ignores the
    // person's own day-to-day variability. That mismatch is exactly why the
    // card could announce "85% above baseline" while the recovery score —
    // which compares ln(RMSSD) to the geometric baseline in units of SD and
    // treats ±0.5 SD as "no meaningful change" (the SWC deadband) — scored HRV
    // as neutral. Both now use the same geometric baseline and the same
    // ±0.5 SD SWC boundary, so the narrative and the score can't contradict.

    /// Smallest Worthwhile Change: a morning is only "above"/"below" baseline
    /// once it exceeds ±0.5 SD of ln(RMSSD). Matches the recovery score's
    /// deadband (scoringParametersV2: z ∈ [-0.5, +0.5] → flat 72).
    private static let swcSDMultiple = 0.5

    /// ln(RMSSD) baseline (mean + sample SD) over the recent overnight
    /// sessions, EXCLUDING today's reading — a reading is never compared to a
    /// baseline that contains it. At least 3 readings required.
    ///
    /// The SD floor AND the estimator must be `BaselineTracker`'s, not a
    /// local copy: a local floor drifts (10x too small is the observed size),
    /// and a plain sample SD ignores the sqrt(7/n) widening `BaselineTracker`
    /// applies below a seven-night window (see `widenedLnSD`). With three
    /// nights the z-scores differ by 1.53x, so this surface and the recovery
    /// score disagree about whether the morning was below baseline — while
    /// the doc comment on `hrvZScore` says they cannot. Both call the same
    /// function, which is the only way this stays true.
    private var lnRmssdBaseline: (mean: Double, sd: Double)? {
        let todayId = overnightSession?.id
        // Exclude untrustworthy-HRV sessions from this ln(RMSSD)
        // baseline (mirrors BaselineTracker). Callers already pre-filter, but
        // gate here too so this parallel baseline can't drift from the app's.
        let lnValues = recentOvernightSessions
            .filter { $0.id != todayId && $0.isReliableForHRVAggregates }
            .compactMap { $0.rmssd }
            .filter { $0 > 0 }
            .map { log($0) }
        guard lnValues.count >= 3 else { return nil }
        let mean = lnValues.reduce(0, +) / Double(lnValues.count)
        let sd = max(BaselineTracker.widenedLnSD(lnValues), BaselineConstants.lnRmssdSDFloor)
        return (mean, sd)
    }

    /// Geometric baseline RMSSD = exp(mean of ln(RMSSD)) — the correct central
    /// tendency for log-normal RMSSD, and the same value the recovery score and
    /// HRV detail view compare against.
    var recoveryBaselineRMSSD: Double? {
        lnRmssdBaseline.map { exp($0.mean) }
    }

    /// z-score of today's ln(RMSSD) against the log baseline — the exact
    /// quantity the recovery score's HRV factor is built from.
    var hrvZScore: Double? {
        guard let today = overnightSession?.rmssd, today > 0,
              let b = lnRmssdBaseline
        else { return nil }
        return (log(today) - b.mean) / b.sd
    }

    var isRecoveryAboveBaseline: Bool {
        guard let z = hrvZScore else { return false }
        return z >= Self.swcSDMultiple
    }

    var isRecoveryBelowBaseline: Bool {
        guard let z = hrvZScore else { return false }
        return z <= -Self.swcSDMultiple
    }

    /// HRV delta as a percentage versus the geometric baseline — positive =
    /// above, negative = below. Nil when no baseline exists. Used only for the
    /// narrative readout; the above/below CLASSIFICATION uses the SWC z-band so
    /// it can't disagree with the score.
    var hrvPercentVsBaseline: Double? {
        guard let today = overnightSession?.rmssd, today > 0,
              let baseline = recoveryBaselineRMSSD, baseline > 0
        else { return nil }
        return (today / baseline - 1) * 100
    }

    // MARK: The Loop paragraph + Tomorrow line

    /// Cause-and-effect prose: connects this morning's recovery to
    /// today's training output and explains why the combination
    /// matters. Used in both the PDF Page 1 "THE LOOP" section and
    /// the SwiftUI card (collapsed/expanded variants).
    var loopParagraph: String {
        openingLine + " " + loopExplanation
    }

    /// What the morning reading and the day's session were, in one sentence.
    private var openingLine: String {
        let trimp = workoutSession?.workoutMetadata?.luciaTRIMP.map { Int($0.rounded()) } ?? 0
        return hrvOpening + "and you put \(trimp) TRIMP into the system on \(intensityWord)."
    }

    private var intensityWord: String {
        switch workoutIntensity {
        case .easy: "an easy aerobic session"
        case .moderate: "a moderate-intensity session"
        case .hard: "a hard session"
        }
    }

    /// A move smaller than the Smallest Worthwhile Change isn't meaningful — and
    /// it's the exact band the recovery score treats as neutral — so say that
    /// instead of quoting a percentage the score won't act on.
    private var hrvOpening: String {
        if let z = hrvZScore, let pct = hrvPercentVsBaseline {
            guard abs(z) >= Self.swcSDMultiple else {
                return "Your HRV was in line with your baseline this morning, "
            }
            let dir = pct >= 0 ? "above" : "below"
            return "Your HRV came in \(abs(Int(pct.rounded())))% \(dir) baseline this morning, "
        }
        if let rmssd = overnightSession?.rmssd {
            return "Your HRV came in at \(Int(rmssd.rounded())) ms this morning, "
        }
        return "Without a morning HRV reading, "
    }

    /// What that combination means, per loop state.
    private var loopExplanation: String {
        switch loopState {
        case .absorbing:
            workoutIntensity == .easy
                ? "That HRV bounce is the body finally getting room — your acute load is still riding above fitness. Today's easy day was right; absorption matters more than another stimulus when you're in this zone."
                : "That combination — high recovery + real training stress — is what adaptation looks like. The autonomic system was ready, the body absorbed the load, and you'll come out the other side fitter."
        case .underloading:
            "You had the budget for more. Not a problem — recovery is still recovery — but if your plan calls for a hard day soon, today is a green light."
        case .sustainable:
            "Recovery and load are tracking together — neither outpacing the other. This is the steady-state rhythm that produces fitness over months without breakdown."
        case .backedOff:
            "You read the signal correctly. When morning HRV is below baseline, an easy day buys back the autonomic capacity needed for the next quality session."
        case .highStrain:
            "One day with this combination is fine — fitness sometimes wins on willpower. Repeated, it stops being adaptation and starts being damage. Watch your training-load chart and HRV trend over the next 2-3 days."
        case .undetermined:
            "Train today as planned. The loop story sharpens once a baseline of overnight readings is in place."
        }
    }

    /// Tomorrow's prescription. Specific actions only — no generic
    /// "rest" or "listen to your body" lines.
    var tomorrowAction: String {
        let snap = workoutSession?.trainingSnapshot
        let tsb = snap?.tsb
        if let acwr = snap?.acuteChronicRatio, acwr >= 1.5 {
            return "Recent training is well above your usual range. Easy day or full rest tomorrow regardless of how recovery looks — the heavier-than-usual load needs absorption time."
        }
        switch loopState {
        case .absorbing:
            return absorbingAction(tsb: tsb)
        case .underloading:
            return underloadingAction(tsb: tsb)
        case .sustainable:
            return "Train as planned. Steady rhythm is producing fitness — don't disrupt it for novelty."
        case .backedOff:
            return "Another easy day or active recovery — let HRV climb back to baseline before the next quality session."
        case .highStrain:
            return "Easy 30-45 min Z2 or full rest. Skip the next interval session until HRV recovers — pattern protection matters more than today's planned session."
        case .undetermined:
            return "Train as planned. Once a few overnight readings build up, this section will get more specific."
        }
    }

    private func underloadingAction(tsb: Double?) -> String {
        if let tsb, tsb > 5 {
            return "TSB is \(String(format: "%+.0f", tsb)) and recovery is strong — open window for intervals or a long aerobic session."
        }
        return "Window for a quality session if your plan calls for one. Otherwise easy aerobic to bank volume."
    }

    private func absorbingAction(tsb: Double?) -> String {
        guard workoutIntensity == .easy else {
            return "Quality session tomorrow if planned, or easy 30-45 min Z2 — both are sustainable from here."
        }
        if let tsb, tsb <= -5 {
            return "TSB is \(String(format: "%+.0f", tsb)) — body's still digesting recent load. Easy 30-45 min Z2 or rest tomorrow; save the next quality session for when TSB climbs back toward zero."
        }
        return "Easy aerobic or rest tomorrow — the recent load is still being absorbed. Hold off on a quality session until acute load eases."
    }
}
