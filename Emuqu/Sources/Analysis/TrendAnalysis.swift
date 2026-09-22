import Foundation

/// Trend analysis for multi-session HRV comparison
enum TrendAnalyzer {
    // MARK: - Data Point

    /// Single data point for trend analysis
    struct TrendDataPoint: Codable, Identifiable {
        let id: UUID
        let date: Date
        let rmssd: Double
        let sdnn: Double
        let meanHR: Double
        let lfHfRatio: Double?
        let hf: Double?
        let lf: Double?
        let dfaAlpha1: Double?
        let stressIndex: Double?
        let readinessScore: Double?
        let artifactPercent: Double
        /// User-reported morning feeling (1–5). Parallel signal, never blended
        /// into the composite score (Saw et al. 2016, Altini 2021) — surfaced
        /// on its own trend line and heatmap.
        let morningFeeling: Int?
        /// Optional context tags attached to a low-feeling morning.
        /// Used by the heatmap's Body/Mind cluster filter and correlation work.
        let morningFeelingTags: [MorningFeelingTag]?

        /// The analysis-derived fields, with the "not analyzed yet" defaults in
        /// one place instead of a mirrored else-branch.
        private struct Metrics {
            var rmssd: Double = 0
            var sdnn: Double = 0
            var meanHR: Double = 0
            var lfHfRatio: Double?
            var hf: Double?
            var lf: Double?
            var dfaAlpha1: Double?
            var stressIndex: Double?
            var readinessScore: Double?
            var artifactPercent: Double = 100

            init(_ result: HRVAnalysisResult?) {
                guard let result else { return }
                rmssd = result.timeDomain.rmssd
                sdnn = result.timeDomain.sdnn
                meanHR = result.timeDomain.meanHR
                lfHfRatio = result.frequencyDomain?.lfHfRatio
                hf = result.frequencyDomain?.hf
                lf = result.frequencyDomain?.lf
                dfaAlpha1 = result.nonlinear.dfaAlpha1
                stressIndex = result.ansMetrics?.stressIndex
                readinessScore = result.ansMetrics?.readinessScore
                artifactPercent = result.artifactPercentage
            }
        }

        init(session: HRVSession) {
            id = session.id
            date = session.startDate
            morningFeeling = session.morningFeeling
            morningFeelingTags = session.morningFeelingTags

            let metrics = Metrics(session.analysisResult)
            rmssd = metrics.rmssd
            sdnn = metrics.sdnn
            meanHR = metrics.meanHR
            lfHfRatio = metrics.lfHfRatio
            hf = metrics.hf
            lf = metrics.lf
            dfaAlpha1 = metrics.dfaAlpha1
            stressIndex = metrics.stressIndex
            readinessScore = metrics.readinessScore
            artifactPercent = metrics.artifactPercent
        }
    }

    // MARK: - Trend Statistics

    /// Statistics for a metric over time
    struct TrendStatistics {
        let metric: String
        let count: Int
        let mean: Double
        let standardDeviation: Double
        let min: Double
        let max: Double
        let percentile25: Double
        let percentile75: Double
        let trend: TrendDirection
        let trendSlope: Double
        let coefficientOfVariation: Double

        /// Personal baseline (rolling 7-day average)
        let baseline: Double?

        /// Current value vs baseline
        let deviationFromBaseline: Double?
    }

    /// Trend direction
    enum TrendDirection: String {
        case improving = "Improving"
        case stable = "Stable"
        case declining = "Declining"
        case insufficient = "Insufficient Data"
    }

    // MARK: - Trend Summary

    /// Overall trend summary
    struct TrendSummary {
        let period: DateInterval
        let dataPoints: [TrendDataPoint]
        let rmssdStats: TrendStatistics
        let sdnnStats: TrendStatistics
        let hrStats: TrendStatistics
        let lfHfStats: TrendStatistics?
        let dfaAlpha1Stats: TrendStatistics?
        let stressStats: TrendStatistics?
        let readinessStats: TrendStatistics?
        let overallTrend: TrendDirection
        let insights: [String]
    }

    // MARK: - Time Periods

    enum TimePeriod {
        case week
        case twoWeeks
        case month
        case threeMonths
        case all

        var days: Int? {
            switch self {
            case .week: 7
            case .twoWeeks: 14
            case .month: 30
            case .threeMonths: 90
            case .all: nil
            }
        }

