import Foundation
import HealthKit

// MARK: - SleepResolver
//
// Pure, deterministic sleep resolution. Four inputs × four cases:
//
//              │ has Watch          │ no Watch
// ─────────────┼────────────────────┼────────────────────────────
// has session  │ row 1: Watch clip  │ row 2: RR-inferred (writes HK)
// no session   │ row 3: Watch only  │ row 4: empty
//
// Total sleep is always computed one way:
//   sum(non-awake stage intervals, clipped to the envelope)
//
// The envelope is a list of DateIntervals (not a single range), built from:
//   - linked recording sessions (pause/resume)
//   - optional AutoSleep back-to-bed extension
//   - or the bedtime window (row 3)
//
// Gaps between envelope sub-intervals are automatically excluded from the
// total because nothing overlaps them after clipping.
//
// No singletons. No mutable state. No SettingsManager reads inside the
// resolver — the caller pre-computes everything into the Context.

enum SleepResolver {
    // MARK: - Context

    /// All inputs the resolver needs, pre-fetched by the caller.
    /// Row dispatch keys off `sessionBounds != nil` and `watchSamples.isEmpty`.
    struct Context {
        /// Absolute bounds of the recording session. Nil for rows 3 / 4.
        let sessionBounds: DateInterval?
        /// Absolute bounds of every linked session (pause/resume chain),
        /// including `sessionBounds` itself. Empty when no session.
        let linkedSessionBounds: [DateInterval]
        /// HealthKit sleep samples available for this night.
        /// Empty = no Watch (rows 2, 4).
        let watchSamples: [HKCategorySample]
        /// Merged RR data spanning all linked sessions.
        let rrPoints: [RRPoint]
        /// User's nightly bedtime window. Used as the envelope in row 3.
        let bedtimeWindow: DateInterval
        /// Whether to run HRV-based augmentation on top of Watch stages
        /// (row 1 only). Maps to `UserSettings.enableHRVSleepAugmentation`.
        let enhanceWithRR: Bool
        /// Optional post-session sleep detected by AutoSleep (row 1).
        let autoSleepExtension: AutoSleepExtension?
        /// Fallback date stamped onto SleepData.date when nothing else is
        /// available (e.g. row 4).
        let fallbackDate: Date
        /// Split-gap threshold captured into SleepData for display-only segment splits.
        let splitGapMinutes: Int
    }

    /// Post-session sleep envelope (e.g. native HealthKit sleep samples
    /// found after the user removed the strap and went back to bed). The
    /// resolver merges this into row 1's envelope and stage list —
    /// idempotent, no separate path.
    struct AutoSleepExtension {
        let bounds: DateInterval
        let stageIntervals: [HealthKitManager.SleepStageInterval]
    }

    // MARK: - Output

    /// Result of resolution. `writeToHealthKit` is the sole authorization
    /// to export sleep to HK — set only in row 2 (session, no Watch).
    struct Resolution: Equatable {
        let sleepData: SleepData
        let writeToHealthKit: Bool

        static func == (lhs: Resolution, rhs: Resolution) -> Bool {
            lhs.writeToHealthKit == rhs.writeToHealthKit
                && lhs.sleepData.nightSleepMinutes == rhs.sleepData.nightSleepMinutes
                && lhs.sleepData.awakeMinutes == rhs.sleepData.awakeMinutes
                && lhs.sleepData.sleepStart == rhs.sleepData.sleepStart
                && lhs.sleepData.sleepEnd == rhs.sleepData.sleepEnd
                && lhs.sleepData.stageIntervals.count == rhs.sleepData.stageIntervals.count
        }
    }

    // MARK: - Entry Point

    /// Resolve sleep for the given context. Dispatches to one of four pure
    /// resolvers keyed on (has session?, has Watch?).
    static func resolve(_ ctx: Context) -> Resolution {
        switch (ctx.sessionBounds != nil, ctx.watchSamples.isEmpty) {
        case (true, false): resolveSessionAndWatch(ctx)
        case (true, true): resolveSessionOnly(ctx)
        case (false, false): resolveWatchOnly(ctx)
        case (false, true): resolveEmpty(ctx)
        }
    }

