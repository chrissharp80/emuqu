import Foundation

/// Stress and ANS Index Analysis
/// Includes Baevsky's Stress Index, PNS Index, SNS Index
enum StressAnalyzer {
    // MARK: - Stress Index (Baevsky's SI)

    /// Compute Baevsky's Stress Index
    /// SI = AMo / (2 * Mo * MxDMn)
    /// Where:
    ///   AMo = amplitude of mode (% of intervals in modal bin)
    ///   Mo = mode (most frequent RR interval)
    ///   MxDMn = difference between max and min RR
    ///
    /// - Parameter rr: RR intervals in ms
    /// - Returns: Stress Index value, or nil if insufficient data
    static func computeStressIndex(_ rr: [Double]) -> Double? {
        guard rr.count >= StressNormativeConstants.stressIndexMinRRCount else { return nil }
        let minRR = rr.min() ?? 0
        let maxRR = rr.max() ?? 0
        let mxdmn = (maxRR - minRR) / 1_000.0 // seconds
        guard mxdmn > 0, let histogram = stressIndexHistogram(rr, minRR: minRR, maxRR: maxRR) else { return nil }
        let binWidth = StressNormativeConstants.stressIndexBinWidthMs
        let maxBinCount = histogram.max() ?? 0
        let modalBinIndex = histogram.firstIndex(of: maxBinCount) ?? 0
        // Mode in seconds, amplitude of mode as a percentage.
        let mo = (minRR + Double(modalBinIndex) * binWidth + binWidth / 2) / 1_000.0
        let amo = Double(maxBinCount) / Double(rr.count) * 100.0
        guard mo > 0 else { return nil }
        return amo / (2.0 * mo * mxdmn)
    }

    /// RR histogram at the standard SI bin width.
    private static func stressIndexHistogram(_ rr: [Double], minRR: Double, maxRR: Double) -> [Int]? {
        let binWidth = StressNormativeConstants.stressIndexBinWidthMs
        let binCount = Int(ceil((maxRR - minRR) / binWidth)) + 1
        guard binCount > 0 else { return nil }
        var histogram = [Int](repeating: 0, count: binCount)
        for interval in rr {
            let binIndex = Int((interval - minRR) / binWidth)
            if binIndex >= 0, binIndex < binCount { histogram[binIndex] += 1 }
        }
        return histogram
    }

    // MARK: - PNS / SNS Indices
    //
    // How these relate to Kubios' indices of the same name, stated precisely
    // ("Reference values from Kubios normative data" is true, and not the
    // whole story):
    //
    //   SAME: the input triples. Kubios publishes them, and ours match — PNS
    //   from mean RR, RMSSD and SD1; SNS from mean HR, Baevsky's Stress Index
    //   and SD2.
    //
    //   SAME: the normative values they are standardised against. RMSSD
    //   42 ± 19 ms, mean RR 926 ± 90 ms and the rest come from Nunan 2010,
    //   which is the source Kubios cites too.
    //
    //   DIFFERENT: Kubios standardises SD1 and SD2 in NORMALISED units. We use
    //   raw-millisecond z-scores. Same input, different scaling.
    //
    //   DIFFERENT: the combination. Kubios states that a proprietary weighting
    //   is applied and does not publish it. Ours is an equal-thirds mean —
    //   a defensible default, but a stand-in for a formula we cannot see
    //   rather than a reproduction of it.
    //
    // The consequence, which is the part that matters: these values will not
    // match Kubios' for the same recording, and are not intended to. They are
    // Emuqu's composites, built from the same published ingredients. The
    // user-facing wording in `MorningResultsPopovers` says so.

    /// Compute PNS Index — composite parasympathetic activity score.
    /// Inputs and norms follow Kubios' published description; the equal
    /// weighting is ours. See the note above the MARK.
    ///
    /// - Parameters:
    ///   - meanRR: Mean RR interval in ms
    ///   - rmssd: RMSSD in ms
    ///   - sd1: Poincaré SD1 in ms
    /// - Returns: PNS Index (typically -3 to +3)
    static func computePNSIndex(meanRR: Double, rmssd: Double, sd1: Double) -> Double {
        // Z-scores against normative reference values (healthy adults, supine)
        let zMeanRR = (meanRR - StressNormativeConstants.refMeanRR) / StressNormativeConstants.refMeanRR_SD
        let zRMSSD = (rmssd - StressNormativeConstants.refRMSSD) / StressNormativeConstants.refRMSSD_SD
        let zSD1 = (sd1 - StressNormativeConstants.refSD1) / StressNormativeConstants.refSD1_SD

        // Equal weights — see the note above the MARK on why this is ours
        // rather than Kubios'.
        return (zMeanRR + zRMSSD + zSD1) / 3.0
    }

