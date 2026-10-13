import Foundation

/// Shared two-pointer window sweep over a time-monotonic RR
/// series. Several analyzers slice the RR series into
/// 5-minute (or rolling) windows by doing
/// `rrPoints.filter { $0.t_ms >= start && $0.t_ms < end }` INSIDE a
/// per-window loop — O(windows × n). `RRPoint.t_ms` is cumulative (strictly
/// monotonic non-decreasing), and the window bounds advance monotonically,
/// so two cursors that only ever move forward yield the exact same window
/// membership in O(n) total across all windows.
///
/// Contract: every `range(start:end:)` call MUST pass `start`/`end` that are
/// each >= the previous call's (windows scanned left-to-right). The cursors
/// never rewind, so an out-of-order call would return a wrong range — this
/// matches how the call sites already iterate (windowStart increases each
/// step). The returned half-open `Range<Int>` indexes the original array and
/// is identical to the membership the per-window `filter` produced.
struct RRWindowSweep {
    private let points: [RRPoint]
    private var lo = 0
    private var hi = 0

    init(_ points: [RRPoint]) {
        self.points = points
    }

    /// Indices of points with `t_ms` in `[start, end)`. Assumes `start`/`end`
    /// are monotonically non-decreasing across successive calls.
    mutating func range(start: Int64, end: Int64) -> Range<Int> {
        // Advance `lo` to the first point at or after `start`.
        while lo < points.count, points[lo].t_ms < start { lo += 1 }
        // `hi` must be at least `lo`, then advance to first point >= end.
        if hi < lo { hi = lo }
        while hi < points.count, points[hi].t_ms < end { hi += 1 }
        return lo ..< hi
    }
}

/// Resolves sleep boundaries from HealthKit, with optional HR validation.
/// When a caller passes RR data, HR analysis validates and can extend the
/// HealthKit boundaries.
///
/// Resolution order:
/// 1. HealthKit + HR validation (when both available)
/// 2. HR-only estimation (when HealthKit unavailable and `useHREstimation`)
/// 3. HealthKit-only (when no RR data is passed)
/// 4. Recording boundaries (final fallback)
///
/// The overnight caller (`RRCollector+Analysis`) passes no RR points, so in
/// production cases 3 and 4 apply; the HR paths run only for callers that
/// supply `rrPoints`.
final class SleepBoundaryResolver: Sendable {
    // MARK: - Types

    struct SleepBoundaries {
        let sleepStartMs: Int64?
        let wakeTimeMs: Int64?
    }

    // MARK: - Dependencies

    private let healthKit: HealthKitServiceProtocol

    // MARK: - Initialization

    init(healthKit: HealthKitServiceProtocol) {
        self.healthKit = healthKit
    }

    // MARK: - Public API

    /// Resolve sleep boundaries for a session using HealthKit with configurable fallback.
    ///
    /// - Parameters:
    ///   - sessionStart: When the recording started
    ///   - recordingEnd: When the recording ended (or estimated end)
    ///   - rrPoints: Optional RR data for HR-based estimation fallback
    ///   - useHREstimation: Whether to try HR-based estimation if HealthKit fails
    /// - Returns: Resolved sleep boundaries. A value nothing resolved is nil
    ///   (never a stand-in): with no HealthKit night and no HR estimate both
    ///   are nil, and an onset-only HR estimate has a nil wake. Callers use
    ///   the recording's own start and end for a nil.
    func resolve(
        sessionStart: Date,
        recordingEnd: Date,
        rrPoints: [RRPoint]? = nil,
        useHREstimation: Bool = false
    ) async -> SleepBoundaries {
        if let hkResult = await resolveFromHealthKit(sessionStart: sessionStart, recordingEnd: recordingEnd) {
            return validatedHealthKitBoundaries(
                hkResult, rrPoints: rrPoints, sessionStart: sessionStart
            )
        }
        // No HealthKit — try HR-only; otherwise nothing is resolved.
        if useHREstimation, let points = rrPoints,
           let hrBoundaries = resolveFromHREstimation(
               rrPoints: points, sessionStart: sessionStart
           ) {
            return hrBoundaries
        }
        return SleepBoundaries(sleepStartMs: nil, wakeTimeMs: nil)
    }

