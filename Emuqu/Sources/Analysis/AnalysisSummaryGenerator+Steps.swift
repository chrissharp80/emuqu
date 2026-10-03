//
//  AnalysisSummaryGenerator+Steps.swift
//  Emuqu
//
//  The "what to do about it" half of the morning summary: actionable steps,
//  tag-specific advice, and the post-exercise readouts. Split out of
//  AnalysisSummaryGenerator+Interpretation, which had crossed
//  1000 lines.
//

import Foundation

extension AnalysisSummaryGenerator {
    // MARK: - Actionable Steps

    // When current readiness is significantly below the morning recovery score
    // AND there was meaningful exercise today, the morning tips are stale.
    // Replace them with post-exercise recovery guidance. This needs the caller
    // to pass `currentReadiness` and `todayTrimp`; without them (nil / 0) the
    // morning steps always show.
    //
    // The todayTrimp gate (>= 20) prevents false triggers when the readiness-
    // vs-recovery gap comes from accumulated training load rather than a
    // same-day workout. Without this, users who just woke up with high ATL
    // would see "Good effort today" despite not having exercised.
    var actionableSteps: [String] {
        let score = computeDiagnosticScore()
        if let readiness = currentReadiness, score >= HRVThresholds.scoreAdequateRecovery, readiness < score - 15, todayTrimp >= 20 {
            return postExerciseSteps(readiness: readiness, recoveryScore: score)
        }
        var steps: [String] = []
        let gates = pushGates()
        appendTrendSteps(&steps, score: score, gates: gates)
        appendTrainingLoadSteps(&steps)
        appendScoreSteps(&steps, score: score, gates: gates)
        appendFeelingSteps(&steps, score: score)
        return steps
    }

    /// The signals that decide whether "push today" is safe advice.
    struct PushGates {
        let rmssd: Double
        let stress: Double
        let lfhf: Double
        let dfa: Double
        let isShortSleep: Bool
        let isGoodSleep: Bool
        let isFragmented: Bool
        let sleepFormatted: String
        let isConsolidated: Bool
        let shouldNotPush: Bool
        let cumulativeLoadElevated: Bool
        let hasUnstableWindow: Bool
        let hasFatigueSignal: Bool
        let hasSympatheticDominance: Bool
        let hasStrongVagalTone: Bool
    }

    private func pushGates() -> PushGates {
        let signals = hrvSignals()
        let shouldNotPush = sleep.isShortSleep || signals.hasUnstableWindow
            || signals.hasFatigueSignal || signals.hasSympatheticDominance || !isConsolidatedWindow
        return PushGates(
            rmssd: signals.rmssd,
            stress: signals.stress,
            lfhf: signals.lfhf,
            dfa: signals.dfa,
            isShortSleep: sleep.isShortSleep,
            isGoodSleep: sleep.isGoodSleep,
            isFragmented: sleep.isFragmented,
            sleepFormatted: sleep.totalSleepFormatted,
            isConsolidated: isConsolidatedWindow,
            shouldNotPush: shouldNotPush,
            cumulativeLoadElevated: cumulativeLoadIsElevated(),
            hasUnstableWindow: signals.hasUnstableWindow,
            hasFatigueSignal: signals.hasFatigueSignal,
            hasSympatheticDominance: signals.hasSympatheticDominance,
            hasStrongVagalTone: signals.hasStrongVagalTone
        )
    }

    // CRITICAL: Distinguish between capacity (high HRV) and consolidated readiness (sustained + stable)
    // Only "push" recommendations should be given when recovery is CONSOLIDATED
    // High HRV alone represents MAX CAPACITY, not necessarily readiness
    //
    // A window is consolidated if: (1) it passed persistence/plateau check, AND (2) CV < 8%
    // This is computed in WindowSelector and propagated via isConsolidated
    private var isConsolidatedWindow: Bool {
        result.isConsolidated ?? false
    }