        var displayName: String {
            switch self {
            case .week: "7 Days"
            case .twoWeeks: "14 Days"
            case .month: "30 Days"
            case .threeMonths: "90 Days"
            case .all: "All Time"
            }
        }
    }

    // MARK: - Public API

    /// Analyze trends from archived sessions
    /// Note: Only overnight sessions are included in trend calculations.
    /// Naps and quick readings are excluded to maintain consistent daily baselines.
    static func analyze(
        sessions: [HRVSession],
        period: TimePeriod = .month
    ) -> TrendSummary? {
        let dataPoints = filteredDataPoints(sessions: sessions, period: period)
        guard dataPoints.count >= 2 else { return nil }
        let allStats = computeAllStatistics(dataPoints: dataPoints)
        guard let first = dataPoints.first, let last = dataPoints.last else { return nil }
        return TrendSummary(
            period: DateInterval(start: first.date, end: last.date),
            dataPoints: dataPoints,
            rmssdStats: allStats.rmssd, sdnnStats: allStats.sdnn, hrStats: allStats.hr,
            lfHfStats: allStats.lfHf, dfaAlpha1Stats: allStats.dfa,
            stressStats: allStats.stress, readinessStats: allStats.readiness,
            overallTrend: determineOverallTrend(
                rmssd: allStats.rmssd, sdnn: allStats.sdnn, readiness: allStats.readiness
            ),
            insights: generateInsights(
                dataPoints: dataPoints, rmssd: allStats.rmssd, sdnn: allStats.sdnn,
                hr: allStats.hr, stress: allStats.stress, readiness: allStats.readiness
            )
        )
    }

    // MARK: - Analyze Helpers

    private static func filteredDataPoints(sessions: [HRVSession], period: TimePeriod) -> [TrendDataPoint] {
        // Exclude untrustworthy-HRV readings from trends. An
        // `.insufficient` awake/too-short partial and a `.preSleep` recording
        // both carry a real but non-representative RMSSD; leaving them in
        // visibly dents the user's trend line. See `isReliableForHRVAggregates`.
        let validSessions = sessions.filter {
            $0.analysisResult != nil && $0.sessionType == .overnight && $0.isReliableForHRVAggregates
        }
        let dropped = sessions.count - validSessions.count
        if dropped > 0 {
            debugLog("[TrendAnalyzer] Filtered \(sessions.count) input sessions → \(validSessions.count) valid (\(dropped) dropped: not overnight, missing analysisResult, or unreliable HRV quality)")
        }
        guard validSessions.count >= 2 else {
            debugLog("[TrendAnalyzer] Too few valid sessions (\(validSessions.count)) — need ≥ 2")
            return []
        }

        var dataPoints = validSessions.map { TrendDataPoint(session: $0) }
        dataPoints = withinPeriod(dataPoints, period: period)
        dataPoints.sort { $0.date < $1.date }
        return dataPoints
    }

    private static func withinPeriod(_ dataPoints: [TrendDataPoint], period: TimePeriod) -> [TrendDataPoint] {
        guard let days = period.days,
              let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        else { return dataPoints }
        let filtered = dataPoints.filter { $0.date >= cutoff }
        if filtered.count != dataPoints.count {
            debugLog("[TrendAnalyzer] Period filter (\(days)d): \(dataPoints.count) → \(filtered.count) sessions")
        }
        return filtered
    }

    private struct AllStatistics {
        let rmssd, sdnn, hr: TrendStatistics
        let lfHf, dfa, stress, readiness: TrendStatistics?
    }

    private static func computeAllStatistics(dataPoints: [TrendDataPoint]) -> AllStatistics {
        let dates = dataPoints.map(\.date)
        let rmssd = computeStatistics(metric: "RMSSD", values: dataPoints.map(\.rmssd), dates: dates, higherIsBetter: true)
        let sdnn = computeStatistics(metric: "SDNN", values: dataPoints.map(\.sdnn), dates: dates, higherIsBetter: true)
        let hr = computeStatistics(metric: "Mean HR", values: dataPoints.map(\.meanHR), dates: dates, higherIsBetter: false)

        let lfHf = computeOptionalStatistics(metric: "Balance", dataPoints: dataPoints, extract: { $0.lfHfRatio }, higherIsBetter: false)
        let dfa = computeOptionalStatistics(metric: "Heart Complexity", dataPoints: dataPoints, extract: { $0.dfaAlpha1 }, higherIsBetter: nil)
        let stress = computeOptionalStatistics(metric: "Stress Index", dataPoints: dataPoints, extract: { $0.stressIndex }, higherIsBetter: false)
        let readiness = computeOptionalStatistics(metric: "Readiness", dataPoints: dataPoints, extract: { $0.readinessScore }, higherIsBetter: true)

        return AllStatistics(rmssd: rmssd, sdnn: sdnn, hr: hr, lfHf: lfHf, dfa: dfa, stress: stress, readiness: readiness)
    }

