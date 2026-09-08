import Foundation

// Temporal smoothing, interval construction and the Apple Watch augmentation
// and validation path. Members are internal rather than `private` because
// Swift's `private` does not reach across files.

extension HRVSleepStageClassifier {
    // MARK: - Temporal Smoothing

    static func smoothStages(_ stages: [HealthKitManager.SleepStage]) -> [HealthKitManager.SleepStage] {
        guard stages.count >= 3 else { return stages }

        var smoothed = stages
        for i in 1 ..< (stages.count - 1) {
            let prev = smoothed[i - 1]
            let curr = smoothed[i]
            let next = smoothed[i + 1]

            if curr == .awake { continue }
            if prev == next, curr != prev {
                smoothed[i] = prev
            }
        }

        return smoothed
    }

    // MARK: - Interval Construction

    static func buildIntervals(
        windows: [FeatureWindow],
        stages: [HealthKitManager.SleepStage]
    ) -> [HealthKitManager.SleepStageInterval] {
        guard windows.count == stages.count, !windows.isEmpty else { return [] }
        var intervals: [HealthKitManager.SleepStageInterval] = []
        var currentStage = stages[0]
        var segmentStart = windows[0].startDate
        for i in 1 ..< windows.count where stages[i] != currentStage {
            intervals.append(HealthKitManager.SleepStageInterval(
                stage: currentStage, start: segmentStart, end: windows[i].startDate
            ))
            currentStage = stages[i]
            segmentStart = windows[i].startDate
        }
        intervals.append(HealthKitManager.SleepStageInterval(
            stage: currentStage, start: segmentStart, end: windows[windows.count - 1].endDate
        ))
        return intervals
    }

    // MARK: - Helpers

    static func percentile(_ sorted: [Double], p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        // `p` is clamped to [0, 1]: unclamped, p = 1.5 indexes past the end
        // and p = -0.5 indexes negatively — both out-of-bounds crashes — and
        // a NaN `p` reaches `Int(idx)`, which traps. No production caller
        // passes an out-of-range percentile, so this is a latent hazard
        // rather than a live bug.
        // Clamping `p` is what keeps the indices in range: with p in [0, 1],
        // idx lands in [0, count-1] and both `lower` and `upper` are valid. A
        // second clamp on `lower` would be dead code — a mutation removing one
        // survived the suite for exactly that reason.
        let clamped = p.isFinite ? min(max(p, 0), 1) : 0
        let idx = clamped * Double(sorted.count - 1)
        let lower = Int(idx)
        let upper = min(lower + 1, sorted.count - 1)
        let frac = idx - Double(lower)
        return sorted[lower] + frac * (sorted[upper] - sorted[lower])
    }

    // MARK: - Watch Stage Augmentation

    /// Augment Apple Watch sleep stages using HRV evidence from RR intervals.
    ///
    /// Apple Watch staging (kappa ~0.5-0.6 vs PSG) has known weaknesses:
    /// - Underreports deep sleep: N3 requires EEG slow waves, Watch uses accelerometer + optical HR
    /// - Confuses REM twitches with wakefulness
    ///
    /// This method uses the same 7-feature rank-based scoring as standalone classification,
    /// but requires HIGHER confidence thresholds to override Watch stages. Watch is the anchor;
    /// HRV evidence catches what Watch misses.
    ///
    /// REM augmentation is gated on frequency-domain (LF/HF) availability. Without LF/HF,
    /// cardiac features cannot reliably distinguish REM from N2: RMSSD shows no significant
    /// difference (42±13 vs 37±16 ms, Herzig 2017), and DFA α1 separation is marginal
    /// (1.18 vs 1.00, Penzel 2003). LF/HF is the only reliable discriminator (~3.0 vs ~1.2,
    /// Vanoli 1995). Deep augmentation works without LF/HF because deep sleep has strong,
    /// reproducible cardiac signatures (RMSSD ICC=0.84, DFA ~0.5-0.7 vs >1.0 for other stages).
    ///
    /// Augmentation rules (in priority order):
    /// 1. Core → Deep: when deep score > 0.68 (Watch's most common miss, no freq-domain gate)
    /// 2. Core → REM: when REM score > 0.63 AND LF/HF available (freq-domain gated)
    /// 3. Awake → REM: when REM score > 0.68 AND awake score < 0.80 AND LF/HF available
    /// 4. Deep ↔ REM: only with very strong opposing evidence (score > 0.72, Watch score < 0.40)
    static func augment(
        watchIntervals: [HealthKitManager.SleepStageInterval],
        rrPoints: [RRPoint],
        sleepStartMs: Int64,
        sleepEndMs: Int64,
        recordingStart: Date
    ) -> AugmentationResult? {
        guard sleepEndMs > sleepStartMs else { return nil }
        let windows = buildFeatureWindows(
            rrPoints: rrPoints, sleepStartMs: sleepStartMs,
            sleepEndMs: sleepEndMs, recordingStart: recordingStart
        )
        guard windows.count >= minWindowsForClassification else {
            debugLog("[HRVSleepStageClassifier] Augmentation skipped: insufficient windows (\(windows.count))")
            return nil
        }
        let scores = computeWindowScores(windows, sleepStartMs: sleepStartMs)
        let watchStages = mapWatchToEpochs(watchIntervals: watchIntervals, windows: windows)
        guard watchStages.count == scores.count else { return nil }
        let (rawStages, augmentations) = applyAugmentationDecisions(
            windows: windows, watchStages: watchStages, scores: scores
        )
        let intervals = buildIntervals(windows: windows, stages: smoothStages(rawStages))
        return augmentationResult(intervals: intervals, augmentations: augmentations, epochs: windows.count)
    }