    /// Raw autonomic signals, before any recommendation gating.
    struct HRVSignals {
        let rmssd: Double
        let stress: Double
        let lfhf: Double
        let dfa: Double
        let hasStrongVagalTone: Bool
        let hasUnstableWindow: Bool
        let hasFatigueSignal: Bool
        let hasSympatheticDominance: Bool
    }

    // Additional gates for "push" recommendations:
    // - windowCV > 0.08 (8%) indicates unstable HR during analysis window
    // - dfaAlpha1 > 1.35 indicates clear fatigue (1.2-1.35 is borderline — not a gate when vagal tone is strong)
    // - lfhf > 3.0 with weak vagal tone indicates strong sympathetic activation
    private func hrvSignals() -> HRVSignals {
        let rmssd = result.timeDomain.rmssd
        let stress = result.ansMetrics?.stressIndex ?? 150
        let lfhf = result.frequencyDomain?.lfHfRatio ?? 1.0
        let dfa = result.nonlinear.dfaAlpha1 ?? 1.0
        let windowCV = result.windowHRStability ?? 0.0
        let hasStrongVagalTone = result.timeDomain.pnn50 > HRVThresholds.pnn50Moderate && rmssd >= HRVThresholds.rmssdModerate
        let hasUnstableWindow = windowCV > HRVThresholds.windowUnstableCVThreshold
        let hasFatigueSignal = hasStrongVagalTone ? dfa > HRVThresholds.dfaAlpha1ClearlyElevated : dfa > HRVThresholds.dfaAlpha1Fatigue
        let hasSympatheticDominance = hasStrongVagalTone ? false : lfhf > HRVThresholds.lfHfSympatheticDominance
        return HRVSignals(
            rmssd: rmssd,
            stress: stress,
            lfhf: lfhf,
            dfa: dfa,
            hasStrongVagalTone: hasStrongVagalTone,
            hasUnstableWindow: hasUnstableWindow,
            hasFatigueSignal: hasFatigueSignal,
            hasSympatheticDominance: hasSympatheticDominance
        )
    }

    // Cumulative-load gate. The morning-HRV signals
    // above describe TODAY'S autonomic state. They do not see what
    // the user has done in the past week. With ACWR 1.99 (acute load
    // nearly double chronic), telling a user "great day to push
    // yourself" is reckless regardless of how good today's HRV looks
    // — the body's job is to absorb, not stack more on. Gabbett 2016
    // marks ACWR ≥ 1.5 as the spike-injury threshold; Impellizzeri
    // 2020/2021 weakens the predictive claim but doesn't make
    // ignoring acute spikes safe. TSB ≤ −15 is the same picture in
    // CTL−ATL form. Either trips the gate.
    //
    // Source = LIVE training load via TrainingLoadRegistry rather
    // than the frozen `result.trainingContext`. The frozen value is
    // captured at session acceptance (excludes today's TRIMP). For
    // a user opening their morning report AFTER a heavy session
    // yesterday or this morning, the frozen value is stale and the
    // gate would underweight current acute load. Live value reflects
    // every archive write since the last cache refresh — exactly
    // the "right now" answer this gate needs to make.
    private func cumulativeLoadIsElevated() -> Bool {
        // Not `MainActor.assumeIsolated { TrainingLoadRegistry.live() }`,
        // which traps from off-main callers (AssistantContextSource
        // async pipeline, PDF render task). The snapshot arrives via
        // init from the caller, who resolves it on MainActor.
        let live = liveLoadSnapshot
        if let acwr = live?.acwr, acwr >= 1.5 { return true }
        if let tsb = live?.tsb, tsb <= -15 { return true }
        // Fall back to frozen training context if live is cold.
        // Worse than live but better than ignoring the dimension.
        let frozen = trainingContext ?? result.trainingContext
        if let acwr = frozen?.acuteChronicRatio, acwr >= 1.5 { return true }
        if let tsb = frozen?.tsb, tsb <= -15 { return true }
        return false
    }

