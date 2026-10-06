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
    //
    // Every band below reads `headlineScore`, the same Recovery Score the
    // ring and the summary title show, so the steps never contradict them.
    var actionableSteps: [String] {
        let score = headlineScore
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
        /// The shared training advice gate's read of the load.
        let load: TrainingAdviceGate.Assessment
        let hasUnstableWindow: Bool
        let hasFatigueSignal: Bool
        let hasSympatheticDominance: Bool
        let hasStrongVagalTone: Bool

        /// The gate says to ease off: a sharp load increase or heavy
        /// accumulated fatigue.
        var cumulativeLoadElevated: Bool { load.level == .easier }

        /// Why the gate holds the push back without asking for an easier
        /// day (load above the usual range, or monotonous training). Nil
        /// otherwise.
        var loadHoldReason: String? {
            load.level == .holdPush ? load.reasonLine(bundle: NarrativeLanguage.bundle) : nil
        }
    }

    private func pushGates() -> PushGates {
        let signals = hrvSignals()
        let load = adviceLoad()
        let shouldNotPush = sleep.isShortSleep || signals.hasUnstableWindow || signals.hasFatigueSignal
            || signals.hasSympatheticDominance || !isConsolidatedWindow || load.level != .clear
        return PushGates(
            rmssd: signals.rmssd, stress: signals.stress,
            lfhf: signals.lfhf, dfa: signals.dfa,
            isShortSleep: sleep.isShortSleep,
            isGoodSleep: sleep.isGoodSleep,
            isFragmented: sleep.isFragmented,
            sleepFormatted: NarrativeLanguage.hoursMinutes(sleep.totalSleepMinutes),
            isConsolidated: isConsolidatedWindow,
            shouldNotPush: shouldNotPush,
            load: load,
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

    // Training-load gate. The morning-HRV signals above describe
    // TODAY'S autonomic state. They do not see what the user has done
    // in the past weeks. With ACWR 1.99 (acute load nearly double
    // chronic), telling a user "great day to push yourself" is reckless
    // regardless of how good today's HRV looks — the body's job is to
    // absorb, not stack more on. The shared `TrainingAdviceGate` makes
    // that call for every advice surface; any load reason it finds keeps
    // the push copy out (`shouldNotPush`).
    //
    // Source = LIVE training load, captured by the caller on MainActor
    // (`liveLoadSnapshot`), because the frozen `result.trainingContext`
    // is captured at session acceptance and misses a heavy session
    // since. The frozen context stands in only when the live cache is
    // cold.
    private func adviceLoad() -> TrainingAdviceGate.Assessment {
        TrainingAdviceGate.assess(.preferring(live: liveLoadSnapshot, frozen: trainingContext ?? result.trainingContext))
    }

    private func appendTrendSteps(_ steps: inout [String], score: Double, gates: PushGates) {
        // shouldNotPush: any of these signals indicates the HRV represents capacity, not readiness
        // Trend-aware recommendations
        guard stats.hasData else { return }
        let rmssdPct = ((gates.rmssd - stats.avgRMSSD) / stats.avgRMSSD) * 100

        // `trend7Day` is present only when the shared trend verdict calls a
        // trend (`TrendVerdict.weeklyRMSSDChange`), so its sign is the
        // direction.
        if let trend = stats.trend7Day, trend > 0 {
            steps.append(String(localized: "Your improving trend suggests your current routine is working well", bundle: NarrativeLanguage.bundle))
        }
        if rmssdPct > 15, score >= 70 {
            appendHighRelativeHRVSteps(&steps, gates: gates)
        }

        if let trend = stats.trend7Day, trend < 0 {
            steps.append(String(localized: "Consider what changed in the past week — sleep, stress, training load?", bundle: NarrativeLanguage.bundle))
        }
    }

    private func appendHighRelativeHRVSteps(_ steps: inout [String], gates: PushGates) {
        guard gates.shouldNotPush else {
            // Consolidated: sustained plateau + stable HR.
            steps.append(String(localized: "This is a great day to push yourself — your recovery pattern held steady through the night", bundle: NarrativeLanguage.bundle))
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
        if gates.cumulativeLoadElevated {
            steps.append(String(localized: "HRV came in strong, but recent training is well above your usual range — easy or moderate today, save the push for after acute load settles. Hammering a body that's still absorbing risks the spike-injury window.", bundle: NarrativeLanguage.bundle))
        } else if let hold = gates.loadHoldReason {
            steps.append(hold)
        } else {
            appendHighHRVTodayReason(&steps, gates: gates)
        }
    }

    /// The reasons that come from today's night alone, once the load has
    /// none.
    private func appendHighHRVTodayReason(_ steps: inout [String], gates: PushGates) {
        let (isShortSleep, isConsolidated) = (gates.isShortSleep, gates.isConsolidated)
        let hasUnstableWindow = gates.hasUnstableWindow
        let (hasFatigueSignal, hasSympatheticDominance) = (gates.hasFatigueSignal, gates.hasSympatheticDominance)
        if !isConsolidated, !hasUnstableWindow, !hasFatigueSignal, !hasSympatheticDominance, !isShortSleep {
            steps.append(String(localized: "Good HRV shows recovery capacity, but the pattern wasn't sustained — moderate load is safer", bundle: NarrativeLanguage.bundle))
        } else if isShortSleep {
            steps.append(String(localized: "High HRV shows good capacity, but short sleep limits how much load you can handle", bundle: NarrativeLanguage.bundle))
        } else if hasUnstableWindow {
            if (sleep.sleepEfficiency ?? 0) >= 90 {
                steps.append(String(localized: "Good HRV with some HR variability during sleep — moderate to high intensity should be fine", bundle: NarrativeLanguage.bundle))
            } else {
                steps.append(String(localized: "Good HRV, but variable HR during sleep suggests recovery wasn't fully consolidated — moderate intensity", bundle: NarrativeLanguage.bundle))
            }
        } else if hasFatigueSignal {
            steps.append(String(localized: "Good HRV numbers, but heart rhythm patterns suggest underlying fatigue — don't overdo it", bundle: NarrativeLanguage.bundle))
        } else if hasSympatheticDominance {
            steps.append(String(localized: "HRV looks good but nervous system is still activated — ease into the day", bundle: NarrativeLanguage.bundle))
        }
    }

    private func appendTrainingLoadSteps(_ steps: inout [String]) {
        // Training load recommendations
        if let training = trainingContext ?? result.trainingContext {
            if let acr = training.acuteChronicRatio, acr < TrainingConstants.ACR.detraining {
                steps.append(String(localized: "Your training load is low — try adding a walk, light jog, or any movement today to rebuild your base", bundle: NarrativeLanguage.bundle))
            } else if training.ctl < RecoveryScoreConstants.Readiness.ctlThreshold, training.atl < RecoveryScoreConstants.Readiness.ctlThreshold {
                steps.append(String(localized: "Even a 20-minute walk will help — your body scores better when it's regularly active", bundle: NarrativeLanguage.bundle))
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
            steps.append(String(localized: "Great day for high-intensity training or challenging activities", bundle: NarrativeLanguage.bundle))
            steps.append(String(localized: "Your recovery is consolidated — your body can handle physical and mental demands", bundle: NarrativeLanguage.bundle))
            if isGoodSleep {
                steps.append(String(localized: "Good sleep is supporting your recovery — maintain this pattern", bundle: NarrativeLanguage.bundle))
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
        if gates.cumulativeLoadElevated || gates.loadHoldReason != nil || !gates.hasStrongVagalTone
            || gates.hasFatigueSignal || gates.isShortSleep {
            steps.append(String(localized: "Consider moderate activity rather than high intensity", bundle: NarrativeLanguage.bundle))
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
            steps.append(String(localized: "Great morning HRV, but recent training is well above your usual range — keep today easy or moderate and let acute load settle before the next quality session.", bundle: NarrativeLanguage.bundle))
        } else if let hold = gates.loadHoldReason {
            steps.append(hold)
        } else if !gates.isConsolidated && !hasUnstableWindow && !hasFatigueSignal && !hasSympatheticDominance {
            steps.append(String(localized: "Excellent recovery capacity detected, but pattern wasn't held long enough for full readiness", bundle: NarrativeLanguage.bundle))
        } else if gates.isShortSleep {
            steps.append(String(localized: "Strong metrics show good capacity, but short sleep (\(sleepFormatted)) is reason to hold something back", bundle: NarrativeLanguage.bundle))
        } else if hasUnstableWindow {
            appendUnstableWindowStep(&steps)
        } else if hasFatigueSignal {
            steps.append(String(localized: "Strong HRV capacity but heart rhythm patterns suggest accumulated fatigue — ease into the day", bundle: NarrativeLanguage.bundle))
        } else if hasSympatheticDominance {
            steps.append(String(localized: "Good recovery capacity but elevated LF/HF ratio — your nervous system is still activated", bundle: NarrativeLanguage.bundle))
        }
    }

    private func appendUnstableWindowStep(_ steps: inout [String]) {
        if (sleep.sleepEfficiency ?? 0) >= 90 {
            steps.append(String(localized: "Great recovery score with some HR variability — you're in good shape for moderate to high intensity", bundle: NarrativeLanguage.bundle))
        } else {
            steps.append(String(localized: "Good overall score, but variable HR during sleep suggests recovery wasn't fully consolidated", bundle: NarrativeLanguage.bundle))
        }
    }

    private func appendAdequateRecoverySteps(_ steps: inout [String], gates: PushGates) {
        let (isShortSleep, sleepFormatted) = (gates.isShortSleep, gates.sleepFormatted)
        steps.append(String(localized: "Moderate activity is fine — listen to your body", bundle: NarrativeLanguage.bundle))
        if isShortSleep {
            steps.append(String(localized: "Prioritize getting more sleep tonight (\(sleepFormatted) is insufficient)", bundle: NarrativeLanguage.bundle))
        } else {
            steps.append(String(localized: "Stay hydrated and maintain good sleep habits", bundle: NarrativeLanguage.bundle))
        }
    }

    private func appendIncompleteRecoverySteps(_ steps: inout [String], gates: PushGates) {
        let (stress, lfhf) = (gates.stress, gates.lfhf)
        let (isShortSleep, isFragmented) = (gates.isShortSleep, gates.isFragmented)
        let sleepFormatted = gates.sleepFormatted
        steps.append(String(localized: "Prioritize rest and recovery today", bundle: NarrativeLanguage.bundle))
        steps.append(String(localized: "Light movement like walking is better than intense exercise", bundle: NarrativeLanguage.bundle))
        if isShortSleep {
            steps.append(String(localized: "Aim for 7-9 hours of sleep tonight (you got \(sleepFormatted))", bundle: NarrativeLanguage.bundle))
        }
        if isFragmented {
            steps.append(String(localized: "Address sleep quality — avoid screens before bed, keep room cool and dark", bundle: NarrativeLanguage.bundle))
        }
        if lfhf > HRVThresholds.lfHfMildSympathetic {
            steps.append(String(localized: "Try 5-10 minutes of slow breathing (4s in, 6s out) to activate parasympathetic", bundle: NarrativeLanguage.bundle))
        }
        if stress > HRVThresholds.stressIndexElevated {
            steps.append(String(localized: "Consider what stressors you can reduce or delegate today", bundle: NarrativeLanguage.bundle))
        }
    }

    private func appendPoorRecoverySteps(_ steps: inout [String], gates: PushGates) {
        let sleepFormatted = gates.sleepFormatted
        let (rmssd, isShortSleep, isFragmented) = (gates.rmssd, gates.isShortSleep, gates.isFragmented)
        steps.append(String(localized: "Take it easy — your body is signaling it needs recovery", bundle: NarrativeLanguage.bundle))
        if isShortSleep {
            steps.append(String(localized: "Your short sleep (\(sleepFormatted)) needs to be addressed — make sleep the priority", bundle: NarrativeLanguage.bundle))
        } else {
            steps.append(String(localized: "Keep today light and notice how you feel over the next day or two", bundle: NarrativeLanguage.bundle))
        }
        if rmssd < HRVThresholds.rmssdReduced {
            steps.append(String(localized: "If you feel unwell, rest, and talk to a clinician about symptoms that concern you", bundle: NarrativeLanguage.bundle))
        }
        steps.append(String(localized: "Ensure adequate hydration and nutrition", bundle: NarrativeLanguage.bundle))
        if isFragmented {
            steps.append(String(localized: "Focus on uninterrupted sleep — avoid alcohol, caffeine after noon", bundle: NarrativeLanguage.bundle))
        } else {
            steps.append(String(localized: "Aim for extra sleep tonight (8-9+ hours)", bundle: NarrativeLanguage.bundle))
        }
    }

    // Divergence detection: morning feeling vs HRV-derived score.
    // Four quadrants (Saw et al. 2016): both signals carry independent
    // information; flagging disagreement is more useful than blending.
    // When tags are present, branch to tag-specific advice.
    private func appendFeelingSteps(_ steps: inout [String], score: Double) {
        guard let feeling = session.morningFeeling else { return }
        let hrvGood = score >= 65
        if feeling <= 2 {
            let advice = feelBadAdvice(hrvGood: hrvGood, tags: session.morningFeelingTags ?? [], feeling: feeling)
            steps.insert(contentsOf: advice, at: 0)
        } else if !hrvGood, feeling >= 4 {
            // HRV suppressed but user feels fine — delayed autonomic recovery.
            steps.insert(FeelingCopy.feelGoodHRVLow(feeling: feeling), at: 0)
        }
    }

    /// Tag-specific recommendations for low-feeling mornings. Each tag routes
    /// to a distinct training decision backed by physiology:
    /// - Unwell → rest, without naming a condition (see `FeelingCopy.unwell`)
    /// - Allergies → mild autonomic effect, train expecting less
    /// - Hangover → alcohol suppresses the signal, keep training easy
    /// - Stomach → training waits until it settles
    /// - Sore → DOMS is mechanical, train other groups
    /// - Tired → general/CNS fatigue, easy day
    /// - Headache → light training, or none if it's bad
    /// - Stressed → psychogenic; exercise can buffer if HRV isn't suppressed
    /// - Down → gentle movement, social contact, sunlight, and a pointer to
    ///   someone to talk to
    /// Unwell, stomach and headache end with a check-with-a-doctor line.
    func feelBadAdvice(
        hrvGood: Bool,
        tags: [MorningFeelingTag],
        feeling: Int
    ) -> [String] {
        guard !tags.isEmpty else { return [FeelingCopy.genericFeelBad(hrvGood: hrvGood, feeling: feeling)] }
        var messages: [String] = []
        // The illness tag comes first — it's the one tag with a rest implication.
        if tags.contains(.infection) { messages.append(FeelingCopy.unwell(hrvGood: hrvGood)) }
        messages += otherTagAdvice(hrvGood: hrvGood, tags: tags)
        return messages
    }

    /// Everything other than the illness tag, in priority order. `.sore` and
    /// `.tired` are suppressed when illness is also tagged — the rest advice
    /// there already covers them.
    private func otherTagAdvice(hrvGood: Bool, tags: [MorningFeelingTag]) -> [String] {
        var messages: [String] = []
        if tags.contains(.stomach) { messages.append(FeelingCopy.stomach) }
        if tags.contains(.hangover) { messages.append(FeelingCopy.hangover(hrvGood: hrvGood)) }
        if tags.contains(.allergies) { messages.append(FeelingCopy.allergies) }
        if tags.contains(.sore), !tags.contains(.infection) { messages.append(FeelingCopy.sore(hrvGood: hrvGood)) }
        if tags.contains(.tired), !tags.contains(.infection) { messages.append(FeelingCopy.tired(hrvGood: hrvGood)) }
        if tags.contains(.headache) { messages.append(FeelingCopy.headache) }
        if tags.contains(.stressed) { messages.append(FeelingCopy.stressed(hrvGood: hrvGood)) }
        if tags.contains(.down) { messages.append(FeelingCopy.down(hrvGood: hrvGood)) }
        return messages
    }

    /// Post-exercise recovery tips when current readiness has dropped below
    /// the morning recovery score due to training done since the reading.
    func postExerciseSteps(readiness: Double, recoveryScore _: Double) -> [String] {
        let label = RecoveryScoreCalculator.readinessLabel(for: RecoveryScoreCalculator.toTenScale(readiness))
        var steps = sessionCostSteps(readiness: readiness, label: label)
        // Carry forward any relevant sleep tips from the morning analysis.
        if sleep.isShortSleep {
            let formatted = NarrativeLanguage.hoursMinutes(sleep.totalSleepMinutes)
            steps.append(String(localized: "You started the day on short sleep (\(formatted)) — extra rest tonight is important", bundle: NarrativeLanguage.bundle))
        }
        return steps
    }

    /// How much of today's capacity the session consumed, and what that means
    /// for the rest of the day.
    private func sessionCostSteps(readiness: Double, label: String) -> [String] {
        if readiness < 30 { return heavySessionSteps(label: label) }
        if readiness < 50 { return moderateSessionSteps() }
        return PostExerciseCopy.lightSession(label: label)
    }

    private func heavySessionSteps(label: String) -> [String] {
        var steps: [String] = []
        // Heavy session — strong recovery advice
        steps.append(String(localized: "You've put in serious work today — prioritize recovery now", bundle: NarrativeLanguage.bundle))
        steps.append(String(localized: "Rehydrate and eat a balanced meal with protein within the next 2 hours", bundle: NarrativeLanguage.bundle))
        steps.append(PostExerciseCopy.avoidHardSession(label: label))
        if !sleep.isGoodSleep {
            steps.append(String(localized: "Sleep is critical for absorbing today's training — aim for 8+ hours tonight", bundle: NarrativeLanguage.bundle))
        }
        return steps
    }

    private func moderateSessionSteps() -> [String] {
        var steps: [String] = []
        // Moderate session — balanced advice
        steps.append(String(localized: "Good effort today — your body needs time to absorb the training load", bundle: NarrativeLanguage.bundle))
        steps.append(String(localized: "Rest and hydrate to get the most out of today's session", bundle: NarrativeLanguage.bundle))
        if !sleep.isGoodSleep {
            steps.append(String(localized: "Prioritize sleep tonight to accelerate recovery", bundle: NarrativeLanguage.bundle))
        }
        steps.append(String(localized: "Light movement like walking is fine, but skip intense training", bundle: NarrativeLanguage.bundle))
        return steps
    }
}

// MARK: - Post-exercise copy

/// The readiness-band sentences after a workout. One sentence per band
/// rather than a label dropped into a sentence, so each language can inflect
/// it. `label` is `RecoveryScoreCalculator.readinessLabel`'s English word.
enum PostExerciseCopy {
    static func avoidHardSession(label: String) -> String {
        switch label {
        case "Ready": String(localized: "Avoid another hard session until readiness recovers (currently ready)", bundle: NarrativeLanguage.bundle)
        case "Moderate": String(localized: "Avoid another hard session until readiness recovers (currently moderate)", bundle: NarrativeLanguage.bundle)
        case "Fatigued": String(localized: "Avoid another hard session until readiness recovers (currently fatigued)", bundle: NarrativeLanguage.bundle)
        default: String(localized: "Avoid another hard session until readiness recovers (currently rest)", bundle: NarrativeLanguage.bundle)
        }
    }

    /// Still some capacity left.
    static func lightSession(label: String) -> [String] {
        let used = switch label {
        case "Ready": String(localized: "You've used some capacity today — readiness is now ready", bundle: NarrativeLanguage.bundle)
        case "Moderate": String(localized: "You've used some capacity today — readiness is now moderate", bundle: NarrativeLanguage.bundle)
        case "Fatigued": String(localized: "You've used some capacity today — readiness is now fatigued", bundle: NarrativeLanguage.bundle)
        default: String(localized: "You've used some capacity today — readiness is now rest", bundle: NarrativeLanguage.bundle)
        }
        return [used, String(localized: "A light session later is possible if you feel good, but listen to your body", bundle: NarrativeLanguage.bundle)]
    }
}

// MARK: - Morning-feeling copy

/// Advice for the morning-feeling check-in, in `NarrativeLanguage`.
///
/// The copy never names a condition the app cannot know, lists symptoms, or
/// ties a referral to an HRV reading: naming a suspected condition and
/// triaging symptoms is the wellness→diagnostic line, whatever the hedging.
/// The tags are USER-SUPPLIED — the user told us how they feel. So the copy
/// acknowledges that and says what it means for training, with no care or
/// medication instructions. The symptom tags (unwell, stomach, headache) end
/// with the general reminder Guideline 1.4.1 asks for — check with a doctor
/// if it's severe or doesn't settle — and low mood ends with a pointer to
/// someone to talk to.
enum FeelingCopy {
    /// Felt good (4 or 5) on a below-par HRV morning.
    static func feelGoodHRVLow(feeling: Int) -> String {
        feeling >= 5
            ? String(localized: "You feel great but your HRV is below par \u{2014} your body may not have caught up yet, ease into the day", bundle: NarrativeLanguage.bundle)
            : String(localized: "You feel good but your HRV is below par \u{2014} your body may not have caught up yet, ease into the day", bundle: NarrativeLanguage.bundle)
    }

    /// Generic low-feeling advice (1 or 2) when the user skipped tagging.
    static func genericFeelBad(hrvGood: Bool, feeling: Int) -> String {
        guard hrvGood else {
            return String(localized: "Autonomic and subjective signals agree \u{2014} rest or easy day, recovery is the priority", bundle: NarrativeLanguage.bundle)
        }
        return feeling <= 1
            ? String(localized: "HRV looks good but you reported feeling terrible \u{2014} listen to your body and consider a lighter day", bundle: NarrativeLanguage.bundle)
            : String(localized: "HRV looks good but you reported feeling poor \u{2014} listen to your body and consider a lighter day", bundle: NarrativeLanguage.bundle)
    }

    static func unwell(hrvGood: Bool) -> String {
        hrvGood
            ? String(localized: "You tagged feeling unwell, and your HRV is still holding \u{2014} a rest day is still the better call. Training while you're run down adds strain your body doesn't need today. If it's severe or doesn't settle, check with a doctor.", bundle: NarrativeLanguage.bundle)
            : String(localized: "You tagged feeling unwell and your HRV is suppressed \u{2014} a day off training makes sense. Give it time before you pick training back up. If it's severe or doesn't settle, check with a doctor.", bundle: NarrativeLanguage.bundle)
    }

    static var stomach: String {
        String(localized: "Stomach upset \u{2014} training can wait until it settles. Ease back in once you're eating and drinking normally again. If it's severe or doesn't settle, check with a doctor.", bundle: NarrativeLanguage.bundle)
    }

    static func hangover(hrvGood: Bool) -> String {
        hrvGood
            ? String(localized: "HRV is often suppressed after drinking; if yours held, the recovery was better than the feeling suggests. Keep any training easy, skip intensity, and drink some water.", bundle: NarrativeLanguage.bundle)
            : String(localized: "Hangover \u{2014} alcohol is suppressing the autonomic signal. Keep any training easy with no intensity, and drink some water.", bundle: NarrativeLanguage.bundle)
    }

    static var allergies: String {
        String(localized: "Allergies \u{2014} the effect on HRV is usually mild. Training is fine; expect reduced performance.", bundle: NarrativeLanguage.bundle)
    }

    static func sore(hrvGood: Bool) -> String {
        hrvGood
            ? String(localized: "Sore with good HRV \u{2014} autonomic recovery is there. Train a different muscle group, easy cardio, or active recovery.", bundle: NarrativeLanguage.bundle)
            : String(localized: "Sore + suppressed HRV \u{2014} full recovery day. Mobility, walking, hydration.", bundle: NarrativeLanguage.bundle)
    }

    static func tired(hrvGood: Bool) -> String {
        hrvGood
            ? String(localized: "Fatigue with HRV holding \u{2014} short session or active recovery. If tiredness persists 3+ days, consider a deload.", bundle: NarrativeLanguage.bundle)
            : String(localized: "CNS fatigue with autonomic signal to match \u{2014} easy aerobic day. Sleep is tonight's priority.", bundle: NarrativeLanguage.bundle)
    }

    static var headache: String {
        String(localized: "Headache \u{2014} keep training light today, or skip it if the headache is bad or getting worse. If it's severe or doesn't settle, check with a doctor.", bundle: NarrativeLanguage.bundle)
    }

    static func stressed(hrvGood: Bool) -> String {
        hrvGood
            ? String(localized: "HRV is fine \u{2014} the stress is psychogenic, not autonomic. Exercise is a proven stress buffer; a calm session or breathwork can regulate the nervous system.", bundle: NarrativeLanguage.bundle)
            : String(localized: "Life stress is showing up in your autonomic signal. Reduce intensity, keep volume if possible. Breathwork and sleep are the highest-leverage tools.", bundle: NarrativeLanguage.bundle)
    }

    static func down(hrvGood: Bool) -> String {
        hrvGood
            ? String(localized: "HRV is fine. Gentle movement, sunlight, and social contact help low mood more than hard training does. If low mood lasts or feels heavy, talk to someone you trust or a health professional.", bundle: NarrativeLanguage.bundle)
            : String(localized: "Low mood + suppressed autonomic \u{2014} a self-care day. Gentle walk outside, connection with someone, basic routines. If low mood lasts or feels heavy, talk to someone you trust or a health professional.", bundle: NarrativeLanguage.bundle)
    }
}
