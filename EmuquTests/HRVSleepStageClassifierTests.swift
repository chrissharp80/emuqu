@testable import Emuqu
import os
import XCTest

/// Tests for HRV-based sleep stage classification.
/// Validates that the classifier produces physiologically plausible stage distributions
/// from RR interval data when Apple Watch stage data is unavailable.
final class HRVSleepStageClassifierTests: XCTestCase {
    /// Capture-and-restore, not fire-and-forget.
    ///
    /// `NSTimeZone.default` is **process-global**. Ten test classes set it to
    /// UTC in `class setUp()` and none of them put it back, so every test class
    /// that happened to run afterwards in the same process silently inherited
    /// UTC. `LiveReadinessTests` computes "today" from `Date()` against the
    /// current calendar, so between 19:00 and midnight US-Central (when the UTC
    /// date is already tomorrow) four of its tests failed — a genuine
    /// time-of-day flake that was invisible only because the suite used to
    /// deadlock before reaching them.
    private static let savedDefaultTimeZone = OSAllocatedUnfairLock<TimeZone?>(initialState: nil)
    override class func setUp() {
        super.setUp()
        // Pin to UTC so the synthetic sleep night anchored at
        // `Date(timeIntervalSince1970:)` lands at the same wall-clock hour
        // on every machine.
        savedDefaultTimeZone.withLock { $0 = NSTimeZone.default }
        NSTimeZone.default = TestTimeZone.utc
    }

    override class func tearDown() {
        if let saved = savedDefaultTimeZone.withLock({ $0 }) { NSTimeZone.default = saved }
        savedDefaultTimeZone.withLock { $0 = nil }
        super.tearDown()
    }

    // MARK: - Helpers

    private let fixedRecordingStart = Date(timeIntervalSince1970: 1_700_000_000)

    private func deterministicOffset(step: Int, min: Int, max: Int) -> Int {
        let span = max - min + 1
        let value = (Int64(step) * 1_103_515_245 + 12345) & 0x7FFF_FFFF
        return min + Int(value % Int64(span))
    }

    /// Generate synthetic RR points simulating a sleep night.
    /// Deep sleep: low HR (~52 bpm → RR ~1154ms), regular intervals
    /// Light sleep: moderate HR (~60 bpm → RR ~1000ms), moderate variation
    /// REM: elevated HR (~65 bpm → RR ~923ms), high variation
    /// Awake: high HR (~75 bpm → RR ~800ms), irregular
    private func generateSleepNight(
        durationHours: Double = 7.0,
        deepPercent _: Double = 0.20,
        remPercent _: Double = 0.22,
        awakePercent _: Double = 0.05
    ) -> [RRPoint] {
        let durationMs = Int64(durationHours * 3600 * 1000)
        var points: [RRPoint] = []
        var currentMs: Int64 = 0
        var beatIndex = 0

        // Simple cycle model: alternate NREM (deep+light) and REM in ~90 min cycles
        let cycleMs: Int64 = 90 * 60 * 1000
        let cycleCount = Int(durationMs / cycleMs)

        for cycle in 0 ..< max(1, cycleCount) {
            let cycleStart = Int64(cycle) * cycleMs
            let cycleEnd = min(cycleStart + cycleMs, durationMs)
            let cycleDuration = cycleEnd - cycleStart

            // Deep sleep: first portion of cycle (more in early cycles)
            let deepFraction = cycle < 2 ? 0.30 : 0.15
            let deepEnd = cycleStart + Int64(Double(cycleDuration) * deepFraction)

            // REM: last portion (more in later cycles)
            let remFraction = cycle < 2 ? 0.15 : 0.30
            let remStart = cycleEnd - Int64(Double(cycleDuration) * remFraction)

            // Brief awake at cycle boundary
            let awakeEnd = min(cycleStart + 2 * 60 * 1000, cycleEnd)

            while currentMs < cycleEnd {
                let rr = if currentMs < awakeEnd, cycle > 0 {
                    // Brief waking between cycles
                    800 + deterministicOffset(step: beatIndex, min: -40, max: 40)
                } else if currentMs < deepEnd {
                    // Deep sleep: low HR, very regular
                    1154 + deterministicOffset(step: beatIndex, min: -15, max: 15)
                } else if currentMs >= remStart {
                    // REM: higher HR, variable
                    923 + deterministicOffset(step: beatIndex, min: -60, max: 60)
                } else {
                    // Light/core sleep: moderate
                    1000 + deterministicOffset(step: beatIndex, min: -30, max: 30)
                }

                let clampedRR = max(200, min(2000, rr))
                points.append(RRPoint(t_ms: currentMs, rr_ms: clampedRR, wallClockMs: nil, hr: nil))
                currentMs += Int64(clampedRR)
                beatIndex += 1
            }
        }

        return points
    }