    // MARK: - SNS Index (Sympathetic)

    /// Compute SNS Index — composite sympathetic activity score.
    /// Inputs and norms follow Kubios' published description; the equal
    /// weighting is ours. See the note above the PNS/SNS MARK.
    ///
    /// - Parameters:
    ///   - meanHR: Mean heart rate in bpm
    ///   - stressIndex: Baevsky's Stress Index
    ///   - sd2: Poincaré SD2 in ms
    /// - Returns: SNS Index (typically -3 to +3)
    static func computeSNSIndex(meanHR: Double, stressIndex: Double, sd2: Double) -> Double {
        // Z-scores (note: higher HR and SI = more sympathetic, lower SD2 = more sympathetic)
        let zMeanHR = (meanHR - StressNormativeConstants.refMeanHR) / StressNormativeConstants.refMeanHR_SD
        let zSI = (stressIndex - StressNormativeConstants.refSI) / StressNormativeConstants.refSI_SD
        let zSD2 = -(sd2 - StressNormativeConstants.refSD2) / StressNormativeConstants.refSD2_SD // Inverted: lower SD2 = higher sympathetic

        // Weighted average
        return (zMeanHR + zSI + zSD2) / 3.0
    }

    // MARK: - Readiness Score

    /// Compute a recovery/readiness score based on HRV metrics and training context
    /// Higher = better recovered
    /// Based on resting HRV compared to baseline, adjusted for recent training load
    ///
    /// - Parameters:
    ///   - rmssd: Current RMSSD
    ///   - baselineRMSSD: Baseline RMSSD (7-day average or user-set)
    ///   - alpha1: DFA α1 value
    ///   - pnsIndex: Parasympathetic index (optional)
    ///   - snsIndex: Sympathetic index (optional)
    ///   - trainingLoadAdjustment: Adjustment based on recent workout intensity (-2 to +1)
    ///     - Negative values indicate recent hard training (expect lower HRV, adjust score up)
    ///     - Zero means no adjustment needed
    ///   - vo2Max: User's VO2max for fitness-adjusted baseline (optional)
    /// - Returns: Readiness score 1-10
    static func computeReadinessScore(
        rmssd: Double,
        baselineRMSSD: Double?,
        alpha1: Double?,
        pnsIndex: Double? = nil,
        snsIndex: Double? = nil,
        trainingLoadAdjustment: Double = 0,
        vo2Max: Double? = nil
    ) -> Double {
        var score = StressNormativeConstants.readinessNeutralBaseline
        score += rmssdAdjustment(
            rmssd: rmssd,
            baseline: fitnessAdjustedBaseline(baselineRMSSD: baselineRMSSD, vo2Max: vo2Max),
            vo2Max: vo2Max
        )
        score += dfaAdjustment(alpha1)
        score += ansBalanceAdjustment(snsIndex: snsIndex, pnsIndex: pnsIndex)
        // Recent hard training: low HRV is expected, so don't penalize it.
        // Subtracting a negative adjustment raises the score.
        if trainingLoadAdjustment < 0 { score -= trainingLoadAdjustment }
        return max(1.0, min(10.0, score))
    }

    /// Higher VO2max implies a higher expected HRV baseline — elite athletes
    /// (VO2max 60+) can run 20-30% higher RMSSD.
    private static func fitnessAdjustedBaseline(baselineRMSSD: Double?, vo2Max: Double?) -> Double? {
        guard let baseline = baselineRMSSD, let vo2 = vo2Max else { return baselineRMSSD }
        let raw = 1.0 + ((vo2 - StressNormativeConstants.fitnessMultiplierCenterVO2) / StressNormativeConstants.fitnessMultiplierDivisor)
        let fitnessMultiplier = max(
            StressNormativeConstants.fitnessMultiplierMin,
            min(StressNormativeConstants.fitnessMultiplierMax, raw)
        )
        return baseline * fitnessMultiplier
    }