    private func appendTrendSteps(_ steps: inout [String], score: Double, gates: PushGates) {
        // shouldNotPush: any of these signals indicates the HRV represents capacity, not readiness
        // Trend-aware recommendations
        guard stats.hasData else { return }
        let rmssdPct = ((gates.rmssd - stats.avgRMSSD) / stats.avgRMSSD) * 100

        if let trend = stats.trend7Day, trend > 10 {
            steps.append("Your improving trend suggests your current routine is working well")
        }
        if rmssdPct > 15, score >= 70 {
            appendHighRelativeHRVSteps(&steps, gates: gates)
        }

        if let trend = stats.trend7Day, trend < -10 {
            steps.append("Consider what changed in the past week — sleep, stress, training load?")
        }
    }

    private func appendHighRelativeHRVSteps(_ steps: inout [String], gates: PushGates) {
        guard gates.shouldNotPush else {
            // Consolidated: sustained plateau + stable HR.
            steps.append("This is a great day to push yourself — your recovery pattern held steady through the night")
            return
        }
        appendHighHRVBlockedReason(&steps, gates: gates)
    }

    // High HRV but something blocks the "push" advice. Order the
    // gates so the most safety-critical reason wins the explanation:
    // cumulative-load elevation outranks all the today-only signals,
    // because no amount of "today's HRV looks fine" makes it safe
    // to stack more on top of an already-spiked acute load.
    private func appendHighHRVBlockedReason(_ steps: inout [String], gates: PushGates) {
        let (isShortSleep, isConsolidated) = (gates.isShortSleep, gates.isConsolidated)
        let (cumulativeLoadElevated, hasUnstableWindow) = (gates.cumulativeLoadElevated, gates.hasUnstableWindow)
        let (hasFatigueSignal, hasSympatheticDominance) = (gates.hasFatigueSignal, gates.hasSympatheticDominance)
        if cumulativeLoadElevated {
            steps.append("HRV came in strong, but recent training is well above your usual range — easy or moderate today, save the push for after acute load settles. Hammering a body that's still absorbing risks the spike-injury window.")
        } else if !isConsolidated, !hasUnstableWindow, !hasFatigueSignal, !hasSympatheticDominance, !isShortSleep {
            steps.append("Good HRV shows recovery capacity, but the pattern wasn't sustained — moderate load is safer")
        } else if isShortSleep {
            steps.append("High HRV shows good capacity, but short sleep limits how much load you can handle")
        } else if hasUnstableWindow {
            if sleep.sleepEfficiency >= 90 {
                steps.append("Good HRV with some HR variability during sleep — moderate to high intensity should be fine")
            } else {
                steps.append("Good HRV, but variable HR during sleep suggests recovery wasn't fully consolidated — moderate intensity")
            }
        } else if hasFatigueSignal {
            steps.append("Good HRV numbers, but heart rhythm patterns suggest underlying fatigue — don't overdo it")
        } else if hasSympatheticDominance {
            steps.append("HRV looks good but nervous system is still activated — ease into the day")
        }
    }

    private func appendTrainingLoadSteps(_ steps: inout [String]) {
        // Training load recommendations
        if let training = trainingContext ?? result.trainingContext {
            if let acr = training.acuteChronicRatio, acr < TrainingConstants.ACR.detraining {
                steps.append("Your training load is low — try adding a walk, light jog, or any movement today to rebuild your base")
            } else if training.ctl < RecoveryScoreConstants.Readiness.ctlThreshold, training.atl < RecoveryScoreConstants.Readiness.ctlThreshold {
                steps.append("Even a 20-minute walk will help — your body scores better when it's regularly active")
            }
        }
    }

    private func appendScoreSteps(_ steps: inout [String], score: Double, gates: PushGates) {
        if score >= HRVThresholds.scoreWellRecovered {
            appendWellRecoveredSteps(&steps, gates: gates)
        } else if score >= HRVThresholds.scoreAdequateRecovery {
            appendAdequateRecoverySteps(&steps, gates: gates)
        } else if score >= HRVThresholds.scoreIncompleteRecovery {
            appendIncompleteRecoverySteps(&steps, gates: gates)
        } else {
            appendPoorRecoverySteps(&steps, gates: gates)
        }
    }