    static func augmentationResult(
        intervals: [HealthKitManager.SleepStageInterval],
        augmentations: [Augmentation],
        epochs: Int
    ) -> AugmentationResult {
        let stageMinutes = accumulateStageMinutes(intervals)
        logAugmentation(
            augmentations: augmentations,
            totalEpochs: epochs,
            deepMinutes: stageMinutes.deep,
            remMinutes: stageMinutes.rem,
            coreMinutes: stageMinutes.core,
            awakeMinutes: stageMinutes.awake
        )
        return AugmentationResult(
            stageIntervals: intervals, deepSleepMinutes: stageMinutes.deep,
            remSleepMinutes: stageMinutes.rem, coreSleepMinutes: stageMinutes.core,
            awakeMinutes: stageMinutes.awake,
            augmentationCount: augmentations.count, augmentations: augmentations
        )
    }

    // MARK: - Augmentation Helpers

    /// Apply per-epoch augmentation decisions comparing Watch stages with HRV scores.
    static func applyAugmentationDecisions(
        windows: [FeatureWindow],
        watchStages: [HealthKitManager.SleepStage],
        scores: [WindowScores]
    ) -> (stages: [HealthKitManager.SleepStage], augmentations: [Augmentation]) {
        var stages = [HealthKitManager.SleepStage]()
        var augmentations = [Augmentation]()
        for i in 0 ..< windows.count {
            let watch = watchStages[i]
            let finalStage = decideAugmentedStage(watch: watch, score: scores[i])
            if finalStage != watch {
                augmentations.append(Augmentation(
                    windowStart: windows[i].startDate,
                    watchStage: watch, augmentedStage: finalStage,
                    score: augmentationScore(for: finalStage, in: scores[i])
                ))
            }
            stages.append(finalStage)
        }
        return (stages, augmentations)
    }

    /// The score that justified the override, for the audit line.
    static func augmentationScore(for stage: HealthKitManager.SleepStage, in score: WindowScores) -> Double {
        switch stage {
        case .deep: score.deepScore
        case .rem: score.remScore
        default: score.awakeScore
        }
    }

    /// Decide the augmented stage for a single epoch based on Watch classification and HRV scores.
    static func decideAugmentedStage(
        watch: HealthKitManager.SleepStage,
        score: WindowScores
    ) -> HealthKitManager.SleepStage {
        switch watch {
        case .core, .unspecified:
            return augmentedFromCore(watch: watch, score: score)
        case .awake:
            if score.hasFreqDomain, score.remScore > augmentAwakeToREMThreshold, score.awakeScore < awakeScoreThreshold {
                return .rem
            }
            return watch
        case .deep:
            if score.hasFreqDomain, score.remScore > augmentCrossStageThreshold, score.deepScore < augmentCrossStageRejectThreshold {
                return .rem
            }
            return watch
        case .rem:
            if score.deepScore > augmentCrossStageThreshold, score.remScore < augmentCrossStageRejectThreshold {
                return .deep
            }
            return watch
        }
    }