    // MARK: - Row 1: session + Watch

    /// Watch owns the stages; session bounds (+ optional extension) own the envelope.
    /// Watch data outside the envelope is discarded. Awake inside the envelope is
    /// preserved as stages but excluded from totalSleepMinutes.
    private static func resolveSessionAndWatch(_ ctx: Context) -> Resolution {
        let envelope = row1Envelope(ctx)
        // Drop iPhone "asleepUnspecified" that fires before the
        // Watch detected actual sleep onset. Beta tester report: sleep claimed
        // 8 PM start, Apple Health (Watch detail) showed 9:30 PM. iPhone's
        // phone-usage-based auto-detect routinely pre-labels the 1–2 hour
        // window of "phone down + lights low" as sleep, dragging the displayed
        // sleep start backward by an hour or more.
        let watchStages = dropIphoneEarlySleepGuesses(classifyWatchSamples(ctx.watchSamples))
        let augmented = maybeAugment(watchStages, ctx: ctx, envelope: envelope)
        let combined = mergeStagesAcrossSources(augmented + (ctx.autoSleepExtension?.stageIntervals ?? []))
        let (clipped, effectiveEnvelope) = clipRescuingWatchSleep(combined, envelope: envelope)
        let sleepData = assemble(
            stages: clipped, envelope: effectiveEnvelope, ctx: ctx,
            source: ctx.autoSleepExtension != nil ? .hrValidated : .healthKit
        )
        return Resolution(sleepData: sleepData, writeToHealthKit: false)
    }

    /// The recording envelope must NEVER be able to erase real
    /// Watch sleep. The envelope is `[session.startDate, session.endDate]`, and
    /// an interrupted overnight (iOS SIGKILL'd the app before the user pressed
    /// stop) leaves `endDate` nil or crash-truncated. Callers collapse a nil end
    /// to `session.startDate`, producing a ZERO-LENGTH envelope — and
    /// `clipToEnvelope`'s `guard start < end` then drops every stage, regardless
    /// of when the Watch actually recorded sleep. Result: the Watch reports a
    /// full night, but `assemble` sees no non-awake stages, so `sleepStart ==
    /// nil` / `totalSleepMinutes == 0`, the dashboard's `sleepSnapshot` is
    /// written empty, and every subsequent refresh re-runs this same clip
    /// against the same bad bounds and never recovers — exactly the "sleep won't
    /// show, no refresh works" report.
    ///
    /// Rescue: if the Watch actually recorded non-awake sleep but the clip
    /// dropped ALL of it, the envelope is untrustworthy. Re-clip against the
    /// union of the (non-degenerate part of the) envelope and the Watch's own
    /// stage span, so the real sleep survives. Healthy nights — where the
    /// recording envelope already covers the Watch stages — never enter this
    /// branch and are completely unchanged.
    private static func clipRescuingWatchSleep(
        _ combined: [HealthKitManager.SleepStageInterval],
        envelope: [DateInterval]
    ) -> ([HealthKitManager.SleepStageInterval], [DateInterval]) {
        let clipped = clipToEnvelope(combined, envelope: envelope)
        guard combined.contains(where: { $0.stage != .awake }),
              !clipped.contains(where: { $0.stage != .awake }),
              let spanStart = combined.map(\.start).min(),
              let spanEnd = combined.map(\.end).max(),
              spanEnd > spanStart
        else { return (clipped, envelope) }
        let watchSpan = DateInterval(start: spanStart, end: spanEnd)
        let rescued = unionIntervals(envelope.filter { $0.duration > 0 } + [watchSpan])
        return (clipToEnvelope(combined, envelope: rescued), rescued)
    }

    // MARK: - Row 2: session, no Watch

    /// HRV classifies stages against the session envelope. Writes to HK —
    /// this is the only row that does.
    private static func resolveSessionOnly(_ ctx: Context) -> Resolution {
        let envelope = ctx.linkedSessionBounds
        let stages = inferStagesFromRR(ctx: ctx, envelope: envelope)
        let sleepData = assemble(
            stages: stages, envelope: envelope, ctx: ctx, source: .hrEstimated
        )
        let hasContent = sleepData.nightSleepMinutes > 0
        return Resolution(sleepData: sleepData, writeToHealthKit: hasContent)
    }

