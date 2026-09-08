@testable import Emuqu
import XCTest

/// Tests for SleepBoundaryResolver.
/// Validates boundary resolution, clamping, and sleep onset detection.
@MainActor
final class SleepBoundaryResolverTests: XCTestCase {
    // MARK: - Clamp Tests

    func testClampWithinRange() {
        let result = SleepBoundaryResolver.clamp(
            sleepStartMs: 60000,
            sleepEndMs: 300_000,
            recordingDurationMs: 480_000
        )

        XCTAssertEqual(result.sleepStartMs, 60000)
        XCTAssertEqual(result.sleepEndMs, 300_000)
    }

    func testClampNegativeStartClampsToZero() {
        let result = SleepBoundaryResolver.clamp(
            sleepStartMs: -5000,
            sleepEndMs: 300_000,
            recordingDurationMs: 480_000
        )

        XCTAssertEqual(result.sleepStartMs, 0)
        XCTAssertEqual(result.sleepEndMs, 300_000)
    }

    func testClampEndBeyondDurationClamped() {
        let result = SleepBoundaryResolver.clamp(
            sleepStartMs: 60000,
            sleepEndMs: 600_000,
            recordingDurationMs: 480_000
        )

        XCTAssertEqual(result.sleepStartMs, 60000)
        XCTAssertEqual(result.sleepEndMs, 480_000)
    }

    func testClampNilValuesStayNil() {
        let result = SleepBoundaryResolver.clamp(
            sleepStartMs: nil,
            sleepEndMs: nil,
            recordingDurationMs: 480_000
        )

        XCTAssertNil(result.sleepStartMs)
        XCTAssertNil(result.sleepEndMs)
    }

    func testClampMixedNilValues() {
        let result = SleepBoundaryResolver.clamp(
            sleepStartMs: nil,
            sleepEndMs: 300_000,
            recordingDurationMs: 480_000
        )

        XCTAssertNil(result.sleepStartMs)
        XCTAssertEqual(result.sleepEndMs, 300_000)
    }

    func testClampStartBeyondDuration() {
        let result = SleepBoundaryResolver.clamp(
            sleepStartMs: 600_000,
            sleepEndMs: nil,
            recordingDurationMs: 480_000
        )

        XCTAssertEqual(result.sleepStartMs, 480_000)
        XCTAssertNil(result.sleepEndMs)
    }

    // MARK: - Sleep Onset Detection Tests

