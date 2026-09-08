import Foundation
import HealthKit

// The sleep-boundary half of the morning pipeline, split out of
// `MorningProcessingService.swift` to keep that file under the
// 1000-line ceiling. Everything here answers one question: when did the user
// actually fall asleep and wake up, given HealthKit, the cache, and the RR
// series itself. The members are internal rather than private because
// `private` is file-scoped and the caller lives next door.

extension MorningProcessingService {
    /// `pollForSleepData` with the wall-clock delta logged, so the morning
    /// timing trace attributes the wait correctly.
    func timedSleepPoll(
        series: RRSeries,
        effectiveStartDate: Date,
        totalBeats: Int,
        isBackgroundRefinement: Bool,
        sleepSchedule: SleepSchedule,
        prefetchedSleepData: SleepData?,
        statusCallback: StatusCallback?
    ) async -> SleepPollResult {
        let started = Date()
        let sleepResult = await pollForSleepData(
            series: series, effectiveStartDate: effectiveStartDate, totalBeats: totalBeats,
            isBackgroundRefinement: isBackgroundRefinement, sleepSchedule: sleepSchedule,
            prefetchedSleepData: prefetchedSleepData, statusCallback: statusCallback
        )
        let sleepMs = Int(Date().timeIntervalSince(started) * 1000)
        debugLog("[MorningTiming] sleep poll: \(sleepMs)ms (source=\(sleepResult.sleepBoundarySource), totalSleepMin=\(sleepResult.fetchedSleepData?.nightSleepMinutes ?? -1))")
        return sleepResult
    }
    /// The REAL recording end = start + measured RR span, NOT
    /// `now()`. `now()` can be well after the recording ended (deferred/late
    /// morning processing), which would inflate the plausibility window so a
    /// foreign-night sleep block always looks valid and the sleep-attach
    /// guard could never reject it for a short pre-sleep clip. The RR span is
    /// the truth. Falls back to `now()` for an empty series.
    func pollForSleepData(
        series: RRSeries,
        effectiveStartDate: Date,
        totalBeats: Int,
        isBackgroundRefinement: Bool,
        sleepSchedule: SleepSchedule,
        prefetchedSleepData: SleepData? = nil,
        statusCallback: StatusCallback?
    ) async -> SleepPollResult {
        let recordingEnd: Date = series.durationMs > 0
            ? effectiveStartDate.addingTimeInterval(TimeInterval(series.durationMs) / 1000.0)
            : now()
        if let ready = readySleepData(
            prefetched: prefetchedSleepData, effectiveStartDate: effectiveStartDate, recordingEnd: recordingEnd, isBackgroundRefinement: isBackgroundRefinement
        ) { return ready }
        var result = await pollHealthKitSleep(
            series: series, effectiveStartDate: effectiveStartDate, recordingEnd: recordingEnd,
            totalBeats: totalBeats, isBackgroundRefinement: isBackgroundRefinement, statusCallback: statusCallback
        )
        await applySleepEstimates(
            to: &result, series: series, effectiveStartDate: effectiveStartDate, sleepSchedule: sleepSchedule
        )
        // Safety net for every path above: a sleep onset can
        // never precede the strap recording start. Clamp any negative offset
        // so the session never stores a pre-recording sleep boundary.
        if let ms = result.sleepStartMs, ms < 0 { result.sleepStartMs = 0 }
        return result
    }
    /// If pre-fetched sleep data is available (found during parallel device
    /// fetch), use it directly — no need to poll again — but only
    /// when it plausibly belongs to this recording; a prefetched/cached block
    /// from a different night must fall through to HR estimation rather than
    /// be grafted on (see SleepData.plausiblyBelongsToRecording).
    ///
    /// Cache-first read. The HK sleep observer
    /// (HealthKitManager+Sleep.startObservingSleepData) warms SleepDataCache
    /// the moment Apple Watch syncs samples. This path must not bypass the
    /// cache the way `fetchSleepData(rrPoints:…)` intentionally does
    /// (the `rrPoints`-supplied branch of `HealthKitManager+Sleep.fetchSleepData`) to force HR-validated
    /// boundaries. That precaution starves the user every morning: 15 × 2s
    /// polls running cold HKSampleQuery + SleepMergingPipeline +
    /// HRVSleepStageClassifier even when the observer had already done
    /// equivalent work overnight.
    ///
    /// Strategy: read the cache directly here. If the observer has populated
    /// it for this night, use it. The rrPoints boundary validation that the
    /// cache bypass was protecting still runs later in the morning pipeline
    /// (window selection sees the same RR data and the recovery-score path
    /// re-derives stages anyway), and the auto-rescore listener folds in any
    /// HK refinement that lands later. Background refinement keeps the
    /// validated path because its caller is willing to wait for accuracy.
    func readySleepData(
        prefetched: SleepData?,
        effectiveStartDate: Date,
        recordingEnd: Date,
        isBackgroundRefinement: Bool
    ) -> SleepPollResult? {
        if let prefetched, prefetched.nightSleepMinutes > 0,
           prefetched.plausiblyBelongsToRecording(start: effectiveStartDate, end: recordingEnd) {
            debugLog("[MorningProcessingService] Using pre-fetched sleep data: \(prefetched.nightSleepMinutes) min")
            return buildSleepPollResult(from: prefetched, effectiveStartDate: effectiveStartDate)
        }
        guard !isBackgroundRefinement,
              let cached = SleepDataCache.read(coveringRecordingStart: effectiveStartDate),
              cached.nightSleepMinutes > 0,
              cached.plausiblyBelongsToRecording(start: effectiveStartDate, end: recordingEnd)
        else { return nil }
        debugLog("[MorningProcessingService] Using cached sleep data: \(cached.nightSleepMinutes) min — skipping poll loop")
        return buildSleepPollResult(from: cached, effectiveStartDate: effectiveStartDate)
    }
    /// 15 × 2s = 30s max poll. Lowered from 60s after a Verity-Sense user
    /// (streaming-only, no device backup) reported staring at a spinner
    /// every morning while we waited for Apple Watch sleep data that may
    /// never arrive (Watch not worn / sync delayed). The SleepDetail
    /// "Refresh Sleep Data" button + the vitals/sleep observers handle
    /// late arrivals without forcing the user to wait synchronously.
    func pollHealthKitSleep(
        series: RRSeries,
        effectiveStartDate: Date,
        recordingEnd: Date,
        totalBeats: Int,
        isBackgroundRefinement: Bool,
        statusCallback: StatusCallback?
    ) async -> SleepPollResult {
        var result = Self.emptyPollResult
        let maxAttempts = isBackgroundRefinement ? 1 : 15
        let pollInterval: UInt64 = 2_000_000_000 // 2 seconds
        for attempt in 1 ... maxAttempts {
            let outcome = await fetchSleepAttempt(
                series: series, effectiveStartDate: effectiveStartDate, recordingEnd: recordingEnd, attempt: attempt
            )
            if let sleepData = outcome.sleepData {
                result = Self.pollResult(fromFetched: sleepData, effectiveStartDate: effectiveStartDate)
                break
            }
            if outcome.abortRetries || skipSleepWait { break }
            guard attempt < maxAttempts else { Self.logPollExhausted(maxAttempts); break }
            if !isBackgroundRefinement {
                statusCallback?(.waitingForSleep(beats: totalBeats, attempt: attempt))
            }
            await sleep(pollInterval)
        }
        return result
    }
    /// One poll attempt. `abortRetries` is set when retrying cannot help.
    ///
    /// When the device is locked, HealthKit returns "Protected
    /// health data is inaccessible" (HKError Code=6). Retrying every 2 s for
    /// 30 s won't change that — the data only becomes readable after
    /// first-unlock. Worse, on overnight sessions retrying burns through the
    /// iOS background-task budget and produces SIGKILLs in the morning.
    /// Abort early; the sleep observer + `sleepDataVersion` bump
    /// triggers a rescore when the user unlocks.
    func fetchSleepAttempt(
        series: RRSeries, effectiveStartDate: Date, recordingEnd: Date, attempt: Int
    ) async -> (sleepData: SleepData?, abortRetries: Bool) {
        do {
            let fetchedSleep = try await healthKit.fetchSleepData(
                for: effectiveStartDate, recordingEnd: recordingEnd, rrPoints: series.points
            )
            // Credit the day-before's qualifying nap toward 24h sleep duration.
            let napMinutes = await healthKit.fetchDaytimeNapMinutes(nightAnchoredAt: effectiveStartDate)
            let sleepData = napMinutes > 0 ? fetchedSleep.withNapSleepMinutes(napMinutes) : fetchedSleep
            return (sleepData.nightSleepMinutes > 0 ? sleepData : nil, false)
        } catch {
            debugLog("[MorningProcessingService] Sleep fetch failed on attempt \(attempt): \(error)")
            let nsError = error as NSError
            guard nsError.domain == HKErrorDomain,
                  nsError.code == HKError.Code.errorDatabaseInaccessible.rawValue else {
                return (nil, false)
            }
            debugLog("[MorningProcessingService] Protected health data — aborting retry loop early; sleep observer will re-trigger after unlock", level: .warning)
            return (nil, true)
        }
    }
    /// If no HealthKit sleep data, try HR-based estimation from RR intervals,
    /// then Apple Watch background HR samples as a last resort. The latter is
    /// scoped to the recording window so it won't pick up daytime relaxation,
    /// and works even when Sleep Focus is off — Apple Watch records HR every
    /// ~10 min passively.
    ///
    /// IMPORTANT: the Watch-HR path only runs when we have NO sleep data at
    /// all — not when we have valid RR-based boundaries but 0 classified
    /// minutes. Watch HR estimation produces absolute dates from passive HR
    /// that can precede the recording start (e.g. user relaxing on the couch
    /// before bed), creating impossible sleep boundaries. When RR estimation
    /// produced valid boundaries (sleepStartMs is set), those are kept.
    func applySleepEstimates(
        to result: inout SleepPollResult,
        series: RRSeries,
        effectiveStartDate: Date,
        sleepSchedule: SleepSchedule
    ) async {
        if result.sleepStartMs == nil, result.sleepBoundarySource != .healthKit,
           let hrEstimate = HealthKitManager.estimateSleepFromHR(
               rrPoints: series.points, recordingStart: effectiveStartDate
           ) {
            Self.applyEstimate(
                hrEstimate, source: .hrEstimated,
                effectiveStartDate: effectiveStartDate, to: &result
            )
        }
        guard result.fetchedSleepData == nil,
              let hkHREstimate = await healthKit.estimateSleepFromHealthKitHR(
                  windowStart: effectiveStartDate,
                  windowEnd: sleepSchedule.overnightWindowEnd(relativeTo: effectiveStartDate)
              ) else { return }
        Self.applyEstimate(
            hkHREstimate, source: .healthKitHREstimated,
            effectiveStartDate: effectiveStartDate, to: &result
        )
    }
    /// Sleep can't have been measured before the strap began
    /// recording. The cached Watch-only result uses a bedtime−2h (~8 PM)
    /// envelope and counts sedentary pre-bed time as "asleep", so without
    /// this clamp the onset reads ~8 PM every night even though the user
    /// put the strap on (and slept) at ~9:30. Clamping to the recording
    /// start makes onset AND duration reflect the actual session.
    func buildSleepPollResult(
        from rawSleepData: SleepData,
        effectiveStartDate: Date
    ) -> SleepPollResult {
        let sleepData = rawSleepData.clampedToRecordingStart(effectiveStartDate)
        var result = SleepPollResult(
            sleepStartMs: sleepData.sleepStart.map { Self.offsetMs($0, from: effectiveStartDate) },
            wakeTimeMs: sleepData.sleepEnd.map { Self.offsetMs($0, from: effectiveStartDate) },
            sleepBoundarySource: sleepData.boundarySource,
            sleepSegments: nil,
            fetchedSleepData: sleepData
        )
        if sleepData.segments.count > 1 {
            result.sleepSegments = sleepData.segments.map { seg in
                HRVSession.SleepSegmentMs(
                    startMs: Self.offsetMs(seg.sleepStart, from: effectiveStartDate),
                    endMs: Self.offsetMs(seg.sleepEnd, from: effectiveStartDate)
                )
            }
        }
        return result
    }
    static func offsetMs(_ date: Date, from start: Date) -> Int64 {
        MillisecondOffset.between(date, and: start, fallback: 0)
    }
    static func logPollExhausted(_ maxAttempts: Int) {
        debugLog("[MorningProcessingService] No sleep data after \(maxAttempts) attempts (\(maxAttempts * 2)s) — proceeding without")
    }
    /// The "we found nothing" poll result: recording bounds, no HK data.
    static let emptyPollResult = SleepPollResult(
        sleepStartMs: nil, wakeTimeMs: nil, sleepBoundarySource: .recordingBounds,
        sleepSegments: nil, fetchedSleepData: nil
    )
}