    // MARK: - Row 3: Watch only

    /// No recording: Watch is authoritative, clipped to the bedtime window.
    /// User can adjust boundaries via the timeline editor; this is the baseline
    /// before any adjustment.
    private static func resolveWatchOnly(_ ctx: Context) -> Resolution {
        let envelope = [ctx.bedtimeWindow]
        let rawStages = classifyWatchSamples(ctx.watchSamples)
        // Same iPhone-early-guess filter as Row 1. This
        // path runs when there's no Emuqu recording — Watch is
        // authoritative and any iPhone `asleepUnspecified` sample that
        // predates the Watch's detailed stages by >15 min is dropped.
        let watchStages = dropIphoneEarlySleepGuesses(rawStages)
        let merged = mergeStagesAcrossSources(watchStages)
        let clipped = clipToEnvelope(merged, envelope: envelope)
        let sleepData = assemble(
            stages: clipped, envelope: envelope, ctx: ctx, source: .healthKit
        )
        return Resolution(sleepData: sleepData, writeToHealthKit: false)
    }

    // MARK: - Row 4: nothing

    private static func resolveEmpty(_ ctx: Context) -> Resolution {
        let empty = SleepData(
            date: ctx.fallbackDate,
            totalSleepMinutes: 0,
            inBedMinutes: 0,
            awakeMinutes: 0,
            sleepEfficiency: 0,
            boundarySource: .recordingBounds,
            splitGapMinutes: ctx.splitGapMinutes
        )
        return Resolution(sleepData: empty, writeToHealthKit: false)
    }

    // MARK: - Envelope

    /// Row 1 envelope = linked recording segments + optional back-to-bed extension.
    private static func row1Envelope(_ ctx: Context) -> [DateInterval] {
        var intervals = ctx.linkedSessionBounds
        if let ext = ctx.autoSleepExtension {
            intervals.append(ext.bounds)
        }
        return unionIntervals(intervals)
    }

    /// Merge overlapping/adjacent DateIntervals into a canonical sorted list.
    /// Adjacent (zero-gap) intervals merge; any real gap is preserved.
    static func unionIntervals(_ input: [DateInterval]) -> [DateInterval] {
        let sorted = input.sorted { $0.start < $1.start }
        var result: [DateInterval] = []
        for interval in sorted {
            if let last = result.last, interval.start <= last.end {
                let mergedEnd = max(last.end, interval.end)
                result[result.count - 1] = DateInterval(start: last.start, end: mergedEnd)
            } else {
                result.append(interval)
            }
        }
        return result
    }

    // MARK: - Clip

    /// Clip stage intervals to the envelope. Each interval is intersected
    /// against each envelope sub-interval; the intersection is kept, the rest
    /// dropped. Zero-length results are discarded. Provenance is preserved.
    static func clipToEnvelope(
        _ intervals: [HealthKitManager.SleepStageInterval],
        envelope: [DateInterval]
    ) -> [HealthKitManager.SleepStageInterval] {
        guard !envelope.isEmpty else { return [] }
        // Sorted: the intersection runs stage by stage, and a stage cut by a
        // gap in the envelope comes out after later stages. Everything
        // downstream (onset, latency, segments) reads the list as a timeline.
        return intervals
            .flatMap { stage in envelope.compactMap { intersect(stage, with: $0) } }
            .sorted { $0.start < $1.start }
    }

    /// Nil when the stage and the envelope window don't overlap at all.
    private static func intersect(
        _ stage: HealthKitManager.SleepStageInterval,
        with env: DateInterval
    ) -> HealthKitManager.SleepStageInterval? {
        let start = max(stage.start, env.start)
        let end = min(stage.end, env.end)
        guard start < end else { return nil }
        return HealthKitManager.SleepStageInterval(stage: stage.stage, start: start, end: end, provenance: stage.provenance)
    }

