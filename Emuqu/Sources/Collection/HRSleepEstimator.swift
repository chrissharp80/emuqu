import Foundation

/// Heart-rate-based sleep estimation, lifted out of `HealthKitManager`.
///
/// This is the fallback used on nights the watch recorded no sleep: infer when
/// the user fell asleep and woke from the shape of their heart rate alone. It
/// is pure arithmetic over samples. Buried as `private static`
/// functions on a 3,500-line manager it was reachable from tests only through
/// the one public entry point, which is why its onset clamp had to be fixed
/// three times in three sibling detectors before all of them had it.
///
/// The two paths in here share the threshold, clamp and wake logic:
///
///  * `estimateSleepFromHR` works from recorded RR intervals (a strap night);
///  * the passive path works from smoothed HealthKit HR samples (the watch
///    monitoring in the background, sparser, so the onset rule is relaxed
///    from three consecutive points to two).
enum HRSleepEstimator {
    /// Estimate sleep onset and wake time from RR interval data when HealthKit sleep data is unavailable
    /// Uses HR drop patterns: sleep onset is detected when HR drops significantly and stabilizes
    /// Wake is detected when HR rises back toward awake levels
    ///
    /// The HR-estimated onset is clamped to a plausible
    /// sleep-onset latency. `detectSleepBoundariesFromHR` thresholds against
    /// the whole night's HR MINIMUM (deep-sleep bradycardia, which occurs
    /// later), so early/light sleep stays above the midpoint and is misread as
    /// "awake" until HR consolidates into deep sleep ~an hour in (a real 69-min
    /// "onset" was observed on a 337-min recording, shifting the 30-70% HRV
    /// band later and shrinking sleep 337→268 min → skewed score). But this
    /// app's recording STARTS at bedtime, so onset can't plausibly be an hour
    /// of lying awake: typical sleep-onset latency is 10-20 min (>30 min is
    /// clinically prolonged). Clamped to that ceiling — symmetric with the wake
    /// side, which already trusts the recording END.
    ///
    /// - Parameters:
    ///   - rrPoints: Array of RR data points with timestamps
    ///   - recordingStart: When the recording started
    /// - Returns: SleepData with estimated boundaries, or nil if estimation fails
    nonisolated static func estimateSleepFromHR(rrPoints: [RRPoint], recordingStart: Date) -> SleepData? {
        guard rrPoints.count >= 100 else { return nil }
        let windowedHR = computeWindowedHR(rrPoints: rrPoints)
        guard windowedHR.count >= 3 else { return nil }
        let (rawOnsetMs, wakeMs) = detectSleepBoundariesFromHR(windowedHR)
        let maxOnsetLatencyMs = Int64(SleepConstants.maxHREstimatedOnsetLatencyMin) * 60 * 1000
        let sleepOnsetMs = rawOnsetMs.map { min($0, maxOnsetLatencyMs) }
        let stageResult = HRVSleepStageClassifier.classify(
            rrPoints: rrPoints,
            sleepStartMs: sleepOnsetMs ?? 0,
            sleepEndMs: wakeMs ?? (rrPoints.last?.t_ms ?? 0),
            recordingStart: recordingStart
        )
        return hrEstimatedSleepData(
            rrPoints: rrPoints, recordingStart: recordingStart,
            sleepOnsetMs: sleepOnsetMs, wakeMs: wakeMs, stageResult: stageResult
        )
    }