    /// With enough RR data, the HealthKit boundaries are cross-checked against
    /// an HR estimate; otherwise they stand as reported.
    private func validatedHealthKitBoundaries(
        _ hkResult: (boundaries: SleepBoundaries, hasDetailedStages: Bool),
        rrPoints: [RRPoint]?,
        sessionStart: Date
    ) -> SleepBoundaries {
        guard let points = rrPoints, points.count >= 100,
              let hrEstimate = resolveFromHREstimation(
                  rrPoints: points, sessionStart: sessionStart
              )
        else { return hkResult.boundaries }
        return Self.validateBoundaries(
            healthKit: hkResult.boundaries,
            hrEstimate: hrEstimate,
            hasDetailedStages: hkResult.hasDetailedStages
        )
    }

    /// Clamp boundaries to valid range within recording duration.
    static func clamp(
        sleepStartMs: Int64?,
        sleepEndMs: Int64?,
        recordingDurationMs: Int64
    ) -> (sleepStartMs: Int64?, sleepEndMs: Int64?) {
        let clampedStart: Int64? = if let start = sleepStartMs {
            max(0, min(start, recordingDurationMs))
        } else {
            nil
        }

        let clampedEnd: Int64? = if let end = sleepEndMs {
            max(0, min(end, recordingDurationMs))
        } else {
            nil
        }

        return (clampedStart, clampedEnd)
    }

    // MARK: - HR Validation

    /// Threshold for boundary disagreement (ms). When HR and HealthKit boundaries
    /// differ by more than this, HR is preferred as the more physiologically accurate signal.
    private static let boundaryDisagreementThresholdMs: Int64 = .init(SleepConstants.boundaryDisagreementMinutes) * 60 * 1000

    /// Compare HealthKit and HR-estimated boundaries.
    /// - Sleep START: when HealthKit has detailed stages (any deep or REM; a
    ///   core-only night is what a source that does not stage sleep writes, as
    ///   `SleepResolver.stageTotals` also treats it) its onset stands in both
    ///   directions. Otherwise HR replaces it when the two disagree by more
    ///   than the threshold.
    /// - Sleep END: HR can only EXTEND (later wake), never shrink. If HR says wake was
    ///   earlier, the recording may have stopped while the user kept sleeping.
    static func validateBoundaries(
        healthKit: SleepBoundaries,
        hrEstimate: SleepBoundaries,
        hasDetailedStages: Bool = false
    ) -> SleepBoundaries {
        return SleepBoundaries(
            sleepStartMs: reconciledStart(healthKit: healthKit, hrEstimate: hrEstimate, hasDetailedStages: hasDetailedStages),
            wakeTimeMs: reconciledEnd(healthKit: healthKit, hrEstimate: hrEstimate)
        )
    }

    /// A Watch onset with physiological stages is authoritative: an HR
    /// estimate moves it neither later nor earlier. HR onsets come from a
    /// heart-rate threshold that misreads light sleep as awake; letting one
    /// pull a staged onset earlier claimed sleep the Watch had staged as
    /// awake and lengthened the night. Without detailed stages HR replaces
    /// the HealthKit onset when the two disagree by more than the threshold.
    private static func reconciledStart(
        healthKit: SleepBoundaries,
        hrEstimate: SleepBoundaries,
        hasDetailedStages: Bool
    ) -> Int64? {
        guard let hkStart = healthKit.sleepStartMs, let hrStart = hrEstimate.sleepStartMs else {
            return healthKit.sleepStartMs ?? hrEstimate.sleepStartMs
        }
        guard !hasDetailedStages, abs(hkStart - hrStart) > boundaryDisagreementThresholdMs else { return hkStart }
        return hrStart
    }

    /// HR can only EXTEND the wake time, never shrink it: an earlier HR wake
    /// usually means the recording stopped while the user kept sleeping.
    private static func reconciledEnd(healthKit: SleepBoundaries, hrEstimate: SleepBoundaries) -> Int64? {
        guard let hkEnd = healthKit.wakeTimeMs, let hrEnd = hrEstimate.wakeTimeMs else {
            return healthKit.wakeTimeMs ?? hrEstimate.wakeTimeMs
        }
        return (hrEnd > hkEnd && (hrEnd - hkEnd) > boundaryDisagreementThresholdMs) ? hrEnd : hkEnd
    }