    // MARK: - Totals

    /// Sum of non-awake interval durations. The single source of truth.
    static func totalMinutes(_ intervals: [HealthKitManager.SleepStageInterval]) -> Int {
        intervals
            .filter { $0.stage != .awake }
            .reduce(0) { $0 + durationMinutes($1) }
    }

    static func awakeMinutes(_ intervals: [HealthKitManager.SleepStageInterval]) -> Int {
        intervals
            .filter { $0.stage == .awake }
            .reduce(0) { $0 + durationMinutes($1) }
    }

    /// Minute-precise duration derived from seconds. Prevents per-interval
    /// rounding loss when many short stages sum into the total.
    private static func durationMinutes(_ interval: HealthKitManager.SleepStageInterval) -> Int {
        Int((interval.end.timeIntervalSince(interval.start) / 60).rounded())
    }

    // MARK: - Cross-Source Merge

    /// Drop iPhone-source `.unspecified` "asleep" samples
    /// that disagree with Watch-detected sleep onset. iPhone auto-detects
    /// sleep from phone-usage patterns (you put it down, screen stays
    /// dark, no taps for N minutes) and routinely calls "asleep" the
    /// hour or two you spend in bed scrolling / watching TV. Watch
    /// detailed stages (Deep / Core / REM) are derived from actual
    /// heart-rate and motion signals and accurately track falling
    /// asleep.
    ///
    /// Beta tester report: wife's session showed sleep starting at 8 PM
    /// but Apple Health (Watch-sourced detail) showed actual sleep onset
    /// at 9:30 PM. Root cause: iPhone wrote `asleepUnspecified [8:00 PM,
    /// 9:30 PM]`, Watch wrote `asleepCore [9:30 PM, ...]` and `asleepDeep
    /// [...]`. Both contributed to `sleepStages.map(\.start).min()`,
    /// which picked 8 PM from the iPhone sample.
    ///
    /// Filter rules:
    ///   • If NO Watch detailed stages exist → keep iPhone samples as-is
    ///     (iPhone is the only signal we have).
    ///   • If Watch detailed stages exist:
    ///     - Drop iPhone `.unspecified` samples that lie entirely in or
    ///       before the Watch's window (Watch has the real data; iPhone
    ///       guess is redundant or wrong).
    ///     - Trim iPhone `.unspecified` samples that extend PAST the
    ///       Watch's last detected sleep so they only contribute the
    ///       tail (e.g. Watch battery died at 4 AM, iPhone caught the
    ///       remaining 2.5 h until wake). The tail is preserved; the
    ///       overlap with Watch is dropped.
    ///   • Watch-source `.unspecified` is left alone — only iPhone's
    ///     `.unspecified` is the problematic one.
    static let iphoneSleepFilterToleranceMinutes: TimeInterval = 15
    /// Exposed `internal` (not `private`) so `SleepResolverTests` can
    /// exercise the filter in isolation — the rest of the resolver
    /// runs through `Resolver.resolve()`, which would need an entire
    /// session + HK sample harness to call indirectly.
    static func dropIphoneEarlySleepGuesses(
        _ intervals: [HealthKitManager.SleepStageInterval]
    ) -> [HealthKitManager.SleepStageInterval] {
        let watchDetailed = intervals
            .filter { $0.provenance == .watch && [.deep, .core, .rem].contains($0.stage) }
        guard let watchFirstDetailed = watchDetailed.map(\.start).min(),
              let watchLastDetailed = watchDetailed.map(\.end).max() else {
            return intervals
        }
        return intervals.compactMap { interval in
            keptIphoneGuess(
                interval, firstDetailed: watchFirstDetailed, lastDetailed: watchLastDetailed
            )
        }
    }

