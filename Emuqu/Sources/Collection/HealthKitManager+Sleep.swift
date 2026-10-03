import Foundation
import HealthKit

// MARK: - Sleep queries and estimation
//
// Kept off `HealthKitManager`, the same seam as the vitals and training
// queries. Export, trend analysis and the sleep observers stay
// on `+SleepTrends.swift` — those write and observe, this one reads.

extension SleepHealthQueries {
    // MARK: - Sleep Data

    /// Predicate that excludes samples written by this app itself. Required
    /// on every sleep READ because we ALSO WRITE sleep back to HealthKit
    /// (via `exportSleepToHealthKit`). Without this, the app reads its own
    /// previously-derived sleep windows back in as "ground truth" — a
    /// circular contamination that shifts boundaries further on each cycle
    /// (e.g. the Watch said 10:18 PM sleep start, we wrote back 8:00 PM,
    /// next morning we read 8:00 PM as "truth" and drift further).
    ///
    /// NSCompoundPredicate(AND) this with the date-range predicate before
    /// running any HKSampleQuery for sleepAnalysis reads.
    func sleepReadExcludingOwnWrites(dateRange: NSPredicate) -> NSPredicate {
        let ownSourcePredicate = HKQuery.predicateForObjects(from: Set([HKSource.default()]))
        let notFromUs = NSCompoundPredicate(notPredicateWithSubpredicate: ownSourcePredicate)
        return NSCompoundPredicate(andPredicateWithSubpredicates: [dateRange, notFromUs])
    }

    /// Fetch sleep data for last night (or most recent sleep session)
    /// - Parameter referenceDate: Anchor date for "last night" lookup. Defaults to now (today's morning).
    ///   For historical sessions, pass the session's end date so the correct night is queried.
    func fetchLastNightSleep(relativeTo referenceDate: Date = Date()) async throws -> SleepData {
        guard manager.isHealthKitAvailable else { throw HealthKitManager.HealthKitError.notAvailable }
        guard let sleepType = HKTypes.category(.sleepAnalysis) else {
            throw HealthKitManager.HealthKitError.typeUnavailable("sleepAnalysis")
        }
        let morning = Calendar.current.startOfDay(for: referenceDate)
        let window = DateInterval(
            start: manager.sleepSchedule.overnightWindowStart(relativeTo: morning),
            end: manager.sleepSchedule.overnightWindowEnd(relativeTo: morning)
        )
        let allSamples = try await lastNightSamples(
            sleepType: sleepType, windowStart: window.start, windowEnd: min(window.end, Date())
        )
        let context = Self.lastNightContext(samples: allSamples, window: window)
        return await Self.resolvedOffMain(context)
    }

    /// Classification runs over every sample and, with RR, the whole night of
    /// beats — detached, because this type is main-actor isolated.
    nonisolated private static func processOffMain(
        _ samples: [HKCategorySample], recordingStart: Date, recordingEnd: Date, config: SleepMergingConfig,
        rrPoints: [RRPoint]?, autoSleepExtension: SleepResolver.AutoSleepExtension?
    ) async -> SleepData {
        await Task.detached(priority: .userInitiated) {
            SleepMergingPipeline.processForRecording(
                samples: samples, recordingStart: recordingStart, recordingEnd: recordingEnd,
                config: config, rrPoints: rrPoints, autoSleepExtension: autoSleepExtension
            )
        }.value
    }

    /// Resolving a night walks every sample, and with RR a whole night of
    /// beats; this type is main-actor isolated, so the work is detached.
    nonisolated static func resolvedOffMain(_ context: SleepResolver.Context) async -> SleepData {
        await Task.detached(priority: .userInitiated) { SleepResolver.resolve(context).sleepData }.value
    }

    nonisolated private static func lastNightContext(samples: [HKCategorySample], window: DateInterval) -> SleepResolver.Context {
        SleepResolver.Context(
            sessionBounds: nil,
            linkedSessionBounds: [],
            watchSamples: samples,
            rrPoints: [],
            bedtimeWindow: window,
            enhanceWithRR: false,
            autoSleepExtension: nil,
            fallbackDate: samples.first?.endDate ?? Date(),
            splitGapMinutes: SleepMergingConfig.defaultProcessing().awakeGapSplitMinutes
        )
    }