    private func appendWellRecoveredSteps(_ steps: inout [String], gates: PushGates) {
        let isGoodSleep = gates.isGoodSleep
        if gates.shouldNotPush {
            appendCapacityWithoutReadinessSteps(&steps, gates: gates)
        } else {
            // Consolidated recovery = safe to push
            steps.append("Great day for high-intensity training or challenging activities")
            steps.append("Your recovery is consolidated — your body can handle physical and mental demands")
            if isGoodSleep {
                steps.append("Good sleep is supporting your recovery — maintain this pattern")
            }
        }
    }

    private func appendCapacityWithoutReadinessSteps(_ steps: inout [String], gates: PushGates) {
        appendBlockedPushReason(&steps, gates: gates)
        // "moderate rather than high intensity" is gated on
        // cumulative load as well as vagal tone / fatigue / sleep,
        // so the user
        // doesn't see "Great score with some HR variability —
        // you're in good shape for moderate to high intensity"
        // alongside a hidden ACWR 1.99.
        if gates.cumulativeLoadElevated || !gates.hasStrongVagalTone || gates.hasFatigueSignal
            || gates.isShortSleep {
            steps.append("Consider moderate activity rather than high intensity")
        }
    }

    // Same priority ordering as the rmssdPct
    // branch above: cumulative-load elevation is the most
    // safety-critical reason to suppress a push and must win
    // the explanation. The "moderate to high intensity"
    // copy below is unsafe at ACWR ≥ 1.5 unless something
    // here looks at acute-vs-chronic load.
    private func appendBlockedPushReason(_ steps: inout [String], gates: PushGates) {
        let (cumulativeLoadElevated, hasUnstableWindow) = (gates.cumulativeLoadElevated, gates.hasUnstableWindow)
        let (hasFatigueSignal, hasSympatheticDominance) = (gates.hasFatigueSignal, gates.hasSympatheticDominance)
        let sleepFormatted = gates.sleepFormatted
        if cumulativeLoadElevated {
            steps.append("Great morning HRV, but recent training is well above your usual range — keep today easy or moderate and let acute load settle before the next quality session.")
        } else if !gates.isConsolidated && !hasUnstableWindow && !hasFatigueSignal && !hasSympatheticDominance {
            steps.append("Excellent recovery capacity detected, but pattern wasn't held long enough for full readiness")
        } else if gates.isShortSleep {
            steps.append("Strong metrics show good capacity, but short sleep (\(sleepFormatted)) is reason to hold something back")
        } else if hasUnstableWindow {
            appendUnstableWindowStep(&steps)
        } else if hasFatigueSignal {
            steps.append("Strong HRV capacity but heart rhythm patterns suggest accumulated fatigue — ease into the day")
        } else if hasSympatheticDominance {
            steps.append("Good recovery capacity but elevated LF/HF ratio — your nervous system is still activated")
        }
    }

    private func appendUnstableWindowStep(_ steps: inout [String]) {
        if sleep.sleepEfficiency >= 90 {
            steps.append("Great recovery score with some HR variability — you're in good shape for moderate to high intensity")
        } else {
            steps.append("Good overall score, but variable HR during sleep suggests recovery wasn't fully consolidated")
        }
    }

    private func appendAdequateRecoverySteps(_ steps: inout [String], gates: PushGates) {
        let (isShortSleep, sleepFormatted) = (gates.isShortSleep, gates.sleepFormatted)
        steps.append("Moderate activity is fine — listen to your body")
        if isShortSleep {
            steps.append("Prioritize getting more sleep tonight (\(sleepFormatted) is insufficient)")
        } else {
            steps.append("Stay hydrated and maintain good sleep habits")
        }
    }

