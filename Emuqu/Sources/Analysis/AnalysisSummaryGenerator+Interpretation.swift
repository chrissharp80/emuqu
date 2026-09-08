import Foundation

// Age-adjusted interpretation: turning computed trend statistics into
// normative language, the half that carries the literature citations.

extension AnalysisSummaryGenerator {
    // MARK: - Age-Adjusted Interpretation

    /// Get age-adjusted HRV interpretation using injected age/sex
    var ageAdjustedInterpretation: RMSSDInterpretation {
        let sex: AgeAdjustedHRV.Sex? = switch biologicalSex {
        case .male: .male
        case .female: .female
        case .other: nil
        case nil: nil
        }
        return AgeAdjustedHRV.interpret(rmssd: result.timeDomain.rmssd, age: userAge, sex: sex)
    }

    // MARK: - Diagnostic Score

    /// Diagnostic-score point weights. The THRESHOLDS are
    /// named (`HRVThresholds.*` / `StressNormativeConstants.*`);
    /// the points awarded at each band live here rather than inline
    /// so the weighting is auditable at a glance.
    private enum DiagnosticPoints {
        static let base = 50.0
        // RMSSD age-adjusted category
        static let rmssdExcellent = 40.0, rmssdGood = 30.0, rmssdFair = 20.0,
                   rmssdReduced = 10.0, rmssdLow = -10.0
        // Stress index bands (low → very high)
        static let stressLow = 20.0, stressNormal = 15.0, stressElevated = 10.0,
                   stressHigh = 0.0, stressVeryHigh = -15.0
        // LF/HF ratio bands
        static let lfHfOptimal = 20.0, lfHfParasympathetic = 15.0,
                   lfHfModerate = 5.0, lfHfSympathetic = -10.0
        // DFA α1 bands
        static let dfaOptimal = 20.0, dfaHighVariability = 10.0
        // ANS balance bands
        static let ansStrongParasympathetic = 15.0, ansBalanced = 10.0,
                   ansMildSympathetic = -5.0, ansSympathetic = -15.0
    }

    func computeDiagnosticScore() -> Double {
        var score = DiagnosticPoints.base
        score += Self.rmssdPoints(ageAdjustedInterpretation.category)
        score += Self.stressIndexPoints(result.ansMetrics?.stressIndex)
        score += Self.lfHfPoints(result.frequencyDomain?.lfHfRatio)
        if let dfa = result.nonlinear.dfaAlpha1,
           dfa >= HRVThresholds.dfaAlpha1OptimalLower, dfa <= HRVThresholds.dfaAlpha1OptimalUpper {
            score += DiagnosticPoints.dfaOptimal
        }
        score += Self.ansBalancePoints(sns: result.ansMetrics?.snsIndex, pns: result.ansMetrics?.pnsIndex)
        return min(100, max(0, score))
    }

    /// Age-adjusted RMSSD interpretation, so a 55-year-old's "good" isn't
    /// scored against a 25-year-old's distribution.
    private static func rmssdPoints(_ category: RMSSDCategory) -> Double {
        switch category {
        case .excellent: DiagnosticPoints.rmssdExcellent
        case .good: DiagnosticPoints.rmssdGood
        case .fair: DiagnosticPoints.rmssdFair
        case .reduced: DiagnosticPoints.rmssdReduced
        case .low: DiagnosticPoints.rmssdLow
        }
    }

    /// Penalizes sympathetic dominance. Positive balance = parasympathetic.
    private static func ansBalancePoints(sns: Double?, pns: Double?) -> Double {
        guard let sns, let pns else { return 0 }
        let balance = pns - sns
        if balance >= StressNormativeConstants.ansBalanceStrongParasympathetic {
            return DiagnosticPoints.ansStrongParasympathetic
        }
        if balance >= 0 { return DiagnosticPoints.ansBalanced }
        if balance >= StressNormativeConstants.ansBalanceMildSympathetic {
            return DiagnosticPoints.ansMildSympathetic
        }
        return DiagnosticPoints.ansSympathetic
    }

    // MARK: - Diagnostic Title, Icon, Color

    var analysisTitle: String {
        let score = computeDiagnosticScore()
        if score >= HRVThresholds.scoreWellRecovered { return "Well Recovered" }
        if score >= HRVThresholds.scoreAdequateRecovery { return "Adequate Recovery" }
        if score >= HRVThresholds.scoreIncompleteRecovery { return "Incomplete Recovery" }
        if score >= HRVThresholds.scoreSignificantStress { return "Significant Stress Load" }
        return "Recovery Needed"
    }

