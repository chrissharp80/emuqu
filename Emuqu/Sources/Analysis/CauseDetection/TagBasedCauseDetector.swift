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
                cause: String(localized: "Alcohol Consumption", bundle: NarrativeLanguage.bundle),
                confidence: confidence,
                explanation: String(localized: "You tagged alcohol. Even moderate drinking suppresses HRV for 24-48 hours by disrupting sleep architecture and increasing sympathetic tone.", bundle: NarrativeLanguage.bundle),
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

            let explanation = hasFatigueSignal
                ? String(localized: "You tagged poor sleep. Sleep debt is one of the strongest suppressors of HRV. Your heart rhythm pattern also points to reduced recovery.", bundle: NarrativeLanguage.bundle)
                : String(localized: "You tagged poor sleep. Sleep debt is one of the strongest suppressors of HRV.", bundle: NarrativeLanguage.bundle)
            causes.append(DetectedCause(
                cause: String(localized: "Poor Sleep Quality", bundle: NarrativeLanguage.bundle),
                confidence: confidence,
                explanation: explanation,
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
                cause: String(localized: "Late Night Eating", bundle: NarrativeLanguage.bundle),
                confidence: .moderateHigh,
                explanation: String(localized: "You tagged a late meal. Digestion during sleep elevates metabolism and heart rate, reducing vagal tone and HRV.", bundle: NarrativeLanguage.bundle),
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
                cause: String(localized: "Caffeine Effect", bundle: NarrativeLanguage.bundle),
                confidence: .moderate,
                explanation: String(localized: "You tagged caffeine. Caffeine's half-life is 5-6 hours—late consumption can disrupt deep sleep even if you fall asleep fine.", bundle: NarrativeLanguage.bundle),
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
                cause: String(localized: "Travel Stress / Jet Lag", bundle: NarrativeLanguage.bundle),
                confidence: .moderateHigh,
                explanation: String(localized: "You tagged travel. Travel disrupts circadian rhythm, sleep, and hydration—all of which lower HRV.", bundle: NarrativeLanguage.bundle),
                rankingWeight: 0.75
            ))
        }
        return causes
    }

    /// Weighted higher when the LF/HF ratio is also raised. The ratio moves
    /// with breathing rate too, so the copy never calls it confirmation.
    private func stressedTagCause(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        if tags.contains(where: { $0.name == ReadingTag.stressed.name }) {
            let hasRaisedLFHF = context.lfHfRatio > HRVThresholds.lfHfModerateSympatheticUpper
            let confidence: DetectedCause.CauseConfidence = hasRaisedLFHF ? .veryHigh : .high
            let weight = hasRaisedLFHF ? 0.9 : 0.8
            let explanation = hasRaisedLFHF
                ? String(localized: "You tagged feeling stressed. Mental and emotional load commonly lowers HRV. Your LF/HF ratio is raised too, which often goes with that load, though breathing rate also moves it.", bundle: NarrativeLanguage.bundle)
                : String(localized: "You tagged feeling stressed. Mental and emotional load commonly lowers HRV.", bundle: NarrativeLanguage.bundle)

            causes.append(DetectedCause(
                cause: String(localized: "Psychological Stress", bundle: NarrativeLanguage.bundle),
                confidence: confidence,
                explanation: explanation,
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
                cause: String(localized: "Exercise Recovery", bundle: NarrativeLanguage.bundle),
                confidence: confidence,
                explanation: String(localized: "You tagged post-exercise. HRV is suppressed for 24-72 hours after intense training while your body repairs and adapts.", bundle: NarrativeLanguage.bundle),
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
                cause: String(localized: "Active Illness", bundle: NarrativeLanguage.bundle),
                confidence: .veryHigh,
                explanation: String(localized: "You tagged illness. Being unwell commonly raises resting heart rate and lowers HRV, so expect today's numbers to reflect that.", bundle: NarrativeLanguage.bundle),
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
                cause: String(localized: "Menstrual Cycle Phase", bundle: NarrativeLanguage.bundle),
                confidence: .moderate,
                explanation: String(localized: "You tagged menstrual. HRV naturally varies across the cycle, often dipping during menstruation due to hormonal shifts.", bundle: NarrativeLanguage.bundle),
                rankingWeight: 0.6
            ))
        }
        return causes
    }
}