    /// Generate uniform RR points at a given HR
    private func generateUniformRR(hr: Double, durationMinutes: Int, startMs: Int64 = 0) -> [RRPoint] {
        let rrMs = Int(60000.0 / hr)
        var points: [RRPoint] = []
        var t: Int64 = startMs
        let endMs = startMs + Int64(durationMinutes) * 60 * 1000
        while t < endMs {
            points.append(RRPoint(t_ms: t, rr_ms: rrMs, wallClockMs: nil, hr: nil))
            t += Int64(rrMs)
        }
        return points
    }

    // MARK: - Classification Tests

    func testClassifyProducesAllStages() throws {
        let rrPoints = generateSleepNight()
        let durationMs = try XCTUnwrap(rrPoints.last?.t_ms)

        let result = HRVSleepStageClassifier.classify(
            rrPoints: rrPoints,
            sleepStartMs: 0,
            sleepEndMs: durationMs,
            recordingStart: fixedRecordingStart
        )

        XCTAssertNotNil(result, "Classification should succeed with 7h of data")

        guard let r = result else { return }

        // All stage types should be present in a full night
        XCTAssertGreaterThan(r.deepSleepMinutes, 0, "Should detect deep sleep")
        XCTAssertGreaterThan(r.remSleepMinutes, 0, "Should detect REM sleep")
        XCTAssertGreaterThan(r.coreSleepMinutes, 0, "Should detect core/light sleep")

        // Total should approximate the input duration
        let totalMinutes = r.deepSleepMinutes + r.remSleepMinutes + r.coreSleepMinutes + r.awakeMinutes
        let expectedMinutes = Int(Double(durationMs) / 60000.0)
        XCTAssertEqual(totalMinutes, expectedMinutes, accuracy: 15, "Total staged minutes should approximate sleep duration")
    }

    func testClassifyDeepSleepProportions() throws {
        let rrPoints = generateSleepNight(durationHours: 8.0)
        let durationMs = try XCTUnwrap(rrPoints.last?.t_ms)

        let result = HRVSleepStageClassifier.classify(
            rrPoints: rrPoints,
            sleepStartMs: 0,
            sleepEndMs: durationMs,
            recordingStart: fixedRecordingStart
        )

        guard let r = result else {
            XCTFail("Classification should succeed")
            return
        }

        let totalSleep = r.deepSleepMinutes + r.remSleepMinutes + r.coreSleepMinutes
        guard totalSleep > 0 else {
            XCTFail("Total sleep should be > 0")
            return
        }

        // Deep sleep should be roughly 10-30% of total (research norm: 13-23%)
        let deepPercent = Double(r.deepSleepMinutes) / Double(totalSleep) * 100
        XCTAssertGreaterThan(deepPercent, 5, "Deep sleep should be at least 5%")
        XCTAssertLessThan(deepPercent, 45, "Deep sleep should be under 45%")
    }

    func testClassifyREMNotInFirstHour() throws {
        let rrPoints = generateSleepNight(durationHours: 7.0)
        let durationMs = try XCTUnwrap(rrPoints.last?.t_ms)

        let result = HRVSleepStageClassifier.classify(
            rrPoints: rrPoints,
            sleepStartMs: 0,
            sleepEndMs: durationMs,
            recordingStart: fixedRecordingStart
        )

        guard let r = result else {
            XCTFail("Classification should succeed")
            return
        }

        // No REM should appear in the first 60 minutes
        let oneHourAfterStart = fixedRecordingStart.addingTimeInterval(3600)
        let earlyREM = r.stageIntervals.filter { $0.stage == .rem && $0.start < oneHourAfterStart }
        XCTAssertTrue(earlyREM.isEmpty, "REM should not appear in the first 60 minutes of sleep")
    }

    func testClassifyInsufficientDataReturnsNil() throws {
        // Only 10 minutes of data — should be insufficient
        let rrPoints = generateUniformRR(hr: 60, durationMinutes: 10)

        let result = try HRVSleepStageClassifier.classify(
            rrPoints: rrPoints,
            sleepStartMs: 0,
            sleepEndMs: XCTUnwrap(rrPoints.last?.t_ms),
            recordingStart: fixedRecordingStart
        )

        XCTAssertNil(result, "Should return nil with insufficient data")
    }