    var diagnosticIcon: String {
        let score = computeDiagnosticScore()
        if score >= HRVThresholds.scoreWellRecovered { return "checkmark.circle.fill" }
        if score >= HRVThresholds.scoreAdequateRecovery { return "hand.thumbsup.fill" }
        if score >= HRVThresholds.scoreIncompleteRecovery { return "exclamationmark.triangle.fill" }
        return "bed.double.fill"
    }

    // MARK: - Diagnostic Explanation

    var analysisExplanation: String {
        categoryExplanation(explanationInputs) + trainingContextNote
    }

    /// Everything the per-category builders read, gathered once.
    private var explanationInputs: Inputs {
        let isShortSleep = sleep.isShortSleep
        let isFragmented = sleep.isFragmented
        let sleepFormatted = sleep.totalSleepFormatted
        return Inputs(
            rmssd: result.timeDomain.rmssd,
            stress: result.ansMetrics?.stressIndex ?? 150,
            lfhf: result.frequencyDomain?.lfHfRatio ?? 1.0,
            dfa: result.nonlinear.dfaAlpha1 ?? 1.0,
            ageNote: ageAdjustedInterpretation.ageContext.map { " (\($0))" } ?? "",
            isShortSleep: isShortSleep,
            isGoodSleep: sleep.isGoodSleep,
            isFragmented: isFragmented,
            sleepFormatted: sleepFormatted,
            sleepContext: sleepContextNote(
                isShortSleep: isShortSleep,
                isFragmented: isFragmented,
                sleepFormatted: sleepFormatted
            )
        )
    }

    private func categoryExplanation(_ inputs: Inputs) -> String {
        switch ageAdjustedInterpretation.category {
        case .low: lowHRVExplanation(inputs)
        case .reduced: reducedHRVExplanation(inputs)
        case .excellent: excellentHRVExplanation(inputs)
        case .good: goodHRVExplanation(inputs)
        case .fair: fairHRVExplanation(inputs)
        }
    }

    /// The one sleep sentence appended to every category explanation — empty
    /// when no sleep was recorded, or when it was neither short nor fragmented
    /// nor inefficient.
    private func sleepContextNote(isShortSleep: Bool, isFragmented: Bool, sleepFormatted: String) -> String {
        var sleepContext = ""
        if sleep.totalSleepMinutes > 0 {
            if isShortSleep {
                sleepContext = " Your short sleep (\(sleepFormatted)) is likely a major contributor."
            } else if isFragmented {
                sleepContext = " Fragmented sleep (\(sleep.awakeMinutes) min awake) may be reducing recovery quality."
            } else if sleep.sleepEfficiency < HRVThresholds.sleepEfficiencyLow {
                sleepContext = " Low sleep efficiency (\(Int(sleep.sleepEfficiency.rounded()))%) limits restorative recovery."
            }
        }
        return sleepContext
    }

    /// Appended only when training load is a significant factor.
    private var trainingContextNote: String {
        var explanation = ""
        // Append training context when it's a significant factor
        if let training = trainingContext ?? result.trainingContext {
            if let acr = training.acuteChronicRatio, acr < TrainingConstants.ACR.detraining {
                explanation += " Low training load is also a factor — your score improves when you stay regularly active."
            } else if training.ctl < RecoveryScoreConstants.Readiness.ctlThreshold, training.atl < RecoveryScoreConstants.Readiness.ctlThreshold {
                explanation += " Your activity level is very low, which contributes to a lower score."
            }
        }
        return explanation
    }

    /// Everything the per-category explanations read, gathered once so each
    /// branch is a pure string builder over the same snapshot. A struct rather
    /// than ten parameters: SwiftLint caps a signature at seven.
    private struct Inputs {
        let rmssd: Double
        let stress: Double
        let lfhf: Double
        let dfa: Double
        let ageNote: String
        let isShortSleep: Bool
        let isGoodSleep: Bool
        let isFragmented: Bool
        let sleepFormatted: String
        let sleepContext: String
    }

    private func lowHRVExplanation(_ v: Inputs) -> String {
        let (rmssd, stress, lfhf, ageNote) = (v.rmssd, v.stress, v.lfhf, v.ageNote)
        let (isShortSleep, sleepFormatted) = (v.isShortSleep, v.sleepFormatted)
        let sleepContext = v.sleepContext
        var explanation = "Your HRV is low at \(String(format: "%.0f", locale: .current, rmssd))ms\(ageNote). "
        if isShortSleep {
            explanation += "With only \(sleepFormatted) of sleep, your body hasn't had adequate time to recover. This is the most likely explanation for your low HRV."
        } else if stress > HRVThresholds.stressIndexHigh {
            explanation += "Combined with high stress markers, this pattern is often seen with: acute illness coming on, severe sleep deprivation, or intense accumulated physical/mental strain.\(sleepContext)"
        } else if lfhf > HRVThresholds.lfHfSympatheticDominance {
            explanation += "Your LF/HF ratio is well above its usual resting range too. That pattern turns up with mental or emotional stress, poor sleep quality, and when the body is fighting something off — though the ratio also moves with breathing rate, so read it alongside the rest.\(sleepContext)"
        } else {
            explanation += "This suggests your parasympathetic (rest-and-digest) system is suppressed. Common causes include heavy recent training load, chronic stress, or early illness.\(sleepContext)"
        }

        return explanation
    }

