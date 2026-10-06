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
                cause: String(localized: "Solid Sleep", bundle: NarrativeLanguage.bundle),
                confidence: .contributingFactor,
                explanation: String(localized: "Last night's sleep data shows \(NarrativeLanguage.number(hours, decimals: 1)) hours of sleep. Getting 7+ hours is associated with higher HRV and better recovery.", bundle: NarrativeLanguage.bundle),
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
        if let efficiency = sleep.sleepEfficiency, efficiency >= HRVThresholds.sleepEfficiencyGood {
            causes.append(DetectedCause(
                cause: String(localized: "Excellent Sleep Quality", bundle: NarrativeLanguage.bundle),
                confidence: .contributingFactor,
                explanation: String(localized: "Last night's sleep data shows \(NarrativeLanguage.integer(Int(efficiency)))% sleep efficiency — minimal awakenings. Uninterrupted sleep gives your body its best chance to recover.", bundle: NarrativeLanguage.bundle),
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
                    cause: String(localized: "Strong Deep Sleep", bundle: NarrativeLanguage.bundle),
                    confidence: .contributingFactor,
                    explanation: String(localized: "\(deepMins) minutes of deep sleep (\(NarrativeLanguage.integer(Int(deepPercent)))%). Deep sleep is when HRV peaks and the nervous system fully recovers.", bundle: NarrativeLanguage.bundle),
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
            cause: String(localized: "Recovery Day", bundle: NarrativeLanguage.bundle),
            confidence: .moderateHigh,
            explanation: String(localized: "Rest days allow accumulated training stress to dissipate, often resulting in HRV rebound.", bundle: NarrativeLanguage.bundle),
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
        // Upward trend: `trend7Day` is present only when the shared trend
        // verdict calls the week rising or falling.
        if let trend = stats.trend7Day, trend > 0 {
            causes.append(DetectedCause(
                cause: String(localized: "Upward Trend", bundle: NarrativeLanguage.bundle),
                confidence: .pattern,
                explanation: String(localized: "Your HRV has been climbing over the past week (+\(NarrativeLanguage.number(trend))%). Whatever you're doing is working — keep it up.", bundle: NarrativeLanguage.bundle),
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
                cause: String(localized: "Above Your Baseline", bundle: NarrativeLanguage.bundle),
                confidence: .excellent,
                explanation: String(localized: "Today's HRV (\(NarrativeLanguage.integer(Int(context.rmssd)))ms) is \(NarrativeLanguage.number(pctAbove))% above your average. Your body is well-recovered and ready for challenges.", bundle: NarrativeLanguage.bundle),
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
                    cause: String(localized: "Low Resting HR", bundle: NarrativeLanguage.bundle),
                    confidence: .goodSign,
                    explanation: String(localized: "Resting HR is \(NarrativeLanguage.number(hrDrop)) bpm below your baseline — indicates strong parasympathetic activity and cardiovascular efficiency.", bundle: NarrativeLanguage.bundle),
                    rankingWeight: 0.6
                ))
            }
        }
        return causes
    }
}