    /// Compute statistics for an optional metric — returns nil if fewer than 2 values exist.
    private static func computeOptionalStatistics(
        metric: String,
        dataPoints: [TrendDataPoint],
        extract: (TrendDataPoint) -> Double?,
        higherIsBetter: Bool?
    ) -> TrendStatistics? {
        let values = dataPoints.compactMap(extract)
        guard values.count >= 2 else { return nil }
        let dates = dataPoints.filter { extract($0) != nil }.map(\.date)
        return computeStatistics(metric: metric, values: values, dates: dates, higherIsBetter: higherIsBetter)
    }

    // MARK: - Rolling Baseline

    /// Compute rolling baseline for a metric
    static func computeRollingBaseline(
        values: [Double],
        dates: [Date],
        windowDays: Int = 7
    ) -> [Double] {
        guard values.count == dates.count else { return values }
        return (0 ..< values.count).map { i in
            priorWindowMean(values: values, dates: dates, index: i, windowDays: windowDays) ?? values[i]
        }
    }

    /// Mean of the readings in the `windowDays` before `index`. Nil when there
    /// is no prior data, so the caller can fall back to the value itself.
    private static func priorWindowMean(values: [Double], dates: [Date], index i: Int, windowDays: Int) -> Double? {
        let currentDate = dates[i]
        guard let windowStart = Calendar.current.date(byAdding: .day, value: -windowDays, to: currentDate) else { return nil }
        let windowValues = (0 ..< i)
            .filter { dates[$0] >= windowStart && dates[$0] < currentDate }
            .map { values[$0] }
        guard !windowValues.isEmpty else { return nil }
        return windowValues.reduce(0, +) / Double(windowValues.count)
    }

    // MARK: - Private Methods

    private static func computeStatistics(
        metric: String,
        values: [Double],
        dates: [Date],
        higherIsBetter: Bool?
    ) -> TrendStatistics {
        let n = values.count
        guard n >= 2 else { return insufficientStatistics(metric: metric, values: values) }
        let mean = values.reduce(0, +) / Double(n)
        let sd = sqrt(values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(n - 1))
        let cv = mean > 0 ? sd / mean * 100 : 0
        let sorted = values.sorted()
        guard let minVal = sorted.first, let maxVal = sorted.last else {
            return emptyRangeStatistics(metric: metric, count: n, mean: mean, sd: sd, cv: cv)
        }
        let slope = linearRegressionSlope(values: values)
        return TrendStatistics(
            metric: metric, count: n, mean: mean, standardDeviation: sd,
            min: minVal, max: maxVal,
            percentile25: sorted[Swift.min(Int(Double(n) * 0.25), n - 1)],
            percentile75: sorted[Swift.min(Int(Double(n) * 0.75), n - 1)],
            trend: trendDirection(slope: slope, sd: sd, higherIsBetter: higherIsBetter),
            trendSlope: slope, coefficientOfVariation: cv,
            baseline: baselineDeviation(values: values, dates: dates, mean: mean).baseline,
            deviationFromBaseline: baselineDeviation(values: values, dates: dates, mean: mean).deviation
        )
    }

    /// The rolling 7-day baseline and today's percentage distance from it.
    private static func baselineDeviation(
        values: [Double],
        dates: [Date],
        mean: Double
    ) -> (baseline: Double?, deviation: Double?) {
        let baseline = computeRollingBaseline(values: values, dates: dates, windowDays: 7).last
        let currentValue = values.last ?? mean
        return (baseline, baseline.map { (currentValue - $0) / $0 * 100 })
    }