    private func reducedHRVExplanation(_ v: Inputs) -> String {
        let (rmssd, stress, dfa, ageNote) = (v.rmssd, v.stress, v.dfa, v.ageNote)
        let (isShortSleep, isFragmented) = (v.isShortSleep, v.isFragmented)
        let (sleepFormatted, sleepContext) = (v.sleepFormatted, v.sleepContext)
        var explanation = "Your HRV is reduced at \(String(format: "%.0f", locale: .current, rmssd))ms\(ageNote). "
        if isShortSleep {
            explanation += "Your short sleep duration (\(sleepFormatted)) is likely contributing to incomplete recovery."
        } else if isFragmented {
            explanation += "Fragmented sleep (\(sleep.awakeMinutes) min awake) may be preventing deep recovery even with adequate duration."
        } else if dfa > HRVThresholds.dfaAlpha1Fatigue {
            explanation += "The reduced complexity in your heart rhythm suggests fatigue or incomplete recovery from recent demands.\(sleepContext)"
        } else if stress > HRVThresholds.stressIndexElevated {
            explanation += "Elevated stress markers suggest your body is working harder than usual to maintain balance.\(sleepContext)"
        } else {
            explanation += "This may indicate accumulated fatigue, mild dehydration, or the early stages of fighting off illness.\(sleepContext)"
        }

        return explanation
    }

    private func excellentHRVExplanation(_ v: Inputs) -> String {
        let (rmssd, stress, ageNote, isShortSleep) = (v.rmssd, v.stress, v.ageNote, v.isShortSleep)
        let (isGoodSleep, isFragmented) = (v.isGoodSleep, v.isFragmented)
        let sleepFormatted = v.sleepFormatted
        let isConsolidated = result.isConsolidated ?? false
        var explanation = "Your HRV of \(String(format: "%.0f", locale: .current, rmssd))ms indicates strong vagal tone and excellent recovery capacity\(ageNote). "
        if isGoodSleep, !isFragmented, isConsolidated {
            explanation += "Quality sleep (\(sleepFormatted)) combined with stable, sustained recovery patterns means you're fully ready for demands."
        } else if isShortSleep {
            explanation += "However, with only \(sleepFormatted) of sleep, treat this as capacity rather than a green light."
        } else if !isConsolidated {
            explanation += "The pattern shows capacity but wasn't sustained long enough to confirm full readiness. Listen to your body."
        } else if stress < HRVThresholds.stressIndexLow {
            explanation += "Low stress markers confirm your nervous system is well-balanced and recovery is consolidated."
        } else {
            explanation += "Your parasympathetic system is active and healthy."
        }

        return explanation
    }

    private func goodHRVExplanation(_ v: Inputs) -> String {
        let (rmssd, ageNote, isShortSleep) = (v.rmssd, v.ageNote, v.isShortSleep)
        let (isGoodSleep, isFragmented) = (v.isGoodSleep, v.isFragmented)
        var explanation = "Your HRV of \(String(format: "%.0f", locale: .current, rmssd))ms is good\(ageNote). "
        if isGoodSleep, !isFragmented {
            explanation += "Combined with quality sleep, you're well-positioned for activity today."
        } else if isShortSleep {
            explanation += "With better sleep, you could see even stronger recovery."
        } else {
            explanation += "Your autonomic nervous system is well-balanced."
        }

        return explanation
    }

    private func fairHRVExplanation(_ v: Inputs) -> String {
        let (rmssd, lfhf, ageNote, isShortSleep) = (v.rmssd, v.lfhf, v.ageNote, v.isShortSleep)
        let sleepFormatted = v.sleepFormatted
        let sleepContext = v.sleepContext
        var explanation = "Your HRV of \(String(format: "%.0f", locale: .current, rmssd))ms is in a moderate range\(ageNote). "
        if isShortSleep {
            explanation += "With only \(sleepFormatted) of sleep, your HRV may improve with better rest."
        } else if lfhf > HRVThresholds.lfHfOptimalUpper {
            explanation += "There's some sympathetic activation present, which could be residual from yesterday's activities or mild ongoing stress.\(sleepContext)"
        } else {
            explanation += "Your autonomic nervous system is reasonably balanced."
        }
        return explanation
    }

    // MARK: - Probable Causes