    func testClassifyEmptyDataReturnsNil() {
        let result = HRVSleepStageClassifier.classify(
            rrPoints: [],
            sleepStartMs: 0,
            sleepEndMs: 100_000,
            recordingStart: fixedRecordingStart
        )

        XCTAssertNil(result, "Should return nil with empty data")
    }

    func testClassifyInvertedBoundariesReturnsNil() {
        let rrPoints = generateUniformRR(hr: 60, durationMinutes: 120)

        let result = HRVSleepStageClassifier.classify(
            rrPoints: rrPoints,
            sleepStartMs: 100_000,
            sleepEndMs: 50000,
            recordingStart: fixedRecordingStart
        )

        XCTAssertNil(result, "Should return nil when sleepEnd < sleepStart")
    }

    func testStageIntervalsAreContinuous() throws {
        let rrPoints = generateSleepNight(durationHours: 6.0)
        let durationMs = try XCTUnwrap(rrPoints.last?.t_ms)

        let result = HRVSleepStageClassifier.classify(
            rrPoints: rrPoints,
            sleepStartMs: 0,
            sleepEndMs: durationMs,
            recordingStart: fixedRecordingStart
        )

        guard let r = result else {
            XCTFail("Classification should succeed")
            return
        }

        // Stage intervals should be continuous — each starts where the previous ended
        for i in 1 ..< r.stageIntervals.count {
            let prev = r.stageIntervals[i - 1]
            let curr = r.stageIntervals[i]
            XCTAssertEqual(
                prev.end.timeIntervalSince1970,
                curr.start.timeIntervalSince1970,
                accuracy: 1.0,
                "Stage intervals should be continuous (no gaps)"
            )
        }
    }

    func testAdjacentIntervalsHaveDifferentStages() throws {
        let rrPoints = generateSleepNight(durationHours: 7.0)
        let durationMs = try XCTUnwrap(rrPoints.last?.t_ms)

        let result = HRVSleepStageClassifier.classify(
            rrPoints: rrPoints,
            sleepStartMs: 0,
            sleepEndMs: durationMs,
            recordingStart: fixedRecordingStart
        )

        guard let r = result else {
            XCTFail("Classification should succeed")
            return
        }

        // Adjacent intervals should have different stages (merged correctly)
        for i in 1 ..< r.stageIntervals.count {
            XCTAssertNotEqual(
                r.stageIntervals[i - 1].stage,
                r.stageIntervals[i].stage,
                "Adjacent intervals should have different stages (should be merged)"
            )
        }
    }

    // MARK: - Smoothing Tests

    func testSmoothingRemovesSingleWindowBlips() {
        let stages: [HealthKitManager.SleepStage] = [.deep, .deep, .core, .deep, .deep]
        let smoothed = HRVSleepStageClassifier.smoothStages(stages)
        XCTAssertEqual(smoothed, [.deep, .deep, .deep, .deep, .deep])
    }

    func testSmoothingPreservesBriefAwakenings() {
        let stages: [HealthKitManager.SleepStage] = [.deep, .deep, .awake, .deep, .deep]
        let smoothed = HRVSleepStageClassifier.smoothStages(stages)
        // Awake should NOT be smoothed away — brief wakings are physiologically real
        XCTAssertEqual(smoothed[2], .awake)
    }

    func testSmoothingPreservesRealTransitions() {
        let stages: [HealthKitManager.SleepStage] = [.deep, .deep, .core, .core, .rem, .rem]
        let smoothed = HRVSleepStageClassifier.smoothStages(stages)
        XCTAssertEqual(smoothed, stages, "Real transitions should not be smoothed")
    }

    func testSmoothingShortInput() {
        let stages: [HealthKitManager.SleepStage] = [.deep, .core]
        let smoothed = HRVSleepStageClassifier.smoothStages(stages)
        XCTAssertEqual(smoothed, stages, "Short input should pass through unchanged")
    }

    // MARK: - Rank and Scoring Tests

