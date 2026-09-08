import Foundation
import HealthKit

// MARK: - Configuration

/// Parameters used by `processForRecording` to build the resolver Context.
/// All sleep accounting lives in `SleepResolver`; this struct is a factored
/// bundle of the settings the pipeline reaches for when a caller doesn't
/// want to touch SettingsManager directly.
struct SleepMergingConfig {
    let overnightWindowStart: Date
    let overnightWindowEnd: Date
    let awakeGapSplitMinutes: Int
    /// Whether to augment Apple Watch sleep stages with chest-strap RR
    /// features (the user's "HRV-Enhanced Sleep Stages" toggle). Carried on
    /// the config — read once via the settings seam below — because a
    /// parameter default that reads a fresh `UserSettings()` is always
    /// `false`, making the toggle a silent no-op on the primary morning
    /// fetch regardless of what the user set.
    let enhanceWithRR: Bool

    /// Build config from current user settings for a recording-scoped fetch.
    static func fromSettings(recordingStart: Date, settingsManager: SettingsManager = AppDependencies.current.app.settingsManager) -> SleepMergingConfig {
        let settings = settingsManager.settingsSnapshot
        let schedule = settings.sleepSchedule
        return SleepMergingConfig(
            overnightWindowStart: schedule.overnightWindowStart(relativeTo: recordingStart),
            overnightWindowEnd: schedule.overnightWindowEnd(relativeTo: recordingStart),
            awakeGapSplitMinutes: settings.sleepSplitGapMinutes,
            enhanceWithRR: settings.enableHRVSleepAugmentation
        )
    }

    /// Defaults for processing-only paths (last-night, trend) that don't have
    /// a recording to anchor on.
    static func defaultProcessing(settingsManager: SettingsManager = AppDependencies.current.app.settingsManager) -> SleepMergingConfig {
        let settings = settingsManager.settingsSnapshot
        return SleepMergingConfig(
            overnightWindowStart: .distantPast,
            overnightWindowEnd: .distantFuture,
            awakeGapSplitMinutes: settings.sleepSplitGapMinutes,
            enhanceWithRR: settings.enableHRVSleepAugmentation
        )
    }
}

// MARK: - Value Types

/// Accumulated stage minutes. Single source of truth for deep/rem/core/awake/unspecified.
struct StageMinutes {
    var deep: Int = 0
    var rem: Int = 0
    var core: Int = 0
    var awake: Int = 0
    var unspecified: Int = 0

    var hasDetailed: Bool {
        (deep + rem + core) > 0
    }

    var detailedSleep: Int {
        deep + rem + core
    }

    /// Sum of all non-awake sleep.
    var totalSleep: Int {
        detailedSleep + unspecified
    }
}

// MARK: - Pipeline

/// Stage-interval primitives used by `SleepResolver` and the timeline editor.
enum SleepMergingPipeline {
    // MARK: - Reusable Primitives

    /// Accumulate stage minutes from sleep stage intervals.
    static func accumulateStageMinutes(
        _ intervals: [HealthKitManager.SleepStageInterval]
    ) -> StageMinutes {
        var result = StageMinutes()
        for interval in intervals {
            let minutes = interval.durationMinutes
            switch interval.stage {
            case .deep: result.deep += minutes
            case .rem: result.rem += minutes
            case .core: result.core += minutes
            case .awake: result.awake += minutes
            case .unspecified: result.unspecified += minutes
            }
        }
        return result
    }

    /// Clip stage intervals to a time window, discarding anything outside.
    /// Provenance is preserved so downstream code (e.g. the timeline editor)
    /// can still tell Watch data apart from user-declared sleep after a clip.
    static func clipIntervals(
        _ intervals: [HealthKitManager.SleepStageInterval],
        to start: Date,
        end: Date
    ) -> [HealthKitManager.SleepStageInterval] {
        intervals.compactMap { interval in
            let s = max(interval.start, start)
            let e = min(interval.end, end)
            guard s < e else { return nil }
            return HealthKitManager.SleepStageInterval(
                stage: interval.stage,
                start: s,
                end: e,
                provenance: interval.provenance
            )
        }
    }

    /// Split items into groups separated by time gaps >= threshold.
    /// Sorts internally by `startOf` — callers need not pre-sort.
    /// Generic over any type with start/end dates.
    static func splitByGaps<T>(
        _ items: [T],
        gap: TimeInterval,
        startOf: (T) -> Date,
        endOf: (T) -> Date
    ) -> [[T]] {
        let sorted = items.sorted { startOf($0) < startOf($1) }
        guard let first = sorted.first else { return [] }
        var groups: [[T]] = []
        var current: [T] = [first]

        for item in sorted.dropFirst() {
            guard let previous = current.last else {
                current = [item]
                continue
            }
            if startOf(item).timeIntervalSince(endOf(previous)) >= gap {
                groups.append(current)
                current = [item]
            } else {
                current.append(item)
            }
        }
        groups.append(current)
        return groups
    }