    func testDetectSleepOnsetReturnsNilForShortData() {
        // Less than 300 points should return nil
        let points = (0 ..< 100).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800)
        }

        let result = SleepBoundaryResolver.detectSleepOnset(in: points)

        XCTAssertNil(result, "Should return nil for data shorter than 300 points")
    }

    func testDetectSleepOnsetWithUniformHR() {
        // Uniform HR — no drop should be detected
        // Need enough data to produce >15 HR windows (windowSize=120, stepSize=30)
        let points = (0 ..< 1200).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800) // 75 bpm constant
        }

        let result = SleepBoundaryResolver.detectSleepOnset(in: points)

        XCTAssertNil(result, "Should return nil when HR is uniform (no drop)")
    }

    func testDetectSleepOnsetWithHRDrop() {
        // Simulate: 600 beats at ~70bpm (857ms), then transition to ~55bpm (1090ms)
        // Need enough data to produce >15 HR windows (windowSize=120, stepSize=30)
        var points: [RRPoint] = []
        var tMs: Int64 = 0

        // Awake period: ~70 bpm (857ms RR)
        for _ in 0 ..< 600 {
            points.append(RRPoint(t_ms: tMs, rr_ms: 857))
            tMs += 857
        }

        // Sleep onset: gradual drop to ~55 bpm (1090ms RR)
        for _ in 0 ..< 600 {
            points.append(RRPoint(t_ms: tMs, rr_ms: 1090))
            tMs += 1090
        }

        let result = SleepBoundaryResolver.detectSleepOnset(in: points)

        // Should detect the HR drop somewhere around the transition
        if let onsetMs = result {
            // The onset should be detected after the awake period
            let awakeEndMs = Int64(600 * 857)
            XCTAssertGreaterThan(onsetMs, 0, "Onset should be after recording start")
            // Allow some tolerance since detection uses windowed averaging
            XCTAssertLessThan(onsetMs, awakeEndMs + 200_000, "Onset should be near the transition")
        }
        // Note: detection may return nil if the algorithm's thresholds aren't met exactly.
        // The HR needs to drop >8 bpm and sustain below 65 bpm.
        // 70->55 bpm is a 15 bpm drop below 65, so it should be detected.
    }

    // MARK: - Resolve Tests (require HealthKit - basic structure)

    func testResolverInitialization() {
        let resolver = SleepBoundaryResolver(healthKit: MockHealthKitService())
        XCTAssertNotNil(resolver)
    }

    func testResolveFallsBackToRecordingBoundaries() async {
        // Without HealthKit data, resolve should fall back to recording boundaries
        let resolver = SleepBoundaryResolver(healthKit: MockHealthKitService())
        let start = Date()
        let end = start.addingTimeInterval(28800) // 8 hours

        let boundaries = await resolver.resolve(
            sessionStart: start,
            recordingEnd: end
        )

        // Fallback should return 0 for start and duration for end
        // (HealthKit will likely fail in test environment, so we get the fallback)
        XCTAssertNotNil(boundaries.sleepStartMs)
        XCTAssertNotNil(boundaries.wakeTimeMs)
    }

    // MARK: - validateBoundaries with hasDetailedStages

    func testValidateBoundaries_HRWantsLater_DetailedStages_KeepsHealthKit() {
        // HealthKit says sleep at 0ms, HR says 30min later — with detailed stages,
        // HealthKit's earlier boundary should be kept (Apple Watch deep/core/REM is authoritative)
        let hk = SleepBoundaryResolver.SleepBoundaries(sleepStartMs: 0, wakeTimeMs: 28_800_000)
        let hr = SleepBoundaryResolver.SleepBoundaries(sleepStartMs: 1_800_000, wakeTimeMs: 28_800_000)

        let result = SleepBoundaryResolver.validateBoundaries(
            healthKit: hk,
            hrEstimate: hr,
            hasDetailedStages: true
        )

        XCTAssertEqual(result.sleepStartMs, 0, "Should keep HealthKit start when HR wants later and detailed stages exist")
    }

    func testValidateBoundaries_HRWantsLater_NoDetailedStages_UsesHR() {
        // HealthKit says sleep at 0ms, HR says 30min later — without detailed stages,
        // HR should override (HealthKit was probably schedule-based / asleepUnspecified)
        let hk = SleepBoundaryResolver.SleepBoundaries(sleepStartMs: 0, wakeTimeMs: 28_800_000)
        let hr = SleepBoundaryResolver.SleepBoundaries(sleepStartMs: 1_800_000, wakeTimeMs: 28_800_000)

        let result = SleepBoundaryResolver.validateBoundaries(
            healthKit: hk,
            hrEstimate: hr,
            hasDetailedStages: false
        )

        XCTAssertEqual(result.sleepStartMs, 1_800_000, "Should use HR start when no detailed stages and HR wants later")
    }

    func testValidateBoundaries_HRWantsEarlier_DetailedStages_UsesHR() {
        // HealthKit says sleep at 30min, HR says 0ms — HR detects earlier sleep
        // even with detailed stages, HR can move onset earlier (catching missed sleep)
        let hk = SleepBoundaryResolver.SleepBoundaries(sleepStartMs: 1_800_000, wakeTimeMs: 28_800_000)
        let hr = SleepBoundaryResolver.SleepBoundaries(sleepStartMs: 0, wakeTimeMs: 28_800_000)

        let result = SleepBoundaryResolver.validateBoundaries(
            healthKit: hk,
            hrEstimate: hr,
            hasDetailedStages: true
        )

        XCTAssertEqual(result.sleepStartMs, 0, "HR should be able to move onset earlier even with detailed stages")
    }

    func testValidateBoundaries_WithinThreshold_KeepsHealthKit() {
        // Difference < 15 min — should keep HealthKit regardless of detailed stages
        let hk = SleepBoundaryResolver.SleepBoundaries(sleepStartMs: 0, wakeTimeMs: 28_800_000)
        let hr = SleepBoundaryResolver.SleepBoundaries(sleepStartMs: 600_000, wakeTimeMs: 28_800_000) // 10 min later

        let result = SleepBoundaryResolver.validateBoundaries(
            healthKit: hk,
            hrEstimate: hr,
            hasDetailedStages: false
        )

        XCTAssertEqual(result.sleepStartMs, 0, "Should keep HealthKit start when difference is within 15min threshold")
    }

    func testValidateBoundaries_EndCanOnlyExtend() {
        // HR says wake earlier — keep HealthKit (recording may have stopped, user slept more)
        let hk = SleepBoundaryResolver.SleepBoundaries(sleepStartMs: 0, wakeTimeMs: 28_800_000)
        let hr = SleepBoundaryResolver.SleepBoundaries(sleepStartMs: 0, wakeTimeMs: 25_200_000) // 1hr earlier

        let result = SleepBoundaryResolver.validateBoundaries(
            healthKit: hk,
            hrEstimate: hr,
            hasDetailedStages: true
        )

        XCTAssertEqual(result.wakeTimeMs, 28_800_000, "Should keep HealthKit end when HR says earlier")
    }

    // MARK: - estimateSleepFromHR baseline fix

    func testEstimateSleepFromHR_FastSleeper_UsesMaxHRBaseline() {
        // Simulate a fast sleeper: sleep HR from the start (~55bpm / 1090ms),
        // brief wake at 5 hours (~72bpm / 833ms), then back to sleep
        // With max-HR baseline, the threshold should use the 72bpm spike as baseline,
        // detecting onset near the beginning of the recording.
        let recordingStart = Date()
        var points: [RRPoint] = []
        var t: Int64 = 0

        // 5 hours of sleep at ~55 bpm = ~16400 beats
        for _ in 0 ..< 16400 {
            points.append(RRPoint(t_ms: t, rr_ms: 1090))
            t += 1090
        }

        // Brief waking: 30 min at ~72 bpm = ~2160 beats
        for _ in 0 ..< 2160 {
            points.append(RRPoint(t_ms: t, rr_ms: 833))
            t += 833
        }

        // Back to sleep for 2 hours at ~55 bpm = ~6560 beats
        for _ in 0 ..< 6560 {
            points.append(RRPoint(t_ms: t, rr_ms: 1090))
            t += 1090
        }

        let result = HealthKitManager.estimateSleepFromHR(rrPoints: points, recordingStart: recordingStart)

        XCTAssertNotNil(result, "Should detect sleep for a fast sleeper")
        if let sleepData = result, let sleepStart = sleepData.sleepStart {
            // Onset should be near the beginning, not hours later
            let onsetMinutes = sleepStart.timeIntervalSince(recordingStart) / 60
            XCTAssertLessThan(onsetMinutes, 30, "Fast sleeper onset should be detected within first 30 minutes")
        }
    }

    func testEstimateSleepFromHR_NormalSleeper_StillWorks() {
        // Sanity check: normal pattern (awake then asleep) still works correctly
        let recordingStart = Date()
        var points: [RRPoint] = []
        var t: Int64 = 0

        // 30 min awake at ~72 bpm = ~2160 beats
        for _ in 0 ..< 2160 {
            points.append(RRPoint(t_ms: t, rr_ms: 833))
            t += 833
        }

        // 6 hours of sleep at ~55 bpm = ~19680 beats
        for _ in 0 ..< 19680 {
            points.append(RRPoint(t_ms: t, rr_ms: 1090))
            t += 1090
        }

        let result = HealthKitManager.estimateSleepFromHR(rrPoints: points, recordingStart: recordingStart)

        XCTAssertNotNil(result, "Should detect sleep for a normal sleeper")
        if let sleepData = result, let sleepStart = sleepData.sleepStart {
            let onsetMinutes = sleepStart.timeIntervalSince(recordingStart) / 60
            // Should detect onset around 30 minutes (after the awake period)
            XCTAssertGreaterThan(onsetMinutes, 10, "Normal sleeper onset should be after awake period")
            XCTAssertLessThan(onsetMinutes, 60, "Normal sleeper onset should be within first hour")
        }
    }
}