    /// Core is where the Watch misses most: it under-reports deep, and reads
    /// REM twitches as light sleep.
    static func augmentedFromCore(
        watch: HealthKitManager.SleepStage,
        score: WindowScores
    ) -> HealthKitManager.SleepStage {
        if score.deepScore > augmentCoreToDeepThreshold, score.deepScore > score.remScore {
            return .deep
        } else if score.hasFreqDomain, score.remScore > augmentCoreToREMThreshold, score.remScore > score.deepScore {
            return .rem
        }
        return watch
    }

    /// Accumulate stage minutes from intervals.
    static func accumulateStageMinutes(
        _ intervals: [HealthKitManager.SleepStageInterval]
    ) -> SleepStageMinutes {
        var deep = 0, rem = 0, core = 0, awake = 0
        for interval in intervals {
            let minutes = interval.durationMinutes
            switch interval.stage {
            case .deep: deep += minutes
            case .rem: rem += minutes
            case .core: core += minutes
            case .awake: awake += minutes
            case .unspecified: core += minutes
            }
        }
        return SleepStageMinutes(deep: deep, rem: rem, core: core, awake: awake)
    }

    /// Log augmentation results to debug output.
    static func logAugmentation(
        augmentations _: [Augmentation],
        totalEpochs _: Int,
        deepMinutes _: Int,
        remMinutes _: Int,
        coreMinutes _: Int,
        awakeMinutes _: Int
    ) {
        // No-op: augmentation details only needed for development debugging
    }

    // MARK: - Validation Against Apple Watch

    struct ValidationResult {
        let totalEpochs: Int
        let matchingEpochs: Int
        let accuracy: Double
        let kappa: Double
        /// Rows = classifier (predicted), Columns = Watch (reference)
        /// Order: [deep, core, rem, awake]
        let confusionMatrix: [[Int]]
        /// Per-stage sensitivity (recall): fraction of Watch epochs correctly identified
        let sensitivity: [HealthKitManager.SleepStage: Double]
        /// Per-stage precision (PPV): fraction of classifier epochs that were correct
        let precision: [HealthKitManager.SleepStage: Double]
    }

    /// Compare HRV classifier output against Apple Watch staging for the same night.
    /// Both datasets must cover the same sleep period. The comparison is done at 5-minute
    /// epoch resolution (the classifier's native window size).
    static func validate(
        watchIntervals: [HealthKitManager.SleepStageInterval],
        rrPoints: [RRPoint],
        sleepStartMs: Int64,
        sleepEndMs: Int64,
        recordingStart: Date
    ) -> ValidationResult? {
        guard sleepEndMs > sleepStartMs else { return nil }
        let windows = buildFeatureWindows(
            rrPoints: rrPoints,
            sleepStartMs: sleepStartMs,
            sleepEndMs: sleepEndMs,
            recordingStart: recordingStart
        )
        guard windows.count >= minWindowsForClassification else { return nil }
        let classifierStages = smoothStages(classifyWindows(windows, sleepStartMs: sleepStartMs))
        // Map Watch intervals to the same 5-min epoch grid.
        let watchStages = mapWatchToEpochs(watchIntervals: watchIntervals, windows: windows)
        guard watchStages.count == classifierStages.count else { return nil }

        let stageOrder: [HealthKitManager.SleepStage] = [.deep, .core, .rem, .awake]
        let (confusion, matching) = confusionMatrix(predicted: classifierStages, reference: watchStages)
        let result = validationResult(confusion: confusion, matching: matching,
                                      total: classifierStages.count, stageOrder: stageOrder)
        logValidation(result, stageOrder: stageOrder)
        return result
    }