    /// Against a baseline: optimal is a ratio near 1.0, with large deviations
    /// either way penalized. Without one, fall back to absolute RMSSD bands.
    private static func rmssdAdjustment(rmssd: Double, baseline: Double?, vo2Max: Double?) -> Double {
        guard let baseline, baseline > 0 else {
            let t = rmssdThresholds(vo2Max: vo2Max)
            return absoluteRMSSDAdjustment(rmssd, high: t.high, mid: t.mid, low: t.low)
        }
        let ratio = rmssd / baseline
        let c = StressNormativeConstants.self
        if ratio >= c.rmssdRatioOptimalLow, ratio <= c.rmssdRatioOptimalHigh {
            return c.readinessRMSSDOptimalBonus
        }
        if ratio >= c.rmssdRatioAcceptableLow, ratio <= c.rmssdRatioAcceptableHigh {
            return c.readinessRMSSDAcceptableBonus
        }
        if ratio < c.rmssdRatioExtremeLow || ratio > c.rmssdRatioExtremeHigh {
            return -c.readinessRMSSDExtremePenalty
        }
        return 0
    }

    /// Fit individuals carry higher absolute RMSSD, so their bands sit higher.
    private static func rmssdThresholds(vo2Max: Double?) -> (high: Double, mid: Double, low: Double) {
        let c = StressNormativeConstants.self
        guard let vo2 = vo2Max, vo2 > c.vo2MaxFitThreshold else {
            return (c.rmssdStandardHigh, c.rmssdStandardMid, c.rmssdStandardLow)
        }
        return (c.rmssdFitHigh, c.rmssdFitMid, c.rmssdFitLow)
    }

    /// DFA α1 in its optimal recovery range.
    private static func dfaAdjustment(_ alpha1: Double?) -> Double {
        guard let a1 = alpha1 else { return 0 }
        let c = StressNormativeConstants.self
        if a1 >= HRVThresholds.dfaAlpha1OptimalLower, a1 <= HRVThresholds.dfaAlpha1OptimalUpper {
            return c.readinessDFAOptimalBonus
        }
        if a1 >= HRVThresholds.dfaAlpha1FlexibleLower, a1 <= c.readinessDFAAlpha1FlexibleUpper {
            return c.readinessDFAFlexibleBonus
        }
        return -c.readinessDFAPenalty
    }

    /// Adjusts readiness by the gap between the two composite indices.
    ///
    /// This is NOT "penalizes sympathetic dominance: when SNS >> PNS
    /// the body is in a stressed/activated state, not fully recovered", for
    /// three reasons.
    ///
    /// The indices are Emuqu's own equal-weight z-score means, not Kubios'
    /// proprietary formula (see the note above the PNS/SNS MARK). Their
    /// difference has never been validated against any measure of autonomic
    /// state. And "not fully recovered" is a verdict the app is not in a
    /// position to issue from it.
    ///
    /// The arithmetic is deliberately kept: it is a mild, bounded
    /// adjustment, and altering it would rewrite every user's readiness history
    /// on no better evidence than it was written with. Only the
    /// claim differs. Read it as: when the stress-side composite runs well above the
    /// rest-side one, readiness is nudged down. That is a heuristic about two
    /// derived numbers, not a measurement of autonomic balance.
    private static func ansBalanceAdjustment(snsIndex: Double?, pnsIndex: Double?) -> Double {
        guard let sns = snsIndex, let pns = pnsIndex else { return 0 }
        let c = StressNormativeConstants.self
        let balance = pns - sns // Positive = parasympathetic dominant (good)
        if balance >= c.ansBalanceStrongParasympathetic { return c.readinessANSStrongParaBonus }
        if balance >= 0 { return c.readinessANSBalancedBonus }
        if balance >= c.ansBalanceMildSympathetic { return -c.readinessANSMildSympPenalty }
        return -c.readinessANSStrongSympPenalty
    }

    /// Absolute-RMSSD adjustment, used when no personal baseline exists yet.
    ///
    /// Thresholds are fitness-adjusted by the caller; this only maps a value to
    /// its band. Split out so `computeReadinessScore` reads as a sequence of
    /// named adjustments rather than one long branch chain.
    private static func absoluteRMSSDAdjustment(
        _ rmssd: Double,
        high: Double,
        mid: Double,
        low: Double
    ) -> Double {
        if rmssd > high { return StressNormativeConstants.readinessAbsoluteRMSSDHighBonus }
        if rmssd > mid { return StressNormativeConstants.readinessAbsoluteRMSSDMidBonus }
        if rmssd < low { return -StressNormativeConstants.readinessAbsoluteRMSSDLowPenalty }
        return 0
    }

}