    /// What survives of one interval once the Watch's own detail is treated as
    /// authoritative. Nil means the interval is dropped entirely.
    private static func keptIphoneGuess(
        _ interval: HealthKitManager.SleepStageInterval,
        firstDetailed watchFirstDetailed: Date,
        lastDetailed watchLastDetailed: Date
    ) -> HealthKitManager.SleepStageInterval? {
        // Only iPhone `.unspecified` is filtered.
        guard interval.provenance == .iphone, interval.stage == .unspecified else { return interval }
        // Case A — entirely AFTER the Watch's last detected stage. Keep
        // (a continuation: e.g. Watch died, iPhone caught the tail).
        if interval.start >= watchLastDetailed { return interval }
        // Case B — entirely BEFORE the Watch's first detected stage. Keep only
        // within the tolerance window (slight pre-detection of the same onset);
        // otherwise drop the wrong "phone-down" guess.
        if interval.end <= watchFirstDetailed {
            let cutoff = watchFirstDetailed.addingTimeInterval(-iphoneSleepFilterToleranceMinutes * 60)
            return interval.start >= cutoff ? interval : nil
        }
        // Case C — overlaps the Watch's window. Watch detail is authoritative
        // for what it covers, so keep ONLY the tail extending past the Watch's
        // last detected end (preserving "Watch ran out of battery" tails).
        guard interval.end > watchLastDetailed else { return nil }
        return HealthKitManager.SleepStageInterval(
            stage: interval.stage, start: watchLastDetailed,
            end: interval.end, provenance: interval.provenance
        )
    }

    /// Merge overlapping time ranges within each stage type across sources.
    /// Unlike picking one source globally, this keeps sleep one source saw
    /// that another didn't, without double-counting.
    ///
    /// Per stage type:
    ///   1. Sort intervals by start time.
    ///   2. Walk forward, merging any that overlap or touch.
    ///   3. Preserve the first provenance seen in each merged run.
    static func mergeStagesAcrossSources(
        _ intervals: [HealthKitManager.SleepStageInterval]
    ) -> [HealthKitManager.SleepStageInterval] {
        Dictionary(grouping: intervals) { $0.stage }
            .flatMap { stage, group in mergeOverlapping(group, stage: stage) }
            .sorted { $0.start < $1.start }
    }

    /// One stage type's intervals, sorted and coalesced where they overlap or
    /// touch. The first provenance seen in a merged run is preserved.
    private static func mergeOverlapping(
        _ group: [HealthKitManager.SleepStageInterval],
        stage: HealthKitManager.SleepStage
    ) -> [HealthKitManager.SleepStageInterval] {
        var merged: [HealthKitManager.SleepStageInterval] = []
        for interval in group.sorted(by: { $0.start < $1.start }) {
            guard let last = merged.last, interval.start <= last.end else {
                merged.append(interval)
                continue
            }
            guard interval.end > last.end else { continue }
            merged[merged.count - 1] = HealthKitManager.SleepStageInterval(
                stage: stage, start: last.start, end: interval.end, provenance: last.provenance
            )
        }
        return merged
    }

    // MARK: - Stage Sourcing

    /// Flatten HK category samples into stage intervals, ignoring `.inBed`
    /// (informational only, not a sleep signal).
    ///
    /// Provenance detection is productType-led. A bundle-identifier check
    /// — `bundleIdentifier.hasPrefix("com.apple.health") && !contains("watch")`
    /// — is unreliable: Apple Watch sleep stages are written to HK by
    /// the iOS Health app *after* sync, with bundleIdentifier
    /// `com.apple.health.<deviceUUID>`. The UUID rarely contains "watch",
    /// so Watch samples are almost always misclassified as `.iphone`.
    /// That makes `dropIphoneEarlySleepGuesses` a no-op against the
    /// actual bug shape (beta tester wife: 8 PM sleep start from
    /// iPhone auto-detect, 9:30 PM truth from Watch detail).
    ///
    /// New rule: examine `sourceRevision.productType` first — Apple sets
    /// it to the device model that ORIGINATED the sample ("Watch6,1",
    /// "iPhone15,2", etc.) regardless of which device synced it.
    /// Falls back to `HKMetadataKeyWasUserEntered` (treat manual entries
    /// as `.iphone`) and finally to bundleIdentifier as a last resort.
    private static func classifyWatchSamples(
        _ samples: [HKCategorySample]
    ) -> [HealthKitManager.SleepStageInterval] {
        samples.compactMap { sample in
            guard let stage = mapHKValueToStage(sample.value) else { return nil }
            guard sample.endDate > sample.startDate else { return nil }
            return HealthKitManager.SleepStageInterval(
                stage: stage,
                start: sample.startDate,
                end: sample.endDate,
                provenance: provenance(for: sample)
            )
        }
    }

