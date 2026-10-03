import Foundation

/// Detects causes based on HRV metrics (without user tags)
/// Single Responsibility: only handles metric-based cause detection
final class MetricBasedCauseDetector: CauseDetectionStrategy {
    func detectCauses(in context: CauseDetectionContext) -> [DetectedCause] {
        // Skip for good readings
        if context.isGoodReading || context.isExcellentReading {
            return []
        }

        var causes: [DetectedCause] = []

        causes.append(contentsOf: detectPossibleIllness(in: context))
        causes.append(contentsOf: detectUntaggedStress(in: context))
        causes.append(contentsOf: detectPossibleSleepDebt(in: context))
        causes.append(contentsOf: detectTrainingLoad(in: context))
        causes.append(contentsOf: detectDehydration(in: context))

        return causes
    }

    // MARK: - Illness Detection

    private func detectPossibleIllness(in context: CauseDetectionContext) -> [DetectedCause] {
        // Skip if the user already tagged illness.
        guard !context.selectedTags.contains(where: { $0.name == ReadingTag.illness.name }) else { return [] }
        let signals = detectIllnessPattern(in: context)
        if let cause = strongIllnessCause(context: context, signals: signals) { return [cause] }
        if let cause = moderateIllnessCause(context: context, signals: signals) { return [cause] }
        if let cause = weakIllnessCause(context: context, signals: signals) { return [cause] }
        return []
    }

    /// Strong pattern: 3+ consecutive declines with low HRV and high stress.
    private func strongIllnessCause(
        context: CauseDetectionContext,
        signals illnessSignals: IllnessSignals
    ) -> DetectedCause? {
        guard illnessSignals.consecutiveDeclines >= 3,
              context.rmssd < HRVThresholds.rmssdGood,
              context.stressIndex > HRVThresholds.stressIndexElevated else { return nil }
        return DetectedCause(
            cause: "Sustained HRV Decline",
            confidence: .moderateHigh,
            explanation: "Your HRV has declined for \(illnessSignals.consecutiveDeclines) consecutive days (\(String(format: "%.0f", illnessSignals.totalDeclinePercent))% total drop) alongside elevated stress markers. Common causes are a run of hard training, short or poor sleep, alcohol, ongoing stress or travel, and sometimes the start of an illness. Worth watching rather than acting on.",
            rankingWeight: 0.72
        )
    }

    /// Moderate pattern: 2+ declines with low HRV or elevated HR.
    private func moderateIllnessCause(
        context: CauseDetectionContext,
        signals illnessSignals: IllnessSignals
    ) -> DetectedCause? {
        guard illnessSignals.consecutiveDeclines >= 2,
              context.rmssd < HRVThresholds.rmssdReduced || illnessSignals.hrElevated else { return nil }
        var explanation = "Your HRV has dropped for \(illnessSignals.consecutiveDeclines) days in a row"
        if illnessSignals.hrElevated {
            explanation += " and your resting HR is elevated (+\(String(format: "%.0f", illnessSignals.hrIncrease)) bpm)"
        }
        explanation += ". This usually follows a run of hard training, short or poor sleep, alcohol, stress or travel, and sometimes the start of an illness; the numbers alone cannot tell you which."
        return DetectedCause(
            cause: illnessSignals.hrElevated ? "Sustained HRV and Resting-HR Shift" : "Multi-Day HRV Decline",
            confidence: .moderateHigh,
            explanation: explanation,
            rankingWeight: 0.72
        )
    }

