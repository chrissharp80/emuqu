@testable import Emuqu
import XCTest

/// Tests for `HRSleepEstimator` — the fallback that infers sleep boundaries
/// from the shape of heart rate alone, on nights the watch recorded no sleep.
///
/// Its component steps were `private static` on `HealthKitManager` and could
/// only be reached through one entry point, which is why the same onset-clamp
/// defect had to be fixed three times in three sibling detectors before all of
/// them had it. Each step is pinned here.
final class HRSleepEstimatorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_785_600_000)

    private func samples(_ bpms: [(minute: Double, hr: Double)]) -> [(date: Date, hr: Double)] {
        bpms.map { (date: start.addingTimeInterval($0.minute * 60), hr: $0.hr) }
    }

    private func windows(_ hrs: [Double], everyMinutes: Int64 = 5) -> [(timeMs: Int64, hr: Double)] {
        hrs.enumerated().map { (timeMs: Int64($0.offset) * everyMinutes * 60_000, hr: $0.element) }
    }

    // MARK: - hrSleepThreshold

    /// Midpoint between the night's awake baseline (max) and its bradycardic
    /// floor (min).
    func testThresholdIsTheMidpointOfTheNightsRange() {
        let smoothed = samples([(0, 80), (30, 70), (60, 50)])
        XCTAssertEqual(HRSleepEstimator.hrSleepThreshold(smoothed), 65)
    }

    /// A flat trace has no sleep signal in it. Splitting an 80–84 bpm night at
    /// 82 would label random noise as sleep.
    func testTooNarrowARangeYieldsNoThreshold() {
        XCTAssertNil(HRSleepEstimator.hrSleepThreshold(samples([(0, 80), (30, 84), (60, 82)])))
    }

    /// Exactly 8 BPM is the documented floor, and it is inclusive.
    func testEightBPMOfRangeIsEnough() {
        XCTAssertEqual(HRSleepEstimator.hrSleepThreshold(samples([(0, 68), (30, 60)])), 64)
    }

    func testNoSamplesYieldsNoThreshold() {
        XCTAssertNil(HRSleepEstimator.hrSleepThreshold([]))
    }

    // MARK: - clampedSleepOnset (the defect fixed three times)

    /// Two consecutive points below threshold mark onset. The passive path is
    /// relaxed from three because watch samples are sparser than RR data.
    func testOnsetIsTheFirstOfTwoConsecutiveBelowThresholdPoints() {
        let smoothed = samples([(0, 80), (5, 70), (10, 55), (15, 54), (20, 53)])
        let onset = HRSleepEstimator.clampedSleepOnset(smoothed, threshold: 65, windowStart: start)
        XCTAssertEqual(onset, start.addingTimeInterval(10 * 60))
    }

    /// A single dip is not sleep — a stretch, a yawn, one noisy sample.
    func testASingleDipBelowThresholdIsNotOnset() {
        let smoothed = samples([(0, 80), (5, 55), (10, 78), (15, 79)])
        XCTAssertNil(HRSleepEstimator.clampedSleepOnset(smoothed, threshold: 65, windowStart: start))
    }

    /// THE regression. This detector thresholds against deep-sleep
    /// bradycardia, which consolidates ~an hour after true onset, so on some
    /// nights it reports a bogus long onset and shrinks the night. Recording
    /// starts at bedtime, so onset cannot plausibly be an hour of lying awake:
    /// typical SOL is 10–20 min, >30 is clinically prolonged (Ohayon et al.,
    /// Sleep 2004;27(7):1255).
    func testALateDetectedOnsetIsClampedToPlausibleSleepLatency() throws {
        let smoothed = samples([(0, 80), (20, 78), (40, 76), (69, 52), (75, 51), (120, 50)])
        let onset = try XCTUnwrap(
            HRSleepEstimator.clampedSleepOnset(smoothed, threshold: 65, windowStart: start)
        )
        let latencyMinutes = onset.timeIntervalSince(start) / 60
        XCTAssertEqual(latencyMinutes, Double(SleepConstants.maxHREstimatedOnsetLatencyMin), accuracy: 0.001)
        XCTAssertLessThan(latencyMinutes, 69, "the raw 69-minute detection must not survive")
    }

    /// The clamp is a ceiling, not a floor: a genuine fast sleeper keeps their
    /// real onset.
    func testAnEarlyOnsetIsLeftAlone() {
        let smoothed = samples([(0, 55), (5, 54), (10, 53)])
        XCTAssertEqual(
            HRSleepEstimator.clampedSleepOnset(smoothed, threshold: 65, windowStart: start),
            start
        )
    }

    /// Onset needs two points; one or none must return nil rather than trap on
    /// an invalid `0 ..< count - 1` range.
    func testTooFewPointsReturnsNilWithoutTrapping() {
        XCTAssertNil(HRSleepEstimator.clampedSleepOnset([], threshold: 65, windowStart: start))
        XCTAssertNil(HRSleepEstimator.clampedSleepOnset(
            samples([(0, 50)]), threshold: 65, windowStart: start
        ))
    }

    // MARK: - sleepWake

    /// Wake is the end of the LAST sleep block, not the first
    /// below→above crossing; otherwise a bathroom trip at 1:30 AM reads as
    /// final wake and the rest of the night is discarded.
    func testAMidNightHRBumpDoesNotTruncateTheNight() {
        let smoothed = samples([
            (0, 55), (60, 54), (120, 75), (180, 53), (240, 52), (300, 54), (360, 80)
        ])
        XCTAssertEqual(
            HRSleepEstimator.sleepWake(smoothed, threshold: 65),
            start.addingTimeInterval(360 * 60),
            "wake is the point after the last below-threshold sample, not the 2 AM bump"
        )
    }

    /// A night that ends while still below threshold (recording stopped before
    /// waking) reports the last sample rather than nothing.
    func testStillAsleepAtTheEndReportsTheLastSample() {
        let smoothed = samples([(0, 55), (60, 54), (120, 53)])
        XCTAssertEqual(
            HRSleepEstimator.sleepWake(smoothed, threshold: 65),
            start.addingTimeInterval(120 * 60)
        )
    }

    /// Never below threshold at all — no sleep found — still yields the last
    /// sample rather than nil, so the caller's own guards decide.
    func testNeverAsleepFallsBackToTheLastSample() {
        let smoothed = samples([(0, 80), (60, 78), (120, 79)])
        XCTAssertEqual(
            HRSleepEstimator.sleepWake(smoothed, threshold: 65),
            start.addingTimeInterval(120 * 60)
        )
    }

    // MARK: - detectSleepBoundariesFromHR (RR path)

    /// The RR path demands three consecutive windows, being denser data.
    func testRRPathOnsetNeedsThreeConsecutiveWindows() {
        // Threshold on 80/50 is 65. Two low windows, then back up: no onset.
        let (onset, _) = HRSleepEstimator.detectSleepBoundariesFromHR(
            windows([80, 80, 55, 54, 80, 50, 80])
        )
        XCTAssertNil(onset, "two consecutive low windows is not enough on the RR path")
    }

    func testRRPathOnsetIsTheFirstOfThreeConsecutiveLowWindows() {
        let (onset, _) = HRSleepEstimator.detectSleepBoundariesFromHR(
            windows([80, 80, 55, 54, 53, 52, 80])
        )
        XCTAssertEqual(onset, 2 * 5 * 60_000)
    }

    /// Same rule as `sleepWake`, on the RR side.
    func testRRPathWakeSurvivesAMidNightBump() {
        let (_, wake) = HRSleepEstimator.detectSleepBoundariesFromHR(
            windows([80, 55, 54, 85, 53, 52, 51, 90])
        )
        XCTAssertEqual(wake, 7 * 5 * 60_000, "wake is the window after the last asleep one")
    }

    /// Fewer than three windows can never satisfy the onset rule, and the
    /// bound must not become an invalid range.
    func testTooFewWindowsReturnsNoOnsetWithoutTrapping() {
        XCTAssertNil(HRSleepEstimator.detectSleepBoundariesFromHR([]).sleepOnsetMs)
        XCTAssertNil(HRSleepEstimator.detectSleepBoundariesFromHR(windows([55])).sleepOnsetMs)
        XCTAssertNil(HRSleepEstimator.detectSleepBoundariesFromHR(windows([80, 55])).sleepOnsetMs)
    }

    // MARK: - windowedHR / computeWindowedHR

    func testAWindowNeedsTenBeatsToReportAHeartRate() {
        let sparse = (0 ..< 9).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: 1000) }
        XCTAssertNil(HRSleepEstimator.windowedHR(sparse, from: 0, to: 5 * 60_000))
        let dense = (0 ..< 10).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: 1000) }
        XCTAssertEqual(HRSleepEstimator.windowedHR(dense, from: 0, to: 5 * 60_000), 60)
    }

    /// 1000 ms RR = 60 bpm, 800 ms = 75 bpm. The window reports the rate
    /// implied by the MEAN interval, not the mean of the rates.
    func testWindowHeartRateComesFromTheMeanInterval() throws {
        var points: [RRPoint] = []
        for i in 0 ..< 10 { points.append(RRPoint(t_ms: Int64(i) * 900, rr_ms: i < 5 ? 1000 : 800)) }
        let hr = try XCTUnwrap(HRSleepEstimator.windowedHR(points, from: 0, to: 5 * 60_000))
        XCTAssertEqual(hr, 60_000 / 900, accuracy: 0.001)
    }

    func testWindowsAreStampedAtTheirMidpoint() {
        let points = (0 ..< 300).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: 1000) }
        let computed = HRSleepEstimator.computeWindowedHR(rrPoints: points)
        XCTAssertEqual(computed.first?.timeMs, 150_000, "a 5-minute window is stamped at 2.5 minutes")
    }

    func testNoPointsProducesNoWindows() {
        XCTAssertTrue(HRSleepEstimator.computeWindowedHR(rrPoints: []).isEmpty)
    }

    // MARK: - estimateSleepDuration

    func testDurationIsOnsetToWakeWhenBothAreKnown() {
        let points = [RRPoint(t_ms: 8 * 3_600_000, rr_ms: 1000)]
        XCTAssertEqual(
            HRSleepEstimator.estimateSleepDuration(rrPoints: points, sleepOnsetMs: 600_000, wakeMs: 6_600_000),
            100
        )
    }

    /// Still asleep when the recording stopped: run to the last beat.
    func testWithNoWakeTheDurationRunsToTheLastBeat() {
        let points = [RRPoint(t_ms: 3_600_000, rr_ms: 1000)]
        XCTAssertEqual(
            HRSleepEstimator.estimateSleepDuration(rrPoints: points, sleepOnsetMs: 600_000, wakeMs: nil),
            50
        )
    }

    /// No onset found at all: report the whole recording rather than zero, so
    /// the caller's efficiency figure stays meaningful.
    func testWithNoOnsetTheDurationIsTheWholeRecording() {
        let points = [RRPoint(t_ms: 3_600_000, rr_ms: 1000)]
        XCTAssertEqual(
            HRSleepEstimator.estimateSleepDuration(rrPoints: points, sleepOnsetMs: nil, wakeMs: 1_800_000),
            60
        )
    }

    // MARK: - smoothHRSamples / meanHRAround

    func testSmoothingEmitsAtMostOnePointPerHalfWindow() {
        let dense = samples((0 ..< 60).map { (Double($0), 60.0) })
        let smoothed = HRSleepEstimator.smoothHRSamples(dense, windowMinutes: 20)
        XCTAssertLessThanOrEqual(smoothed.count, 60 / 10 + 1)
        XCTAssertFalse(smoothed.isEmpty)
    }

    func testSmoothingNoSamplesYieldsNoPoints() {
        XCTAssertTrue(HRSleepEstimator.smoothHRSamples([], windowMinutes: 20).isEmpty)
    }

    func testMeanIsTakenOverTheWindowOnly() {
        let trace = samples([(0, 60), (5, 70), (60, 200)])
        XCTAssertEqual(
            HRSleepEstimator.meanHRAround(start, in: trace, halfWindow: 10 * 60),
            65, accuracy: 0.001
        )
    }

    /// An empty window would divide by zero. A NaN heart rate compares false
    /// against every threshold, so it would silently erase the night rather
    /// than fail loudly.
    func testAnEmptyWindowYieldsZeroRatherThanNaN() {
        let far = samples([(600, 60)])
        let mean = HRSleepEstimator.meanHRAround(start, in: far, halfWindow: 60)
        XCTAssertFalse(mean.isNaN)
        XCTAssertEqual(mean, 0)
    }

    // MARK: - Entry point

    func testTooFewBeatsIsNotEstimated() {
        let points = (0 ..< 99).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: 1000) }
        XCTAssertNil(HRSleepEstimator.estimateSleepFromHR(rrPoints: points, recordingStart: start))
    }

    /// End to end, with the clamp in place: a night whose HR only consolidates
    /// an hour in still reports a plausible onset.
    func testEndToEndOnsetNeverExceedsThePlausibleLatencyCeiling() throws {
        var points: [RRPoint] = []
        var t: Int64 = 0
        for _ in 0 ..< 4_300 { points.append(RRPoint(t_ms: t, rr_ms: 833)); t += 833 }   // 60 min awake
        for _ in 0 ..< 19_680 { points.append(RRPoint(t_ms: t, rr_ms: 1_090)); t += 1_090 } // 6 h asleep
        let result = try XCTUnwrap(
            HRSleepEstimator.estimateSleepFromHR(rrPoints: points, recordingStart: start)
        )
        let onsetMinutes = try XCTUnwrap(result.sleepStart).timeIntervalSince(start) / 60
        XCTAssertLessThanOrEqual(onsetMinutes, Double(SleepConstants.maxHREstimatedOnsetLatencyMin))
    }

    func testTheRRPathIsLabelledAsAnEstimate() {
        var points: [RRPoint] = []
        var t: Int64 = 0
        for _ in 0 ..< 2_160 { points.append(RRPoint(t_ms: t, rr_ms: 833)); t += 833 }
        for _ in 0 ..< 19_680 { points.append(RRPoint(t_ms: t, rr_ms: 1_090)); t += 1_090 }
        let result = HRSleepEstimator.estimateSleepFromHR(rrPoints: points, recordingStart: start)
        XCTAssertEqual(result?.boundarySource, .hrEstimated)
    }

    /// Efficiency is the classified sleep over time in bed, the same total
    /// the screen shows, not onset-to-wake time: 300 min classified asleep in
    /// a 340-min recording with onset-to-wake 330 min is 88 %, not 97 %.
    func testEfficiencyUsesTheClassifiedSleepMinutes() {
        let points = [RRPoint(t_ms: 340 * 60_000, rr_ms: 1000)]
        let classified = HRVSleepStageClassifier.ClassificationResult(
            stageIntervals: [], deepSleepMinutes: 60, remSleepMinutes: 60, coreSleepMinutes: 180, awakeMinutes: 30
        )
        let data = HRSleepEstimator.hrEstimatedSleepData(
            rrPoints: points, recordingStart: start,
            sleepOnsetMs: 5 * 60_000, wakeMs: 335 * 60_000, stageResult: classified
        )
        XCTAssertEqual(data.nightSleepMinutes, 300)
        XCTAssertEqual(data.sleepEfficiency, 300.0 / 340.0 * 100, accuracy: 0.01)
    }
}