    func testComputeRanksOrdering() {
        let values = [50.0, 30.0, 70.0, 10.0, 90.0]
        let ranks = HRVSleepStageClassifier.computeRanks(values)

        // 10=0.0, 30=0.25, 50=0.5, 70=0.75, 90=1.0
        XCTAssertEqual(ranks[0], 0.50, accuracy: 0.01) // 50
        XCTAssertEqual(ranks[1], 0.25, accuracy: 0.01) // 30
        XCTAssertEqual(ranks[2], 0.75, accuracy: 0.01) // 70
        XCTAssertEqual(ranks[3], 0.00, accuracy: 0.01) // 10
        XCTAssertEqual(ranks[4], 1.00, accuracy: 0.01) // 90
    }

    func testComputeRanksSingleElement() {
        let ranks = HRVSleepStageClassifier.computeRanks([42.0])
        XCTAssertEqual(ranks, [0.5])
    }

    func testDFARankDirectionLowAlpha1IsDeepLike() {
        // Per Penzel 2003 / Bunde 2000: deep sleep has LOWEST α1 (~0.5-0.7)
        // The classifier uses ranks directly: low dfaRank → deep, high dfaRank → REM
        let values = [0.55, 0.85, 1.10, 0.95, 1.25]
        let ranks = HRVSleepStageClassifier.computeRanks(values)

        // α1=0.55 should have the lowest rank (most deep-like)
        XCTAssertEqual(ranks[0], 0.0, accuracy: 0.01, "α1=0.55 should be rank 0 (deep-like)")
        // α1=1.25 should have the highest rank (most REM-like)
        XCTAssertEqual(ranks[4], 1.0, accuracy: 0.01, "α1=1.25 should be rank 1 (REM-like)")
    }

    func testCoreSleepDominatesWithUniformPhysiology() {
        // Simulate a very fit person with minimal HR/RMSSD variation across the night
        // (the exact scenario that broke the previous threshold approach)
        var points: [RRPoint] = []
        var t: Int64 = 0
        var beatIndex = 0
        let durationMs: Int64 = 7 * 3600 * 1000
        while t < durationMs {
            // ~48 bpm throughout with very little variation
            let rr = 1250 + deterministicOffset(step: beatIndex, min: -20, max: 20)
            points.append(RRPoint(t_ms: t, rr_ms: rr, wallClockMs: nil, hr: nil))
            t += Int64(rr)
            beatIndex += 1
        }

        let result = HRVSleepStageClassifier.classify(
            rrPoints: points,
            sleepStartMs: 0,
            sleepEndMs: durationMs,
            recordingStart: fixedRecordingStart
        )

        guard let r = result else {
            XCTFail("Classification should succeed")
            return
        }

        let totalSleep = r.deepSleepMinutes + r.remSleepMinutes + r.coreSleepMinutes
        guard totalSleep > 0 else {
            XCTFail("Total sleep > 0")
            return
        }

        // With uniform physiology, classification should not collapse into all-deep.
        let corePercent = Double(r.coreSleepMinutes) / Double(totalSleep) * 100
        XCTAssertGreaterThan(corePercent, 15, "Core should remain materially present with uniform physiology")

        // Deep should not fully dominate
        let deepPercent = Double(r.deepSleepMinutes) / Double(totalSleep) * 100
        XCTAssertLessThan(deepPercent, 80, "Deep should not fully dominate with uniform physiology")
    }

    func testClassifyREMProportionWithinNorms() throws {
        // REM should be ~20-25% of total sleep for healthy adults (Ohayon et al. 2004).
        // A temporal weighting bias in the classifier shows up here as ~50% REM.
        let rrPoints = generateSleepNight(durationHours: 8.0)
        let durationMs = try XCTUnwrap(rrPoints.last?.t_ms)

        let result = HRVSleepStageClassifier.classify(
            rrPoints: rrPoints,
            sleepStartMs: 0,
            sleepEndMs: durationMs,
            recordingStart: fixedRecordingStart
        )

        guard let r = result else {
            XCTFail("Classification should succeed")
            return
        }

        let totalSleep = r.deepSleepMinutes + r.remSleepMinutes + r.coreSleepMinutes
        guard totalSleep > 0 else {
            XCTFail("Total sleep should be > 0")
            return
        }

        let remPercent = Double(r.remSleepMinutes) / Double(totalSleep) * 100
        XCTAssertGreaterThan(remPercent, 5, "REM should be at least 5% of sleep")
        XCTAssertLessThan(remPercent, 35, "REM should be under 35% of sleep (norm ~20-25%)")
    }

    // MARK: - Percentile Helper Tests