    /// productType-led provenance detection. See
    /// `classifyWatchSamples` doc-comment for the rationale.
    private static func provenance(for sample: HKCategorySample) -> HealthKitManager.SleepStageProvenance {
        let productType = sample.sourceRevision.productType?.lowercased() ?? ""
        if productType.hasPrefix("watch") { return .watch }
        if productType.hasPrefix("iphone") { return .iphone }
        // Manually entered samples (user typed sleep time into Health
        // app) — treat as `.iphone` so the conservative Watch-first
        // filter applies. A manual entry that contradicts Watch is more
        // likely user error than a third truth.
        if sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool == true {
            return .iphone
        }
        // Third-party app (AutoSleep, Sleep++, etc.) — those typically
        // re-publish Apple Watch data after their own merge step. Treat
        // as `.watch` so we don't accidentally over-filter them. Real
        // problem samples (iPhone auto-detect) are caught by the
        // productType check above.
        return .watch
    }

    private static func mapHKValueToStage(_ value: Int) -> HealthKitManager.SleepStage? {
        switch value {
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: .deep
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue: .core
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue: .rem
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: .unspecified
        case HKCategoryValueSleepAnalysis.awake.rawValue: .awake
        default: nil // .inBed and anything else
        }
    }

    /// HRV augmentation pass for row 1. When the toggle is off or there
    /// isn't enough RR, the watch stages pass through unchanged.
    private static func maybeAugment(
        _ watchStages: [HealthKitManager.SleepStageInterval],
        ctx: Context,
        envelope: [DateInterval]
    ) -> [HealthKitManager.SleepStageInterval] {
        guard ctx.enhanceWithRR, ctx.rrPoints.count >= 100 else { return watchStages }
        guard let first = envelope.first, let last = envelope.last else { return watchStages }
        guard let recordingStart = ctx.sessionBounds?.start else { return watchStages }
        let sleepStartMs = MillisecondOffset.between(first.start, and: recordingStart, fallback: 0)
        let sleepEndMs = MillisecondOffset.between(last.end, and: recordingStart, fallback: 0)
        guard sleepEndMs > sleepStartMs else { return watchStages }
        guard let result = HRVSleepStageClassifier.augment(
            watchIntervals: watchStages,
            rrPoints: ctx.rrPoints,
            sleepStartMs: sleepStartMs,
            sleepEndMs: sleepEndMs,
            recordingStart: recordingStart
        ), result.augmentationCount > 0 else {
            return watchStages
        }
        return result.stageIntervals
    }

    /// Row 2: run the full HRV classifier against the session envelope.
    /// Returns stages tagged `.hrvDerived`.
    private static func inferStagesFromRR(
        ctx: Context,
        envelope: [DateInterval]
    ) -> [HealthKitManager.SleepStageInterval] {
        guard let sessionStart = ctx.sessionBounds?.start, ctx.rrPoints.count >= 100,
              let first = envelope.first, let last = envelope.last else { return [] }
        let envelopeStartMs = MillisecondOffset.between(first.start, and: sessionStart, fallback: 0)
        let sleepEndMs = MillisecondOffset.between(last.end, and: sessionStart, fallback: 0)
        // Anchor classification at the ACTUAL sleep onset (a
        // sustained HR drop) rather than the recording/envelope start. A strap
        // user who clips the strap on at 8 PM but doesn't sleep until 9:30 would
        // otherwise get every calm-but-awake pre-bed window classified as
        // sleep → "asleep 8:00 PM" every night. `detectSleepOnset`
        // returns ms-from-recording-start (same units as the envelope offsets)
        // or nil when there's no clear drop — in which case the envelope-start
        // anchor stands rather than risk dropping the night.
        let detectedOnsetMs = SleepBoundaryResolver.detectSleepOnset(in: ctx.rrPoints)
        let sleepStartMs = max(envelopeStartMs, detectedOnsetMs ?? envelopeStartMs)
        guard sleepEndMs > sleepStartMs else { return [] }
        return HRVSleepStageClassifier.classify(
            rrPoints: ctx.rrPoints, sleepStartMs: sleepStartMs,
            sleepEndMs: sleepEndMs, recordingStart: sessionStart
        )?.stageIntervals ?? []
    }