    var probableCauses: [ProbableCause] {
        CauseDetector().detectCauses(in: causeContext, limit: 3).map { $0.toProbableCause() }
    }

    private var causeContext: CauseDetectionContext {
        let rmssd = result.timeDomain.rmssd
        let stress = result.ansMetrics?.stressIndex ?? 150
        let lfhf = result.frequencyDomain?.lfHfRatio ?? 1.0
        let dfa = result.nonlinear.dfaAlpha1 ?? 1.0
        return CauseDetectionContext(
            rmssd: rmssd,
            stressIndex: stress,
            lfHfRatio: lfhf,
            dfaAlpha1: dfa,
            pnn50: result.timeDomain.pnn50,
            isGoodReading: rmssd >= HRVThresholds.rmssdModerate && stress < HRVThresholds.stressIndexElevated && lfhf < HRVThresholds.lfHfMildSympathetic && dfa < HRVThresholds.dfaAlpha1Fatigue,
            isExcellentReading: stats.hasData && rmssd > stats.avgRMSSD * 1.15,
            selectedTags: selectedTags,
            trendStats: stats,
            sleepInput: sleep,
            sleepTrend: sleepTrend,
            session: session,
            recentSessions: recentSessions
        )
    }

    // MARK: - Key Findings

    var keyFindings: [String] {
        var findings: [String] = []

        findings.append(contentsOf: trendAndBaselineFindings)
        findings.append(contentsOf: ageAdjustedFindings(existingFindings: findings))
        findings.append(contentsOf: stressFindings)
        findings.append(contentsOf: ansBalanceFindings)
        findings.append(contentsOf: heartRhythmFindings)
        findings.append(contentsOf: windowQualityFindings)
        findings.append(contentsOf: beatVariationFindings)

        let isGoodHRV = result.timeDomain.rmssd >= HRVThresholds.rmssdModerate || (stats.hasData && result.timeDomain.rmssd >= stats.avgRMSSD * 0.95)
        findings.append(contentsOf: sleepFindings)
        findings.append(contentsOf: sleepTrendFindings(isGoodHRV: isGoodHRV))
        findings.append(contentsOf: trainingLoadFindings)

        return findings
    }

    // MARK: - Key Findings Sub-Methods

    var trendAndBaselineFindings: [String] {
        guard stats.hasData else { return [] }
        let rmssd = result.timeDomain.rmssd
        let rmssdPct = ((rmssd - stats.avgRMSSD) / stats.avgRMSSD) * 100
        return recentAverageFindings(rmssdPct: rmssdPct)
            + personalBaselineFindings(rmssd: rmssd)
            + sevenDayTrendFindings
            + restingHRFindings
    }

    private func recentAverageFindings(rmssdPct: Double) -> [String] {
        var findings: [String] = []
        if rmssdPct > HRVThresholds.trendSignificantChange {
            findings.append("HRV is significantly higher than your recent baseline of \(String(format: "%.0f", locale: .current, stats.avgRMSSD))ms (+\(String(format: "%.0f", locale: .current, rmssdPct))%) — excellent recovery today")
        } else if rmssdPct > HRVThresholds.trendModerateChange {
            findings.append("HRV is above your recent baseline of \(String(format: "%.0f", locale: .current, stats.avgRMSSD))ms (+\(String(format: "%.0f", locale: .current, rmssdPct))%) — good recovery")
        } else if rmssdPct < -HRVThresholds.trendSignificantChange {
            findings.append("HRV is significantly below your recent baseline of \(String(format: "%.0f", locale: .current, stats.avgRMSSD))ms (\(String(format: "%.0f", locale: .current, rmssdPct))%) — recovery may be compromised")
        } else if rmssdPct < -HRVThresholds.trendModerateChange {
            findings.append("HRV is below your recent baseline of \(String(format: "%.0f", locale: .current, stats.avgRMSSD))ms (\(String(format: "%.0f", locale: .current, rmssdPct))%) — below your usual range")
        }

        return findings
    }

    private func personalBaselineFindings(rmssd: Double) -> [String] {
        var findings: [String] = []
        if let baseline = stats.baselineRMSSD {
            let baselineDiff = ((rmssd - baseline) / baseline) * 100
            if baselineDiff > HRVThresholds.baselineAboveThreshold {
                findings.append("You're \(String(format: "%.0f", locale: .current, baselineDiff))% above your personal baseline — you're in great shape")
            } else if baselineDiff < -HRVThresholds.baselineAboveThreshold {
                findings.append("You're \(String(format: "%.0f", locale: .current, abs(baselineDiff)))% below your personal baseline")
            }
        }
        return findings
    }