    private func appendIncompleteRecoverySteps(_ steps: inout [String], gates: PushGates) {
        let (stress, lfhf) = (gates.stress, gates.lfhf)
        let (isShortSleep, isFragmented) = (gates.isShortSleep, gates.isFragmented)
        let sleepFormatted = gates.sleepFormatted
        steps.append("Prioritize rest and recovery today")
        steps.append("Light movement like walking is better than intense exercise")
        if isShortSleep {
            steps.append("Aim for 7-9 hours of sleep tonight (you got \(sleepFormatted))")
        }
        if isFragmented {
            steps.append("Address sleep quality — avoid screens before bed, keep room cool and dark")
        }
        if lfhf > HRVThresholds.lfHfMildSympathetic {
            steps.append("Try 5-10 minutes of slow breathing (4s in, 6s out) to activate parasympathetic")
        }
        if stress > HRVThresholds.stressIndexElevated {
            steps.append("Consider what stressors you can reduce or delegate today")
        }
    }

    private func appendPoorRecoverySteps(_ steps: inout [String], gates: PushGates) {
        let sleepFormatted = gates.sleepFormatted
        let (rmssd, isShortSleep, isFragmented) = (gates.rmssd, gates.isShortSleep, gates.isFragmented)
        steps.append("Take it easy — your body is signaling it needs recovery")
        if isShortSleep {
            steps.append("Your short sleep (\(sleepFormatted)) needs to be addressed — make sleep the priority")
        } else {
            steps.append("Keep today light and notice how you feel over the next day or two")
        }
        if rmssd < HRVThresholds.rmssdReduced {
            steps.append("If you feel unwell, rest, and talk to a clinician about symptoms that concern you")
        }
        steps.append("Ensure adequate hydration and nutrition")
        if isFragmented {
            steps.append("Focus on uninterrupted sleep — avoid alcohol, caffeine after noon")
        } else {
            steps.append("Aim for extra sleep tonight (8-9+ hours)")
        }
    }

    // Divergence detection: morning feeling vs HRV-derived score.
    // Four quadrants (Saw et al. 2016): both signals carry independent
    // information; flagging disagreement is more useful than blending.
    // When tags are present, branch to tag-specific advice.
    private func appendFeelingSteps(_ steps: inout [String], score: Double) {
        if let feeling = session.morningFeeling {
            let hrvGood = score >= 65
            let feelGood = feeling >= 4
            let feelBad = feeling <= 2
            let tags = session.morningFeelingTags ?? []

            if feelBad {
                let advice = feelBadAdvice(hrvGood: hrvGood, tags: tags, feeling: feeling)
                steps.insert(contentsOf: advice, at: 0)
            } else if !hrvGood, feelGood {
                // HRV suppressed but user feels fine — delayed autonomic recovery.
                steps.insert(
                    "You feel \(feelingLabel(feeling)) but your HRV is below par \u{2014} your body may not have caught up yet, ease into the day",
                    at: 0
                )
            }
        }
    }

    /// Tag-specific recommendations for low-feeling mornings. Each tag routes
    /// to a distinct training decision backed by physiology:
    /// - Unwell → rest, without naming a condition (see `unwellAdvice`)
    /// - Allergies → mild autonomic effect, train expecting less
    /// - Hangover → dehydration + acetaldehyde, easy aerobic aids clearance
    /// - Stomach/GI → rest until resolved
    /// - Sore → DOMS is mechanical, train other groups
    /// - Tired → general/CNS fatigue, easy day
    /// - Headache → context-dependent
    /// - Stressed → psychogenic; exercise can buffer if HRV isn't suppressed
    /// - Down → gentle movement, social contact, sunlight
    func feelBadAdvice(
        hrvGood: Bool,
        tags: [MorningFeelingTag],
        feeling: Int
    ) -> [String] {
        guard !tags.isEmpty else { return [genericFeelBadAdvice(hrvGood: hrvGood, feeling: feeling)] }
        var messages: [String] = []
        // The illness tag comes first — it's the one tag with a rest implication.
        if tags.contains(.infection) { messages.append(unwellAdvice(hrvGood: hrvGood)) }
        messages += otherTagAdvice(hrvGood: hrvGood, tags: tags)
        return messages
    }