    /// Convenience: split SleepStageIntervals by physical gap threshold. Sorts internally.
    static func splitStageIntervals(
        _ intervals: [HealthKitManager.SleepStageInterval],
        gap: TimeInterval
    ) -> [[HealthKitManager.SleepStageInterval]] {
        let sorted = intervals.sorted { $0.start < $1.start }
        return splitByGaps(sorted, gap: gap, startOf: \.start, endOf: \.end)
    }

    /// Build a SleepSegment from stage intervals.
    /// Uses first/last interval for boundaries.
    static func buildSegmentFromIntervals(
        _ intervals: [HealthKitManager.SleepStageInterval]
    ) -> HealthKitManager.SleepSegment? {
        guard let first = intervals.first, let last = intervals.last else { return nil }
        let stages = accumulateStageMinutes(intervals)
        return HealthKitManager.SleepSegment(
            sleepStart: first.start,
            sleepEnd: last.end,
            totalSleepMinutes: stages.totalSleep,
            deepSleepMinutes: stages.deep > 0 ? stages.deep : nil,
            remSleepMinutes: stages.rem > 0 ? stages.rem : nil,
            coreSleepMinutes: stages.core > 0 ? stages.core : nil,
            awakeMinutes: stages.awake
        )
    }

    // MARK: - Awake-Accumulation Split (single generic algorithm)

    /// Split a sorted sequence when accumulated awake >= threshold.
    ///
    /// Tracks accumulated awake time across interleaved awake/sleep intervals.
    /// The awake counter only resets when there's been >= `thresholdMinutes` of
    /// consecutive sleep (proving the person genuinely fell back asleep).
    /// Short sleep intervals embedded in an awake stretch don't reset the counter.
    ///
    /// A split requires BOTH conditions:
    /// 1. Accumulated awake >= threshold
    /// 2. The region is predominantly awake (>= 50% of total span)
    /// This prevents splitting on restless-but-still-sleeping periods where
    /// awake is scattered among real sleep blocks.
    ///
    /// The awake region (including embedded sleep) is dropped from both groups.
    static func splitByAccumulatedAwake<T>(
        _ items: [T],
        thresholdMinutes: Int,
        isAwake: (T) -> Bool,
        durationMinutes: (T) -> Int,
        sortBy: (T, T) -> Bool
    ) -> [[T]] {
        var state = AwakeSplitState<T>()
        for item in items.sorted(by: sortBy) {
            let minutes = durationMinutes(item)
            if isAwake(item) {
                state.absorbAwake(item, minutes: minutes)
            } else if state.awakeBuffer.isEmpty {
                // Not in an awake streak — accumulate sleep normally
                state.currentGroup.append(item)
            } else {
                // In an awake streak — track consecutive sleep
                state.absorbSleepCandidate(item, minutes: minutes, thresholdMinutes: thresholdMinutes)
            }
        }
        return state.finish(thresholdMinutes: thresholdMinutes)
    }

    /// The running state of `splitByAccumulatedAwake`: the groups emitted so
    /// far, the group being built, the awake buffer (awake plus any sleep
    /// embedded in it), and the sleep run that might end the awake streak.
    private struct AwakeSplitState<T> {
        var result: [[T]] = []
        var currentGroup: [T] = []
        var awakeBuffer: [T] = []
        var awakeMinutes = 0
        /// Total duration of everything in `awakeBuffer`.
        var bufferTotalMinutes = 0
        var sleepCandidate: [T] = []
        var sleepCandidateMinutes = 0

        /// At least half the buffered span was actually awake — the test that
        /// separates a real wake-up from restless-but-still-asleep.
        var predominantlyAwake: Bool {
            bufferTotalMinutes > 0 && awakeMinutes * 2 >= bufferTotalMinutes
        }

        /// A sleep run that wasn't long enough to reset folds back into the
        /// awake buffer before the new awake interval joins it.
        mutating func absorbAwake(_ item: T, minutes: Int) {
            if !sleepCandidate.isEmpty {
                awakeBuffer.append(contentsOf: sleepCandidate)
                bufferTotalMinutes += sleepCandidateMinutes
                sleepCandidate = []
                sleepCandidateMinutes = 0
            }
            awakeBuffer.append(item)
            awakeMinutes += minutes
            bufferTotalMinutes += minutes
        }