    // MARK: - Sleep Onset Detection

    /// Algorithm-specific thresholds for HR-based sleep onset detection.
    private enum OnsetDetection {
        static let minimumBeats = 300
        static let windowSize = 120 // ~2 min of beats
        static let stepSize = 30 // ~30 sec steps
        /// `firstSustainedDrop` compares 5 windows before a candidate with
        /// the 10 from it on, so it needs at least 16 to test one candidate.
        static let minimumWindows = 16
        // HR drops at sleep onset via parasympathetic surge (magnitude, not
        // onset-specific) — de Zambotti et al., Sleep 2020;43(7):zsaa045
        static let hrDropThreshold = 8.0 // bpm — significant sustained drop
        // The "asleep" HR ceiling is ADAPTIVE, not a fixed absolute
        // (per Chris: it must work for anyone). Computed per-night in
        // `detectSleepOnset` as the midpoint of the night's OWN HR range
        // (maxHR − (maxHR − minHR)·fraction), self-normalizing per person. A
        // fixed 65 bpm failed entirely for anyone whose true sleeping HR sits
        // above it (deconditioned / older / stressed / febrile) and was
        // non-binding for athletes (~45 bpm). Same midpoint the sibling HR-onset
        // detectors (estimateSleepFromHR / estimateSleepFromHealthKitHR) use.
        static let sleepCeilingMidpointFraction = 0.5
    }

    /// Detect sleep onset by finding where HR suddenly drops and sustains.
    /// Returns the time where sleep likely began, in ms from recording start
    /// on the wall clock — the clock HealthKit envelopes and the window
    /// selector's boundaries use. A beat without a wall-clock time (H10
    /// internal recording, which has no gaps) gives its `t_ms`.
    static func detectSleepOnset(in rrPoints: [RRPoint]) -> Int64? {
        guard rrPoints.count > OnsetDetection.minimumBeats else { return nil }
        let hrWindows = onsetHRWindows(rrPoints)
        guard hrWindows.count >= OnsetDetection.minimumWindows else { return nil }
        // Adaptive "asleep" ceiling (per Chris — works for anyone):
        // post-drop HR must fall into the lower half of the NIGHT'S OWN HR range,
        // self-normalizing per person instead of a fixed 65 bpm. Identical in form
        // to the midpoint threshold the sibling detectors use.
        let allHR = hrWindows.map(\.hr)
        guard let nightMaxHR = allHR.max(), let nightMinHR = allHR.min() else { return nil }
        let ceiling = nightMaxHR - (nightMaxHR - nightMinHR) * OnsetDetection.sleepCeilingMidpointFraction
        if let onset = firstSustainedDrop(in: hrWindows, ceiling: ceiling) { return onset }
        debugLog("[SleepBoundaryResolver] No plausible HR drop detected - onset undetermined")
        return nil
    }

    /// Mean HR per sliding window, skipping windows too sparse to trust,
    /// timed at the window's middle beat on the wall clock (`t_ms` when the
    /// beat carries none).
    private static func onsetHRWindows(_ rrPoints: [RRPoint]) -> [(timeMs: Int64, hr: Double)] {
        let windowSize = OnsetDetection.windowSize
        var hrWindows: [(timeMs: Int64, hr: Double)] = []
        var i = 0
        while i + windowSize < rrPoints.count {
            let windowPoints = Array(rrPoints[i ..< min(i + windowSize, rrPoints.count)])
            if let hr = Self.windowMeanHR(windowPoints, windowSize: windowSize) {
                let middle = windowPoints[windowSize / 2]
                hrWindows.append((middle.wallClockMs ?? middle.t_ms, hr))
            }
            i += OnsetDetection.stepSize
        }
        return hrWindows
    }

    /// Nil when fewer than half the beats in the window are physiologically
    /// valid — an average over mostly-artifact beats is not a heart rate.
    private static func windowMeanHR(_ windowPoints: [RRPoint], windowSize: Int) -> Double? {
        let validRRs = windowPoints.filter { HRVConstants.RRInterval.isValid($0.rr_ms) }
        guard validRRs.count > windowSize / 2 else { return nil }
        let meanRR = validRRs.map { Double($0.rr_ms) }.reduce(0, +) / Double(validRRs.count)
        return 60_000.0 / meanRR
    }

