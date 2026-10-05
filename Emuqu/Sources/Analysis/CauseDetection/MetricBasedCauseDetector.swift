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
            cause: String(localized: "Sustained HRV Decline", bundle: NarrativeLanguage.bundle),
            confidence: .moderateHigh,
            explanation: String(localized: "Your HRV has declined for \(illnessSignals.consecutiveDeclines) consecutive days (\(NarrativeLanguage.number(illnessSignals.totalDeclinePercent))% total drop) alongside elevated stress markers. Common causes are a run of hard training, short or poor sleep, alcohol, ongoing stress or travel, and sometimes the start of an illness. Worth watching rather than acting on.", bundle: NarrativeLanguage.bundle),
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
        let days = illnessSignals.consecutiveDeclines
        let explanation = if illnessSignals.hrElevated {
            String(localized: "Your HRV has dropped for \(days) days in a row and your resting HR is elevated (+\(NarrativeLanguage.number(illnessSignals.hrIncrease)) bpm). This usually follows a run of hard training, short or poor sleep, alcohol, stress or travel, and sometimes the start of an illness; the numbers alone cannot tell you which.", bundle: NarrativeLanguage.bundle)
        } else {
            String(localized: "Your HRV has dropped for \(days) days in a row. This usually follows a run of hard training, short or poor sleep, alcohol, stress or travel, and sometimes the start of an illness; the numbers alone cannot tell you which.", bundle: NarrativeLanguage.bundle)
        }
        return DetectedCause(
            cause: illnessSignals.hrElevated
                ? String(localized: "Sustained HRV and Resting-HR Shift", bundle: NarrativeLanguage.bundle)
                : String(localized: "Multi-Day HRV Decline", bundle: NarrativeLanguage.bundle),
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
            cause: String(localized: "Low HRV with Elevated Stress Index", bundle: NarrativeLanguage.bundle),
            confidence: .moderate,
            explanation: String(localized: "Reduced HRV alongside an elevated stress index. Common causes are hard training, short or poor sleep, alcohol, stress or travel, and sometimes the start of an illness.", bundle: NarrativeLanguage.bundle),
            rankingWeight: 0.45
        )
    }

    private func immuneResponseCause() -> DetectedCause {
        DetectedCause(
            cause: String(localized: "Very Low HRV with High Stress Index", bundle: NarrativeLanguage.bundle),
            confidence: .high,
            explanation: String(localized: "Very low HRV alongside high stress markers. The usual causes are hard training, short or poor sleep, alcohol, stress or travel, and sometimes the start of an illness. If you feel unwell, rest, and talk to a clinician about symptoms that concern you.",
                bundle: NarrativeLanguage.bundle),
            rankingWeight: 0.75
        )
    }

    private func elevatedRestingHRCause(signals illnessSignals: IllnessSignals) -> DetectedCause {
        DetectedCause(
            cause: String(localized: "Elevated Resting HR", bundle: NarrativeLanguage.bundle),
            confidence: .moderate,
            explanation: String(localized: "Your resting HR is \(NarrativeLanguage.number(illnessSignals.hrIncrease)) bpm above your average. Combined with elevated stress markers, this most often follows hard training, short sleep, alcohol, stress, heat or travel, and sometimes the start of an illness.", bundle: NarrativeLanguage.bundle),
            rankingWeight: 0.55
        )
    }

    /// Overnight-only. Illness/RHR trends must compare resting nights, not
    /// workouts — a workout's crushed RMSSD or elevated HR in this sequence
    /// would fabricate a "consecutive decline" or mask an elevated resting HR.
    /// `.preSleep` / `.insufficient` partials carry awake RMSSD, so one between
    /// two real nights would read as a decline; they are left out too.
    /// `recentSessions` holds only the nights before tonight, so tonight's
    /// reading starts the decline walk and two earlier nights are enough.
    private func detectIllnessPattern(in context: CauseDetectionContext) -> IllnessSignals {
        let none = IllnessSignals(consecutiveDeclines: 0, totalDeclinePercent: 0, hrElevated: false, hrIncrease: 0)
        let sortedSessions = context.recentSessions
            .filter { $0.sessionType == .overnight && $0.isReliableForHRVAggregates }
            .filter { $0.state == .complete && $0.analysisResult != nil }
            .sorted { $0.startDate > $1.startDate }
        guard sortedSessions.count >= 2 else { return none }
        let declines = consecutiveDeclines(from: context.rmssd, in: sortedSessions)
        let hr = hrElevation(context: context)
        return IllnessSignals(
            consecutiveDeclines: declines.count,
            totalDeclinePercent: declines.totalPercent,
            hrElevated: hr.elevated,
            hrIncrease: hr.increase
        )
    }

    /// `sortedSessions` is NEWEST-first, so this walks backwards in time from
    /// tonight's `current` reading.
    /// `newer` holds the more-recent morning already seen; `rmssd` is the
    /// older morning of the current iteration. A genuine illness signal is HRV
    /// FALLING as we approach today — i.e. the newer day is below the older day
    /// (newer < older × 0.95). The reversed test, `rmssd < newer × 0.95`, asks
    /// the opposite (older below newer) and so fires "Likely getting sick" on a
    /// RISING trend while missing real declines.
    private func consecutiveDeclines(from current: Double, in sortedSessions: [HRVSession]) -> (count: Int, totalPercent: Double) {
        var consecutiveDeclines = 0
        var totalDeclinePercent = 0.0
        var newer = current
        for rmssd in sortedSessions.prefix(6).compactMap(\.rmssd) {
            guard newer < rmssd * HRVThresholds.illnessDeclineThreshold else { break }
            consecutiveDeclines += 1
            totalDeclinePercent += ((rmssd - newer) / rmssd) * 100
            newer = rmssd
        }
        return (consecutiveDeclines, totalDeclinePercent)
    }

    /// Against `trendStats.avgHR`, the same resting-HR baseline the Key
    /// Findings quote (the canonical one when the caller passed it), so the
    /// two never show different deltas. With no prior HR history there is no
    /// baseline and no elevation is claimed: an average of 0 would read as
    /// ~+60 bpm and fabricate an illness signal.
    private func hrElevation(context: CauseDetectionContext) -> (elevated: Bool, increase: Double) {
        let stats = context.trendStats
        guard stats.hasData, stats.avgHR > 0, let currentHR = context.currentHR else { return (false, 0) }
        let hrIncrease = currentHR - stats.avgHR
        return (hrIncrease > HRVThresholds.hrElevationThreshold, hrIncrease)
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
                cause: String(localized: "Unidentified Stress", bundle: NarrativeLanguage.bundle),
                confidence: .moderateHigh,
                explanation: String(localized: "Your stress index is elevated and nothing is tagged to explain it. Consider what might be weighing on you mentally.", bundle: NarrativeLanguage.bundle),
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
                cause: String(localized: "Possible Sleep Debt", bundle: NarrativeLanguage.bundle),
                confidence: .moderate,
                explanation: String(localized: "Reduced HRV with disrupted heart rhythm patterns is characteristic of insufficient sleep.", bundle: NarrativeLanguage.bundle),
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
                cause: String(localized: "Accumulated Training Load", bundle: NarrativeLanguage.bundle),
                confidence: .lowModerate,
                explanation: String(localized: "If you've been training hard recently, your body may need extra recovery time.", bundle: NarrativeLanguage.bundle),
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
                cause: String(localized: "Dehydration or Fasting", bundle: NarrativeLanguage.bundle),
                confidence: .lowModerate,
                explanation: String(localized: "Low HRV without strong sympathetic shift can indicate dehydration or low blood sugar.", bundle: NarrativeLanguage.bundle),
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