    private var sevenDayTrendFindings: [String] {
        var findings: [String] = []
        if let trend = stats.trend7Day {
            if trend > HRVThresholds.trendModerateChange {
                findings.append("Your 7-day HRV trend is improving (+\(String(format: "%.0f", locale: .current, trend))%) — keep doing what you're doing!")
            } else if trend < -HRVThresholds.trendModerateChange {
                findings.append("Your 7-day HRV trend shows a decline (\(String(format: "%.0f", locale: .current, trend))%)")
            }
        }
        return findings
    }

    private var restingHRFindings: [String] {
        var findings: [String] = []
        let hrDiff = result.timeDomain.meanHR - stats.avgHR
        if hrDiff > HRVThresholds.hrElevationThreshold {
            findings.append("Resting HR is elevated (+\(String(format: "%.0f", locale: .current, hrDiff)) bpm vs average) — possible stress or incomplete recovery")
        } else if hrDiff < -HRVThresholds.hrElevationThreshold {
            findings.append("Resting HR is lower than average (\(String(format: "%.0f", locale: .current, abs(hrDiff))) bpm) — good cardiovascular state")
        }

        return findings
    }

    func ageAdjustedFindings(existingFindings: [String]) -> [String] {
        let rmssd = result.timeDomain.rmssd
        if existingFindings.isEmpty {
            let interpretation = ageAdjustedInterpretation
            let ageContext = interpretation.ageContext.map { " — \($0)" } ?? ""
            switch interpretation.category {
            case .excellent:
                return ["HRV is excellent at \(String(format: "%.0f", locale: .current, rmssd))ms\(ageContext)"]
            case .good:
                return ["HRV is good at \(String(format: "%.0f", locale: .current, rmssd))ms\(ageContext)"]
            case .fair:
                return ["HRV is fair at \(String(format: "%.0f", locale: .current, rmssd))ms\(ageContext)"]
            case .reduced:
                return ["HRV is reduced at \(String(format: "%.0f", locale: .current, rmssd))ms\(ageContext)"]
            case .low:
                return ["HRV is low at \(String(format: "%.0f", locale: .current, rmssd))ms\(ageContext)"]
            }
        } else if let ageContext = ageAdjustedInterpretation.ageContext {
            return ["This reading is \(ageContext)"]
        }
        return []
    }

    var stressFindings: [String] {
        guard let s = result.ansMetrics?.stressIndex else { return [] }
        if s > HRVThresholds.stressIndexHigh {
            return ["Stress index is high (\(Int(s))) - significant physiological load"]
        } else if s > HRVThresholds.stressIndexNormal {
            return ["Stress index is elevated (\(Int(s))) - moderate strain present"]
        } else if s > HRVThresholds.stressIndexVeryLow {
            return ["Stress index is normal (\(Int(s))) - within typical resting range"]
        } else {
            return ["Stress index is low (\(Int(s))) - very relaxed state"]
        }
    }

    /// LF/HF findings.
    ///
    /// These lines must not read like "Your nervous system is in
    /// fight-or-flight mode", "Your body is in deep rest mode" or "Your
    /// nervous system is well balanced". All three are autonomic-state
    /// verdicts read off a single LF/HF value, which is the specific
    /// interpretation Billman 2013 dismantled ("The LF/HF ratio does not
    /// accurately measure cardiac sympatho-vagal balance") — and which the
    /// app's own Help Center cites him to reject. The findings report where
    /// the ratio sits instead of what it proves about the reader.
    var ansBalanceFindings: [String] {
        let rmssd = result.timeDomain.rmssd
        let pnn50 = result.timeDomain.pnn50
        let hasStrongVagalTone = pnn50 > HRVThresholds.pnn50Moderate && rmssd >= HRVThresholds.rmssdModerate
        guard let ratio = result.frequencyDomain?.lfHfRatio else { return [] }
        if ratio > HRVThresholds.lfHfSympatheticDominance {
            if hasStrongVagalTone {
                return ["Your LF/HF ratio is high, but your other markers are strong — this is common sleep-stage variation"]
            } else {
                return ["Your LF/HF ratio is above its usual resting range — deep breathing or a gentle walk may help you wind down"]
            }
        } else if ratio < HRVThresholds.lfHfParasympatheticDominance {
            return ["Your LF/HF ratio is low, the pattern typical of settled rest"]
        } else if ratio >= HRVThresholds.lfHfBalancedLower, ratio <= HRVThresholds.lfHfBalancedUpper {
            return ["Your LF/HF ratio sits in its usual resting range"]
        }
        return []
    }

