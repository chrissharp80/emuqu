import Foundation

// MARK: - Sleep boundaries and off-actor analysis passes
//
// The per-step machinery behind `processOvernightData`, in an extension so the
// entry point reads as its numbered steps rather than as the arithmetic for
// each of them.

extension MorningProcessingService {
    /// Map a freshly-fetched HealthKit result into the poll result.
    ///
    /// Deliberately NOT `buildSleepPollResult`, which is the *cached* path.
    /// That one applies `clampedToRecordingStart` because a cached Watch-only
    /// result uses a bedtime−2h envelope and counts sedentary pre-bed time as
    /// asleep. A live fetch is validated against `rrPoints` on the way in and
    /// carries its own boundaries, so clamping it here would move an onset the
    /// fetch already established.
    ///
    /// The two paths genuinely differ: the clamp is a decision, not drift.
    static func pollResult(
        fromFetched sleepData: SleepData,
        effectiveStartDate: Date
    ) -> SleepPollResult {
        func offsetMs(_ date: Date) -> Int64 {
            MillisecondOffset.between(date, and: effectiveStartDate, fallback: 0)
        }
        return SleepPollResult(
            sleepStartMs: sleepData.sleepStart.map(offsetMs),
            wakeTimeMs: sleepData.sleepEnd.map(offsetMs),
            sleepBoundarySource: sleepData.boundarySource,
            sleepSegments: sleepData.segments.count > 1
                ? sleepData.segments.map {
                    HRVSession.SleepSegmentMs(
                        startMs: offsetMs($0.sleepStart),
                        endMs: offsetMs($0.sleepEnd)
                    )
                }
                : nil,
            fetchedSleepData: sleepData
        )
    }

    /// Fold an estimated sleep window into the result, tagging where it came
    /// from. Both fallback estimators — RR-derived and Watch passive-HR —
    /// write the same four fields the same way; only the source label differs.
    static func applyEstimate(
        _ estimate: SleepData,
        source: HealthKitManager.SleepBoundarySource,
        effectiveStartDate: Date,
        to result: inout SleepPollResult
    ) {
        func offsetMs(_ date: Date) -> Int64 {
            MillisecondOffset.between(date, and: effectiveStartDate, fallback: 0)
        }
        if let sleepStart = estimate.sleepStart { result.sleepStartMs = offsetMs(sleepStart) }
        if let sleepEnd = estimate.sleepEnd { result.wakeTimeMs = offsetMs(sleepEnd) }
        result.sleepBoundarySource = source
        result.fetchedSleepData = estimate
    }

    /// Artifact detection + quality verification, off the main actor.
    ///
    /// The timing log exists to attribute the user's "still ~5 min
    /// for 10 sec of work" complaint: each step logs a wall-clock delta, and the
    /// sum should bound the visible wait.
    ///
    /// Off-actor because this service is `@MainActor` and these are
    /// pure value-in/value-out CPU passes over a whole night (~20k beats) that
    /// would otherwise freeze the UI behind the processing spinner. Both detectors are
    /// stateless with immutable default config — production and the tests use
    /// `ArtifactDetector()` / `Verification()` defaults — so fresh instances
    /// inside the task are behaviour-identical.
    static func detectArtifacts(
        in series: RRSeries
    ) async -> ([ArtifactFlags], Verification.Result) {
        let started = Date()
        let result = await Task.detached(priority: .userInitiated) {
            let detectedFlags = ArtifactDetector().detectArtifacts(in: series)
            return (detectedFlags, Verification().verify(series, flags: detectedFlags))
        }.value
        debugLog("[MorningTiming] artifact + verify: \(Int(Date().timeIntervalSince(started) * 1000))ms (n=\(series.points.count))")
        return result
    }

    /// Pick the recovery window, off the main actor.
    ///
    /// The baseline goes in so window ranking matches the scorer — without it
    /// you get the "auto picks the high-RMSSD window but the user-picked one
    /// scores higher" bug.
    ///
    /// This is the single heaviest synchronous pass in the
    /// pipeline: two full sliding-window sweeps over the night. Inputs are
    /// captured on the main actor and the scan runs on a background task;
    /// `WindowSelector` is stateless with default config.
    static func selectWindow(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepResult: SleepPollResult,
        baselineStats: BaselineTracker.RecoveryBaselineStats?
    ) async -> WindowSelector.WindowSelectionResult? {
        let started = Date()
        let sleepStartMs = sleepResult.sleepStartMs
        let wakeTimeMs = sleepResult.wakeTimeMs
        let result = await Task.detached(priority: .userInitiated) {
            WindowSelector().findBestWindowWithCapacity(
                in: series, flags: flags,
                sleepStartMs: sleepStartMs,
                wakeTimeMs: wakeTimeMs,
                baselineStats: baselineStats
            )
        }.value
        debugLog("[MorningTiming] window selection: \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return result
    }
}
