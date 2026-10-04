@testable import Emuqu
import Foundation
import XCTest

/// Tests for `SessionAcceptanceService.classifyHRVQuality` — the decision that
/// says whether to trust a night's HRV or fall back to the user's baseline.
///
/// Getting it wrong is not cosmetic — a night
/// wrongly marked `.insufficient` silently replaces a real reading with the
/// baseline, and the user sees a recovery score that has nothing to do with how
/// they actually slept.
///
/// The four rules, in the order the function applies them:
///   1. Insufficient data (short window, or no organised recovery in a short
///      session) *and* below baseline → `.insufficient`, use baseline
///   2. No overlap with sleep → `.preSleep`, use baseline
///   3. Overlaps sleep, and either at/above baseline or long enough → `.good`
///   4. Overlaps sleep, short, below baseline → `.insufficient`, use baseline
@MainActor
final class SessionAcceptanceQualityTests: XCTestCase {
    // MARK: - Fixtures

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// A baseline whose RMSSD works out to `rmssd` (the classifier exponentiates
    /// `lnRmssdMean`, so the fixture takes the log).
    private func baseline(rmssd: Double) -> BaselineTracker.RecoveryBaselineStats {
        BaselineTracker.RecoveryBaselineStats(
            lnRmssdMean: log(rmssd),
            lnRmssdSD: 0.2,
            lnRmssdCV7Day: nil,
            meanHRBaseline: 55,
            meanHRSD: 3,
            daysInWindow: 30,
            lastDataPointDate: nil
        )
    }

    private func result(
        rmssd: Double,
        windowMs: Int64?,
        organizedRecovery: Bool?
    ) -> HRVAnalysisResult {
        var r = HRVAnalysisResult(
            windowStart: 0,
            windowEnd: 600_000,
            timeDomain: TimeDomainMetrics(
                meanRR: 1_000, sdnn: rmssd * 1.2, rmssd: rmssd, pnn50: 20,
                sdsd: rmssd * 0.95, meanHR: 60, sdHR: 3, triangularIndex: 12
            ),
            frequencyDomain: nil,
            nonlinear: NonlinearMetrics(
                sd1: rmssd * 0.7, sd2: rmssd * 1.1, sd1Sd2Ratio: 0.64,
                sampleEntropy: 1.5, approxEntropy: 1.2,
                dfaAlpha1: 0.95, dfaAlpha2: 0.85, dfaAlpha1R2: 0.95
            ),
            ansMetrics: nil,
            artifactPercentage: 2,
            cleanBeatCount: 500,
            analysisDate: start
        )
        r.isOrganizedRecovery = organizedRecovery
        if let windowMs {
            r.windowStartMs = 0
            r.windowEndMs = windowMs
        }
        return r
    }

    /// Sleep spanning the given offsets from `start`, in hours.
    private func sleep(fromHour: Double, toHour: Double) -> SleepData {
        SleepData(
            date: start,
            sleepStart: start.addingTimeInterval(fromHour * 3600),
            sleepEnd: start.addingTimeInterval(toHour * 3600),
            totalSleepMinutes: Int((toHour - fromHour) * 60),
            inBedMinutes: Int((toHour - fromHour) * 60),
            awakeMinutes: 0,
            sleepEfficiency: 95,
            boundarySource: .healthKit
        )
    }

    private func classify(
        rmssd: Double,
        baselineRmssd: Double?,
        durationHours: Double,
        windowMs: Int64? = 600_000,
        organizedRecovery: Bool? = true,
        sleepData: SleepData?
    ) -> SessionAcceptanceService.HRVQualityDecision {
        SessionAcceptanceService.classifyHRVQuality(
            result: result(rmssd: rmssd, windowMs: windowMs, organizedRecovery: organizedRecovery),
            sleepData: sleepData,
            baselineStats: baselineRmssd.map { baseline(rmssd: $0) },
            recordingStart: start,
            recordingEnd: start.addingTimeInterval(durationHours * 3600)
        )
    }

    // MARK: - Rule 3: the normal good night

    func testOvernightAboveBaselineIsTrusted() {
        let d = classify(
            rmssd: 55, baselineRmssd: 45, durationHours: 8,
            sleepData: sleep(fromHour: 0.5, toHour: 7.5)
        )
        XCTAssertEqual(d.dataQuality, .good)
        XCTAssertFalse(d.useBaselineHRV)
    }

    func testLongSessionBelowBaselineIsStillTrusted() {
        // A genuinely bad night is data, not an error. Over the 3-hour
        // threshold the low reading is believed rather than replaced.
        let d = classify(
            rmssd: 30, baselineRmssd: 45, durationHours: 8,
            sleepData: sleep(fromHour: 0.5, toHour: 7.5)
        )
        XCTAssertEqual(d.dataQuality, .good)
        XCTAssertFalse(d.useBaselineHRV)
    }

    func testShortSessionAtOrAboveBaselineIsTrusted() {
        // Short but healthy: the reading agrees with the baseline, so there is
        // no reason to distrust it.
        let d = classify(
            rmssd: 45, baselineRmssd: 45, durationHours: 1,
            sleepData: sleep(fromHour: 0.1, toHour: 0.9)
        )
        XCTAssertEqual(d.dataQuality, .good)
        XCTAssertFalse(d.useBaselineHRV)
    }

    // MARK: - Rule 2: no overlap with sleep

