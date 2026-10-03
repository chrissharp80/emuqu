@testable import Emuqu
import XCTest

// MARK: - HallucinationFeedbackTests
//
// Covers the cross-turn corrections buffer added to
// MetricsVerifier in response to a real-user log showing the AI
// fabricating HR (72 vs actual 91, then 71 vs actual 88) on
// consecutive turns. The TTS-side guard substituted the right
// number, but the model kept fabricating because nothing fed the
// correction back.
//
// `recordCorrections` accumulates discrepancies; `consumePending-
// CorrectionsBlock` drains them as a single short reminder for
// the next turn's system prompt. After consume, the buffer is
// empty so subsequent turns aren't perpetually scolded.

final class HallucinationFeedbackTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Ensure a clean buffer between tests — `consume` clears
        // it, so calling once is sufficient even on first run.
        _ = MetricsVerifier.consumePendingCorrectionsBlock()
    }

    /// No corrections recorded → nil block (no system prompt clutter
    /// when the model behaved).
    func testEmptyBufferReturnsNil() {
        XCTAssertNil(MetricsVerifier.consumePendingCorrectionsBlock(),
            "no recorded corrections should produce no block")
    }

    /// Recording one discrepancy and consuming should yield a block
    /// containing the rule, the metric, both numbers, and clear the
    /// buffer.
    func testRecordOneCorrectionThenConsumeClearsBuffer() {
        let d = MetricsVerifier.Discrepancy(
            metric: "HR",
            claimed: "72",
            actual: "91",
            absoluteDelta: 19,
            range: wholeRange("72")
        )
        MetricsVerifier.recordCorrections([d])

        let block = MetricsVerifier.consumePendingCorrectionsBlock()
        XCTAssertNotNil(block)
        XCTAssertTrue(block?.contains("DO NOT FABRICATE") ?? false,
            "block should lead with the don't-fabricate rule")
        XCTAssertTrue(block?.contains("HR=72") ?? false,
            "block should include claimed value")
        XCTAssertTrue(block?.contains("actual was 91") ?? false,
            "block should include actual value")

        // Second consume after one record + one consume = empty.
        XCTAssertNil(MetricsVerifier.consumePendingCorrectionsBlock(),
            "consume should clear the buffer; second call returns nil")
    }

    /// Recording several discrepancies in one batch produces one
    /// block with all of them.
    func testRecordMultipleInOneBatch() {
        let hrD = MetricsVerifier.Discrepancy(
            metric: "HR", claimed: "72", actual: "91",
            absoluteDelta: 19, range: wholeRange("x")
        )
        let paceD = MetricsVerifier.Discrepancy(
            metric: "pace", claimed: "8:30", actual: "9:15",
            absoluteDelta: 45, range: wholeRange("x")
        )
        MetricsVerifier.recordCorrections([hrD, paceD])

        let block = MetricsVerifier.consumePendingCorrectionsBlock()
        XCTAssertNotNil(block)
        XCTAssertTrue(block?.contains("HR=72") ?? false)
        XCTAssertTrue(block?.contains("pace=8:30") ?? false)
        XCTAssertTrue(block?.contains("actual was 91") ?? false)
        XCTAssertTrue(block?.contains("actual was 9:15") ?? false)
    }

    /// Buffer caps at 4 entries — a model fabricating 6 numbers in
    /// one turn doesn't grow the reminder unboundedly. Most-recent
    /// entries win (suffix(4)).
    func testBufferCapsAtFour() {
        for i in 0..<6 {
            let d = MetricsVerifier.Discrepancy(
                metric: "metric\(i)",
                claimed: "claimed\(i)",
                actual: "actual\(i)",
                absoluteDelta: Double(i),
                range: wholeRange("x")
            )
            MetricsVerifier.recordCorrections([d])
        }
        let block = MetricsVerifier.consumePendingCorrectionsBlock()
        XCTAssertNotNil(block)
        // The 4 most-recent entries (indices 2, 3, 4, 5) should be
        // present; 0 and 1 dropped.
        XCTAssertFalse(block?.contains("metric0") ?? true,
            "earliest entries should be dropped when cap is exceeded")
        XCTAssertFalse(block?.contains("metric1") ?? true)
        XCTAssertTrue(block?.contains("metric2") ?? false)
        XCTAssertTrue(block?.contains("metric5") ?? false)
    }

    /// Recording across multiple turns accumulates until consumed.
    /// (Until the system prompt actually consumes the buffer, every
    /// subsequent guard fire adds more entries.)
    func testRecordingAcrossCallsAccumulates() {
        let d1 = MetricsVerifier.Discrepancy(
            metric: "HR", claimed: "70", actual: "85",
            absoluteDelta: 15, range: wholeRange("x")
        )
        MetricsVerifier.recordCorrections([d1])

        let d2 = MetricsVerifier.Discrepancy(
            metric: "pace", claimed: "8:00", actual: "9:30",
            absoluteDelta: 90, range: wholeRange("x")
        )
        MetricsVerifier.recordCorrections([d2])

        let block = MetricsVerifier.consumePendingCorrectionsBlock()
        XCTAssertTrue(block?.contains("HR=70") ?? false,
            "first batch survives until consumed")
        XCTAssertTrue(block?.contains("pace=8:00") ?? false,
            "second batch accumulates with first")
    }
}