    /// `confusion[predicted][reference]`, plus the count on the diagonal.
    /// `.unspecified` folds into `.core`, matching how it is reported elsewhere.
    static func confusionMatrix(
        predicted: [HealthKitManager.SleepStage],
        reference: [HealthKitManager.SleepStage]
    ) -> ([[Int]], Int) {
        let stageIndex: [HealthKitManager.SleepStage: Int] = [.deep: 0, .core: 1, .rem: 2, .awake: 3]
        // confusion[predicted][reference]
        var confusion = [[Int]](repeating: [Int](repeating: 0, count: 4), count: 4)
        var matching = 0

        for i in 0 ..< predicted.count {
            let pred = predicted[i]
            let ref = reference[i]
            let pi = stageIndex[pred == .unspecified ? .core : pred] ?? 1
            let ri = stageIndex[ref == .unspecified ? .core : ref] ?? 1
            confusion[pi][ri] += 1
            if pi == ri { matching += 1 }
        }
        return (confusion, matching)
    }

    static func validationResult(
        confusion: [[Int]],
        matching: Int,
        total: Int,
        stageOrder: [HealthKitManager.SleepStage]
    ) -> ValidationResult {
        let (sensitivity, precision) = perStageRates(confusion: confusion, stageOrder: stageOrder)
        return ValidationResult(
            totalEpochs: total,
            matchingEpochs: matching,
            accuracy: Double(matching) / Double(total),
            kappa: computeKappa(confusion: confusion, total: total),
            confusionMatrix: confusion,
            sensitivity: sensitivity,
            precision: precision
        )
    }

    /// Sensitivity = TP / column sum; precision = TP / row sum.
    static func perStageRates(
        confusion: [[Int]],
        stageOrder: [HealthKitManager.SleepStage]
    ) -> ([HealthKitManager.SleepStage: Double], [HealthKitManager.SleepStage: Double]) {
        var sensitivity: [HealthKitManager.SleepStage: Double] = [:]
        var precision: [HealthKitManager.SleepStage: Double] = [:]

        for (si, stage) in stageOrder.enumerated() {
            // Sensitivity = TP / (TP + FN) = confusion[si][si] / column sum
            let colSum = (0 ..< 4).reduce(0) { $0 + confusion[$1][si] }
            sensitivity[stage] = colSum > 0 ? Double(confusion[si][si]) / Double(colSum) : 0

            // Precision = TP / (TP + FP) = confusion[si][si] / row sum
            let rowSum = confusion[si].reduce(0, +)
            precision[stage] = rowSum > 0 ? Double(confusion[si][si]) / Double(rowSum) : 0
        }
        return (sensitivity, precision)
    }

    /// Map Watch intervals to 5-min epoch grid by majority vote.
    /// For each classifier window, find which Watch stage covers the majority of that window.
    static func mapWatchToEpochs(
        watchIntervals: [HealthKitManager.SleepStageInterval],
        windows: [FeatureWindow]
    ) -> [HealthKitManager.SleepStage] {
        windows.map { window in
            // Default to core when no Watch interval overlaps at all.
            dominantStage(in: window, watchIntervals: watchIntervals) ?? .core
        }
    }

    static func dominantStage(
        in window: FeatureWindow,
        watchIntervals: [HealthKitManager.SleepStageInterval]
    ) -> HealthKitManager.SleepStage? {
        var stageDuration: [HealthKitManager.SleepStage: TimeInterval] = [:]
        for interval in watchIntervals {
            let overlap = min(window.endDate, interval.end).timeIntervalSince(max(window.startDate, interval.start))
            guard overlap > 0 else { continue }
            stageDuration[interval.stage, default: 0] += overlap
        }
        return stageDuration.max(by: { $0.value < $1.value })?.key
    }

    /// Cohen's kappa from a confusion matrix.
    static func computeKappa(confusion: [[Int]], total: Int) -> Double {
        guard total > 0 else { return 0 }
        let n = Double(total)

        // Observed agreement
        let po = Double((0 ..< 4).reduce(0) { $0 + confusion[$1][$1] }) / n

        // Expected agreement (chance)
        var pe = 0.0
        for i in 0 ..< 4 {
            let rowSum = Double(confusion[i].reduce(0, +))
            let colSum = Double((0 ..< 4).reduce(0) { $0 + confusion[$1][i] })
            pe += (rowSum * colSum) / (n * n)
        }

        return pe < 1.0 ? (po - pe) / (1.0 - pe) : 1.0
    }

    /// Log validation results to debug output.
    static func logValidation(_: ValidationResult, stageOrder _: [HealthKitManager.SleepStage]) {
        // Validation details stripped to reduce console noise
    }
}