    var heartRhythmFindings: [String] {
        let rmssd = result.timeDomain.rmssd
        let pnn50 = result.timeDomain.pnn50
        let hasStrongVagalTone = pnn50 > HRVThresholds.pnn50Moderate && rmssd >= HRVThresholds.rmssdModerate
        guard let alpha = result.nonlinear.dfaAlpha1 else { return [] }
        if alpha > HRVThresholds.dfaAlpha1ClearlyElevated {
            return ["Your heart rhythm pattern suggests accumulated fatigue — consider extra rest today"]
        } else if alpha > HRVThresholds.dfaAlpha1Fatigue {
            if hasStrongVagalTone {
                return ["Heart rhythm patterns are within normal variation"]
            } else {
                return ["Your heart rhythm suggests you may be carrying some fatigue — don't overdo it"]
            }
        } else if alpha >= HRVThresholds.dfaAlpha1OptimalLower, alpha <= HRVThresholds.dfaAlpha1OptimalUpper {
            return ["Your heart rhythm shows a healthy, complex pattern — a sign of good fitness"]
        } else if alpha < HRVThresholds.dfaAlpha1OptimalLower, alpha >= HRVThresholds.dfaAlpha1FlexibleLower {
            return ["Your heart rhythm is less organized than usual — this often improves with consistent sleep"]
        }
        return []
    }

    var windowQualityFindings: [String] {
        let isOrganized = result.isOrganizedRecovery ?? true
        guard !isOrganized else { return [] }
        let dfa = result.nonlinear.dfaAlpha1
        if let alpha = dfa {
            if alpha < HRVThresholds.dfaAlpha1Disorganized {
                return ["Your body didn't settle into a steady recovery pattern overnight. The score reflects your recovery capacity, but you may not be fully ready for heavy demands."]
            } else if alpha > HRVThresholds.dfaAlpha1HighVariability {
                return ["Signs of fatigue in your heart rhythm. The score shows what your body can handle, but take it easier than usual."]
            } else {
                return ["Your recovery wasn't fully consolidated overnight. The score may be slightly optimistic — listen to your body."]
            }
        } else {
            return ["No deep recovery window was detected overnight. The score reflects your capacity, but real-world readiness may be lower."]
        }
    }

    var beatVariationFindings: [String] {
        let pnn50 = result.timeDomain.pnn50
        if pnn50 < HRVThresholds.pnn50VeryLow {
            return ["Very low beat-to-beat variation — your nervous system recovery signals are weak"]
        } else if pnn50 > HRVThresholds.pnn50Strong {
            return ["Strong beat-to-beat variation — your body is recovering well"]
        }
        return []
    }

    var sleepFindings: [String] {
        guard sleep.totalSleepMinutes > 0 else { return [] }
        return sleepDurationFindings + sleepEfficiencyFindings
    }

    private var sleepDurationFindings: [String] {
        var findings: [String] = []
        let rmssd = result.timeDomain.rmssd
        let hours = Double(sleep.totalSleepMinutes) / 60.0
        let isGoodHRV = rmssd >= HRVThresholds.rmssdModerate || (stats.hasData && rmssd >= stats.avgRMSSD * 0.95)
        let isExcellentHRV = stats.hasData && rmssd > stats.avgRMSSD * 1.1

        if sleep.totalSleepMinutes < HRVThresholds.sleepShortMinutes {
            if isExcellentHRV {
                findings.append("Remarkable: Excellent HRV despite only \(String(format: "%.1f", locale: .current, hours))h sleep — your recovery capacity is impressive")
            } else if isGoodHRV {
                findings.append("Solid HRV despite \(String(format: "%.1f", locale: .current, hours))h sleep — you're handling the short night well")
            } else {
                findings.append("Short sleep (\(String(format: "%.1f", locale: .current, hours))h) per HealthKit — likely a major factor in reduced HRV")
            }
        } else if sleep.totalSleepMinutes >= HRVThresholds.sleepMinimumMinutes, isExcellentHRV {
            findings.append("Great combo: \(String(format: "%.1f", locale: .current, hours))h sleep + HRV above your usual range")
        }

        return findings
    }

    private var sleepEfficiencyFindings: [String] {
        var findings: [String] = []
        if sleep.sleepEfficiency >= HRVThresholds.sleepEfficiencyExcellent {
            findings.append("Sleep efficiency \(Int(sleep.sleepEfficiency.rounded()))% — nearly uninterrupted rest")
        } else if sleep.sleepEfficiency < HRVThresholds.sleepEfficiencyLow, sleep.inBedMinutes > HRVThresholds.sleepVeryShortMinutes {
            findings.append("Low sleep efficiency (\(Int(sleep.sleepEfficiency.rounded()))%) — \(sleep.awakeMinutes) min awake during the night")
        }

        return findings
    }