    func testRecordingBeforeSleepFallsBackToBaseline() {
        // Strap on, then taken off before actually falling asleep.
        let d = classify(
            rmssd: 55, baselineRmssd: 45, durationHours: 1,
            sleepData: sleep(fromHour: 3, toHour: 10)
        )
        XCTAssertEqual(d.dataQuality, .preSleep)
        XCTAssertTrue(d.useBaselineHRV)
    }

    func testRecordingAfterSleepFallsBackToBaseline() {
        let d = classify(
            rmssd: 55, baselineRmssd: 45, durationHours: 1,
            sleepData: SleepData(
                date: start,
                sleepStart: start.addingTimeInterval(-8 * 3600),
                sleepEnd: start.addingTimeInterval(-1 * 3600),
                totalSleepMinutes: 420, inBedMinutes: 420,
                awakeMinutes: 0, sleepEfficiency: 95, boundarySource: .healthKit
            )
        )
        XCTAssertEqual(d.dataQuality, .preSleep)
        XCTAssertTrue(d.useBaselineHRV)
    }

    func testMissingSleepDataIsTreatedAsOverlapping() {
        // Without sleep data there is no way to know, and the documented
        // choice is to trust the HRV rather than discard it.
        let d = classify(
            rmssd: 55, baselineRmssd: 45, durationHours: 8, sleepData: nil
        )
        XCTAssertEqual(d.dataQuality, .good)
        XCTAssertFalse(d.useBaselineHRV)
    }

    // MARK: - Rule 1: insufficient data

    func testShortAnalysisWindowBelowBaselineIsInsufficient() {
        // Strap died mid-window: under 5 minutes of analysis and below
        // baseline, so the number is not worth trusting.
        let d = classify(
            rmssd: 30, baselineRmssd: 45, durationHours: 8,
            windowMs: 60_000,
            sleepData: sleep(fromHour: 0.5, toHour: 7.5)
        )
        XCTAssertEqual(d.dataQuality, .insufficient)
        XCTAssertTrue(d.useBaselineHRV)
    }

    func testShortAnalysisWindowAboveBaselineIsStillTrusted() {
        // The sufficiency check only bites when the reading is ALSO below
        // baseline — a short window agreeing with history is believed.
        let d = classify(
            rmssd: 55, baselineRmssd: 45, durationHours: 8,
            windowMs: 60_000,
            sleepData: sleep(fromHour: 0.5, toHour: 7.5)
        )
        XCTAssertEqual(d.dataQuality, .good)
        XCTAssertFalse(d.useBaselineHRV)
    }

    func testNoOrganizedRecoveryInShortSessionBelowBaselineIsInsufficient() {
        // Never reached the recovery zone, session under 3 hours, below
        // baseline: the reading reflects a failed recording, not a bad night.
        let d = classify(
            rmssd: 30, baselineRmssd: 45, durationHours: 1,
            organizedRecovery: false,
            sleepData: sleep(fromHour: 0.1, toHour: 0.9)
        )
        XCTAssertEqual(d.dataQuality, .insufficient)
        XCTAssertTrue(d.useBaselineHRV)
    }

    // MARK: - Rule 4: ambiguous short night

    func testShortSessionBelowBaselineIsAmbiguous() {
        let d = classify(
            rmssd: 30, baselineRmssd: 45, durationHours: 1,
            sleepData: sleep(fromHour: 0.1, toHour: 0.9)
        )
        XCTAssertEqual(d.dataQuality, .insufficient)
        XCTAssertTrue(d.useBaselineHRV)
    }

    // MARK: - No baseline yet

    func testWithoutABaselineNothingIsBelowIt() {
        // A brand-new user has no baseline; it reads as 0, so no reading can be
        // "below" it and the sufficiency checks can never fire. First nights are
        // taken at face value rather than discarded.
        let d = classify(
            rmssd: 20, baselineRmssd: nil, durationHours: 0.5,
            windowMs: 30_000, organizedRecovery: false,
            sleepData: sleep(fromHour: 0.05, toHour: 0.4)
        )
        XCTAssertEqual(d.dataQuality, .good)
        XCTAssertFalse(d.useBaselineHRV)
    }

    // MARK: - Threshold boundaries

    func testThreeHourSessionIsLongEnoughToTrust() {
        // The overnight threshold is 10,800 s exactly; at the boundary the
        // reading is trusted.
        let d = classify(
            rmssd: 30, baselineRmssd: 45, durationHours: 3,
            sleepData: sleep(fromHour: 0.1, toHour: 2.9)
        )
        XCTAssertEqual(d.dataQuality, .good)
        XCTAssertFalse(d.useBaselineHRV)
    }

    func testJustUnderThreeHoursBelowBaselineIsNotTrusted() {
        let d = classify(
            rmssd: 30, baselineRmssd: 45, durationHours: 2.99,
            sleepData: sleep(fromHour: 0.1, toHour: 2.9)
        )
        XCTAssertEqual(d.dataQuality, .insufficient)
        XCTAssertTrue(d.useBaselineHRV)
    }

    func testFiveMinuteWindowIsTheReliabilityBoundary() {
        // 300,000 ms is the minimum reliable window; at it, the reading stands.
        let d = classify(
            rmssd: 30, baselineRmssd: 45, durationHours: 8,
            windowMs: 300_000,
            sleepData: sleep(fromHour: 0.5, toHour: 7.5)
        )
        XCTAssertEqual(d.dataQuality, .good)
        XCTAssertFalse(d.useBaselineHRV)
    }
}