    // MARK: - SleepData Assembly

    /// Build the final SleepData. totalSleepMinutes / awakeMinutes / efficiency
    /// are all derived from `stages` — no other source is consulted.
    private static func assemble(
        stages: [HealthKitManager.SleepStageInterval],
        envelope: [DateInterval],
        ctx: Context,
        source: HealthKitManager.SleepBoundarySource
    ) -> SleepData {
        let (total, awake) = (totalMinutes(stages), awakeMinutes(stages))
        let inBed = total + awake
        let sleepStages = stages.filter { $0.stage != .awake }
        let (deep, rem) = stageTotals(stages)
        return SleepData(
            date: ctx.fallbackDate,
            inBedStart: inBedStart(envelope: envelope, ctx: ctx, sleepStages: sleepStages),
            sleepStart: sleepStages.map(\.start).min(),
            sleepEnd: sleepStages.map(\.end).max(),
            totalSleepMinutes: total,
            inBedMinutes: inBed,
            deepSleepMinutes: deep > 0 ? deep : nil,
            remSleepMinutes: rem > 0 ? rem : nil,
            awakeMinutes: awake,
            sleepEfficiency: inBed > 0 ? Double(total) / Double(inBed) * 100 : 0,
            boundarySource: source,
            segments: buildSegments(stages: stages, splitGapMinutes: ctx.splitGapMinutes),
            stageIntervals: stages,
            splitGapMinutes: ctx.splitGapMinutes
        )
    }

    /// Priority: Apple-supplied "in bed" envelope segment → strap recording
    /// start (the user pressed Start before bed, a reliable "got into bed"
    /// signal) → sleep start (no latency computable).
    ///
    /// Falling straight through to sleepStart for
    /// users without Sleep Schedule wind-down would make `sleepLatencyMinutes`
    /// always nil even though the strap recording-start time is known.
    private static func inBedStart(
        envelope: [DateInterval],
        ctx: Context,
        sleepStages: [HealthKitManager.SleepStageInterval]
    ) -> Date? {
        envelope.first?.start ?? ctx.sessionBounds?.start ?? sleepStages.map(\.start).min()
    }

    private static func stageTotals(
        _ stages: [HealthKitManager.SleepStageInterval]
    ) -> (deep: Int, rem: Int) {
        var deep = 0
        var rem = 0
        for s in stages {
            let m = durationMinutes(s)
            switch s.stage {
            case .deep: deep += m
            case .rem: rem += m
            default: break
            }
        }
        return (deep, rem)
    }

    /// Build display-only segments. Two independent split reasons, applied
    /// in order so both are handled cleanly:
    ///   1. Physical time gap between stages — covers AutoSleep back-to-bed,
    ///      where the strap was off and no stages exist in the gap.
    ///   2. Accumulated awake within a continuous data stretch — covers a
    ///      single-session night with a long internal awakening.
    /// Does NOT affect totals.
    private static func buildSegments(
        stages: [HealthKitManager.SleepStageInterval],
        splitGapMinutes: Int
    ) -> [HealthKitManager.SleepSegment] {
        guard !stages.isEmpty else { return [] }
        let gapSeconds = Double(splitGapMinutes) * 60
        return SleepMergingPipeline.splitStageIntervals(stages, gap: gapSeconds)
            .flatMap { SleepMergingPipeline.splitStageIntervalsByAwake($0, gap: gapSeconds) }
            .compactMap(SleepMergingPipeline.buildSegmentFromIntervals)
    }
}