    /// Fewer than two readings is not a trend — report the single value with
    /// everything else zeroed rather than inventing a slope.
    private static func insufficientStatistics(metric: String, values: [Double]) -> TrendStatistics {
        TrendStatistics(
            metric: metric,
            count: values.count,
            mean: values.first ?? 0,
            standardDeviation: 0,
            min: values.first ?? 0,
            max: values.first ?? 0,
            percentile25: values.first ?? 0,
            percentile75: values.first ?? 0,
            trend: .insufficient,
            trendSlope: 0,
            coefficientOfVariation: 0,
            baseline: nil,
            deviationFromBaseline: nil
        )
    }

    private static func emptyRangeStatistics(metric: String, count: Int, mean: Double, sd: Double, cv: Double) -> TrendStatistics {
        TrendStatistics(
            metric: metric,
            count: count,
            mean: mean,
            standardDeviation: sd,
            min: 0,
            max: 0,
            percentile25: 0,
            percentile75: 0,
            trend: .insufficient,
            trendSlope: 0,
            coefficientOfVariation: cv,
            baseline: nil,
            deviationFromBaseline: nil
        )
    }

    /// A slope smaller than a tenth of an SD is noise, not movement.
    private static func trendDirection(slope: Double, sd: Double, higherIsBetter: Bool?) -> TrendDirection {
        // When SD=0 all values are identical -> stable.
        let slopeThreshold = sd > 0 ? sd * 0.1 : 0.01
        guard abs(slope) >= slopeThreshold else { return .stable }
        // Without a direction preference (DFA, where optimal is ~1.0) we can
        // only report which way it moved.
        guard let better = higherIsBetter else { return slope > 0 ? .improving : .declining }
        return (slope > 0) == better ? .improving : .declining
    }

    private static func linearRegressionSlope(values: [Double]) -> Double {
        let n = Double(values.count)
        guard n >= 2 else { return 0 }

        // Use index as x (0, 1, 2, ...)
        let xMean = (n - 1) / 2
        let yMean = values.reduce(0, +) / n

        var numerator = 0.0
        var denominator = 0.0

        for (i, y) in values.enumerated() {
            let x = Double(i)
            numerator += (x - xMean) * (y - yMean)
            denominator += (x - xMean) * (x - xMean)
        }

        return denominator > 0 ? numerator / denominator : 0
    }

    /// Readiness counts double: it already folds in the other signals, so when
    /// it disagrees with RMSSD/SDNN it is usually the one to believe.
    private static func determineOverallTrend(
        rmssd: TrendStatistics,
        sdnn: TrendStatistics,
        readiness: TrendStatistics?
    ) -> TrendDirection {
        var improvingCount = 0
        var decliningCount = 0
        for stat in [rmssd, sdnn] {
            improvingCount += stat.trend == .improving ? 1 : 0
            decliningCount += stat.trend == .declining ? 1 : 0
        }
        if let r = readiness {
            improvingCount += r.trend == .improving ? 2 : 0
            decliningCount += r.trend == .declining ? 2 : 0
        }
        if improvingCount > decliningCount + 1 { return .improving }
        if decliningCount > improvingCount + 1 { return .declining }
        return .stable
    }

    /// What the RMSSD trend and its spread say on their own.
    private static func rmssdInsights(_ rmssd: TrendStatistics) -> [String] {
        var out: [String] = []
        switch rmssd.trend {
        case .improving:
            out.append("Your recovery capacity is trending upward — keep doing what you're doing.")
        case .declining:
            out.append("Your recovery is declining. Consider reducing training load, improving sleep, or taking a rest day.")
        case .stable:
            out.append("Your HRV is stable — your recovery patterns are consistent.")
        case .insufficient:
            break
        }
        if rmssd.coefficientOfVariation > 25 {
            out.append("Your HRV varies a lot day-to-day. This could mean inconsistent sleep or recovery patterns.")
        }
        out += baselineDeviationInsights(rmssd.deviationFromBaseline)
        return out
    }

    /// A day well off the user's own baseline is worth calling out in either
    /// direction.
    private static func baselineDeviationInsights(_ deviation: Double?) -> [String] {
        guard let deviation else { return [] }
        if deviation < -15 {
            return [String(format: "Today's HRV is %.0f%% below your baseline. Consider a rest day.", abs(deviation))]
        }
        if deviation > 15 {
            return [String(format: "Today's HRV is %.0f%% above your baseline. Good day for harder training.", deviation)]
        }
        return []
    }

