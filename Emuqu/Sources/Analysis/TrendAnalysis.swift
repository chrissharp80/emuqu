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
        /// Moved up or down, for a metric with no better direction (DFA α1,
        /// best near 1.0), where "improving" would claim a judgement.
        case rising = "Rising"
        case falling = "Falling"
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
        /// The RMSSD verdict. HRV is the primary signal, and this is the same
        /// rule, on the same readings, as the Trends screen's RMSSD card.
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
            overallTrend: allStats.rmssd.trend,
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
        let rmssd = computeStatistics(
            metric: "RMSSD", values: dataPoints.map(\.rmssd), dates: dates, rule: TrendRule(higherIsBetter: true, scale: .logarithmic)
        )
        let sdnn = computeStatistics(
            metric: "SDNN", values: dataPoints.map(\.sdnn), dates: dates, rule: TrendRule(higherIsBetter: true, scale: .logarithmic)
        )
        let hr = computeStatistics(
            metric: "Mean HR", values: dataPoints.map(\.meanHR), dates: dates, rule: TrendRule(higherIsBetter: false, scale: .linear)
        )
        let lfHf = computeOptionalStatistics(metric: "Balance", dataPoints: dataPoints, extract: { $0.lfHfRatio }, rule: TrendRule(higherIsBetter: false, scale: .logarithmic))
        let dfa = computeOptionalStatistics(metric: "Heart Complexity", dataPoints: dataPoints, extract: { $0.dfaAlpha1 }, rule: TrendRule(higherIsBetter: nil, scale: .linear))
        let stress = computeOptionalStatistics(metric: "Stress Index", dataPoints: dataPoints, extract: { $0.stressIndex }, rule: TrendRule(higherIsBetter: false, scale: .linear))
        let readiness = computeOptionalStatistics(metric: "Readiness", dataPoints: dataPoints, extract: { $0.readinessScore }, rule: TrendRule(higherIsBetter: true, scale: .linear))

        return AllStatistics(rmssd: rmssd, sdnn: sdnn, hr: hr, lfHf: lfHf, dfa: dfa, stress: stress, readiness: readiness)
    }

    /// How a metric's trend is read: which way is better (nil when neither
    /// is, as for DFA α1, best near 1.0) and the scale its noise lives on.
    struct TrendRule {
        let higherIsBetter: Bool?
        let scale: TrendVerdict.Scale
    }

    /// Compute statistics for an optional metric — returns nil if fewer than 2 values exist.
    private static func computeOptionalStatistics(
        metric: String,
        dataPoints: [TrendDataPoint],
        extract: (TrendDataPoint) -> Double?,
        rule: TrendRule
    ) -> TrendStatistics? {
        let values = dataPoints.compactMap(extract)
        guard values.count >= 2 else { return nil }
        let dates = dataPoints.filter { extract($0) != nil }.map(\.date)
        return computeStatistics(metric: metric, values: values, dates: dates, rule: rule)
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
        rule: TrendRule
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
        let slope = linearRegressionSlope(values: values, dates: dates)
        return TrendStatistics(
            metric: metric, count: n, mean: mean, standardDeviation: sd,
            min: minVal, max: maxVal,
            percentile25: sorted[Swift.min(Int(Double(n) * 0.25), n - 1)],
            percentile75: sorted[Swift.min(Int(Double(n) * 0.75), n - 1)],
            trend: direction(of: TrendVerdict.evaluate(values: values, dates: dates, scale: rule.scale), rule: rule),
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

    /// The shared verdict (`TrendVerdict`), named for this metric: improving
    /// or declining when one direction is better, rising or falling when
    /// neither is.
    static func direction(of verdict: TrendVerdict.Result, rule: TrendRule) -> TrendDirection {
        switch verdict.movement {
        case .insufficient: return .insufficient
        case .flat: return .stable
        case .up, .down:
            let wentUp = verdict.movement == .up
            guard let better = rule.higherIsBetter else { return wentUp ? .rising : .falling }
            return wentUp == better ? .improving : .declining
        }
    }

    /// Least-squares slope per DAY, regressed on days since the first reading.
    /// Regressing on the reading index gave a slope per reading, which the
    /// assistant reports as per day: with missed nights (10 readings over 30
    /// days) that read about 3× too steep. Falls back to the index when the
    /// dates don't line up with the values.
    private static func linearRegressionSlope(values: [Double], dates: [Date]) -> Double {
        let n = Double(values.count)
        guard n >= 2 else { return 0 }
        let xs: [Double] = if dates.count == values.count, let first = dates.first {
            dates.map { $0.timeIntervalSince(first) / 86_400 }
        } else {
            values.indices.map(Double.init)
        }
        let xMean = xs.reduce(0, +) / n
        let yMean = values.reduce(0, +) / n
        var numerator = 0.0
        var denominator = 0.0
        for (x, y) in zip(xs, values) {
            numerator += (x - xMean) * (y - yMean)
            denominator += (x - xMean) * (x - xMean)
        }
        return denominator > 0 ? numerator / denominator : 0
    }

    /// What the RMSSD trend and its spread say on their own.
    private static func rmssdInsights(_ rmssd: TrendStatistics) -> [String] {
        var out: [String] = []
        switch rmssd.trend {
        case .improving:
            out.append(String(localized: "Your recovery capacity is trending upward — keep doing what you're doing.", bundle: LanguageManager.appBundle))
        case .declining:
            out.append(String(localized: "Your recovery is declining. Consider reducing training load, improving sleep, or taking a rest day.", bundle: LanguageManager.appBundle))
        case .stable:
            out.append(String(localized: "Your HRV is stable — your recovery patterns are consistent.", bundle: LanguageManager.appBundle))
        case .insufficient, .rising, .falling:
            break
        }
        if rmssd.coefficientOfVariation > 25 {
            out.append(String(localized: "Your HRV varies a lot day-to-day. This could mean inconsistent sleep or recovery patterns.", bundle: LanguageManager.appBundle))
        }
        out += baselineDeviationInsights(rmssd.deviationFromBaseline)
        return out
    }

    /// A day well off the user's own baseline is worth calling out in either
    /// direction.
    private static func baselineDeviationInsights(_ deviation: Double?) -> [String] {
        guard let deviation else { return [] }
        if deviation < -15 {
            return [String(localized: "Today's HRV is \(abs(deviation).formatted(.number.precision(.fractionLength(0))))% below your baseline. Consider a rest day.", bundle: LanguageManager.appBundle)]
        }
        if deviation > 15 {
            // An observation only: whether to train hard is the training
            // advice gate's call, which also weighs the training load.
            return [String(localized: "Today's HRV is \(deviation.formatted(.number.precision(.fractionLength(0))))% above your baseline.", bundle: LanguageManager.appBundle)]
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
                out.append(String(localized: "Your average Stress Index is elevated. Focus on stress management and recovery.", bundle: LanguageManager.appBundle))
            } else if s.mean < 50, s.trend != .declining {
                out.append(String(localized: "Your average Stress Index is low relative to its usual range.", bundle: LanguageManager.appBundle))
            }
        }
        if let r = readiness {
            if r.trend == .improving {
                out.append(String(localized: "Your Readiness Score is improving. Training adaptations are progressing well.", bundle: LanguageManager.appBundle))
            } else if r.mean < 5 {
                out.append(String(localized: "Your average Readiness is below optimal. Prioritize recovery strategies.", bundle: LanguageManager.appBundle))
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
        // Resting HR has `higherIsBetter: false`, so a falling HR is `.improving`.
        if hr.trend == .improving, hr.trendSlope < -0.5 {
            out.append(String(localized: "Your resting heart rate is decreasing, a positive sign of cardiovascular adaptation.", bundle: LanguageManager.appBundle))
        }
        let highArtifactSessions = dataPoints.filter { $0.artifactPercent > 5 }.count
        if highArtifactSessions > dataPoints.count / 3 {
            out.append(String(localized: "Several sessions have elevated artifact levels. Ensure proper sensor contact during recordings.", bundle: LanguageManager.appBundle))
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