    func testPercentileEmpty() {
        XCTAssertEqual(HRVSleepStageClassifier.percentile([], p: 0.5), 0)
    }

    func testPercentileSingleValue() {
        XCTAssertEqual(HRVSleepStageClassifier.percentile([42.0], p: 0.5), 42.0)
    }

    func testPercentileMedian() {
        let sorted = [10.0, 20.0, 30.0, 40.0, 50.0]
        XCTAssertEqual(HRVSleepStageClassifier.percentile(sorted, p: 0.5), 30.0)
    }

    func testPercentileExtremes() {
        let sorted = [10.0, 20.0, 30.0, 40.0, 50.0]
        XCTAssertEqual(HRVSleepStageClassifier.percentile(sorted, p: 0.0), 10.0)
        XCTAssertEqual(HRVSleepStageClassifier.percentile(sorted, p: 1.0), 50.0)
    }

    // MARK: - Out-of-range percentiles

    /// `upper` was bounded but `lower` was not, so a
    /// percentile above 1 indexed past the end of the array and one below 0
    /// indexed negatively — both out-of-bounds crashes. A NaN `p` reached
    /// `Int(idx)`, which traps outright.
    func testPercentileAboveOneClampsToTheLastValue() {
        let sorted: [Double] = [10, 20, 30, 40, 50]
        XCTAssertEqual(HRVSleepStageClassifier.percentile(sorted, p: 1.5), 50.0)
        XCTAssertEqual(HRVSleepStageClassifier.percentile(sorted, p: 99), 50.0)
    }

    func testPercentileBelowZeroClampsToTheFirstValue() {
        let sorted: [Double] = [10, 20, 30, 40, 50]
        XCTAssertEqual(HRVSleepStageClassifier.percentile(sorted, p: -0.5), 10.0)
    }

    func testNonFinitePercentileDoesNotTrap() {
        let sorted: [Double] = [10, 20, 30, 40, 50]
        XCTAssertEqual(HRVSleepStageClassifier.percentile(sorted, p: .nan), 10.0)
        XCTAssertEqual(HRVSleepStageClassifier.percentile(sorted, p: .infinity), 10.0)
    }

    // MARK: - Interval Building Tests

    func testBuildIntervalsNoWindows() {
        let intervals = HRVSleepStageClassifier.buildIntervals(windows: [], stages: [])
        XCTAssertTrue(intervals.isEmpty)
    }

    func testBuildIntervalsMergesAdjacentSameStage() {
        let now = Date()
        let windows = (0 ..< 4).map { window(at: $0, from: now) }
        let stages: [HealthKitManager.SleepStage] = [.deep, .deep, .core, .core]
        let intervals = HRVSleepStageClassifier.buildIntervals(windows: windows, stages: stages)

        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(intervals[0].stage, .deep)
        XCTAssertEqual(intervals[1].stage, .core)
    }

    // MARK: - Statistics Parity (routed through Utilities/Statistics)

    /// RMSSD parity: buildFeatureWindows now computes RMSSD via
    /// Statistics.rootMeanSquare over the successive-difference array.
    /// All 15 RR points land in a single 5-minute window.
    func testBuildFeatureWindowsRMSSDParityExact() throws {
        // Pattern [1000, 1050, 950, 1020, 980] x3 → diffs cycle
        // [50, -100, 70, -40, 20] (with wraparound 980→1000 = +20), 14 diffs,
        // RMSSD = sqrt(sumSq/14) ≈ 64.25396.
        let pattern = [1000, 1050, 950, 1020, 980]
        var points: [RRPoint] = []
        var t: Int64 = 0
        for _ in 0 ..< 3 {
            for rr in pattern {
                points.append(RRPoint(t_ms: t, rr_ms: rr, wallClockMs: nil, hr: nil))
                t += Int64(rr)
            }
        }

        let windows = HRVSleepStageClassifier.buildFeatureWindows(
            rrPoints: points,
            sleepStartMs: 0,
            sleepEndMs: 5 * 60 * 1000,
            recordingStart: fixedRecordingStart
        )

        XCTAssertEqual(windows.count, 1, "All points should fall in one 5-minute window")
        XCTAssertEqual(try XCTUnwrap(windows.first).rmssd, 64.25396041156863, accuracy: 1e-6)
    }