    /// Autonomic balance, read from stress index and readiness together.
    private static func autonomicInsights(
        stress: TrendStatistics?,
        readiness: TrendStatistics?
    ) -> [String] {
        var out: [String] = []
        if let s = stress {
            if s.mean > 150 {
                out.append("Your average Stress Index is elevated. Focus on stress management and recovery.")
            } else if s.mean < 50, s.trend != .declining {
                out.append("Your Stress Index is in a healthy range, indicating good autonomic balance.")
            }
        }
        if let r = readiness {
            if r.trend == .improving {
                out.append("Your Readiness Score is improving. Training adaptations are progressing well.")
            } else if r.mean < 5 {
                out.append("Your average Readiness is below optimal. Prioritize recovery strategies.")
            }
        }
        return out
    }

    /// Cardiovascular adaptation, and whether the data is clean enough to trust.
    private static func heartRateAndQualityInsights(
        hr: TrendStatistics,
        dataPoints: [TrendDataPoint]
    ) -> [String] {
        var out: [String] = []
        if hr.trend == .declining, hr.trendSlope < -0.5 {
            out.append("Your resting heart rate is decreasing, a positive sign of cardiovascular adaptation.")
        }
        let highArtifactSessions = dataPoints.filter { $0.artifactPercent > 5 }.count
        if highArtifactSessions > dataPoints.count / 3 {
            out.append("Several sessions have elevated artifact levels. Ensure proper sensor contact during recordings.")
        }
        return out
    }

    /// Three independent readings of the same window, concatenated in the order
    /// a user would want them: what recovery is doing, what the nervous system
    /// is doing, and whether to believe either.
    private static func generateInsights(
        dataPoints: [TrendDataPoint],
        rmssd: TrendStatistics,
        sdnn _: TrendStatistics,
        hr: TrendStatistics,
        stress: TrendStatistics?,
        readiness: TrendStatistics?
    ) -> [String] {
        rmssdInsights(rmssd)
            + autonomicInsights(stress: stress, readiness: readiness)
            + heartRateAndQualityInsights(hr: hr, dataPoints: dataPoints)
    }

    // MARK: - Trend Insight Generation

    /// Baseline averages computed from recent sessions (excluding the most recent)
    struct SessionBaseline {
        let avgRMSSD: Double?
        let avgHR: Double?
        let avgStress: Double?
    }

    /// Compute rolling baseline from recent sessions (last 7-14 days, excluding the most recent)
    static func computeSessionBaseline(from recentSessions: [HRVSession]) -> SessionBaseline {
        let validSessions = recentSessions.dropFirst().prefix(14).filter { $0.analysisResult != nil }

        guard validSessions.count >= 3 else {
            return SessionBaseline(avgRMSSD: nil, avgHR: nil, avgStress: nil)
        }

        let rmssdValues = validSessions.compactMap(\.rmssd)
        let hrValues = validSessions.compactMap(\.meanHR)
        let stressValues = validSessions.compactMap(\.stressIndex)

        return SessionBaseline(
            avgRMSSD: rmssdValues.isEmpty ? nil : rmssdValues.reduce(0, +) / Double(rmssdValues.count),
            avgHR: hrValues.isEmpty ? nil : hrValues.reduce(0, +) / Double(hrValues.count),
            avgStress: stressValues.isEmpty ? nil : stressValues.reduce(0, +) / Double(stressValues.count)
        )
    }

    /// Generate a substantial trend insight paragraph for a single session result,
    /// combining HRV baseline comparison, HR context, stress, HR dip, weekly trend, and guidance.
}

// MARK: - Morning Insight
//
// The plain-language paragraph the user reads first thing. Kept in its own
// extension so the six observation builders live together and the main
// `TrendAnalyzer` body stays readable.

extension TrendAnalyzer {
    /// Part 1 — where today's HRV sits against the user's own baseline, or
    /// against population ranges when there is no baseline yet.
    private static func hrvSentences(rmssd: Double, baseline: SessionBaseline) -> [String] {
        guard let avgRMSSD = baseline.avgRMSSD else { return [hrvAgainstPopulation(rmssd: rmssd)] }
        return [hrvAgainstBaseline(rmssd: rmssd, avgRMSSD: avgRMSSD)]
    }