    /// The weaker single-signal patterns, in descending confidence.
    private func weakIllnessCause(
        context: CauseDetectionContext,
        signals illnessSignals: IllnessSignals
    ) -> DetectedCause? {
        // Very low HRV with high stress.
        if context.rmssd < HRVThresholds.rmssdLow, context.stressIndex > 250 {
            return immuneResponseCause()
        }
        // Elevated HR with high stress.
        if illnessSignals.hrElevated, context.stressIndex > HRVThresholds.stressIndexElevated,
           context.rmssd < HRVThresholds.rmssdGood {
            return elevatedRestingHRCause(signals: illnessSignals)
        }
        // Low HRV with elevated stress.
        guard context.rmssd < HRVThresholds.rmssdReduced, context.stressIndex > 220 else { return nil }
        return DetectedCause(
            cause: "Low HRV with Elevated Stress Index",
            confidence: .moderate,
            explanation: "Reduced HRV alongside an elevated stress index. Common causes are hard training, short or poor sleep, alcohol, stress or travel, and sometimes the start of an illness.",
            rankingWeight: 0.45
        )
    }

    private func immuneResponseCause() -> DetectedCause {
        DetectedCause(
            cause: "Very Low HRV with High Stress Index",
            confidence: .high,
            explanation: "Very low HRV alongside high stress markers. The usual causes are hard training, short or poor sleep, alcohol, stress or travel, and sometimes the start of an illness. If you feel unwell, rest, and talk to a clinician about symptoms that concern you.",
            rankingWeight: 0.75
        )
    }

    private func elevatedRestingHRCause(signals illnessSignals: IllnessSignals) -> DetectedCause {
        DetectedCause(
            cause: "Elevated Resting HR",
            confidence: .moderate,
            explanation: "Your resting HR is \(String(format: "%.0f", illnessSignals.hrIncrease)) bpm above your average. Combined with elevated stress markers, this most often follows hard training, short sleep, alcohol, stress, heat or travel, and sometimes the start of an illness.",
            rankingWeight: 0.55
        )
    }

    /// Overnight-only. Illness/RHR trends must compare resting nights, not
    /// workouts — a workout's crushed RMSSD or elevated HR in this sequence
    /// would fabricate a "consecutive decline" or mask an elevated resting HR.
    /// `.preSleep` / `.insufficient` partials carry awake RMSSD, so one between
    /// two real nights would read as a decline; they are left out too.
    private func detectIllnessPattern(in context: CauseDetectionContext) -> IllnessSignals {
        let none = IllnessSignals(consecutiveDeclines: 0, totalDeclinePercent: 0, hrElevated: false, hrIncrease: 0)
        let recentSessions = context.recentSessions.filter { $0.sessionType == .overnight && $0.isReliableForHRVAggregates }
        guard recentSessions.count >= 3 else { return none }
        let sortedSessions = recentSessions
            .filter { $0.state == .complete && $0.analysisResult != nil }
            .sorted { $0.startDate > $1.startDate }
        guard sortedSessions.count >= 3 else { return none }
        let declines = consecutiveDeclines(in: sortedSessions)
        let hr = hrElevation(in: sortedSessions, context: context)
        return IllnessSignals(
            consecutiveDeclines: declines.count,
            totalDeclinePercent: declines.totalPercent,
            hrElevated: hr.elevated,
            hrIncrease: hr.increase
        )
    }

    /// `sortedSessions` is NEWEST-first, so this walks backwards in time.
    /// `newerRMSSD` holds the more-recent morning already seen; `rmssd` is the
    /// older morning of the current iteration. A genuine illness signal is HRV
    /// FALLING as we approach today — i.e. the newer day is below the older day
    /// (newer < older × 0.95). The reversed test, `rmssd < newer × 0.95`, asks
    /// the opposite (older below newer) and so fires "Likely getting sick" on a
    /// RISING trend while missing real declines.
    private func consecutiveDeclines(in sortedSessions: [HRVSession]) -> (count: Int, totalPercent: Double) {
        var consecutiveDeclines = 0
        var totalDeclinePercent = 0.0
        var newerRMSSD: Double?
        for rmssd in sortedSessions.prefix(7).compactMap(\.rmssd) {
            guard let newer = newerRMSSD else {
                newerRMSSD = rmssd
                continue
            }
            guard newer < rmssd * HRVThresholds.illnessDeclineThreshold else { break }
            consecutiveDeclines += 1
            totalDeclinePercent += ((rmssd - newer) / rmssd) * 100
            newerRMSSD = rmssd
        }
        return (consecutiveDeclines, totalDeclinePercent)
    }