    /// Generic low-feeling advice when the user skipped tagging.
    private func genericFeelBadAdvice(hrvGood: Bool, feeling: Int) -> String {
        if hrvGood {
            return "HRV looks good but you reported feeling \(feelingLabel(feeling)) \u{2014} listen to your body and consider a lighter day"
        } else {
            return "Autonomic and subjective signals agree \u{2014} rest or easy day, recovery is the priority"
        }
    }

    /// Everything other than the illness tag, in priority order. `.sore` and
    /// `.tired` are suppressed when illness is also tagged — the rest advice
    /// there already covers them.
    private func otherTagAdvice(hrvGood: Bool, tags: [MorningFeelingTag]) -> [String] {
        var messages: [String] = []
        if tags.contains(.stomach) { messages.append(stomachAdvice(hrvGood: hrvGood)) }
        if tags.contains(.hangover) { messages.append(hangoverAdvice(hrvGood: hrvGood)) }
        if tags.contains(.allergies) { messages.append(allergiesAdvice(hrvGood: hrvGood)) }
        if tags.contains(.sore), !tags.contains(.infection) { messages.append(soreAdvice(hrvGood: hrvGood)) }
        if tags.contains(.tired), !tags.contains(.infection) { messages.append(tiredAdvice(hrvGood: hrvGood)) }
        if tags.contains(.headache) { messages.append(headacheAdvice(hrvGood: hrvGood)) }
        if tags.contains(.stressed) { messages.append(stressedAdvice(hrvGood: hrvGood)) }
        if tags.contains(.down) { messages.append(downAdvice(hrvGood: hrvGood)) }
        return messages
    }

    private func tiredAdvice(hrvGood: Bool) -> String {
        hrvGood
            ? "Fatigue with HRV holding \u{2014} short session or active recovery. If tiredness persists 3+ days, consider a deload."
            : "CNS fatigue with autonomic signal to match \u{2014} easy aerobic day. Sleep is tonight's priority."
    }

    private func stressedAdvice(hrvGood: Bool) -> String {
        hrvGood
            ? "HRV is fine \u{2014} the stress is psychogenic, not autonomic. Exercise is a proven stress buffer; a calm session or breathwork can regulate the nervous system."
            : "Life stress is showing up in your autonomic signal. Reduce intensity, keep volume if possible. Breathwork and sleep are the highest-leverage tools."
    }

    private func downAdvice(hrvGood: Bool) -> String {
        hrvGood
            ? "HRV is fine. Gentle movement, sunlight, and social contact help low mood more than hard training does."
            : "Low mood + suppressed autonomic \u{2014} a self-care day. Gentle walk outside, connection with someone, basic routines."
    }

    func feelingLabel(_ value: Int) -> String {
        switch value {
        case 1: "terrible"
        case 2: "poor"
        case 3: "OK"
        case 4: "good"
        case 5: "great"
        default: "OK"
        }
    }

    /// Post-exercise recovery tips when current readiness has dropped below
    /// the morning recovery score due to training done since the reading.
    func postExerciseSteps(readiness: Double, recoveryScore _: Double) -> [String] {
        let readiness10 = RecoveryScoreCalculator.toTenScale(readiness)
        let label = RecoveryScoreCalculator.readinessLabel(for: readiness10)
        var steps = sessionCostSteps(readiness: readiness, label: label)
        // Carry forward any relevant sleep tips from the morning analysis.
        if sleep.isShortSleep {
            steps.append("You started the day on short sleep (\(sleep.totalSleepFormatted)) — extra rest tonight is important")
        }
        return steps
    }

    /// How much of today's capacity the session consumed, and what that means
    /// for the rest of the day.
    private func sessionCostSteps(readiness: Double, label: String) -> [String] {
        if readiness < 30 { return heavySessionSteps(label: label) }
        if readiness < 50 { return moderateSessionSteps() }
        return lightSessionSteps(label: label)
    }