    /// Assemble the SleepData for the RR-inferred path. Total sleep prefers the
    /// classifier's staged minutes when it produced any, falling back to the
    /// raw onset→wake duration.
    nonisolated static func hrEstimatedSleepData(
        rrPoints: [RRPoint],
        recordingStart: Date,
        sleepOnsetMs: Int64?,
        wakeMs: Int64?,
        stageResult: HRVSleepStageClassifier.ClassificationResult?
    ) -> SleepData {
        let sleepStart = sleepOnsetMs.map { recordingStart.addingTimeInterval(Double($0) / 1000.0) }
        let sleepEnd = wakeMs.map { recordingStart.addingTimeInterval(Double($0) / 1000.0) }
        let sleepDurationMinutes = estimateSleepDuration(rrPoints: rrPoints, sleepOnsetMs: sleepOnsetMs, wakeMs: wakeMs)
        let inBedMinutes = Int((rrPoints.last?.t_ms ?? 0) / 60000)
        let efficiency = inBedMinutes > 0 ? Double(sleepDurationMinutes) / Double(inBedMinutes) * 100 : 0
        let classifiedMinutes = stageResult.map { $0.deepSleepMinutes + $0.remSleepMinutes + $0.coreSleepMinutes } ?? sleepDurationMinutes
        return SleepData(
            date: recordingStart, inBedStart: recordingStart,
            sleepStart: sleepStart, sleepEnd: sleepEnd,
            totalSleepMinutes: classifiedMinutes, inBedMinutes: inBedMinutes,
            deepSleepMinutes: stageResult?.deepSleepMinutes,
            remSleepMinutes: stageResult?.remSleepMinutes,
            awakeMinutes: stageResult?.awakeMinutes ?? 0,
            sleepEfficiency: efficiency, boundarySource: .hrEstimated,
            segments: [], stageIntervals: stageResult?.stageIntervals ?? [],
            boundaryValidation: nil, hrSleepQuality: nil,
            splitGapMinutes: SleepConstants.defaultSplitGapMinutes
        )
    }

    /// Compute 5-minute windowed heart rate from RR intervals.
    ///
    /// A window needs at least 10 beats to report a value; sparser windows are
    /// dropped rather than averaged from noise.
    nonisolated static func computeWindowedHR(rrPoints: [RRPoint]) -> [(timeMs: Int64, hr: Double)] {
        let windowSizeMs: Int64 = 5 * 60 * 1000
        var result: [(timeMs: Int64, hr: Double)] = []
        var windowStart: Int64 = 0
        while windowStart < (rrPoints.last?.t_ms ?? 0) {
            if let hr = windowedHR(rrPoints, from: windowStart, to: windowStart + windowSizeMs) {
                result.append((timeMs: windowStart + windowSizeMs / 2, hr: hr))
            }
            windowStart += windowSizeMs
        }
        return result
    }

    nonisolated static func windowedHR(_ rrPoints: [RRPoint], from windowStart: Int64, to windowEnd: Int64) -> Double? {
        let windowPoints = rrPoints.filter { $0.t_ms >= windowStart && $0.t_ms < windowEnd }
        guard windowPoints.count >= 10 else { return nil }
        let avgRR = windowPoints.map { Double($0.rr_ms) }.reduce(0, +) / Double(windowPoints.count)
        return 60000.0 / avgRR
    }

    /// Detect sleep onset and wake times from windowed HR using threshold crossings.
    ///
    /// Sleep onset is the first of 3 consecutive windows below threshold.
    ///
    /// Wake is the end of the LAST continuous sleep block. Taking
    /// the first backward below→above crossing instead meant a
    /// single mid-night HR bump (bathroom trip, REM tachycardia, or a
    /// BLE-reconnect gap artifact) was read as "final wake" and the rest of the
    /// night was discarded — surfacing wake at e.g. 1:30 AM. Instead, find the
    /// last window you were still asleep (below threshold) and set wake to the
    /// window right after it. Brief above-threshold blips that are followed by
    /// more sleep do not truncate the night. (Onset already requires 3
    /// sustained windows; this makes the wake side comparably robust.)
    nonisolated static func detectSleepBoundariesFromHR(
        _ windowedHR: [(timeMs: Int64, hr: Double)]
    ) -> (sleepOnsetMs: Int64?, wakeMs: Int64?) {
        guard let maxHR = windowedHR.map(\.hr).max() else { return (nil, nil) }
        let minHR = windowedHR.map(\.hr).min() ?? maxHR
        let hrDropThreshold = maxHR - (maxHR - minHR) * 0.5
        var sleepOnsetMs: Int64?
        // Onset needs 3 consecutive windows, so fewer than 3 can never produce
        // one — and `count - 2` would be a negative, trapping range.
        // empty-range-ok: guarded on windowedHR.count >= 3 immediately above.
        for i in 0 ..< max(0, windowedHR.count - 2)
            where windowedHR[i].hr < hrDropThreshold
            && windowedHR[i + 1].hr < hrDropThreshold
            && windowedHR[i + 2].hr < hrDropThreshold {
            sleepOnsetMs = windowedHR[i].timeMs
            break
        }
        var wakeMs: Int64?
        if let lastAsleepIndex = windowedHR.lastIndex(where: { $0.hr < hrDropThreshold }) {
            let wakeIndex = min(lastAsleepIndex + 1, windowedHR.count - 1)
            wakeMs = windowedHR[wakeIndex].timeMs
        }
        return (sleepOnsetMs, wakeMs)
    }