    /// The first window where HR drops by more than the threshold and stays
    /// below the night's adaptive ceiling, when it lies within a plausible
    /// sleep-onset latency; else nil.
    ///
    /// This HR-drop heuristic thresholds against deep-sleep bradycardia,
    /// which consolidates LATER than actual sleep onset — so on a night where
    /// HR doesn't drop below the ceiling until well in, it reports a bogus
    /// long onset (one night reported 66 min when the Apple Watch had true
    /// onset at 5 min, skewing the HRV band late and the score with it). The
    /// recording STARTS at bedtime, so onset can't plausibly be an hour of
    /// lying awake; typical latency is 10-20 min. The window times are on the
    /// wall clock, the clock `SleepConstants.isPlausibleHROnsetLatency` takes.
    /// The first drop is the earliest candidate, so one past the ceiling
    /// leaves the onset undetermined (nil) and each caller falls back to the
    /// recording or envelope start, never a made-up minute 20.
    private static func firstSustainedDrop(
        in hrWindows: [(timeMs: Int64, hr: Double)],
        ceiling: Double
    ) -> Int64? {
        for j in 5 ..< (hrWindows.count - 10) {
            let beforeHR = hrWindows[(j - 5) ..< j].map(\.hr).reduce(0, +) / 5.0
            let afterHR = hrWindows[j ..< (j + 10)].map(\.hr).reduce(0, +) / 10.0
            guard beforeHR - afterHR > OnsetDetection.hrDropThreshold, afterHR < ceiling else { continue }
            let onsetMs = hrWindows[j].timeMs
            let plausible = SleepConstants.isPlausibleHROnsetLatency(wallClockMs: onsetMs)
            debugLog("[SleepBoundaryResolver] First HR drop at \(onsetMs / 60_000)m — \(plausible ? "onset" : "past the latency ceiling, onset undetermined")")
            return plausible ? onsetMs : nil
        }
        return nil
    }

    // MARK: - Private Resolution Strategies

    private func resolveFromHealthKit(
        sessionStart: Date,
        recordingEnd: Date
    ) async -> (boundaries: SleepBoundaries, hasDetailedStages: Bool)? {
        do {
            let sleepData = try await healthKit.fetchSleepData(for: sessionStart, recordingEnd: recordingEnd)
            let sleepStartMs = sleepData.sleepStart.flatMap { MillisecondOffset.between($0, and: sessionStart) }
            let wakeTimeMs = sleepData.sleepEnd.flatMap { MillisecondOffset.between($0, and: sessionStart) }
            // Only useful with at least one boundary.
            guard sleepStartMs != nil || wakeTimeMs != nil else { return nil }
            let hasDetailed = (sleepData.deepSleepMinutes ?? 0) > 0 || (sleepData.remSleepMinutes ?? 0) > 0
            return (SleepBoundaries(sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs), hasDetailed)
        } catch {
            debugLog("[SleepBoundaryResolver] HealthKit sleep fetch failed: \(error)")
            return nil
        }
    }

    private func resolveFromHREstimation(
        rrPoints: [RRPoint],
        sessionStart: Date
    ) -> SleepBoundaries? {
        // Try static estimation from HealthKitManager (uses HR patterns)
        if let estimation = HealthKitManager.estimateSleepFromHR(rrPoints: rrPoints, recordingStart: sessionStart) {
            let startMs = estimation.sleepStart.flatMap { MillisecondOffset.between($0, and: sessionStart) }
            let endMs = estimation.sleepEnd.flatMap { MillisecondOffset.between($0, and: sessionStart) }
            if startMs != nil || endMs != nil {
                return SleepBoundaries(sleepStartMs: startMs, wakeTimeMs: endMs)
            }
        }

        // Try onset detection (simpler algorithm). It finds no wake time, so
        // none is claimed: reporting the recording end as "wake" would let
        // `reconciledEnd` stretch a HealthKit wake out to the strap's stop.
        if let onsetMs = SleepBoundaryResolver.detectSleepOnset(in: rrPoints) {
            return SleepBoundaries(sleepStartMs: onsetMs, wakeTimeMs: nil)
        }

        return nil
    }
}
