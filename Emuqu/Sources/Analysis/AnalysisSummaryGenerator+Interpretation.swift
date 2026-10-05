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

    /// The night's HRV band: against the user's own baseline once there is
    /// one, by age and sex before that.
    ///
    /// The card used the population band alone, so a 35-year-old whose normal
    /// is 22 ms scored 72 and read "Your HRV is low… your parasympathetic
    /// system is suppressed", while a fall from 90 to 42 ms read as fine.
    var hrvCategory: RMSSDCategory {
        guard let baseline = canonicalBaselineRMSSD, baseline > 0 else { return ageAdjustedInterpretation.category }
        return Self.personalCategory(ratio: result.timeDomain.rmssd / baseline)
    }

    /// Bands on the ratio to the baseline, on the readiness score's cut
    /// points: within 15% is the user's normal.
    static func personalCategory(ratio: Double) -> RMSSDCategory {
        let c = StressNormativeConstants.self
        if ratio >= c.rmssdRatioOptimalHigh { return .excellent }
        if ratio >= c.rmssdRatioOptimalLow { return .good }
        if ratio >= c.rmssdRatioAcceptableLow { return .fair }
        if ratio >= c.rmssdRatioExtremeLow { return .reduced }
        return .low
    }

    // MARK: - Diagnostic Score

    /// Diagnostic-score point weights. The THRESHOLDS are
    /// named (`HRVThresholds.*` / `StressNormativeConstants.*`);
    /// the points awarded at each band live here rather than inline
    /// so the weighting is auditable at a glance.
    private enum DiagnosticPoints {
        static let base = 50.0
        // RMSSD category (personal once a baseline exists, else age-adjusted)
        static let rmssdExcellent = 40.0, rmssdGood = 30.0, rmssdFair = 20.0,
                   rmssdReduced = 10.0, rmssdLow = -10.0
        // Stress index bands (low → very high)
        static let stressLow = 20.0, stressNormal = 15.0, stressElevated = 10.0,
                   stressHigh = 0.0, stressVeryHigh = -15.0
        // LF/HF ratio bands
        static let lfHfOptimal = 20.0, lfHfParasympathetic = 15.0,
                   lfHfModerate = 5.0, lfHfSympathetic = -10.0
        // DFA α1 bands
        static let dfaOptimal = 20.0
        // ANS balance bands
        static let ansStrongParasympathetic = 15.0, ansBalanced = 10.0,
                   ansMildSympathetic = -5.0, ansSympathetic = -15.0
    }

    func computeDiagnosticScore() -> Double {
        var score = DiagnosticPoints.base
        score += Self.rmssdPoints(hrvCategory)
        score += Self.stressIndexPoints(result.ansMetrics?.stressIndex)
        score += Self.lfHfPoints(result.frequencyDomain?.lfHfRatio)
        if let dfa = result.nonlinear.dfaAlpha1,
           dfa >= HRVThresholds.dfaAlpha1OptimalLower, dfa <= HRVThresholds.dfaAlpha1OptimalUpper {
            score += DiagnosticPoints.dfaOptimal
        }
        score += Self.ansBalancePoints(sns: result.ansMetrics?.snsIndex, pns: result.ansMetrics?.pnsIndex)
        return min(100, max(0, score))
    }

    /// Points for the RMSSD category: personal (against the user's own
    /// baseline) once one exists, age-adjusted before that.
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

    // MARK: - Headline Title and Icon

    /// The Recovery Score (0-100) the headline speaks for: the session's
    /// frozen breakdown, else its stored 0-10 score. Nil for a reading that
    /// carries no recovery score.
    var compositeHeadlineScore: Double? {
        session.scoreBreakdown?.compositeScore ?? session.recoveryScore.map { $0 * 10 }
    }

    /// The headline speaks the Recovery Score's own verdict, so the summary
    /// title, the PDF card and the assistant never disagree with the ring. A
    /// reading without a recovery score falls back to the diagnostic score on
    /// the same ladder.
    var headlineScore: Double {
        compositeHeadlineScore ?? computeDiagnosticScore()
    }

    var headlineVerdict: ScoreVerdict { ScoreVerdict(score: headlineScore) }

    var analysisTitle: String { NarrativeLanguage.isEnglish ? headlineVerdict.word : headlineVerdict.localizedWord }

    var diagnosticIcon: String { headlineVerdict.glyphName }

    // MARK: - Diagnostic Explanation

    /// No training-load sentence: it said low activity lowered the score, and
    /// load is not part of the score.
    var analysisExplanation: String {
        let inputs = explanationInputs
        switch hrvCategory {
        case .low: return ExplanationCopy.low(inputs)
        case .reduced: return ExplanationCopy.reduced(inputs)
        case .excellent: return ExplanationCopy.excellent(inputs)
        case .good: return ExplanationCopy.good(inputs)
        case .fair: return ExplanationCopy.fair(inputs)
        }
    }

    /// Everything the per-category builders read, gathered once.
    private var explanationInputs: ExplanationCopy.Inputs {
        let sleepFormatted = NarrativeLanguage.hoursMinutes(sleep.totalSleepMinutes)
        return ExplanationCopy.Inputs(
            rmssd: NarrativeLanguage.number(result.timeDomain.rmssd),
            stress: result.ansMetrics?.stressIndex ?? 150,
            lfhf: result.frequencyDomain?.lfHfRatio ?? 1.0,
            dfa: result.nonlinear.dfaAlpha1 ?? 1.0,
            // The age note only belongs to the population band.
            ageNote: canonicalBaselineRMSSD == nil ? populationAgePhrase.map { " (\($0))" } ?? "" : "",
            isShortSleep: sleep.isShortSleep,
            isGoodSleep: sleep.isGoodSleep,
            isFragmented: sleep.isFragmented,
            isConsolidated: result.isConsolidated ?? false,
            awakeMinutes: NarrativeLanguage.integer(sleep.awakeMinutes),
            sleepFormatted: sleepFormatted,
            sleepContext: sleepContextNote(sleepFormatted: sleepFormatted)
        )
    }

    /// The age band's phrase, mid-sentence; nil when no age was given.
    var populationAgePhrase: String? {
        let interpretation = ageAdjustedInterpretation
        guard interpretation.ageContext != nil else { return nil }
        return ExplanationCopy.agePhrase(interpretation.category)
    }

    /// The one sleep sentence appended to most category explanations — nil
    /// when no sleep was recorded, or when it was neither short nor fragmented
    /// nor inefficient.
    private func sleepContextNote(sleepFormatted: String) -> String? {
        guard sleep.totalSleepMinutes > 0 else { return nil }
        if sleep.isShortSleep {
            return String(localized: "Your short sleep (\(sleepFormatted)) is likely a major contributor.", bundle: NarrativeLanguage.bundle)
        }
        if sleep.isFragmented {
            let awake = NarrativeLanguage.integer(sleep.awakeMinutes)
            return String(localized: "Fragmented sleep (\(awake) min awake) may be reducing recovery quality.", bundle: NarrativeLanguage.bundle)
        }
        guard let efficiency = sleep.sleepEfficiency, efficiency < HRVThresholds.sleepEfficiencyLow else { return nil }
        let percent = NarrativeLanguage.integer(Int(efficiency.rounded()))
        return String(localized: "Low sleep efficiency (\(percent)%) limits restorative recovery.", bundle: NarrativeLanguage.bundle)
    }

    /// A good reading suppresses the negative causes. RMSSD is judged the way
    /// `hrvCategory` judges it: against the user's own baseline once there is
    /// one (at or above the "good" ratio), by the absolute cut before that.
    /// So a low-baseline user's normal night gets no negative causes, and a
    /// fall from 90 to 42 ms is not "good".
    private func isGoodReading(rmssd: Double, stress: Double, lfhf: Double, dfa: Double) -> Bool {
        isGoodRMSSD(rmssd) && stress < HRVThresholds.stressIndexElevated
            && lfhf < HRVThresholds.lfHfMildSympathetic && dfa < HRVThresholds.dfaAlpha1Fatigue
    }

    private func isGoodRMSSD(_ rmssd: Double) -> Bool {
        guard let baseline = canonicalBaselineRMSSD, baseline > 0 else { return rmssd >= HRVThresholds.rmssdModerate }
        return rmssd >= baseline * StressNormativeConstants.rmssdRatioOptimalLow
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
            isGoodReading: isGoodReading(rmssd: rmssd, stress: stress, lfhf: lfhf, dfa: dfa),
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
        let (avg, pct) = (NarrativeLanguage.number(stats.avgRMSSD), NarrativeLanguage.number(rmssdPct))
        if rmssdPct > HRVThresholds.trendSignificantChange {
            return [String(localized: "HRV is significantly higher than your recent baseline of \(avg)ms (+\(pct)%) — excellent recovery today", bundle: NarrativeLanguage.bundle)]
        } else if rmssdPct > HRVThresholds.trendModerateChange {
            return [String(localized: "HRV is above your recent baseline of \(avg)ms (+\(pct)%) — good recovery", bundle: NarrativeLanguage.bundle)]
        } else if rmssdPct < -HRVThresholds.trendSignificantChange {
            return [String(localized: "HRV is significantly below your recent baseline of \(avg)ms (\(pct)%) — recovery may be compromised", bundle: NarrativeLanguage.bundle)]
        } else if rmssdPct < -HRVThresholds.trendModerateChange {
            return [String(localized: "HRV is below your recent baseline of \(avg)ms (\(pct)%) — below your usual range", bundle: NarrativeLanguage.bundle)]
        }
        return []
    }

    /// The 5-night "personal baseline" line, only when there is no canonical
    /// scoring baseline: with one, `avgRMSSD` already is that baseline and a
    /// second, differently computed baseline could contradict it in one list.
    private func personalBaselineFindings(rmssd: Double) -> [String] {
        guard canonicalBaselineRMSSD == nil, let baseline = stats.baselineRMSSD, baseline > 0 else { return [] }
        let baselineDiff = ((rmssd - baseline) / baseline) * 100
        let pct = NarrativeLanguage.number(abs(baselineDiff))
        if baselineDiff > HRVThresholds.baselineAboveThreshold {
            return [String(localized: "You're \(pct)% above your personal baseline — you're in great shape", bundle: NarrativeLanguage.bundle)]
        } else if baselineDiff < -HRVThresholds.baselineAboveThreshold {
            return [String(localized: "You're \(pct)% below your personal baseline", bundle: NarrativeLanguage.bundle)]
        }
        return []
    }

    private var sevenDayTrendFindings: [String] {
        guard let trend = stats.trend7Day else { return [] }
        let pct = NarrativeLanguage.number(trend)
        if trend > HRVThresholds.trendModerateChange {
            return [String(localized: "Your 7-day HRV trend is improving (+\(pct)%) — keep doing what you're doing!", bundle: NarrativeLanguage.bundle)]
        } else if trend < -HRVThresholds.trendModerateChange {
            return [String(localized: "Your 7-day HRV trend shows a decline (\(pct)%)", bundle: NarrativeLanguage.bundle)]
        }
        return []
    }

    private var restingHRFindings: [String] {
        let hrDiff = result.timeDomain.meanHR - stats.avgHR
        let bpm = NarrativeLanguage.number(abs(hrDiff))
        if hrDiff > HRVThresholds.hrElevationThreshold {
            return [String(localized: "Resting HR is elevated (+\(bpm) bpm vs average) — possible stress or incomplete recovery", bundle: NarrativeLanguage.bundle)]
        } else if hrDiff < -HRVThresholds.hrElevationThreshold {
            return [String(localized: "Resting HR is lower than average (\(bpm) bpm) — good cardiovascular state", bundle: NarrativeLanguage.bundle)]
        }
        return []
    }

    /// The HRV band line shown when no trend finding fired. It reads
    /// `hrvCategory`, as the explanation does, so the two never disagree; the
    /// population age note only accompanies the population band.
    func ageAdjustedFindings(existingFindings: [String]) -> [String] {
        let agePhrase = canonicalBaselineRMSSD == nil ? populationAgePhrase : nil
        guard existingFindings.isEmpty else {
            return agePhrase.map { [String(localized: "This reading is \($0)", bundle: NarrativeLanguage.bundle)] } ?? []
        }
        let value = NarrativeLanguage.number(result.timeDomain.rmssd)
        let suffix = agePhrase.map { " — \($0)" } ?? ""
        switch hrvCategory {
        case .excellent: return [String(localized: "HRV is excellent at \(value)ms\(suffix)", bundle: NarrativeLanguage.bundle)]
        case .good: return [String(localized: "HRV is good at \(value)ms\(suffix)", bundle: NarrativeLanguage.bundle)]
        case .fair: return [String(localized: "HRV is fair at \(value)ms\(suffix)", bundle: NarrativeLanguage.bundle)]
        case .reduced: return [String(localized: "HRV is reduced at \(value)ms\(suffix)", bundle: NarrativeLanguage.bundle)]
        case .low: return [String(localized: "HRV is low at \(value)ms\(suffix)", bundle: NarrativeLanguage.bundle)]
        }
    }

    var stressFindings: [String] {
        guard let s = result.ansMetrics?.stressIndex else { return [] }
        let value = NarrativeLanguage.integer(Int(s))
        if s > HRVThresholds.stressIndexHigh {
            return [String(localized: "Stress index is high (\(value)) - significant physiological load", bundle: NarrativeLanguage.bundle)]
        } else if s > HRVThresholds.stressIndexNormal {
            return [String(localized: "Stress index is elevated (\(value)) - moderate strain present", bundle: NarrativeLanguage.bundle)]
        } else if s > HRVThresholds.stressIndexVeryLow {
            return [String(localized: "Stress index is normal (\(value)) - within typical resting range", bundle: NarrativeLanguage.bundle)]
        } else {
            return [String(localized: "Stress index is low (\(value)) - very relaxed state", bundle: NarrativeLanguage.bundle)]
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
                return [String(localized: "Your LF/HF ratio is high, but your other markers are strong — this is common sleep-stage variation", bundle: NarrativeLanguage.bundle)]
            } else {
                return [String(localized: "Your LF/HF ratio is above its usual resting range — deep breathing or a gentle walk may help you wind down", bundle: NarrativeLanguage.bundle)]
            }
        } else if ratio < HRVThresholds.lfHfParasympatheticDominance {
            return [String(localized: "Your LF/HF ratio is low, the pattern typical of settled rest", bundle: NarrativeLanguage.bundle)]
        } else if ratio >= HRVThresholds.lfHfBalancedLower, ratio <= HRVThresholds.lfHfBalancedUpper {
            return [String(localized: "Your LF/HF ratio sits in its usual resting range", bundle: NarrativeLanguage.bundle)]
        }
        return []
    }

    var heartRhythmFindings: [String] {
        let rmssd = result.timeDomain.rmssd
        let pnn50 = result.timeDomain.pnn50
        let hasStrongVagalTone = pnn50 > HRVThresholds.pnn50Moderate && rmssd >= HRVThresholds.rmssdModerate
        guard let alpha = result.nonlinear.dfaAlpha1 else { return [] }
        if alpha > HRVThresholds.dfaAlpha1ClearlyElevated {
            return [String(localized: "Your heart rhythm pattern suggests accumulated fatigue — consider extra rest today", bundle: NarrativeLanguage.bundle)]
        } else if alpha > HRVThresholds.dfaAlpha1Fatigue {
            if hasStrongVagalTone {
                return [String(localized: "Heart rhythm patterns are within normal variation", bundle: NarrativeLanguage.bundle)]
            } else {
                return [String(localized: "Your heart rhythm suggests you may be carrying some fatigue — don't overdo it", bundle: NarrativeLanguage.bundle)]
            }
        } else if alpha >= HRVThresholds.dfaAlpha1OptimalLower, alpha <= HRVThresholds.dfaAlpha1OptimalUpper {
            return [String(localized: "DFA α1 was within the app's reference range last night", bundle: NarrativeLanguage.bundle)]
        } else if alpha < HRVThresholds.dfaAlpha1OptimalLower, alpha >= HRVThresholds.dfaAlpha1FlexibleLower {
            return [String(localized: "Your heart rhythm is less organized than usual — this often improves with consistent sleep", bundle: NarrativeLanguage.bundle)]
        }
        return []
    }

    var windowQualityFindings: [String] {
        let isOrganized = result.isOrganizedRecovery ?? true
        guard !isOrganized else { return [] }
        let dfa = result.nonlinear.dfaAlpha1
        if let alpha = dfa {
            if alpha < HRVThresholds.dfaAlpha1Disorganized {
                return [String(localized: "Your body didn't settle into a steady recovery pattern overnight. The score reflects your recovery capacity, but you may not be fully ready for heavy demands.", bundle: NarrativeLanguage.bundle)]
            } else if alpha > HRVThresholds.dfaAlpha1HighVariability {
                return [String(localized: "Signs of fatigue in your heart rhythm. The score shows what your body can handle, but take it easier than usual.", bundle: NarrativeLanguage.bundle)]
            } else {
                return [String(localized: "Your recovery wasn't fully consolidated overnight. The score may be slightly optimistic — listen to your body.", bundle: NarrativeLanguage.bundle)]
            }
        } else {
            return [String(localized: "No deep recovery window was detected overnight. The score reflects your capacity, but real-world readiness may be lower.", bundle: NarrativeLanguage.bundle)]
        }
    }

    var beatVariationFindings: [String] {
        let pnn50 = result.timeDomain.pnn50
        if pnn50 < HRVThresholds.pnn50VeryLow {
            return [String(localized: "Very low beat-to-beat variation — your nervous system recovery signals are weak", bundle: NarrativeLanguage.bundle)]
        } else if pnn50 > HRVThresholds.pnn50Strong {
            return [String(localized: "Strong beat-to-beat variation — your body is recovering well", bundle: NarrativeLanguage.bundle)]
        }
        return []
    }

    var sleepFindings: [String] {
        guard sleep.totalSleepMinutes > 0 else { return [] }
        return sleepDurationFindings + sleepEfficiencyFindings
    }

    private var sleepDurationFindings: [String] {
        let rmssd = result.timeDomain.rmssd
        let hours = NarrativeLanguage.number(Double(sleep.totalSleepMinutes) / 60.0, decimals: 1)
        let isGoodHRV = rmssd >= HRVThresholds.rmssdModerate || (stats.hasData && rmssd >= stats.avgRMSSD * 0.95)
        let isExcellentHRV = stats.hasData && rmssd > stats.avgRMSSD * 1.1
        if sleep.totalSleepMinutes < HRVThresholds.sleepShortMinutes {
            if isExcellentHRV {
                return [String(localized: "Remarkable: Excellent HRV despite only \(hours)h sleep — your recovery capacity is impressive", bundle: NarrativeLanguage.bundle)]
            } else if isGoodHRV {
                return [String(localized: "Solid HRV despite \(hours)h sleep — you're handling the short night well", bundle: NarrativeLanguage.bundle)]
            }
            return [String(localized: "Short sleep (\(hours)h) — likely a major factor in reduced HRV", bundle: NarrativeLanguage.bundle)]
        } else if sleep.totalSleepMinutes >= HRVThresholds.sleepMinimumMinutes, isExcellentHRV {
            return [String(localized: "Great combo: \(hours)h sleep + HRV above your usual range", bundle: NarrativeLanguage.bundle)]
        }
        return []
    }

    private var sleepEfficiencyFindings: [String] {
        guard let efficiency = sleep.sleepEfficiency else { return [] }
        let percent = NarrativeLanguage.integer(Int(efficiency.rounded()))
        if efficiency >= HRVThresholds.sleepEfficiencyExcellent {
            return [String(localized: "Sleep efficiency \(percent)% — nearly uninterrupted rest", bundle: NarrativeLanguage.bundle)]
        } else if efficiency < HRVThresholds.sleepEfficiencyLow, sleep.inBedMinutes > HRVThresholds.sleepVeryShortMinutes {
            let awake = NarrativeLanguage.integer(sleep.awakeMinutes)
            return [String(localized: "Low sleep efficiency (\(percent)%) — \(awake) min awake during the night", bundle: NarrativeLanguage.bundle)]
        }
        return []
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
        let avgHours = trends.averageSleepMinutes / 60.0
        let avg = NarrativeLanguage.number(avgHours, decimals: 1)
        switch trends.trend {
        case .declining:
            return [String(localized: "Sleep trending down over past \(trends.nightsAnalyzed) nights (avg \(avg)h) — watch for cumulative fatigue", bundle: NarrativeLanguage.bundle)]
        case .improving:
            return isGoodHRV ? [String(localized: "Sleep improving over past week — your body is responding positively", bundle: NarrativeLanguage.bundle)] : []
        case .stable:
            return avgHours >= 7 && isGoodHRV ? [String(localized: "Consistent \(avg)h average sleep supporting steady HRV", bundle: NarrativeLanguage.bundle)] : []
        case .insufficient:
            return []
        }
    }

    /// Called out only when tonight is well off the recent average — a small
    /// nightly wobble is not news.
    private func tonightVsAverageFindings(_ sleepDiffPercent: Double, avgHours: Double) -> [String] {
        guard abs(sleepDiffPercent) > 25 else { return [] }
        let tonight = NarrativeLanguage.number(Double(sleep.totalSleepMinutes) / 60.0, decimals: 1)
        let pct = NarrativeLanguage.integer(Int(abs(sleepDiffPercent)))
        if sleepDiffPercent > 25 {
            return [String(localized: "Tonight's \(tonight)h is \(pct)% above your recent average", bundle: NarrativeLanguage.bundle)]
        }
        let avg = NarrativeLanguage.number(avgHours, decimals: 1)
        return [String(localized: "Tonight's \(tonight)h is \(pct)% below your \(avg)h average", bundle: NarrativeLanguage.bundle)]
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
                return [String(localized: "Recent training is below your usual range — regular activity helps maintain fitness", bundle: NarrativeLanguage.bundle)]
            } else if acr > TrainingConstants.ACR.overreaching {
                return [String(localized: "Recent training jumped sharply vs your usual range — an easier session helps you absorb the work", bundle: NarrativeLanguage.bundle)]
            } else if acr > TrainingConstants.ACR.building {
                return [String(localized: "Recent training is above your usual range — listen to your body for signs of accumulated fatigue", bundle: NarrativeLanguage.bundle)]
            }
        } else if training.ctl < RecoveryScoreConstants.Readiness.ctlThreshold, training.atl < RecoveryScoreConstants.Readiness.ctlThreshold {
            return [String(localized: "Very low activity level — even light exercise like walking helps maintain fitness", bundle: NarrativeLanguage.bundle)]
        }
        return []
    }

    // MARK: - Trend Insight

    var trendInsight: String {
        guard stats.hasData else { return String(localized: "Record more sessions to see trends.", bundle: NarrativeLanguage.bundle) }
        let currentRMSSD = result.timeDomain.rmssd
        let rmssdPct = ((currentRMSSD - stats.avgRMSSD) / stats.avgRMSSD) * 100
        var insights = rmssdAverageInsights(rmssdPct: rmssdPct)
            + rmssdBaselineInsights(currentRMSSD: currentRMSSD)
            + restingHRInsights
            + stressInsights
            + sevenDayTrendInsights
        if stats.sessionCount < 7 {
            insights.append(String(localized: "With \(stats.sessionCount) sessions recorded, trends will become more accurate over time.", bundle: NarrativeLanguage.bundle))
        }
        return insights.joined(separator: " ")
    }

    private func rmssdAverageInsights(rmssdPct: Double) -> [String] {
        let (avg, pct) = (NarrativeLanguage.number(stats.avgRMSSD), NarrativeLanguage.number(rmssdPct))
        if abs(rmssdPct) < HRVThresholds.trendModerateChange {
            return [String(localized: "Your HRV is consistent with your recent average (\(avg)ms).", bundle: NarrativeLanguage.bundle)]
        } else if rmssdPct > HRVThresholds.trendSignificantChange {
            return [String(localized: "Your HRV is significantly higher than your average of \(avg)ms (+\(pct)%), suggesting excellent recovery today.", bundle: NarrativeLanguage.bundle)]
        } else if rmssdPct > HRVThresholds.trendModerateChange {
            return [String(localized: "Your HRV is above your average of \(avg)ms (+\(pct)%), indicating good recovery.", bundle: NarrativeLanguage.bundle)]
        } else if rmssdPct < -HRVThresholds.trendSignificantChange {
            return [String(localized: "Your HRV is significantly below your average of \(avg)ms (\(pct)%). Consider taking it easy today.", bundle: NarrativeLanguage.bundle)]
        } else if rmssdPct < -HRVThresholds.trendModerateChange {
            return [String(localized: "Your HRV is below your average of \(avg)ms (\(pct)%). Below your usual range.", bundle: NarrativeLanguage.bundle)]
        }
        return []
    }

    /// Same rule as `personalBaselineFindings`: silent when the canonical
    /// baseline is present.
    private func rmssdBaselineInsights(currentRMSSD: Double) -> [String] {
        guard canonicalBaselineRMSSD == nil, let baseline = stats.baselineRMSSD, baseline > 0 else { return [] }
        let baselineDiff = ((currentRMSSD - baseline) / baseline) * 100
        let pct = NarrativeLanguage.number(abs(baselineDiff))
        if baselineDiff < -HRVThresholds.baselineAboveThreshold {
            return [String(localized: "This is \(pct)% below your personal baseline.", bundle: NarrativeLanguage.bundle)]
        } else if baselineDiff > HRVThresholds.baselineAboveThreshold {
            return [String(localized: "This is \(pct)% above your baseline—you're in great shape.", bundle: NarrativeLanguage.bundle)]
        }
        return []
    }

    private var restingHRInsights: [String] {
        let hrDiff = result.timeDomain.meanHR - stats.avgHR
        if hrDiff > HRVThresholds.hrElevationThreshold {
            let bpm = NarrativeLanguage.number(hrDiff)
            return [String(localized: "Resting heart rate is elevated (+\(bpm) bpm), which may indicate stress, dehydration, or incomplete recovery.", bundle: NarrativeLanguage.bundle)]
        } else if hrDiff < -HRVThresholds.hrElevationThreshold {
            return [String(localized: "Resting heart rate is lower than average, suggesting good cardiovascular fitness or deep rest.", bundle: NarrativeLanguage.bundle)]
        }
        return []
    }

    private var stressInsights: [String] {
        guard let stress = result.ansMetrics?.stressIndex, let avgStress = stats.avgStress,
              stress > avgStress * 1.3, stress > HRVThresholds.stressIndexElevated else { return [] }
        return [String(localized: "Stress markers are elevated compared to your norm. Consider stress management today.", bundle: NarrativeLanguage.bundle)]
    }

    private var sevenDayTrendInsights: [String] {
        guard let trend = stats.trend7Day else { return [] }
        let pct = NarrativeLanguage.number(trend)
        if trend > HRVThresholds.trendModerateChange {
            return [String(localized: "Your 7-day HRV trend is improving (+\(pct)%)—keep doing what you're doing!", bundle: NarrativeLanguage.bundle)]
        } else if trend < -HRVThresholds.trendModerateChange {
            return [String(localized: "Your 7-day HRV trend shows a decline (\(pct)%). Consider prioritizing recovery.", bundle: NarrativeLanguage.bundle)]
        }
        return []
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

// MARK: - Explanation copy

/// The "What This Means" paragraph, one builder per HRV band, in
/// `NarrativeLanguage`. Each joins its sentences with a space.
enum ExplanationCopy {
    /// What the builders read, numbers already formatted. A struct rather
    /// than a dozen parameters: SwiftLint caps a signature at seven.
    struct Inputs {
        let rmssd: String
        let stress: Double
        let lfhf: Double
        let dfa: Double
        /// " (below average for your age)", or empty.
        let ageNote: String
        let isShortSleep: Bool
        let isGoodSleep: Bool
        let isFragmented: Bool
        let isConsolidated: Bool
        let awakeMinutes: String
        let sleepFormatted: String
        let sleepContext: String?
    }

    /// The population age band, written to sit mid-sentence.
    static func agePhrase(_ category: RMSSDCategory) -> String {
        switch category {
        case .excellent: String(localized: "well above average for your age", bundle: NarrativeLanguage.bundle)
        case .good: String(localized: "above average for your age", bundle: NarrativeLanguage.bundle)
        case .fair: String(localized: "typical for your age", bundle: NarrativeLanguage.bundle)
        case .reduced: String(localized: "below average for your age", bundle: NarrativeLanguage.bundle)
        case .low: String(localized: "significantly below average for your age", bundle: NarrativeLanguage.bundle)
        }
    }

    static func low(_ v: Inputs) -> String {
        let opening = String(localized: "Your HRV is low at \(v.rmssd)ms\(v.ageNote).", bundle: NarrativeLanguage.bundle)
        if v.isShortSleep {
            return join(opening, String(localized: "With only \(v.sleepFormatted) of sleep, your body hasn't had adequate time to recover. This is the most likely explanation for your low HRV.", bundle: NarrativeLanguage.bundle))
        }
        let reason = if v.stress > HRVThresholds.stressIndexHigh {
            String(localized: "Combined with high stress markers, this pattern is most often seen after hard training, very short or poor sleep, alcohol, heavy stress or travel, and sometimes at the start of an illness.", bundle: NarrativeLanguage.bundle)
        } else if v.lfhf > HRVThresholds.lfHfSympatheticDominance {
            String(localized: "Your LF/HF ratio is well above its usual resting range too. That pattern turns up with mental or emotional stress, poor sleep quality, alcohol, and sometimes the start of an illness — though the ratio also moves with breathing rate, so read it alongside the rest.",
                bundle: NarrativeLanguage.bundle)
        } else {
            String(localized: "This suggests your parasympathetic (rest-and-digest) system is suppressed. Common causes include heavy recent training load, short or poor sleep, alcohol, ongoing stress, and sometimes the start of an illness.", bundle: NarrativeLanguage.bundle)
        }
        return join(opening, reason, v.sleepContext)
    }

    static func reduced(_ v: Inputs) -> String {
        let opening = String(localized: "Your HRV is reduced at \(v.rmssd)ms\(v.ageNote).", bundle: NarrativeLanguage.bundle)
        if v.isShortSleep {
            return join(opening, String(localized: "Your short sleep duration (\(v.sleepFormatted)) is likely contributing to incomplete recovery.", bundle: NarrativeLanguage.bundle))
        }
        if v.isFragmented {
            return join(opening, String(localized: "Fragmented sleep (\(v.awakeMinutes) min awake) may be preventing deep recovery even with adequate duration.", bundle: NarrativeLanguage.bundle))
        }
        let reason = if v.dfa > HRVThresholds.dfaAlpha1Fatigue {
            String(localized: "The reduced complexity in your heart rhythm suggests fatigue or incomplete recovery from recent demands.", bundle: NarrativeLanguage.bundle)
        } else if v.stress > HRVThresholds.stressIndexElevated {
            String(localized: "Elevated stress markers suggest your body is working harder than usual to maintain balance.", bundle: NarrativeLanguage.bundle)
        } else {
            String(localized: "This may reflect accumulated fatigue, short sleep, alcohol, mild dehydration or stress, and occasionally the start of an illness.", bundle: NarrativeLanguage.bundle)
        }
        return join(opening, reason, v.sleepContext)
    }

    static func excellent(_ v: Inputs) -> String {
        let opening = String(localized: "Your HRV of \(v.rmssd)ms indicates strong vagal tone and excellent recovery capacity\(v.ageNote).", bundle: NarrativeLanguage.bundle)
        let reason = if v.isGoodSleep, !v.isFragmented, v.isConsolidated {
            String(localized: "Quality sleep (\(v.sleepFormatted)) combined with stable, sustained recovery patterns means you're fully ready for demands.", bundle: NarrativeLanguage.bundle)
        } else if v.isShortSleep {
            String(localized: "However, with only \(v.sleepFormatted) of sleep, treat this as capacity rather than a green light.", bundle: NarrativeLanguage.bundle)
        } else if !v.isConsolidated {
            String(localized: "The pattern shows capacity but wasn't sustained long enough to confirm full readiness. Listen to your body.", bundle: NarrativeLanguage.bundle)
        } else if v.stress < HRVThresholds.stressIndexLow {
            String(localized: "Low stress markers confirm your nervous system is well-balanced and recovery is consolidated.", bundle: NarrativeLanguage.bundle)
        } else {
            String(localized: "Your beat-to-beat variation is in a good place relative to your own recent nights.", bundle: NarrativeLanguage.bundle)
        }
        return join(opening, reason)
    }

    static func good(_ v: Inputs) -> String {
        let opening = String(localized: "Your HRV of \(v.rmssd)ms is good\(v.ageNote).", bundle: NarrativeLanguage.bundle)
        let reason = if v.isGoodSleep, !v.isFragmented {
            String(localized: "Combined with quality sleep, you're well-positioned for activity today.", bundle: NarrativeLanguage.bundle)
        } else if v.isShortSleep {
            String(localized: "With better sleep, you could see even stronger recovery.", bundle: NarrativeLanguage.bundle)
        } else {
            String(localized: "Your autonomic nervous system is well-balanced.", bundle: NarrativeLanguage.bundle)
        }
        return join(opening, reason)
    }

    static func fair(_ v: Inputs) -> String {
        let opening = String(localized: "Your HRV of \(v.rmssd)ms is in a moderate range\(v.ageNote).", bundle: NarrativeLanguage.bundle)
        if v.isShortSleep {
            return join(opening, String(localized: "With only \(v.sleepFormatted) of sleep, your HRV may improve with better rest.", bundle: NarrativeLanguage.bundle))
        }
        if v.lfhf > HRVThresholds.lfHfOptimalUpper {
            return join(opening, String(localized: "There's some sympathetic activation present, which could be residual from yesterday's activities or mild ongoing stress.", bundle: NarrativeLanguage.bundle), v.sleepContext)
        }
        return join(opening, String(localized: "Your autonomic nervous system is reasonably balanced.", bundle: NarrativeLanguage.bundle))
    }

    private static func join(_ sentences: String?...) -> String {
        sentences.compactMap { $0 }.joined(separator: " ")
    }
}