        /// Enough consecutive sleep closes the awake streak; anything shorter
        /// just accumulates and the streak stays open.
        mutating func absorbSleepCandidate(_ item: T, minutes: Int, thresholdMinutes: Int) {
            sleepCandidate.append(item)
            sleepCandidateMinutes += minutes
            guard sleepCandidateMinutes >= thresholdMinutes else { return }
            closeStreak(thresholdMinutes: thresholdMinutes)
        }

        /// Solid sleep arrived — the awake streak is over. Only split if the
        /// region was predominantly awake (not just restless sleep); otherwise
        /// the whole buffer folds back into the current group.
        mutating func closeStreak(thresholdMinutes: Int) {
            if awakeMinutes >= thresholdMinutes, predominantlyAwake {
                if !currentGroup.isEmpty { result.append(currentGroup) }
                currentGroup = sleepCandidate
            } else {
                currentGroup.append(contentsOf: awakeBuffer)
                currentGroup.append(contentsOf: sleepCandidate)
            }
            awakeBuffer = []
            awakeMinutes = 0
            bufferTotalMinutes = 0
            sleepCandidate = []
            sleepCandidateMinutes = 0
        }

        /// Flush whatever is still buffered at the end of the sequence. A
        /// trailing sleep run only becomes its own group if it is itself long
        /// enough to count as sleep.
        mutating func finish(thresholdMinutes: Int) -> [[T]] {
            if awakeMinutes >= thresholdMinutes, predominantlyAwake {
                if !currentGroup.isEmpty { result.append(currentGroup) }
                currentGroup = sleepCandidateMinutes >= thresholdMinutes ? sleepCandidate : []
            } else {
                currentGroup.append(contentsOf: awakeBuffer)
                currentGroup.append(contentsOf: sleepCandidate)
            }
            if !currentGroup.isEmpty { result.append(currentGroup) }
            return result
        }
    }

    /// Split stage intervals by accumulated awake. Thin wrapper over splitByAccumulatedAwake.
    static func splitStageIntervalsByAwake(
        _ intervals: [HealthKitManager.SleepStageInterval],
        gap: TimeInterval
    ) -> [[HealthKitManager.SleepStageInterval]] {
        splitByAccumulatedAwake(
            intervals,
            thresholdMinutes: Int(gap / 60),
            isAwake: { $0.stage == .awake },
            durationMinutes: { $0.durationMinutes },
            sortBy: { $0.start < $1.start }
        )
    }

    // MARK: - Entry Point

    /// Full pipeline for a recording-scoped sleep fetch.
    ///
    /// Thin adapter: builds a `SleepResolver.Context` and delegates. All sleep
    /// accounting — total minutes, envelope clipping, cross-source merging,
    /// stage augmentation, segment building — lives in `SleepResolver` and
    /// is covered by `SleepResolverTests`.
    ///
    /// Never hand the resolver a zero- or negative-length
    /// envelope. A crash-interrupted overnight can arrive here with
    /// `recordingEnd <= recordingStart` (callers collapse a nil `endDate` to
    /// `startDate`); that would clip away every Watch sleep stage and the night
    /// would score sleepless. Widen the end to the overnight window's end (the
    /// real morning) so the Watch stages survive the clip. The resolver has its
    /// own Watch-span rescue too — this keeps the envelope sane at the source
    /// so `inBedStart`/segment boundaries stay correct.
    static func processForRecording(
        samples: [HKCategorySample],
        recordingStart: Date,
        recordingEnd: Date,
        config: SleepMergingConfig,
        rrPoints: [RRPoint]? = nil,
        autoSleepExtension: SleepResolver.AutoSleepExtension? = nil
    ) -> SleepData {
        let safeRecordingEnd = recordingEnd > recordingStart
            ? recordingEnd
            : max(config.overnightWindowEnd, recordingStart.addingTimeInterval(60))
        let bounds = DateInterval(start: recordingStart, end: safeRecordingEnd)
        let ctx = SleepResolver.Context(
            sessionBounds: bounds,
            linkedSessionBounds: [bounds],
            watchSamples: samples,
            rrPoints: rrPoints ?? [],
            bedtimeWindow: DateInterval(start: config.overnightWindowStart, end: config.overnightWindowEnd),
            enhanceWithRR: config.enhanceWithRR,
            autoSleepExtension: autoSleepExtension,
            fallbackDate: samples.first?.startDate ?? recordingStart,
            splitGapMinutes: config.awakeGapSplitMinutes
        )
        return SleepResolver.resolve(ctx).sleepData
    }
}