    /// Drops `.strictStartDate` for this window-anchored read.
    /// `.strictStartDate` excludes any sleep stage that STARTED
    /// before the overnight window opened (e.g. an asleep segment that began
    /// just before `windowStart`), truncating the first stage of the night. The
    /// default (overlap) predicate includes samples that merely intersect the
    /// window, and the resolver clips stages to the bedtime bounds anyway, so
    /// the early stage is counted without bleeding outside the window.
    private func lastNightSamples(sleepType: HKCategoryType, windowStart: Date, windowEnd: Date) async throws -> [HKCategorySample] {
        let datePredicate = HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd, options: [])
        return try await executeSleepQuery(
            sleepType: sleepType,
            predicate: sleepReadExcludingOwnWrites(dateRange: datePredicate),
            sort: NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        )
    }

    /// Fetch sleep data for a specific recording session
    /// Uses Apple's sleep data as the authoritative source - no truncation
    /// The recording times are used only to identify which sleep session is relevant
    /// When rrPoints are provided, HR analysis validates HealthKit boundaries and computes RMSSD quality metrics
    func fetchSleepData(
        for recordingStart: Date,
        recordingEnd: Date,
        rrPoints: [RRPoint]? = nil,
        autoSleepExtension: SleepResolver.AutoSleepExtension? = nil
    ) async throws -> SleepData {
        guard manager.isHealthKitAvailable else { throw HealthKitManager.HealthKitError.notAvailable }
        if let cached = cachedSleepData(recordingStart: recordingStart, recordingEnd: recordingEnd, rrPoints: rrPoints, autoSleepExtension: autoSleepExtension) {
            return cached
        }
        // When an AutoSleep extension is present, pull samples through the
        // extension's end so post-session stages are available to the resolver.
        let queryEnd = autoSleepExtension.map { max(recordingEnd, $0.bounds.end) } ?? recordingEnd
        let samples = try await querySleepSamples(recordingStart: recordingStart, recordingEnd: queryEnd)
        let config = SleepMergingConfig.fromSettings(recordingStart: recordingStart)
        let resolved = await Self.processOffMain(
            samples, recordingStart: recordingStart, recordingEnd: recordingEnd,
            config: config, rrPoints: rrPoints, autoSleepExtension: autoSleepExtension
        )
        guard plausibleForRecording(resolved, recordingStart: recordingStart, recordingEnd: recordingEnd, autoSleepExtension: autoSleepExtension) else {
            return .empty
        }
        warmSleepCache(resolved, rrPoints: rrPoints, autoSleepExtension: autoSleepExtension)
        return resolved
    }

    /// Opportunistically warm the cache so the next read is fast even when the
    /// observer hasn't fired yet (cold start, fresh install).
    private func warmSleepCache(_ resolved: SleepData, rrPoints: [RRPoint]?, autoSleepExtension: SleepResolver.AutoSleepExtension?) {
        guard resolved.nightSleepMinutes > 0, rrPoints == nil, autoSleepExtension == nil else { return }
        SleepDataCache.write(resolved)
    }

    // MARK: - Sleep Data Pipeline Helpers

    /// Query HealthKit for sleep analysis samples within the overnight window.
    ///
    /// Reads ONLY real, non-own sleep sources (Apple Watch / iPhone), excluding
    /// the app's own HR-estimated mirror — exactly like AutoSleep's "Apple Sleep
    /// Stages" mode reads Apple's samples as-is.
    ///
    /// Deliberately NO "all-sources fallback." Such a fallback fires
    /// whenever the real Watch samples haven't finished syncing
    /// at wake (the COMMON case — the Watch syncs a few minutes late), and
    /// returns the app's OWN prior HR-estimate as the night's sleep. That is
    /// the "morning sleep is wrong" regression: the user then opens Apple
    /// Health (forcing the Watch to sync) and manually refreshes — and that
    /// refresh re-picks the HRV window and drops the score. Returning only real
    /// sources is the long-stable behavior. A strap-recorded night
    /// with no Watch sleep is still covered by the resolver's RR-inference
    /// path, so this never leaves a recorded night sleepless.
    private func querySleepSamples(recordingStart: Date, recordingEnd: Date) async throws -> [HKCategorySample] {
        guard let sleepType = HKTypes.category(.sleepAnalysis) else {
            throw HealthKitManager.HealthKitError.typeUnavailable("sleepAnalysis")
        }
        let searchStart = manager.sleepSchedule.overnightWindowStart(relativeTo: recordingStart)
        let scheduleEnd = manager.sleepSchedule.overnightWindowEnd(relativeTo: recordingStart)
        let mergeBasedEnd = recordingEnd.addingTimeInterval(manager.settingsProvider().effectiveMergeGapSeconds)
        let searchEnd = max(scheduleEnd, mergeBasedEnd)
        let datePredicate = HKQuery.predicateForSamples(withStart: searchStart, end: searchEnd, options: [])
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let sleepSamples = try await executeSleepQuery(
            sleepType: sleepType,
            predicate: sleepReadExcludingOwnWrites(dateRange: datePredicate),
            sort: sortDescriptor
        )
        logSleepDiag("excl-own", sleepSamples, window: (searchStart, searchEnd))
        return sleepSamples
    }

    /// Run one sleep-sample query and return its category samples (empty on none).
    private func executeSleepQuery(
        sleepType: HKCategoryType,
        predicate: NSPredicate,
        sort: NSSortDescriptor
    ) async throws -> [HKCategorySample] {
        try await manager.runBoundedThrowingQuery(
            timeout: HealthKitManager.sleepQueryTimeoutSec,
            makeQuery: { resolve in
                HKSampleQuery(
                    sampleType: sleepType,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: [sort]
                ) { _, results, error in
                    resolve(HealthKitManager.categoryResult(results, error))
                }
            },
            onTimeout: { .success([]) }
        )
    }

    /// Total qualifying daytime-nap sleep (minutes) for the waking day that led
    /// into the night anchored at `nightAnchor` (the overnight recording start /
    /// bedtime). Reads HealthKit `sleepAnalysis` over the daytime nap window
    /// (`SleepSchedule.daytimeNapWindow`), excludes the app's own HR-estimated
    /// writes, groups samples into nap episodes, unions each episode's intervals
    /// (so overlapping stage samples aren't double-counted), and sums only
    /// episodes at least `napMinimumMinutesToCount` long.
    ///
    /// Best-effort: returns 0 when HealthKit is unavailable, the query fails, or
    /// there is no qualifying nap. Deliberately separate from the overnight query
    /// — nap minutes feed the recovery score's DURATION component only, never the
    /// night's architecture (efficiency / fragmentation / cycles / stage %).
    func fetchDaytimeNapMinutes(nightAnchoredAt nightAnchor: Date) async -> Int {
        guard manager.isHealthKitAvailable, let sleepType = HKTypes.category(.sleepAnalysis) else { return 0 }
        let window = manager.sleepSchedule.daytimeNapWindow(relativeTo: nightAnchor)
        guard window.end > window.start else { return 0 }
        guard let samples = await napSamples(sleepType: sleepType, window: window) else { return 0 }
        let intervals = Self.asleepIntervals(samples, clippedTo: window)
        guard !intervals.isEmpty else { return 0 }
        return Self.qualifyingNapMinutes(
            asleepIntervals: intervals,
            episodeGapSeconds: TimeInterval(SleepConstants.napEpisodeGapMinutes * 60),
            floorSeconds: TimeInterval(SleepConstants.napMinimumMinutesToCount * 60)
        )
    }

    private func napSamples(sleepType: HKCategoryType, window: (start: Date, end: Date)) async -> [HKCategorySample]? {
        let datePredicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return try? await executeSleepQuery(
            sleepType: sleepType,
            predicate: sleepReadExcludingOwnWrites(dateRange: datePredicate),
            sort: sort
        )
    }

    /// Estimate sleep boundaries from recorded RR intervals when the watch
    /// logged no sleep for the night. The estimator itself lives in
    /// `HRSleepEstimator`; this stays for the three call sites that reach it
    /// through the manager.
    nonisolated static func estimateSleepFromHR(rrPoints: [RRPoint], recordingStart: Date) -> SleepData? {
        HRSleepEstimator.estimateSleepFromHR(rrPoints: rrPoints, recordingStart: recordingStart)
    }

    /// Asleep intervals only (drops inBed / awake), clipped to the nap window.
    nonisolated private static func asleepIntervals(_ samples: [HKCategorySample], clippedTo window: (start: Date, end: Date)) -> [(start: Date, end: Date)] {
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue
        ]
        return samples
            .filter { asleepValues.contains($0.value) }
            .compactMap { sample in
                let s = max(sample.startDate, window.start)
                let e = min(sample.endDate, window.end)
                return e > s ? (start: s, end: e) : nil
            }
            .sorted { $0.start < $1.start }
    }

    /// Pure episode-aware nap aggregation, factored out of `fetchDaytimeNapMinutes`
    /// for testability. Groups asleep intervals into episodes separated by gaps
    /// longer than `episodeGapSeconds`, unions each episode's intervals so
    /// overlapping stage samples count once, and returns the total minutes across
    /// only those episodes that individually reach `floorSeconds`.
    nonisolated static func qualifyingNapMinutes(
        asleepIntervals: [(start: Date, end: Date)],
        episodeGapSeconds: TimeInterval,
        floorSeconds: TimeInterval
    ) -> Int {
        let intervals = asleepIntervals
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard !intervals.isEmpty else { return 0 }
        var totalSeconds: TimeInterval = 0
        var episode: [(start: Date, end: Date)] = []
        var lastEnd: Date?
        for iv in intervals {
            if let prevEnd = lastEnd, iv.start.timeIntervalSince(prevEnd) > episodeGapSeconds {
                totalSeconds += episodeSeconds(episode, floorSeconds: floorSeconds)
                episode.removeAll()
            }
            episode.append(iv)
            lastEnd = max(lastEnd ?? iv.end, iv.end)
        }
        totalSeconds += episodeSeconds(episode, floorSeconds: floorSeconds)
        return Int(totalSeconds / 60)
    }

    /// One episode's contribution: union its (already start-sorted) intervals so
    /// overlaps count once, then keep the total only if it reaches the floor.
    nonisolated private static func episodeSeconds(_ episode: [(start: Date, end: Date)], floorSeconds: TimeInterval) -> TimeInterval {
        guard !episode.isEmpty else { return 0 }
        var merged: [(start: Date, end: Date)] = []
        for iv in episode {
            if var last = merged.last, iv.start <= last.end {
                last.end = max(last.end, iv.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(iv)
            }
        }
        let dur = merged.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        return dur >= floorSeconds ? dur : 0
    }

    /// SLEEP-DIAG — a DENIED HealthKit read returns 0
    /// samples with NO error, indistinguishable in code from "no data exists".
    /// Log what came back per query so we can tell a permission/predicate miss
    /// (returned=0) from a mapping rejection (returned>0 but all filtered) or a
    /// source-exclusion miss (excl-own=0 but all-sources>0). Grep [SLEEP-DIAG].
    private func logSleepDiag(_ tag: String, _ samples: [HKCategorySample], window: (Date, Date)) {
        let names = Set(samples.map { $0.sourceRevision.source.name }).sorted().joined(separator: ", ")
        let valueHistogram = Dictionary(grouping: samples, by: { $0.value }).mapValues(\.count)
        debugLog("[SLEEP-DIAG] querySleepSamples(\(tag)) window=\(window.0)…\(window.1) returned=\(samples.count) sources=[\(names)] values=\(valueHistogram)", level: .warning)
    }

    /// Check whether HealthKit contains additional sleep samples after a given date,
    /// up to a cutoff. Returns the `(start, end)` of the earliest and latest sleep
    /// samples found, or `nil` if no additional sleep exists. Callers gate on
    /// both values: the gap from the anchor to `start` bounds whether the
    /// samples are a continuation or a separate nap, and `end` sets the
    /// re-fetch window for the merged snapshot.
    ///
    /// Drops `.strictStartDate`. A continuation stage
    /// that started before `anchor` but extends past it is exactly what this
    /// "is there more sleep after X?" probe needs to see; the strict option
    /// would hide it and under-report the additional range.
    func findAdditionalSleepRange(after anchor: Date, before cutoff: Date) async -> (start: Date, end: Date)? {
        guard manager.isHealthKitAvailable, cutoff > anchor else { return nil }
        guard let sleepType = HKTypes.category(.sleepAnalysis) else { return nil }
        let datePredicate = HKQuery.predicateForSamples(withStart: anchor, end: cutoff, options: [])
        let predicate = sleepReadExcludingOwnWrites(dateRange: datePredicate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await manager.runBoundedQuery(timeout: HealthKitManager.sleepQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, results, _ in
                resolve(Self.sleepSampleBounds(results))
            }
        }
    }

    /// Earliest start and latest end across actual sleep (not inBed) samples.
    nonisolated private static func sleepSampleBounds(_ results: [HKSample]?) -> (start: Date, end: Date)? {
        guard let samples = results as? [HKCategorySample] else { return nil }
        let sleepSamples = samples.filter { HKCategoryValueSleepAnalysis(rawValue: $0.value) != .inBed }
        guard let earliestStart = sleepSamples.map(\.startDate).min(),
              let latestEnd = sleepSamples.map(\.endDate).max()
        else { return nil }
        return (earliestStart, latestEnd)
    }

    // MARK: - HR-Based Sleep Estimation

    // MARK: - HealthKit Background HR Sleep Estimation

    /// Estimate sleep from Apple Watch background heart rate samples in HealthKit.
    ///
    /// Apple Watch records HR every ~10 minutes even without Sleep Mode enabled.
    /// This method queries those passive HR samples and detects sleep using the same
    /// HR-drop algorithm as `estimateSleepFromHR`, adapted for sparser data.
    ///
    /// Use case: user wears Apple Watch overnight but doesn't enable Sleep Focus,
    /// so Apple's native sleep tracking writes no sleep samples to HealthKit.
    ///
    /// - Parameters:
    ///   - windowStart: Start of overnight search window
    ///   - windowEnd: End of overnight search window
    /// - Returns: SleepData with estimated boundaries, or nil if insufficient HR data
    func estimateSleepFromHealthKitHR(
        windowStart: Date,
        windowEnd: Date,
        minimumSamples: Int = 12,
        minimumSleepMinutes: Int = 120
    ) async -> SleepData? {
        guard manager.isHealthKitAvailable else { return nil }
        guard let smoothed = await smoothedOvernightHR(
            windowStart: windowStart, windowEnd: windowEnd,
            minimumSamples: minimumSamples, minimumSleepMinutes: minimumSleepMinutes
        ) else { return nil }
        guard let threshold = HRSleepEstimator.hrSleepThreshold(smoothed) else { return nil }
        guard let sleepStart = HRSleepEstimator.clampedSleepOnset(smoothed, threshold: threshold, windowStart: windowStart),
              let sleepEnd = HRSleepEstimator.sleepWake(smoothed, threshold: threshold)
        else { return nil }
        // Default: 120 min for full-night detection.
        // Extended-sleep callers pass lower thresholds (e.g. 15 min).
        let sleepMinutes = Int(sleepEnd.timeIntervalSince(sleepStart) / 60)
        guard sleepMinutes >= minimumSleepMinutes else {
            debugLog("[HealthKitManager] HealthKit HR sleep estimation: only \(sleepMinutes) min detected, need \(minimumSleepMinutes)+")
            return nil
        }
        return HRSleepEstimator.estimatedSleepData(sleepStart: sleepStart, sleepEnd: sleepEnd, sleepMinutes: sleepMinutes)
    }

    /// Fetch the passive Watch HR samples for the window and smooth them with a
    /// 20-minute rolling average to handle sparse, noisy data.
    ///
    /// Default: 12 samples (~2 hours at 10-min intervals) for full-night
    /// detection. Extended-sleep callers pass lower thresholds (e.g. 4 samples
    /// for ~40 min), and correspondingly need fewer smoothed points.
    private func smoothedOvernightHR(
        windowStart: Date,
        windowEnd: Date,
        minimumSamples: Int,
        minimumSleepMinutes: Int
    ) async -> [(date: Date, hr: Double)]? {
        let samples: [(date: Date, hr: Double)]
        do {
            samples = try await manager.fetchHeartRateSamples(from: windowStart, to: windowEnd)
        } catch {
            debugLog("[HealthKitManager] HealthKit HR sleep estimation failed to fetch samples: \(error)")
            return nil
        }
        guard samples.count >= minimumSamples else {
            debugLog("[HealthKitManager] HealthKit HR sleep estimation: only \(samples.count) samples, need \(minimumSamples)+")
            return nil
        }
        let smoothed = HRSleepEstimator.smoothHRSamples(samples, windowMinutes: 20)
        let minSmoothed = minimumSleepMinutes < 120 ? 3 : 6
        guard smoothed.count >= minSmoothed else { return nil }
        return smoothed
    }

}

