import Foundation

/// Detects causes based on HealthKit sleep data
/// Single Responsibility: only handles sleep-related cause detection
final class SleepCauseDetector: CauseDetectionStrategy {
    func detectCauses(in context: CauseDetectionContext) -> [DetectedCause] {
        // Skip positive causes for good readings (handled elsewhere)
        if context.isGoodReading || context.isExcellentReading {
            return detectPositiveSleepCauses(in: context)
        }

        var causes: [DetectedCause] = []
        let sleep = context.sleepInput

        guard sleep.totalSleepMinutes > 0 else {
            return causes
        }

        causes.append(contentsOf: detectInsufficientSleep(sleep: sleep))
        causes.append(contentsOf: detectFragmentedSleep(sleep: sleep))
        causes.append(contentsOf: detectFrequentAwakenings(sleep: sleep, context: context))
        causes.append(contentsOf: detectLowDeepSleep(sleep: sleep, context: context))
        causes.append(contentsOf: detectSleepTrendIssues(in: context))

        return causes
    }

    // MARK: - Positive Sleep Detection

    private func detectPositiveSleepCauses(in context: CauseDetectionContext) -> [DetectedCause] {
        guard let trends = context.sleepTrend, trends.nightsAnalyzed >= 3 else { return [] }
        var causes = aboveSleepAverageCause(in: context, trends: trends)
        if trends.trend == .improving {
            causes.append(DetectedCause(
                cause: "Improving Sleep Pattern",
                confidence: .moderateHigh,
                explanation: "Your sleep has been improving over the past week. Consistent sleep improvements compound - expect HRV to continue rising if you maintain this pattern.",
                rankingWeight: 0.7
            ))
        }
        return causes
    }