    /// One evenly-spaced feature window.
    ///
    /// Extracted from an inline `map` closure: the untyped numeric literals in
    /// a ten-argument initialiser cost 674 ms to type-check on their own. Each
    /// `let` here is annotated so the checker solves one small problem per line.
    private func window(at index: Int, from start: Date) -> HRVSleepStageClassifier.FeatureWindow {
        let offset: TimeInterval = Double(index) * 300
        let midpointMs: Int64 = Int64(index) * 300_000 + 150_000
        return HRVSleepStageClassifier.FeatureWindow(
            startDate: start.addingTimeInterval(offset),
            endDate: start.addingTimeInterval(offset + 300),
            midpointMs: midpointMs,
            hr: 55, rmssd: 50, sdnn: 40, hrCV: 0.03,
            dfaAlpha1: 0.85, lfHfRatio: 1.5, hfPower: 200
        )
    }
    // MARK: - Window variability
    //
    // SDNN here is POPULATION variance (divisor N). The distinction from the
    // sample form (N-1) lived only in a comment until a
    // mutation to N-1 survived this whole suite. On the short windows this
    // classifier runs on the two differ by several percent, and SDNN feeds the
    // stage decision.

    /// Four evenly spread intervals: mean 1000, deviations ±100 and ±50.
    /// Population variance is (100² + 50² + 50² + 100²)/4 = 6250, so SDNN is
    /// 79.06. The sample form would divide by 3 and give 91.29.
    func testSDNNUsesPopulationVarianceNotTheSampleForm() {
        let rrs: [Double] = [900, 950, 1_050, 1_100]
        let result = HRVSleepStageClassifier.windowVariability(rrs, avgRR: 1_000)
        XCTAssertEqual(result.sdnn, 79.0569, accuracy: 0.001)
        XCTAssertNotEqual(result.sdnn, 91.287, accuracy: 0.01)
    }

    /// Stated as the formula rather than one number, so any window size is
    /// covered rather than the one that happened to be written down.
    func testSDNNMatchesThePopulationFormulaForEveryWindowSize() {
        for count in 2 ... 12 {
            let rrs = (0 ..< count).map { 1_000.0 + Double($0) * 13.0 }
            let mean = rrs.reduce(0, +) / Double(rrs.count)
            let population = (rrs.map { pow($0 - mean, 2) }.reduce(0, +) / Double(rrs.count)).squareRoot()
            let result = HRVSleepStageClassifier.windowVariability(rrs, avgRR: mean)
            XCTAssertEqual(result.sdnn, population, accuracy: 1e-9, "window of \(count)")
        }
    }

    /// RMSSD is the root-mean-square of successive differences — a different
    /// quantity from SDNN, and the one that reflects beat-to-beat change.
    func testRMSSDIsTheRootMeanSquareOfSuccessiveDifferences() {
        // Differences: +100, +100, +100 → RMSSD 100.
        let rrs: [Double] = [900, 1_000, 1_100, 1_200]
        let result = HRVSleepStageClassifier.windowVariability(rrs, avgRR: 1_050)
        XCTAssertEqual(result.rmssd, 100, accuracy: 0.001)
    }

    /// The coefficient of variation is SDNN over the mean, which is what makes
    /// it comparable between a 50 bpm sleeper and an 80 bpm one.
    func testCoefficientOfVariationIsSDNNOverTheMean() {
        let rrs: [Double] = [900, 950, 1_050, 1_100]
        let result = HRVSleepStageClassifier.windowVariability(rrs, avgRR: 1_000)
        XCTAssertEqual(result.hrCV, result.sdnn / 1_000, accuracy: 1e-9)
    }

    /// Fewer than two beats yields no variability rather than a trapping
    /// `1 ..< 1` range or a divide by zero.
    func testTooFewBeatsYieldsZeroesRatherThanTrapping() {
        for rrs in [[Double](), [1_000.0]] {
            let result = HRVSleepStageClassifier.windowVariability(rrs, avgRR: 1_000)
            XCTAssertEqual(result.rmssd, 0)
            XCTAssertEqual(result.sdnn, 0)
            XCTAssertEqual(result.hrCV, 0)
        }
    }

    /// A zero mean would divide by zero; the CV degrades to 0 instead of NaN,
    /// which would poison every downstream comparison silently.
    func testAZeroMeanYieldsZeroCoefficientRatherThanNaN() {
        let result = HRVSleepStageClassifier.windowVariability([0, 0, 0], avgRR: 0)
        XCTAssertFalse(result.hrCV.isNaN)
        XCTAssertEqual(result.hrCV, 0)
    }

}
