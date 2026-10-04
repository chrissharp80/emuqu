import Foundation

// Temporal smoothing, interval construction and the Apple Watch augmentation
// path. Members are internal rather than `private` because
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

    /// One interval per run of same-stage, back-to-back windows. Windows
    /// dropped for too few beats (a strap dropout) leave a gap, and the gap
    /// ends the interval at the last window's end: stretching the stage
    /// across it would count the dropout as sleep.
    static func buildIntervals(
        windows: [FeatureWindow],
        stages: [HealthKitManager.SleepStage]
    ) -> [HealthKitManager.SleepStageInterval] {
        guard windows.count == stages.count, !windows.isEmpty else { return [] }
        var intervals: [HealthKitManager.SleepStageInterval] = []
        var currentStage = stages[0]
        var segmentStart = windows[0].startDate
        for i in 1 ..< windows.count
        where stages[i] != currentStage || windows[i].startDate > windows[i - 1].endDate {
            intervals.append(HealthKitManager.SleepStageInterval(
                stage: currentStage, start: segmentStart, end: windows[i - 1].endDate
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
        // `p` is a fraction clamped to [0, 1]: unclamped, p = 1.5 indexes past
        // the end and p = -0.5 indexes negatively, and a NaN `p` reaches
        // `Int(idx)`, which traps. NaN reads as 0 (the first value); +infinity
        // clamps to 1 (the last value) and -infinity to 0, like any other
        // out-of-range p. With p in [0, 1], idx lands in [0, count-1], so
        // `lower` and `upper` are always valid indices.
        let clamped = p.isNaN ? 0 : min(max(p, 0), 1)
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
    /// HRV evidence catches what Watch misses. The result is the Watch's own intervals with
    /// only the overridden 5-minute epochs repainted (`applyOverrides`): Watch sleep before
    /// the strap starts, after it comes off and across strap dropouts keeps the Watch's
    /// stages and timing, an epoch the Watch doesn't cover is never invented, and no
    /// smoothing pass touches a Watch stage that HRV didn't override.
    ///
    /// REM augmentation is gated on frequency-domain (LF/HF) availability. Without LF/HF,
    /// cardiac features cannot reliably distinguish REM from N2: RMSSD shows no significant
    /// difference (42±13 vs 37±16 ms, Herzig 2017), and DFA α1 separation is marginal
    /// (1.18 vs 1.00, Penzel 2003). LF/HF is the only reliable discriminator (~3.0 vs ~1.2,
    /// Vanoli 1995). Deep augmentation works without LF/HF because deep sleep has strong,
    /// reproducible cardiac signatures (RMSSD ICC=0.84, and the lowest DFA α1 of
    /// the night; see `computeWindowScores` for why no magnitude is quoted).
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
        guard scores.count == windows.count else { return nil }
        let watchStages = windows.map { dominantStage(in: $0, watchIntervals: watchIntervals) }
        let augmentations = applyAugmentationDecisions(windows: windows, watchStages: watchStages, scores: scores)
        let intervals = applyOverrides(augmentations, to: watchIntervals)
        return augmentationResult(intervals: intervals, augmentations: augmentations, epochs: windows.count)
    }

    /// Repaint the Watch's own intervals with the HRV overrides. Inside an
    /// overridden epoch only the part the Watch labelled with the overridden
    /// stage changes (a minority stage sharing the epoch keeps its label), and
    /// the repainted slice is marked `.hrvDerived`. Everything outside the
    /// overrides is the Watch's interval, unchanged.
    static func applyOverrides(
        _ overrides: [Augmentation],
        to watchIntervals: [HealthKitManager.SleepStageInterval]
    ) -> [HealthKitManager.SleepStageInterval] {
        watchIntervals
            .flatMap { interval in
                repaint(interval, with: overrides.filter {
                    $0.watchStage == interval.stage && $0.windowStart < interval.end && $0.windowEnd > interval.start
                })
            }
            .sorted { $0.start < $1.start }
    }

    /// One Watch interval cut at the overrides that fall inside it.
    static func repaint(
        _ interval: HealthKitManager.SleepStageInterval,
        with overrides: [Augmentation]
    ) -> [HealthKitManager.SleepStageInterval] {
        var pieces: [HealthKitManager.SleepStageInterval] = []
        var cursor = interval.start
        for change in overrides.sorted(by: { $0.windowStart < $1.windowStart }) {
            let start = max(change.windowStart, cursor)
            let end = min(change.windowEnd, interval.end)
            guard start < end else { continue }
            if cursor < start {
                pieces.append(.init(stage: interval.stage, start: cursor, end: start, provenance: interval.provenance))
            }
            pieces.append(.init(stage: change.augmentedStage, start: start, end: end, provenance: .hrvDerived))
            cursor = end
        }
        if cursor < interval.end {
            pieces.append(.init(stage: interval.stage, start: cursor, end: interval.end, provenance: interval.provenance))
        }
        return pieces
    }

    static func augmentationResult(
        intervals: [HealthKitManager.SleepStageInterval],
        augmentations: [Augmentation],
        epochs: Int
    ) -> AugmentationResult {
        let stageMinutes = accumulateStageMinutes(intervals)
        debugLog("[SleepAugmentation] \(augmentations.count) of \(epochs) epochs changed")
        return AugmentationResult(
            stageIntervals: intervals, deepSleepMinutes: stageMinutes.deep,
            remSleepMinutes: stageMinutes.rem, coreSleepMinutes: stageMinutes.core,
            awakeMinutes: stageMinutes.awake,
            augmentationCount: augmentations.count, augmentations: augmentations
        )
    }

    // MARK: - Augmentation Helpers

    /// Per-epoch overrides where HRV evidence disagrees with the Watch. An
    /// epoch the Watch doesn't cover (`nil`) is skipped: augmentation refines
    /// the Watch's stages, it never adds sleep the Watch didn't record.
    static func applyAugmentationDecisions(
        windows: [FeatureWindow],
        watchStages: [HealthKitManager.SleepStage?],
        scores: [WindowScores]
    ) -> [Augmentation] {
        zip(windows, zip(watchStages, scores)).compactMap { window, pair -> Augmentation? in
            let (watchStage, score) = pair
            guard let watch = watchStage else { return nil }
            let finalStage = decideAugmentedStage(watch: watch, score: score)
            guard finalStage != watch else { return nil }
            return Augmentation(
                windowStart: window.startDate, windowEnd: window.endDate,
                watchStage: watch, augmentedStage: finalStage,
                score: augmentationScore(for: finalStage, in: score)
            )
        }
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

    /// The Watch stage covering most of `window`, or nil when no Watch
    /// interval overlaps it, so augmentation leaves an uncovered epoch alone.
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
}
