import Foundation

/// Detects causes based on user-reported tags
/// Single Responsibility: only handles tag-based cause detection
final class TagBasedCauseDetector: CauseDetectionStrategy {
    func detectCauses(in context: CauseDetectionContext) -> [DetectedCause] {
        // Skip for good readings (positive causes handled elsewhere)
        if context.isGoodReading || context.isExcellentReading {
            return []
        }

        var causes: [DetectedCause] = []
        let tags = context.selectedTags

        causes.append(contentsOf: detectAlcoholCause(tags: tags, context: context))
        causes.append(contentsOf: detectSleepTags(tags: tags, context: context))
        causes.append(contentsOf: detectDietTags(tags: tags, context: context))
        causes.append(contentsOf: detectLifestyleTags(tags: tags, context: context))
        causes.append(contentsOf: detectHealthTags(tags: tags, context: context))

        return causes
    }

    // MARK: - Private Detection Methods

    private func detectAlcoholCause(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        if tags.contains(where: { $0.name == ReadingTag.alcohol.name }) {
            let isLowHRV = context.rmssd < HRVThresholds.rmssdReduced
            let confidence: DetectedCause.CauseConfidence = isLowHRV ? .veryHigh : .high
            let weight = isLowHRV ? 0.95 : 0.85

            causes.append(DetectedCause(
                cause: "Alcohol Consumption",
                confidence: confidence,
                explanation: "You tagged alcohol. Even moderate drinking suppresses HRV for 24-48 hours by disrupting sleep architecture and increasing sympathetic tone.",
                rankingWeight: weight
            ))
        }

        return causes
    }

    private func detectSleepTags(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        if tags.contains(where: { $0.name == ReadingTag.poorSleep.name }) {
            let hasFatigueSignal = context.dfaAlpha1 > HRVThresholds.dfaAlpha1HighVariability
            let confidence: DetectedCause.CauseConfidence = hasFatigueSignal ? .veryHigh : .high
            let weight = hasFatigueSignal ? 0.92 : 0.82

            causes.append(DetectedCause(
                cause: "Poor Sleep Quality",
                confidence: confidence,
                explanation: "You tagged poor sleep. Sleep debt is one of the strongest suppressors of HRV. Your heart rhythm pattern confirms reduced recovery.",
                rankingWeight: weight
            ))
        }

        return causes
    }

    private func detectDietTags(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        causes += lateMealTagCause(tags: tags, context: context)
        causes += caffeineTagCause(tags: tags, context: context)
        return causes
    }

    /// Late digestion keeps HR up overnight.
    private func lateMealTagCause(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        if tags.contains(where: { $0.name == ReadingTag.lateMeal.name }) {
            causes.append(DetectedCause(
                cause: "Late Night Eating",
                confidence: .moderateHigh,
                explanation: "You tagged a late meal. Digestion during sleep elevates metabolism and heart rate, reducing vagal tone and HRV.",
                rankingWeight: 0.7
            ))
        }
        return causes
    }

    /// Caffeine half-life reaches into the night.
    private func caffeineTagCause(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        if tags.contains(where: { $0.name == ReadingTag.caffeine.name }) {
            causes.append(DetectedCause(
                cause: "Caffeine Effect",
                confidence: .moderate,
                explanation: "You tagged caffeine. Caffeine's half-life is 5-6 hours—late consumption can disrupt deep sleep even if you fall asleep fine.",
                rankingWeight: 0.6
            ))
        }
        return causes
    }

    private func detectLifestyleTags(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        causes += travelTagCause(tags: tags, context: context)
        causes += stressedTagCause(tags: tags, context: context)
        causes += postExerciseTagCause(tags: tags, context: context)
        return causes
    }

    /// Travel disrupts circadian rhythm, sleep and hydration at once.
    private func travelTagCause(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        if tags.contains(where: { $0.name == ReadingTag.travel.name }) {
            causes.append(DetectedCause(
                cause: "Travel Stress / Jet Lag",
                confidence: .moderateHigh,
                explanation: "You tagged travel. Travel disrupts circadian rhythm, sleep, and hydration—all of which lower HRV.",
                rankingWeight: 0.75
            ))
        }
        return causes
    }

    /// Weighted higher when LF/HF confirms sympathetic activation.
    private func stressedTagCause(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        if tags.contains(where: { $0.name == ReadingTag.stressed.name }) {
            let hasSympatheticActivation = context.lfHfRatio > HRVThresholds.lfHfModerateSympatheticUpper
            let confidence: DetectedCause.CauseConfidence = hasSympatheticActivation ? .veryHigh : .high
            let weight = hasSympatheticActivation ? 0.9 : 0.8

            causes.append(DetectedCause(
                cause: "Psychological Stress",
                confidence: confidence,
                explanation: "You tagged feeling stressed. Your LF/HF ratio confirms elevated sympathetic activity consistent with mental/emotional load.",
                rankingWeight: weight
            ))
        }
        return causes
    }

    /// Weighted higher when the HRV drop confirms the training cost.
    private func postExerciseTagCause(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        if tags.contains(where: { $0.name == ReadingTag.postExercise.name }) {
            let isLowHRV = context.rmssd < HRVThresholds.rmssdReduced
            let confidence: DetectedCause.CauseConfidence = isLowHRV ? .high : .moderate
            let weight = isLowHRV ? 0.85 : 0.65

            causes.append(DetectedCause(
                cause: "Exercise Recovery",
                confidence: confidence,
                explanation: "You tagged post-exercise. HRV is suppressed for 24-72 hours after intense training while your body repairs and adapts.",
                rankingWeight: weight
            ))
        }
        return causes
    }

    private func detectHealthTags(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        causes += illnessTagCause(tags: tags, context: context)
        causes += menstrualTagCause(tags: tags, context: context)
        return causes
    }

    /// The user reported illness.
    private func illnessTagCause(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        if tags.contains(where: { $0.name == ReadingTag.illness.name }) {
            causes.append(DetectedCause(
                cause: "Active Illness",
                confidence: .veryHigh,
                explanation: "You tagged illness. Your immune system is active, which dramatically increases sympathetic tone and suppresses HRV.",
                rankingWeight: 0.98
            ))
        }
        return causes
    }

    /// Cycle phase has a known autonomic signature.
    private func menstrualTagCause(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        if tags.contains(where: { $0.name == ReadingTag.menstrual.name }) {
            causes.append(DetectedCause(
                cause: "Menstrual Cycle Phase",
                confidence: .moderate,
                explanation: "You tagged menstrual. HRV naturally varies across the cycle, often dipping during menstruation due to hormonal shifts.",
                rankingWeight: 0.6
            ))
        }
        return causes
    }
}