    private static func hrvAgainstBaseline(rmssd: Double, avgRMSSD: Double) -> String {
        let pctDiff = ((rmssd - avgRMSSD) / avgRMSSD) * 100
        if pctDiff > 25 {
            return "Your HRV is significantly elevated at \(Int(rmssd)) ms (+\(Int(pctDiff))% vs your baseline) — your body recovered really well overnight."
        } else if pctDiff > 10 {
            return "Your HRV of \(Int(rmssd)) ms is \(Int(pctDiff))% above your baseline — good recovery."
        } else if pctDiff < -25 {
            return "Your HRV is notably suppressed at \(Int(rmssd)) ms (\(Int(abs(pctDiff)))% below baseline) — your body is under extra strain, take it easy today."
        } else if pctDiff < -10 {
            return "Your HRV of \(Int(rmssd)) ms is \(Int(abs(pctDiff)))% below your baseline."
        } else {
            return "Your HRV of \(Int(rmssd)) ms is within your normal range."
        }
    }

    /// No baseline yet — fall back to population ranges.
    private static func hrvAgainstPopulation(rmssd: Double) -> String {
        if rmssd >= 50 {
            return "Your HRV of \(Int(rmssd)) ms shows strong recovery signals."
        } else if rmssd >= 30 {
            return "Your HRV of \(Int(rmssd)) ms is in a moderate range."
        } else {
            return "Your HRV of \(Int(rmssd)) ms is on the lower side — your body may need more rest."
        }
    }

    /// Part 2 — resting heart rate against the same baseline.
    private static func heartRateSentences(meanHR: Double, baseline: SessionBaseline) -> [String] {
        var sentences: [String] = []
            if let avgHR = baseline.avgHR {
                let hrDiff = meanHR - avgHR
                if hrDiff < -5 {
                    sentences.append("Resting heart rate is \(Int(abs(hrDiff))) bpm lower than your average, a positive sign of cardiovascular efficiency or deep rest.")
                } else if hrDiff > 8 {
                    sentences.append("Resting HR is elevated by \(Int(hrDiff)) bpm — this most often follows hard training, short sleep, alcohol, stress or dehydration, and sometimes the start of an illness.")
                } else if hrDiff > 5 {
                    sentences.append("Resting HR is slightly elevated (+\(Int(hrDiff)) bpm vs average).")
                }
            }
        return sentences
    }

    /// Part 3 — stress index read together with readiness, since neither
    /// means much alone.
    private static func stressSentences(stress: Double?, readiness: Double) -> [String] {
        var sentences: [String] = []
            if let si = stress {
                if si < 80, readiness >= 7 {
                    sentences.append("Your stress levels are low — nervous system is well-balanced.")
                } else if si > 250 {
                    sentences.append("Your body is showing high stress — try to reduce demands or take a scheduled break.")
                } else if si > 180, readiness < 6 {
                    sentences.append("Stress markers suggest incomplete recovery — prioritize rest.")
                }
            }
        return sentences
    }

    /// Part 4 — overnight heart-rate dip. The healthy-range line is only
    /// worth saying when there is not already plenty to report, hence
    /// `sentencesSoFar`.
    private static func dipSentences(hrDip: Double?, sentencesSoFar: Int) -> [String] {
        guard let dip = hrDip else { return [] }
        if dip < 8 {
            return ["Your heart rate barely dropped overnight (\(Int(dip))%), which can indicate poor sleep quality or lingering stress. A short walk or relaxation exercise before bed may help."]
        }
        if dip > 22 {
            return ["Your heart rate dropped a lot overnight (\(Int(dip))%) — you slept very deeply, though if you're training hard, build in an easier day to consolidate the work."]
        }
        guard dip >= 10, dip <= 20, sentencesSoFar < 2 else { return [] }
        return ["Your overnight heart rate drop of \(Int(dip))% is in the healthy range — good sleep."]
    }

    /// Part 5 — direction of travel across the last seven readings.
    private static func weeklyTrendSentences(recentSessions: [HRVSession]) -> [String] {
        guard let trendPct = sevenDayRMSSDTrendPercent(recentSessions: recentSessions) else { return [] }
        if trendPct > 10 {
            return ["Your 7-day HRV trend is improving (+\(Int(trendPct))%) — keep doing what you're doing."]
        }
        if trendPct < -15 {
            return ["Your HRV has been declining over the past week (\(Int(trendPct))%). Consider prioritizing recovery."]
        }
        return []
    }

