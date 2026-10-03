import Foundation

/// Detects positive contributing factors when HRV reading is good
/// Single Responsibility: only handles positive/recovery insights
final class PositiveCauseDetector: CauseDetectionStrategy {
    func detectCauses(in context: CauseDetectionContext) -> [DetectedCause] {
        guard context.isGoodReading || context.isExcellentReading else {
            return []
        }

        var causes: [DetectedCause] = []

        causes.append(contentsOf: detectSleepPositives(in: context))
        causes.append(contentsOf: detectTagPositives(in: context))
        causes.append(contentsOf: detectTrendPositives(in: context))

        return causes
    }

    // MARK: - Private Detection Methods

    private func detectSleepPositives(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        causes += solidSleepDurationCause(in: context)
        causes += sleepEfficiencyCause(in: context)
        causes += deepSleepCause(in: context)
        return causes
    }

    /// Seven-plus hours is the single strongest lever.
    private func solidSleepDurationCause(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        let sleep = context.sleepInput
        // Solid sleep duration
        if sleep.totalSleepMinutes >= HRVThresholds.sleepMinimumMinutes {
            let hours = Double(sleep.totalSleepMinutes) / 60.0
            causes.append(DetectedCause(
                cause: "Solid Sleep",
                confidence: .contributingFactor,
                explanation: "Last night's sleep data shows \(String(format: "%.1f", hours)) hours of sleep. Getting 7+ hours is associated with higher HRV and better recovery.",
                rankingWeight: 0.8
            ))
        }
        return causes
    }

    /// Minimal awakenings.
    private func sleepEfficiencyCause(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        let sleep = context.sleepInput
        // Excellent sleep efficiency
        if sleep.sleepEfficiency >= HRVThresholds.sleepEfficiencyGood {
            causes.append(DetectedCause(
                cause: "Excellent Sleep Quality",
                confidence: .contributingFactor,
                explanation: "Last night's sleep data shows \(Int(sleep.sleepEfficiency))% sleep efficiency — minimal awakenings. Uninterrupted sleep gives your body its best chance to recover.",
                rankingWeight: 0.75
            ))
        }
        return causes
    }

    /// Deep sleep is when HRV peaks.
    private func deepSleepCause(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        let sleep = context.sleepInput
        // Strong deep sleep
        if let deepMins = sleep.deepSleepMinutes, sleep.totalSleepMinutes > 0 {
            let deepPercent = Double(deepMins) / Double(sleep.totalSleepMinutes) * 100
            if deepPercent >= HRVThresholds.deepSleepGoodPercent {
                causes.append(DetectedCause(
                    cause: "Strong Deep Sleep",
                    confidence: .contributingFactor,
                    explanation: "\(deepMins) minutes of deep sleep (\(Int(deepPercent))%). Deep sleep is when HRV peaks and the nervous system fully recovers.",
                    rankingWeight: 0.7
                ))
            }
        }
        return causes
    }

    /// The user tagged the reading as a recovery day.
    private func detectTagPositives(in context: CauseDetectionContext) -> [DetectedCause] {
        guard context.selectedTags.contains(where: { $0.name == ReadingTag.recovery.name }) else { return [] }
        return [DetectedCause(
            cause: "Recovery Day",
            confidence: .moderateHigh,
            explanation: "Rest days allow accumulated training stress to dissipate, often resulting in HRV rebound.",
            rankingWeight: 0.7
        )]
    }

    private func detectTrendPositives(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        let stats = context.trendStats
        guard stats.hasData, stats.sessionCount >= 5 else { return causes }
        causes += upwardTrendCause(in: context)
        causes += aboveBaselineCause(in: context)
        causes += lowRestingHRCause(in: context)
        return causes
    }

    /// HRV climbing across the week.
    private func upwardTrendCause(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        let stats = context.trendStats
        // Upward trend
        if let trend = stats.trend7Day, trend > HRVThresholds.trendModerateChange {
            causes.append(DetectedCause(
                cause: "Upward Trend",
                confidence: .pattern,
                explanation: "Your HRV has been climbing over the past week (+\(String(format: "%.0f", trend))%). Whatever you're doing is working — keep it up.",
                rankingWeight: 0.65
            ))
        }
        return causes
    }

    /// Today well clear of the user's own average.
    private func aboveBaselineCause(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        let stats = context.trendStats
        // Above baseline
        if context.rmssd > stats.avgRMSSD * 1.2 {
            let pctAbove = ((context.rmssd - stats.avgRMSSD) / stats.avgRMSSD) * 100
            causes.append(DetectedCause(
                cause: "Above Your Baseline",
                confidence: .excellent,
                explanation: "Today's HRV (\(Int(context.rmssd))ms) is \(String(format: "%.0f", pctAbove))% above your average. Your body is well-recovered and ready for challenges.",
                rankingWeight: 0.8
            ))
        }
        return causes
    }

    /// Last night's resting HR below baseline is its own recovery signal.
    /// `avgHR` is the canonical resting-HR baseline the Vitals card uses.
    private func lowRestingHRCause(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        let baselineHR = context.trendStats.avgHR
        if baselineHR > 0, let currentHR = context.currentHR {
            let hrDrop = baselineHR - currentHR
            if hrDrop > 5 {
                causes.append(DetectedCause(
                    cause: "Low Resting HR",
                    confidence: .goodSign,
                    explanation: "Resting HR is \(String(format: "%.0f", hrDrop)) bpm below your baseline — indicates strong parasympathetic activity and cardiovascular efficiency.",
                    rankingWeight: 0.6
                ))
            }
        }
        return causes
    }
}