    func sleepTrendFindings(isGoodHRV: Bool) -> [String] {
        guard sleep.totalSleepMinutes > 0,
              let trends = sleepTrend, trends.nightsAnalyzed >= 3 else { return [] }
        var findings = trendDirectionFindings(trends, isGoodHRV: isGoodHRV)
        let sleepDiffPercent = trends.averageSleepMinutes > 0
            ? ((Double(sleep.totalSleepMinutes) - trends.averageSleepMinutes) / trends.averageSleepMinutes) * 100
            : 0
        findings += tonightVsAverageFindings(sleepDiffPercent, avgHours: trends.averageSleepMinutes / 60.0)
        return findings
    }

    /// What the multi-night direction says on its own.
    private func trendDirectionFindings(_ trends: AnalysisSleepTrendInput, isGoodHRV: Bool) -> [String] {
        var findings: [String] = []
        let avgHours = trends.averageSleepMinutes / 60.0
        switch trends.trend {
        case .declining:
            findings.append("Sleep trending down over past \(trends.nightsAnalyzed) nights (avg \(String(format: "%.1f", locale: .current, avgHours))h) — watch for cumulative fatigue")
        case .improving:
            if isGoodHRV {
                findings.append("Sleep improving over past week — your body is responding positively")
            }
        case .stable:
            if avgHours >= 7, isGoodHRV {
                findings.append("Consistent \(String(format: "%.1f", locale: .current, avgHours))h average sleep supporting steady HRV")
            }
        case .insufficient:
            break
        }
        return findings
    }

    /// Called out only when tonight is well off the recent average — a small
    /// nightly wobble is not news.
    private func tonightVsAverageFindings(_ sleepDiffPercent: Double, avgHours: Double) -> [String] {
        guard abs(sleepDiffPercent) > 25 else { return [] }
        let tonightHours = Double(sleep.totalSleepMinutes) / 60.0
        var findings: [String] = []
        if sleepDiffPercent > 25 {
            findings.append("Tonight's \(String(format: "%.1f", locale: .current, tonightHours))h is \(Int(sleepDiffPercent))% above your recent average")
        } else {
            findings.append("Tonight's \(String(format: "%.1f", locale: .current, tonightHours))h is \(Int(abs(sleepDiffPercent)))% below your \(String(format: "%.1f", locale: .current, avgHours))h average")
        }
        return findings
    }

    var trainingLoadFindings: [String] {
        guard let training = trainingContext ?? result.trainingContext else { return [] }
        // Descriptive load-range copy — no
        // "overreaching" / "spike" framing. Training load does not
        // feed the recovery score, so these
        // findings appear in the Surface 2 / Load context, not as a
        // score-penalty explanation.
        if let acr = training.acuteChronicRatio {
            if acr < TrainingConstants.ACR.detraining {
                return ["Recent training is below your usual range — regular activity helps maintain fitness"]
            } else if acr > TrainingConstants.ACR.overreaching {
                return ["Recent training jumped sharply vs your usual range — an easier session helps you absorb the work"]
            } else if acr > TrainingConstants.ACR.building {
                return ["Recent training is above your usual range — listen to your body for signs of accumulated fatigue"]
            }
        } else if training.ctl < RecoveryScoreConstants.Readiness.ctlThreshold, training.atl < RecoveryScoreConstants.Readiness.ctlThreshold {
            return ["Very low activity level — even light exercise like walking helps maintain fitness"]
        }
        return []
    }

    // MARK: - Trend Insight

    var trendInsight: String {
        guard stats.hasData else { return "Record more sessions to see trends." }
        let currentRMSSD = result.timeDomain.rmssd
        let rmssdPct = ((currentRMSSD - stats.avgRMSSD) / stats.avgRMSSD) * 100
        var insights = rmssdAverageInsights(rmssdPct: rmssdPct)
            + rmssdBaselineInsights(currentRMSSD: currentRMSSD)
            + restingHRInsights
            + stressInsights
            + sevenDayTrendInsights

        if stats.sessionCount < 7 {
            insights.append(String(localized: "With \(stats.sessionCount) sessions recorded, trends will become more accurate over time.", bundle: LanguageManager.appBundle))
        }

        return insights.joined(separator: " ")
    }

    private func rmssdAverageInsights(rmssdPct: Double) -> [String] {
        var insights: [String] = []
        if abs(rmssdPct) < HRVThresholds.trendModerateChange {
            insights.append("Your HRV is consistent with your recent average (\(String(format: "%.0f", locale: .current, stats.avgRMSSD))ms).")
        } else if rmssdPct > HRVThresholds.trendSignificantChange {
            insights.append("Your HRV is significantly higher than your average of \(String(format: "%.0f", locale: .current, stats.avgRMSSD))ms (+\(String(format: "%.0f", locale: .current, rmssdPct))%), suggesting excellent recovery today.")
        } else if rmssdPct > HRVThresholds.trendModerateChange {
            insights.append("Your HRV is above your average of \(String(format: "%.0f", locale: .current, stats.avgRMSSD))ms (+\(String(format: "%.0f", locale: .current, rmssdPct))%), indicating good recovery.")
        } else if rmssdPct < -HRVThresholds.trendSignificantChange {
            insights.append("Your HRV is significantly below your average of \(String(format: "%.0f", locale: .current, stats.avgRMSSD))ms (\(String(format: "%.0f", locale: .current, rmssdPct))%). Consider taking it easy today.")
        } else if rmssdPct < -HRVThresholds.trendModerateChange {
            insights.append("Your HRV is below your average of \(String(format: "%.0f", locale: .current, stats.avgRMSSD))ms (\(String(format: "%.0f", locale: .current, rmssdPct))%). Below your usual range.")
        }

        return insights
    }