    /// Newest three readings against the oldest three of the last seven. Nil
    /// when fewer than five readings exist, or either half has no RMSSD.
    private static func sevenDayRMSSDTrendPercent(recentSessions: [HRVSession]) -> Double? {
        let weekSessions = recentSessions.prefix(7)
        guard weekSessions.count >= 5 else { return nil }
        let weekRMSSD = weekSessions.compactMap(\.rmssd)
        let firstHalf = Array(weekRMSSD.suffix(3))
        let secondHalf = Array(weekRMSSD.prefix(3))
        guard !firstHalf.isEmpty, !secondHalf.isEmpty else { return nil }
        let oldAvg = firstHalf.reduce(0, +) / Double(firstHalf.count)
        let newAvg = secondHalf.reduce(0, +) / Double(secondHalf.count)
        return ((newAvg - oldAvg) / oldAvg) * 100
    }

    /// Part 6 — the actual advice, which is the only part that always fires.
    private static func guidanceSentences(readiness: Double) -> [String] {
        var sentences: [String] = []
            if readiness >= 7.0 {
                sentences.append("You're well-recovered and ready for high-intensity training or challenging activities.")
            } else if readiness >= 5.5 {
                sentences.append("Normal activity and moderate training should be fine today.")
            } else if readiness >= 3.5 {
                sentences.append("Consider lighter activity today and prioritize quality sleep tonight.")
            } else {
                sentences.append("Your body is signaling it needs rest. Focus on recovery — gentle movement, hydration, and early bedtime.")
            }
        return sentences
    }

    /// Assemble the plain-language morning insight.
    ///
    /// Six independent observations, each of which may contribute nothing.
    /// They were one 100-line function at complexity 27; the numbered comments
    /// were already telling us where the seams were.
    static func generateTrendInsight(result: HRVAnalysisResult, sessions: [HRVSession]) -> String {
        let readiness = result.ansMetrics?.readinessScore ?? 5.0
        let recentSessions = sessions
            .filter { $0.state == .complete && $0.analysisResult != nil && $0.isReliableForHRVAggregates }
            .sorted { $0.startDate > $1.startDate }
        let baseline = computeSessionBaseline(from: recentSessions)
        var parts: [String] = []
        parts += hrvSentences(rmssd: result.timeDomain.rmssd, baseline: baseline)
        parts += heartRateSentences(meanHR: result.timeDomain.meanHR, baseline: baseline)
        parts += stressSentences(stress: result.ansMetrics?.stressIndex, readiness: readiness)
        parts += dipSentences(
            hrDip: result.ansMetrics?.nocturnalHRDip,
            sentencesSoFar: parts.count
        )
        parts += weeklyTrendSentences(recentSessions: recentSessions)
        parts += guidanceSentences(readiness: readiness)
        return parts.joined(separator: " ")
    }
}

// MARK: - Chart Data Helpers

extension TrendAnalyzer {
    /// Get chart-ready data for a specific metric
    static func chartData(
        from dataPoints: [TrendDataPoint],
        metric: ChartMetric
    ) -> [(date: Date, value: Double)] {
        dataPoints.compactMap { point -> (Date, Double)? in
            guard let value = Self.value(of: metric, in: point) else { return nil }
            return (point.date, value)
        }
    }

    private static func value(of metric: ChartMetric, in point: TrendDataPoint) -> Double? {
        switch metric {
        case .rmssd: point.rmssd
        case .sdnn: point.sdnn
        case .meanHR: point.meanHR
        case .lfHfRatio: point.lfHfRatio
        case .hf: point.hf
        case .lf: point.lf
        case .dfaAlpha1: point.dfaAlpha1
        case .stressIndex: point.stressIndex
        case .readiness: point.readinessScore
        case .morningFeeling: point.morningFeeling.map { Double($0) }
        }
    }

    enum ChartMetric: String, CaseIterable {
        case rmssd = "RMSSD"
        case sdnn = "SDNN"
        case meanHR = "Mean HR"
        case lfHfRatio = "Balance"
        case hf = "HF Power"
        case lf = "LF Power"
        case dfaAlpha1 = "Heart Complexity"
        case stressIndex = "Stress Index"
        case readiness = "Readiness"
        case morningFeeling = "How You Feel"
    }
}