// MARK: - Which numbers count as a claim about now

/// `verify` only corrects a number the text says is the current value. The
/// voice pipeline replaces each discrepancy's range before TTS, so a target,
/// another metric or a threshold rewritten to the live value would make the
/// coach say something false.
final class LiveClaimVerificationTests: XCTestCase {
    func testCurrentHeartRateClaimIsCorrectedWithoutItsLabel() {
        let text = "Your HR is 150 bpm, nice and steady."
        let found = MetricsVerifier.verify(text, against: context(hr: 162))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first.map { String(text[$0.range]) }, "150 bpm", "Only the value and unit are replaced")
        XCTAssertEqual(found.first?.actual, "162 bpm")
    }

    func testTargetsOtherMetricsAndThresholdsAreNotClaims() {
        let notClaims = [
            "Keep it under 150 bpm for this block.",
            "Your resting HR was 52 bpm this morning.",
            "Hold your HR around 150 bpm or lower.",
            "Ease off if α1 drops below 0.75.",
            "Aim for 220 W on the climbs."
        ]
        let snapshot = context(hr: 162, alpha1: 1.1, watts: 260)
        for text in notClaims {
            XCTAssertTrue(MetricsVerifier.verify(text, against: snapshot).isEmpty, "Rewrote a non-claim: \(text)")
        }
    }

    func testCurrentAlphaAndPowerClaimsAreStillChecked() {
        let snapshot = context(hr: nil, alpha1: 1.1, watts: 260)
        XCTAssertEqual(MetricsVerifier.verify("Your α1 is 0.62 right now.", against: snapshot).first?.metric, "alpha1")
        XCTAssertEqual(MetricsVerifier.verify("Your power is 180 W.", against: snapshot).first?.metric, "power_watts")
    }

    private func context(hr: Int?, alpha1: Double? = nil, watts: Int? = nil) -> WorkoutAIContext {
    WorkoutAIContext(
        sport: .run,
        nowAt: Date(),
        sessionStart: Date().addingTimeInterval(-600),
        elapsedSeconds: 600,
        heartRate: hr,
        peakHR: hr ?? 0,
        userMaxHR: 190,
        hrDriftPercent: nil,
        alpha1: alpha1,
        band: .unknown,
        alpha1FitQuality: nil,
        alpha1Status: .warmup(fractionReady: 0),
        distanceMeters: 2000,
        currentPaceSecPerKm: nil,
        currentSpeedMS: nil,
        cadenceStepsPerMin: nil,
        powerWatts: watts,
        footPodActive: false,
        currentMETs: nil,
        recentSplitPaces: [],
        currentLatitude: nil,
        currentLongitude: nil,
        currentAltitudeMeters: nil,
        currentHeadingDegrees: nil,
        gpsAccuracyMeters: nil,
        elevationGainMeters: 0,
        currentGradePercent: nil,
        upcomingClimb: nil,
        routeTopology: nil,
        weather: nil,
        strapConnected: false,
        strapSilentSec: nil,
        currentRoadName: nil,
        currentLocality: nil,
        currentAdministrativeArea: nil,
        currentCountryCode: nil,
        currentCompactAddress: nil,
        currentNearestCrossStreet: nil,
        currentNearestIntersection: nil,
        sessionAverageHR: nil,
        reverseSplitDeltaSecPerKm: nil,
        liveHRDriftPercent: nil,
        recentHRSlopeBpm: nil,
        aerobicDecouplingPercent: nil,
        cadenceDriftSpm: nil,
        gradeAdjustedPaceSecPerKm: nil,
        recentSplitGradeAdjustedPaces: [],
        projectedMinutesUntilFade: nil,
        historicalSportAvgPaceSecPerKm: nil,
        historicalSportAvgHR: nil,
        historicalSportAvgAlpha1: nil,
        historicalSportSampleCount: 0,
        todayRecoveryScore: nil,
        todayTrainingReadiness: nil,
        todayATL: nil,
        todayCTL: nil,
        todayTSB: nil,
        projectedDaysUntilFresh: nil,
        projectedTSBTomorrowSteadyState: nil,
        recoveryHoursNeeded: nil,
        zone1Sec: 0,
        zone2Sec: 0,
        zone3Sec: 0,
        zone4Sec: 0,
        zone5Sec: 0,
        dominantZone: nil,
        predictedRaceTime5KSec: nil,
        predictedRaceTime10KSec: nil,
        predictedRaceTimeHalfSec: nil,
        predictedRaceTimeMarathonSec: nil,
        userUnits: .metric,
        targetZone: nil,
        activeThresholds: [],
        thresholdBreachSec: [:]
    )
    }
}

/// Full range of a string literal.
///
/// These call sites read `"x".range(of: "x")!` — a string searched for itself,
/// which cannot fail. But a force-unwrap in a test target traps, and a trap
/// takes the whole test process down rather than failing one case, so the
/// provably-safe version is still the wrong shape here.
private func wholeRange(_ s: String) -> Range<String.Index> {
    s.startIndex ..< s.endIndex
}