    private func rmssdBaselineInsights(currentRMSSD: Double) -> [String] {
        var insights: [String] = []
        if let baseline = stats.baselineRMSSD {
            let baselineDiff = ((currentRMSSD - baseline) / baseline) * 100
            if baselineDiff < -HRVThresholds.baselineAboveThreshold {
                insights.append("This is \(String(format: "%.0f", locale: .current, abs(baselineDiff)))% below your personal baseline.")
            } else if baselineDiff > HRVThresholds.baselineAboveThreshold {
                insights.append("This is \(String(format: "%.0f", locale: .current, baselineDiff))% above your baseline—you're in great shape.")
            }
        }

        return insights
    }

    private var restingHRInsights: [String] {
        var insights: [String] = []
        let currentHR = result.timeDomain.meanHR
        let hrDiff = currentHR - stats.avgHR
        if hrDiff > HRVThresholds.hrElevationThreshold {
            insights.append("Resting heart rate is elevated (+\(String(format: "%.0f", locale: .current, hrDiff)) bpm), which may indicate stress, dehydration, or incomplete recovery.")
        } else if hrDiff < -HRVThresholds.hrElevationThreshold {
            insights.append("Resting heart rate is lower than average, suggesting good cardiovascular fitness or deep rest.")
        }

        return insights
    }

    private var stressInsights: [String] {
        var insights: [String] = []
        let currentStress = result.ansMetrics?.stressIndex
        if let stress = currentStress, let avgStress = stats.avgStress {
            if stress > avgStress * 1.3, stress > HRVThresholds.stressIndexElevated {
                insights.append("Stress markers are elevated compared to your norm. Consider stress management today.")
            }
        }

        return insights
    }

    private var sevenDayTrendInsights: [String] {
        var insights: [String] = []
        if let trend = stats.trend7Day {
            if trend > HRVThresholds.trendModerateChange {
                insights.append("Your 7-day HRV trend is improving (+\(String(format: "%.0f", locale: .current, trend))%)—keep doing what you're doing!")
            } else if trend < -HRVThresholds.trendModerateChange {
                insights.append("Your 7-day HRV trend shows a decline (\(String(format: "%.0f", locale: .current, trend))%). Consider prioritizing recovery.")
            }
        }
        return insights
    }

    // MARK: - Diagnostic score bands
    //
    // One function per metric, each returning the points that metric
    // contributes. `computeDiagnosticScore` then reads as a sum of named
    // contributions instead of one long accumulating branch chain.

    /// Baevsky stress index bands: <100 low, <150 normal, <200 elevated,
    /// <300 high, above that very high.
    static func stressIndexPoints(_ stressIndex: Double?) -> Double {
        guard let stress = stressIndex else { return 0 }
        if stress < HRVThresholds.stressIndexLow { return DiagnosticPoints.stressLow }
        if stress < HRVThresholds.stressIndexNormal { return DiagnosticPoints.stressNormal }
        if stress < HRVThresholds.stressIndexElevated { return DiagnosticPoints.stressElevated }
        if stress < HRVThresholds.stressIndexHigh { return DiagnosticPoints.stressHigh }
        return DiagnosticPoints.stressVeryHigh
    }

    /// LF/HF ratio bands, as empirical regions of the ratio — see the note on
    /// `HRVThresholds`'s LF/HF section for why these are not autonomic-state
    /// measurements.
    static func lfHfPoints(_ lfHfRatio: Double?) -> Double {
        guard let ratio = lfHfRatio else { return 0 }
        if ratio >= HRVThresholds.lfHfParasympatheticDominance,
           ratio <= HRVThresholds.lfHfOptimalUpper {
            return DiagnosticPoints.lfHfOptimal
        }
        if ratio < HRVThresholds.lfHfParasympatheticDominance {
            return DiagnosticPoints.lfHfParasympathetic
        }
        if ratio <= HRVThresholds.lfHfModerateSympatheticUpper {
            return DiagnosticPoints.lfHfModerate
        }
        return DiagnosticPoints.lfHfSympathetic
    }

}