    /// Tonight well over the recent average.
    private func aboveSleepAverageCause(
        in context: CauseDetectionContext,
        trends: AnalysisSleepTrendInput
    ) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        let sleep = context.sleepInput
        let tonightHours = Double(sleep.totalSleepMinutes) / 60.0
        let sleepDiffPercent = Self.sleepDiffPercent(sleep: sleep, trends: trends)
        if sleepDiffPercent > HRVThresholds.trendSignificantChange {
            causes.append(DetectedCause(
                cause: "Above Your Sleep Average",
                confidence: .high,
                explanation: "Tonight's \(String(format: "%.1f", tonightHours))h is \(Int(sleepDiffPercent))% above your recent average. Extra sleep pays immediate dividends in HRV recovery.",
                rankingWeight: 0.78
            ))
        }
        return causes
    }

    // MARK: - Negative Sleep Detection

    private func detectInsufficientSleep(sleep: AnalysisSleepInput) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        // Under 6 h (`sleepVeryShortMinutes`) is short; under 5 h
        // (`sleepShortMinutes`) is severely short. The constant names are
        // historical and read the other way round.
        if sleep.totalSleepMinutes < HRVThresholds.sleepVeryShortMinutes {
            let isSeverelyShort = sleep.totalSleepMinutes < Int(HRVThresholds.sleepShortMinutes)
            let confidence: DetectedCause.CauseConfidence = isSeverelyShort ? .veryHigh : .high
            let weight = isSeverelyShort ? 0.92 : 0.82
            let hours = Double(sleep.totalSleepMinutes) / 60.0

            causes.append(DetectedCause(
                cause: "Insufficient Sleep",
                confidence: confidence,
                explanation: "Last night's sleep data shows only \(String(format: "%.1f", hours)) hours of sleep. Short sleep is one of the most common reasons HRV dips below your usual range.",
                rankingWeight: weight
            ))
        }

        return causes
    }

    private func detectFragmentedSleep(sleep: AnalysisSleepInput) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        // Unmeasured efficiency (passive Watch HR estimate) is no evidence either way.
        guard let efficiency = sleep.sleepEfficiency else { return causes }
        let hasLowEfficiency = efficiency < HRVThresholds.sleepEfficiencyAcceptable
        let hasAdequateTime = sleep.inBedMinutes > Int(HRVThresholds.sleepShortMinutes)

        if hasLowEfficiency, hasAdequateTime {
            let isVeryLow = efficiency < HRVThresholds.sleepEfficiencyLow
            let confidence: DetectedCause.CauseConfidence = isVeryLow ? .high : .moderateHigh
            let weight = isVeryLow ? 0.78 : 0.65

            causes.append(DetectedCause(
                cause: "Fragmented Sleep",
                confidence: confidence,
                explanation: "Last night's sleep data shows \(Int(efficiency))% sleep efficiency with \(sleep.awakeMinutes) minutes awake. Fragmented sleep reduces HRV even when total time is adequate.",
                rankingWeight: weight
            ))
        }

        return causes
    }

    private func detectFrequentAwakenings(sleep: AnalysisSleepInput, context: CauseDetectionContext) -> [DetectedCause] {
        guard sleep.awakeMinutes > 30, context.rmssd < HRVThresholds.rmssdGood else {
            return []
        }

        return [DetectedCause(
            cause: "Frequent Awakenings",
            confidence: .moderate,
            explanation: "Last night's sleep data shows \(sleep.awakeMinutes) minutes awake during sleep. Each awakening interrupts recovery cycles.",
            rankingWeight: 0.55
        )]
    }

    private func detectLowDeepSleep(sleep: AnalysisSleepInput, context _: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        guard let deepMins = sleep.deepSleepMinutes,
              deepMins < Int(HRVThresholds.deepSleepMinimumMinutes),
              sleep.totalSleepMinutes > Int(HRVThresholds.sleepShortMinutes)
        else {
            return causes
        }

        let deepPercent = Double(deepMins) / Double(sleep.totalSleepMinutes) * 100
        guard deepPercent < HRVThresholds.deepSleepLowPercent else { return causes }
        causes.append(DetectedCause(
            cause: "Low Deep Sleep",
            confidence: .moderateHigh,
            explanation: "Only \(deepMins) minutes of deep sleep (\(Int(deepPercent))%). Deep sleep is when HRV-restoring parasympathetic activity peaks. Alcohol, late meals, and stress reduce deep sleep.",
            rankingWeight: 0.7
        ))
        return causes
    }

    private func detectSleepTrendIssues(in context: CauseDetectionContext) -> [DetectedCause] {
        guard let trends = context.sleepTrend, trends.nightsAnalyzed >= 3 else { return [] }
        var causes = belowSleepAverageCause(in: context, trends: trends)
        causes += decliningSleepCause(in: context, trends: trends)
        return causes
    }

    /// Tonight well under the recent average, with HRV to match.
    private func belowSleepAverageCause(
        in context: CauseDetectionContext,
        trends: AnalysisSleepTrendInput
    ) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        let sleep = context.sleepInput
        let tonightHours = Double(sleep.totalSleepMinutes) / 60.0
        let sleepDiffPercent = Self.sleepDiffPercent(sleep: sleep, trends: trends)
        let avgHours = trends.averageSleepMinutes / 60.0
        // Below average tonight
        if sleepDiffPercent < -HRVThresholds.trendSignificantChange, context.rmssd < HRVThresholds.rmssdGood {
            causes.append(DetectedCause(
                cause: "Below Your Sleep Average",
                confidence: .high,
                explanation: "Tonight's \(String(format: "%.1f", tonightHours))h is \(Int(abs(sleepDiffPercent)))% below your 7-day average of \(String(format: "%.1f", avgHours))h. Consistently getting less sleep than usual impacts HRV.",
                rankingWeight: 0.75
            ))
        }
        return causes
    }

    /// A multi-night downward slope, not just one short night.
    private func decliningSleepCause(
        in context: CauseDetectionContext,
        trends: AnalysisSleepTrendInput
    ) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        // Declining trend
        if trends.trend == .declining, context.rmssd < HRVThresholds.rmssdGood {
            causes.append(DetectedCause(
                cause: "Declining Sleep Pattern",
                confidence: .moderateHigh,
                explanation: "Your sleep duration has been trending downward over the past week (avg \(trends.averageSleepFormatted)). Cumulative sleep debt suppresses HRV even before you feel tired.",
                rankingWeight: 0.72
            ))
        }
        return causes
    }

    /// Tonight against the recent average, as a percentage. Zero when there is
    /// no average to compare against.
    private static func sleepDiffPercent(
        sleep: AnalysisSleepInput,
        trends: AnalysisSleepTrendInput
    ) -> Double {
        guard trends.averageSleepMinutes > 0 else { return 0 }
        return ((Double(sleep.totalSleepMinutes) - trends.averageSleepMinutes) / trends.averageSleepMinutes) * 100
    }
}