// MARK: - File-scope helpers
//
// Kept out of HealthKitManager. Each names no member of the
// type and calls nothing inside it, so none needs to be a member.
// `private` at file scope is fileprivate, so every call site in this
// file resolves the same way.

/// Cache-first read: the sleep observer keeps SleepDataCache warm as Apple
/// Watch syncs samples through the night. By morning, the value the wake-up
/// flow needs is already sitting in UserDefaults.
///
/// Bypassed when rrPoints are supplied — those callers want HR validation
/// against the freshest HK samples — and when an AutoSleep extension is
/// requested (post-recording stage extension outside the cached window).
private func cachedSleepData(
    recordingStart: Date,
    recordingEnd: Date,
    rrPoints: [RRPoint]?,
    autoSleepExtension: SleepResolver.AutoSleepExtension?
) -> HealthKitManager.SleepData? {
    guard rrPoints == nil, autoSleepExtension == nil,
          let cached = SleepDataCache.read(coveringRecordingStart: recordingStart),
          cached.nightSleepMinutes > 0,
          cached.plausiblyBelongsToRecording(start: recordingStart, end: recordingEnd)
    else { return nil }
    return cached
}

/// CHOKE POINT for the "HealthKit grafts a foreign night's
/// sleep onto a short recording" bug. HealthKit returns whole sleep blocks
/// within a broad look-back window; for a short pre-sleep clip it can hand
/// back the *following* night's full block. Reject any resolved block that
/// doesn't plausibly belong to THIS recording so no caller — morning
/// processing, acceptance, reanalysis, backfill — can attach it, fabricate
/// hours of sleep, mis-date the session, or trip the archive integrity hash.
/// Skipped when an AutoSleep extension is requested (the user deliberately
/// opted into sleep beyond the recording window).
private func plausibleForRecording(
    _ resolved: HealthKitManager.SleepData,
    recordingStart: Date,
    recordingEnd: Date,
    autoSleepExtension: SleepResolver.AutoSleepExtension?
) -> Bool {
    guard resolved.nightSleepMinutes > 0, autoSleepExtension == nil,
          !resolved.plausiblyBelongsToRecording(start: recordingStart, end: recordingEnd)
    else { return true }
    debugLog("[Sleep] Resolved \(resolved.nightSleepMinutes)m sleep does not overlap recording (\(Int(recordingEnd.timeIntervalSince(recordingStart) / 60))m) — returning empty (implausible attach blocked)", level: .warning)
    return false
}