    private func heavySessionSteps(label: String) -> [String] {
        var steps: [String] = []
        // Heavy session — strong recovery advice
        steps.append("You've put in serious work today — prioritize recovery now")
        steps.append("Rehydrate and eat a balanced meal with protein within the next 2 hours")
        steps.append("Avoid another hard session until readiness recovers (currently \(label.lowercased()))")
        if !sleep.isGoodSleep {
            steps.append("Sleep is critical for absorbing today's training — aim for 8+ hours tonight")
        }
        return steps
    }

    private func moderateSessionSteps() -> [String] {
        var steps: [String] = []
        // Moderate session — balanced advice
        steps.append("Good effort today — your body needs time to absorb the training load")
        steps.append("Rest and hydrate to get the most out of today's session")
        if !sleep.isGoodSleep {
            steps.append("Prioritize sleep tonight to accelerate recovery")
        }
        steps.append("Light movement like walking is fine, but skip intense training")
        return steps
    }

    /// Still some capacity left.
    private func lightSessionSteps(label: String) -> [String] {
        [
            "You've used some capacity today — readiness is now \(label.lowercased())",
            "A light session later is possible if you feel good, but listen to your body"
        ]
    }
}

// MARK: - File-scope helpers
//
// Moved out of AnalysisSummaryGenerator. Each names no member of the
// type and calls nothing that stayed behind, so none needed to be inside
// it. `private` at file scope is fileprivate, so every call site in this
// file resolves exactly as before.

/// Framed away from clinical risk-prediction
/// language ("cardiac risk", "myocarditis risk"), and further than a first
/// pass went: that text still asserted a condition the app cannot know
/// ("Possible infection"), named two cardiac symptoms (chest discomfort,
/// palpitations) that `MedicalQueryGuard` refuses to even discuss, and
/// issued a clinician referral off an HRV reading. Naming a suspected
/// condition and triaging symptoms is the wellness→diagnostic line, whatever
/// the surrounding hedging says.
///
/// The tag is USER-SUPPLIED — they told us they feel unwell. So the copy
/// acknowledges what they said and gives rest guidance, which is squarely
/// wellness advice, without diagnosing, listing symptoms, or referring out.
private func unwellAdvice(hrvGood: Bool) -> String {
    hrvGood
        ? "You tagged feeling unwell, and your HRV is still holding \u{2014} rest anyway. Training while you're run down adds strain your body doesn't need today."
        : "You tagged feeling unwell and your HRV is suppressed \u{2014} rest, hydrate, skip training. Give it time before you pick training back up."
}

private func stomachAdvice(hrvGood _: Bool) -> String {
    "GI upset \u{2014} rest until resolved. Return gradually when tolerating food and fluids."
}

private func hangoverAdvice(hrvGood: Bool) -> String {
    hrvGood
        ? "Hangover-level HRV is often suppressed; if yours held, the recovery was better than the feeling suggests. Easy aerobic aids clearance \u{2014} skip intensity, hydrate."
        : "Hangover \u{2014} dehydration + acetaldehyde are suppressing the autonomic signal. Easy aerobic, aggressive hydration, no intensity."
}

private func allergiesAdvice(hrvGood _: Bool) -> String {
    "Allergies \u{2014} autonomic effect is usually mild. Training is fine; expect reduced performance. Note: antihistamines can blunt HR response, so target zones by feel."
}

private func soreAdvice(hrvGood: Bool) -> String {
    hrvGood
        ? "Sore with good HRV \u{2014} autonomic recovery is there. Train a different muscle group, easy cardio, or active recovery."
        : "Sore + suppressed HRV \u{2014} full recovery day. Mobility, walking, hydration."
}

private func headacheAdvice(hrvGood _: Bool) -> String {
    "Headache \u{2014} tension or dehydration often eases with light aerobic; migraine calls for rest until resolved."
}