    /// Estimate sleep duration in minutes from onset and wake timestamps.
    nonisolated static func estimateSleepDuration(rrPoints: [RRPoint], sleepOnsetMs: Int64?, wakeMs: Int64?) -> Int {
        if let onset = sleepOnsetMs, let wake = wakeMs, wake > onset {
            return Int((wake - onset) / 60000)
        } else if let lastPoint = rrPoints.last, let onset = sleepOnsetMs {
            return Int((lastPoint.t_ms - onset) / 60000)
        }
        return Int((rrPoints.last?.t_ms ?? 0) / 60000)
    }

    /// Midpoint between the night's max (awake baseline, same logic as the
    /// RR-based estimation) and min HR. Needs at least 8 BPM of range for the
    /// split to mean anything.
    nonisolated static func hrSleepThreshold(_ smoothed: [(date: Date, hr: Double)]) -> Double? {
        guard let maxHR = smoothed.map(\.hr).max() else { return nil }
        let minHR = smoothed.map(\.hr).min() ?? maxHR
        guard maxHR - minHR >= 8 else {
            debugLog("[HealthKitManager] HealthKit HR sleep estimation: HR range too narrow (\(String(format: "%.0f", minHR))-\(String(format: "%.0f", maxHR)) BPM)")
            return nil
        }
        return maxHR - (maxHR - minHR) * 0.5
    }

    /// Sleep onset: 2 consecutive smoothed points below threshold (relaxed from
    /// 3 because samples are sparser than RR data).
    ///
    /// Clamped to a plausible sleep-onset latency, IDENTICAL to
    /// the sibling detectors `estimateSleepFromHR` (RR path) and
    /// `SleepBoundaryResolver.detectSleepOnset`.
    /// This passive-Watch-HR detector also thresholds against
    /// deep-sleep bradycardia, which consolidates LATER than true onset, so on
    /// some nights it reports a bogus long "onset" and shrinks the night (the
    /// same 66/69-min artifact the other two were clamped for). `windowStart`
    /// is the recording start (bedtime) for BOTH callers —
    /// MorningProcessingService passes `effectiveStartDate`, and
    /// MorningResultsViewModel passes `window.start`, the same anchor its
    /// `estimateSleepFromHR` call on the line above uses — so onset can't
    /// plausibly exceed the typical 10–20 min SOL (>30 clinically prolonged;
    /// Ohayon et al., Sleep 2004;27(7):1255). This was the THIRD and last
    /// HR-onset estimator still missing the clamp (the recurrence the 2026-08
    /// fixes kept re-introducing by fixing one copy at a time).
    nonisolated static func clampedSleepOnset(
        _ smoothed: [(date: Date, hr: Double)],
        threshold: Double,
        windowStart: Date
    ) -> Date? {
        var sleepOnsetDate: Date?
        // Onset needs 2 consecutive points; `count - 1` on an empty array is a
        // negative, trapping range.
        // empty-range-ok: max(0,) makes the range empty rather than invalid.
        for i in 0 ..< max(0, smoothed.count - 1) where smoothed[i].hr < threshold && smoothed[i + 1].hr < threshold {
            sleepOnsetDate = smoothed[i].date
            break
        }
        guard let sleepOnsetDetected = sleepOnsetDate else {
            debugLog("[HealthKitManager] HealthKit HR sleep estimation: no sleep onset detected")
            return nil
        }
        let maxOnsetLatency = TimeInterval(SleepConstants.maxHREstimatedOnsetLatencyMin * 60)
        return min(sleepOnsetDetected, windowStart.addingTimeInterval(maxOnsetLatency))
    }