    /// With no prior HR history, avgHR would be 0 and `hrIncrease` would read
    /// as ~+60 bpm — fabricating an "elevated resting HR" illness signal for
    /// every such user. A real baseline is required before claiming any
    /// elevation.
    private func hrElevation(
        in sortedSessions: [HRVSession],
        context: CauseDetectionContext
    ) -> (elevated: Bool, increase: Double) {
        let hrValues = sortedSessions.prefix(14).compactMap(\.meanHR)
        let avgHR = hrValues.isEmpty ? 0 : hrValues.reduce(0, +) / Double(hrValues.count)
        guard let currentHR = context.currentHR, !hrValues.isEmpty else { return (false, 0) }
        let hrIncrease = currentHR - avgHR
        let hrElevated = hrIncrease > HRVThresholds.hrElevationThreshold
        return (hrElevated, hrIncrease)
    }

    // MARK: - Stress Detection

    private func detectUntaggedStress(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        // Skip if user already tagged stress
        if context.selectedTags.contains(where: { $0.name == ReadingTag.stressed.name }) {
            return causes
        }

        if context.lfHfRatio > HRVThresholds.lfHfSympatheticDominance, context.stressIndex > HRVThresholds.stressIndexElevated {
            causes.append(DetectedCause(
                cause: "Unidentified Stress",
                confidence: .moderateHigh,
                explanation: "Your stress index is elevated and nothing is tagged to explain it. Consider what might be weighing on you mentally.",
                rankingWeight: 0.65
            ))
        }

        return causes
    }

    // MARK: - Sleep Debt Detection

    private func detectPossibleSleepDebt(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        // Skip if the user tagged poor sleep (another cause covers it) or
        // last night's sleep data shows good sleep.
        if context.selectedTags.contains(where: { $0.name == ReadingTag.poorSleep.name }) || context.isGoodSleep {
            return causes
        }

        if context.rmssd < HRVThresholds.rmssdReduced, context.dfaAlpha1 > HRVThresholds.dfaAlpha1HighVariability {
            causes.append(DetectedCause(
                cause: "Possible Sleep Debt",
                confidence: .moderate,
                explanation: "Reduced HRV with disrupted heart rhythm patterns is characteristic of insufficient sleep.",
                rankingWeight: 0.55
            ))
        }

        return causes
    }

    // MARK: - Training Load Detection

    private func detectTrainingLoad(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        // Skip if user tagged post-exercise
        if context.selectedTags.contains(where: { $0.name == ReadingTag.postExercise.name }) {
            return causes
        }

        if context.rmssd < HRVThresholds.rmssdGood,
           context.pnn50 < HRVThresholds.pnn50Low,
           context.dfaAlpha1 > 1.1 {
            causes.append(DetectedCause(
                cause: "Accumulated Training Load",
                confidence: .lowModerate,
                explanation: "If you've been training hard recently, your body may need extra recovery time.",
                rankingWeight: 0.4
            ))
        }

        return causes
    }

    // MARK: - Dehydration Detection

    private func detectDehydration(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        if context.rmssd < HRVThresholds.rmssdGood,
           context.stressIndex > 180,
           context.lfHfRatio < HRVThresholds.lfHfOptimalUpper {
            causes.append(DetectedCause(
                cause: "Dehydration or Fasting",
                confidence: .lowModerate,
                explanation: "Low HRV without strong sympathetic shift can indicate dehydration or low blood sugar.",
                rankingWeight: 0.35
            ))
        }

        return causes
    }
}

// MARK: - Supporting Types

private struct IllnessSignals {
    let consecutiveDeclines: Int
    let totalDeclinePercent: Double
    let hrElevated: Bool
    let hrIncrease: Double
}