    /// Wake: end of the last continuous sleep block. Same reasoning
    /// as `detectSleepBoundariesFromHR`: taking the first backward below→above
    /// crossing lets a mid-night HR bump truncate the night. Anchors to the last
    /// smoothed point still below threshold (asleep) and takes the point right
    /// after it.
    ///
    /// `smoothed` is non-empty (the caller guards), so the
    /// final fallback binds rather than force-unwrapping.
    nonisolated static func sleepWake(_ smoothed: [(date: Date, hr: Double)], threshold: Double) -> Date? {
        var wakeDate: Date?
        if let lastAsleepIndex = smoothed.lastIndex(where: { $0.hr < threshold }) {
            let wakeIndex = min(lastAsleepIndex + 1, smoothed.count - 1)
            wakeDate = smoothed[wakeIndex].date
        }
        return wakeDate ?? smoothed.last?.date
    }

    /// In-bed is approximated as the same span: first below-threshold sample to
    /// wake. Stages can't be classified from sparse HR, so they stay nil.
    nonisolated static func estimatedSleepData(sleepStart: Date, sleepEnd: Date, sleepMinutes: Int) -> SleepData {
        let inBedMinutes = Int(sleepEnd.timeIntervalSince(sleepStart) / 60)
        let efficiency = inBedMinutes > 0 ? Double(sleepMinutes) / Double(inBedMinutes) * 100 : 0
        return SleepData(
            date: sleepStart,
            inBedStart: sleepStart,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            totalSleepMinutes: sleepMinutes,
            inBedMinutes: inBedMinutes,
            deepSleepMinutes: nil,
            remSleepMinutes: nil,
            awakeMinutes: 0,
            sleepEfficiency: efficiency,
            boundarySource: .healthKitHREstimated,
            segments: [],
            stageIntervals: [],
            boundaryValidation: nil,
            hrSleepQuality: nil,
            splitGapMinutes: SleepConstants.defaultSplitGapMinutes
        )
    }

    /// Smooth sparse HR samples with a rolling average window.
    /// Groups samples within windowMinutes intervals and averages them.
    /// Only one smoothed point is emitted per window, to avoid redundancy.
    nonisolated static func smoothHRSamples(_ samples: [(date: Date, hr: Double)], windowMinutes: Int) -> [(date: Date, hr: Double)] {
        guard !samples.isEmpty else { return [] }
        let windowSeconds = TimeInterval(windowMinutes * 60)
        var smoothed: [(date: Date, hr: Double)] = []
        for sample in samples {
            let avgHR = meanHRAround(sample.date, in: samples, halfWindow: windowSeconds / 2)
            guard let last = smoothed.last else {
                smoothed.append((date: sample.date, hr: avgHR))
                continue
            }
            if sample.date.timeIntervalSince(last.date) >= windowSeconds * 0.5 {
                smoothed.append((date: sample.date, hr: avgHR))
            }
        }
        return smoothed
    }

    /// Mean HR of every sample within ±halfWindow of `date`.
    nonisolated static func meanHRAround(_ date: Date, in samples: [(date: Date, hr: Double)], halfWindow: TimeInterval) -> Double {
        let windowSamples = samples.filter { abs($0.date.timeIntervalSince(date)) <= halfWindow }
        // In practice `date` comes from `samples`, so the window always holds
        // at least that sample — but 0/0 is NaN, and a NaN heart rate poisons
        // every threshold comparison downstream into silently answering false.
        guard !windowSamples.isEmpty else { return 0 }
        return windowSamples.map(\.hr).reduce(0, +) / Double(windowSamples.count)
    }
}
