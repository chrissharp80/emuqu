@testable import Emuqu
import XCTest

/// Pass 1 unit tests for `BeatConsistency`. the minimum set, plus
/// supporting tests for the statistics helpers. No UI / persistence
/// touched — these only exercise the pure-math module.
final class BeatConsistencyTests: XCTestCase {
    // MARK: - Synthetic RR helpers

    /// Build an RR series at `meanMs` average plus optional jitter,
    /// cumulative `t_ms` advancing by each interval. Spans roughly
    /// `count * meanMs` ms.
    private func makeRR(count: Int, meanMs: Int, jitterMs: Int = 0) -> [RRPoint] {
        var t: Int64 = 0
        var generator = SystemRandomNumberGenerator()
        var rrs: [RRPoint] = []
        rrs.reserveCapacity(count)
        for _ in 0..<count {
            let jitter = jitterMs > 0 ? Int.random(in: -jitterMs...jitterMs, using: &generator) : 0
            let rr = max(300, meanMs + jitter)
            rrs.append(RRPoint(t_ms: t, rr_ms: rr))
            t += Int64(rr)
        }
        return rrs
    }

    /// Synthetic baseline at a known center / scale per feature, with
    /// `nights` accepted nights. Used to build a Baseline without
    /// running the analyzer in a loop.
    private func makeBaseline(
        nights: Int,
        pNN50: Double, cvRR: Double, ratio: Double,
        scalePNN50: Double, scaleCVRR: Double, scaleRatio: Double
    ) -> BeatConsistency.Baseline {
        BeatConsistency.Baseline(
            center: .init(pNN50: pNN50, cvRR: cvRR, ratio: ratio),
            scale: .init(pNN50: scalePNN50, cvRR: scaleCVRR, ratio: scaleRatio),
            acceptedNightCount: nights
        )
    }

    // MARK: - Minimum set

    /// Perfectly-regular RR (constant interval) → pNN50 = 0, cvRR = 0,
    /// SD1 ≈ 0, score = 100, band Consistent.
    func testPerfectlyRegularRRScoresMaxConsistent() throws {
        // 8h of 1000ms beats. Sleep window covers all of it.
        let rr = makeRR(count: 28_800, meanMs: 1000)
        let baseline = makeBaseline(
            nights: 30,
            pNN50: 5, cvRR: 0.03, ratio: 0.4,
            scalePNN50: 2.0, scaleCVRR: 0.01, scaleRatio: 0.03
        )
        let result = BeatConsistency.score(
            rr: rr, flags: [],
            sleepStartMs: 0, sleepEndMs: try XCTUnwrap(rr.last).t_ms,
            baseline: baseline
        )
        XCTAssertEqual(result.state, .normal)
        XCTAssertEqual(result.score, 100)
        XCTAssertEqual(result.band, .consistent)
        XCTAssertEqual(result.fracHigh.pNN50, 0)
        XCTAssertEqual(result.fracHigh.cvRR, 0)
        XCTAssertEqual(result.fracHigh.ratio, 0)
    }

    /// High-dispersion RR → low score, band Notably Variable.
    func testHighDispersionScoresLowAndNotablyVariable() throws {
        // 8h with ±400ms jitter on every beat — very irregular,
        // pNN50 blows out, ratio approaches 1 (cloud shape).
        let rr = makeRR(count: 28_800, meanMs: 1000, jitterMs: 400)
        let baseline = makeBaseline(
            nights: 30,
            pNN50: 5, cvRR: 0.03, ratio: 0.4,
            scalePNN50: 2.0, scaleCVRR: 0.01, scaleRatio: 0.03
        )
        let result = BeatConsistency.score(
            rr: rr, flags: [],
            sleepStartMs: 0, sleepEndMs: try XCTUnwrap(rr.last).t_ms,
            baseline: baseline
        )
        XCTAssertEqual(result.state, .normal)
        guard let score = result.score, let band = result.band else {
            return XCTFail("expected a score and band")
        }
        XCTAssertLessThan(score, 60, "high-dispersion night should fall in Notably Variable")
        XCTAssertEqual(band, .notablyVariable)
    }

    /// Windowing: a known RR series produces the expected count of
    /// valid scoring windows; windows straddling an injected gap are
    /// rejected.
    func testWindowingProducesExpectedScoringCountAndRejectsGappedWindows() throws {
        // 10 minutes of clean 1000ms beats = 600 intervals = 20 valid
        // scoring windows expected.
        let rr = makeRR(count: 600, meanMs: 1000)
        let baseline = makeBaseline(
            nights: 30,
            pNN50: 5, cvRR: 0.03, ratio: 0.4,
            scalePNN50: 2.0, scaleCVRR: 0.01, scaleRatio: 0.03
        )
        let clean = BeatConsistency.score(
            rr: rr, flags: [],
            sleepStartMs: 0, sleepEndMs: try XCTUnwrap(rr.last).t_ms + 1,
            baseline: baseline
        )
        XCTAssertEqual(clean.scoringWindowCount, 20)

        // Now inject a 5-second gap by jumping `t_ms` forward in the
        // middle of the series. The window that straddles this gap
        // has too few intervals on each side AND/OR a span that
        // exceeds 32s, so it is rejected.
        var gapped = rr
        let gapAt = gapped.count / 2
        let gapStartT = gapped[gapAt].t_ms
        for i in gapAt..<gapped.count {
            let p = gapped[i]
            gapped[i] = RRPoint(t_ms: p.t_ms + 5_000, rr_ms: p.rr_ms, wallClockMs: p.wallClockMs)
        }
        let withGap = BeatConsistency.score(
            rr: gapped, flags: [],
            sleepStartMs: 0, sleepEndMs: try XCTUnwrap(gapped.last).t_ms + 1,
            baseline: baseline
        )
        // At least one window must have been rejected — the one
        // covering the gap. Span widens past tolerance OR the window
        // ends up nearly empty depending on alignment.
        XCTAssertLessThan(withGap.scoringWindowCount, clean.scoringWindowCount,
            "gap at t=\(gapStartT)ms should reduce valid window count")
    }

    /// Calibration gate: 13 / 14 / 27 / 28 accepted nights →
    /// Calibrating / Low Confidence / Low Confidence / Normal.
    func testCalibrationGateThresholds() throws {
        let rr = makeRR(count: 600, meanMs: 1000)
        let sleepEnd = try XCTUnwrap(rr.last).t_ms + 1

        // 13 nights → Calibrating (no score)
        let b13 = makeBaseline(
            nights: 13, pNN50: 5, cvRR: 0.03, ratio: 0.4,
            scalePNN50: 2.0, scaleCVRR: 0.01, scaleRatio: 0.03
        )
        let r13 = BeatConsistency.score(
            rr: rr, flags: [], sleepStartMs: 0, sleepEndMs: sleepEnd, baseline: b13
        )
        XCTAssertEqual(r13.state, .calibrating(nightsCollected: 13, nightsNeeded: 14))
        XCTAssertNil(r13.score)
        XCTAssertNil(r13.band)

        // 14 → Low Confidence
        let b14 = makeBaseline(
            nights: 14, pNN50: 5, cvRR: 0.03, ratio: 0.4,
            scalePNN50: 2.0, scaleCVRR: 0.01, scaleRatio: 0.03
        )
        let r14 = BeatConsistency.score(
            rr: rr, flags: [], sleepStartMs: 0, sleepEndMs: sleepEnd, baseline: b14
        )
        XCTAssertEqual(r14.state, .lowConfidence(nightsCollected: 14))
        XCTAssertNotNil(r14.score)

        // 27 → still Low Confidence
        let b27 = makeBaseline(
            nights: 27, pNN50: 5, cvRR: 0.03, ratio: 0.4,
            scalePNN50: 2.0, scaleCVRR: 0.01, scaleRatio: 0.03
        )
        let r27 = BeatConsistency.score(
            rr: rr, flags: [], sleepStartMs: 0, sleepEndMs: sleepEnd, baseline: b27
        )
        XCTAssertEqual(r27.state, .lowConfidence(nightsCollected: 27))

        // 28 → Normal
        let b28 = makeBaseline(
            nights: 28, pNN50: 5, cvRR: 0.03, ratio: 0.4,
            scalePNN50: 2.0, scaleCVRR: 0.01, scaleRatio: 0.03
        )
        let r28 = BeatConsistency.score(
            rr: rr, flags: [], sleepStartMs: 0, sleepEndMs: sleepEnd, baseline: b28
        )
        XCTAssertEqual(r28.state, .normal)
    }

    /// Data floor: 19 valid windows → Insufficient Data; 20 → scored.
    func testInsufficientDataAtNineteenWindowsScoredAtTwenty() throws {
        let baseline = makeBaseline(
            nights: 30, pNN50: 5, cvRR: 0.03, ratio: 0.4,
            scalePNN50: 2.0, scaleCVRR: 0.01, scaleRatio: 0.03
        )

        // 19 windows = 19 * 30s = 570s = 570 beats at 1000ms.
        let rr19 = makeRR(count: 570, meanMs: 1000)
        let r19 = BeatConsistency.score(
            rr: rr19, flags: [],
            sleepStartMs: 0, sleepEndMs: try XCTUnwrap(rr19.last).t_ms + 1,
            baseline: baseline
        )
        if case .insufficientData(let count) = r19.state {
            XCTAssertEqual(count, 19)
            XCTAssertNil(r19.score)
        } else {
            XCTFail("expected insufficientData, got \(r19.state)")
        }

        // 20 windows = 600 beats.
        let rr20 = makeRR(count: 600, meanMs: 1000)
        let r20 = BeatConsistency.score(
            rr: rr20, flags: [],
            sleepStartMs: 0, sleepEndMs: try XCTUnwrap(rr20.last).t_ms + 1,
            baseline: baseline
        )
        XCTAssertEqual(r20.state, .normal)
        XCTAssertNotNil(r20.score)
    }

    /// Winsorized MAD: one extreme outlier night should NOT inflate
    /// the scale term substantially (proves winsorization works).
    func testWinsorizedMADAbsorbsOutlier() {
        let normal = Array(repeating: 5.0, count: 55) + [5.0]   // 56 entries, all 5
        let withOutlier = Array(repeating: 5.0, count: 55) + [500.0] // one wild
        let madNormal = BeatConsistency.winsorizedMAD(normal, low: 0.10, high: 0.90)
        let madOutlier = BeatConsistency.winsorizedMAD(withOutlier, low: 0.10, high: 0.90)
        // The outlier gets clipped to the 90th percentile (which is
        // 5.0 in this sample), so the MAD is identical (both 0).
        XCTAssertEqual(madNormal, madOutlier, accuracy: 1e-9,
            "winsorization should clip the outlier — MAD unchanged")
    }

    /// Scale floor: a hyper-regular user (MAD ≈ 0) gets the per-
    /// feature floor as their effective scale, so normal windows
    /// don't trip the high test.
    func testScaleFloorHoldsThresholdOpenForHyperRegularUser() throws {
        // Build a baseline from 30 identical "perfect" nights.
        let priors = Array(repeating: BeatConsistency.Features(pNN50: 1.0, cvRR: 0.005, ratio: 0.2), count: 30)
        let baseline = try XCTUnwrap(BeatConsistency.buildBaseline(priorNights: priors))
        // Without the floor, scale would be 0 → any window above
        // center would flag. WITH the floor, scale = (2.0, 0.01, 0.03)
        XCTAssertEqual(baseline.scale.pNN50, 2.0, accuracy: 1e-9)
        XCTAssertEqual(baseline.scale.cvRR, 0.01, accuracy: 1e-9)
        XCTAssertEqual(baseline.scale.ratio, 0.03, accuracy: 1e-9)

        // Now score a perfectly-regular night. Per-window features
        // should be ≈ 0, well below center + k*scale, so frac_high
        // for every feature is 0 → score 100.
        let rr = makeRR(count: 600, meanMs: 1000)
        let result = BeatConsistency.score(
            rr: rr, flags: [],
            sleepStartMs: 0, sleepEndMs: try XCTUnwrap(rr.last).t_ms + 1,
            baseline: baseline
        )
        XCTAssertEqual(result.score, 100,
            "perfectly-regular night should score 100 — scale floor must hold the threshold open")
    }

    /// SD2 degenerate path: an RR series that yields `2*var - SD1^2 ≤ 0`
    /// returns ratio = 0, no NaN, no crash.
    func testSD2DegenerateReturnsZeroRatio() {
        // Identical RR values → variance = 0 → SD1 = 0 → SD2 = 0.
        // Our code path: sd2Squared = 0, sd2 = 0, ratio = 0.
        let rrIntervals = Array(repeating: 1000, count: 60)
        let f = BeatConsistency.computeFeatures(rrIntervals: rrIntervals)
        XCTAssertEqual(f.pNN50, 0)
        XCTAssertEqual(f.cvRR, 0)
        XCTAssertEqual(f.ratio, 0)
        XCTAssertFalse(f.ratio.isNaN)
    }

    // MARK: - Supporting tests for the statistics helpers

    func testMedianOddAndEvenCounts() {
        XCTAssertEqual(BeatConsistency.median([3, 1, 2]), 2)
        XCTAssertEqual(BeatConsistency.median([1, 2, 3, 4]), 2.5)
        XCTAssertEqual(BeatConsistency.median([7]), 7)
        XCTAssertEqual(BeatConsistency.median([]), 0)
    }

    func testFeaturesComputeForKnownInput() {
        // Synthetic [800, 850, 900, 850, 800] (5 intervals, steps of
        // exactly 50 ms). pNN50 should be 0 (diffs == 50, not > 50).
        // cvRR small, ratio defined.
        //
        // Not the alternating series [800, 850, 800, 850,
        // 800], which is DEGENERATE under the module's documented
        // population-variance convention ("population stddev,
        // consistent across all three features"): population var = 600,
        // SD1² = 1250, so SD2² = 2·600 − 1250 = −50 ≤ 0 → ratio
        // clamps to 0 by the degenerate rule and the `ratio > 0`
        // assertion below could never pass. A ramp keeps every
        // assertion's intent (diffs still exactly 50) without the
        // alternation that maximizes SD1 against SD2.
        let rr = [800, 850, 900, 850, 800]
        let f = BeatConsistency.computeFeatures(rrIntervals: rr)
        XCTAssertEqual(f.pNN50, 0, accuracy: 1e-9,
            "pNN50 counts diffs STRICTLY > 50; |850-800|=50 should NOT count")
        XCTAssertGreaterThan(f.cvRR, 0)
        XCTAssertGreaterThan(f.ratio, 0)
    }

    func testPNN50CountsOnlyDiffsStrictlyAbove50() {
        // [1000, 1060, 1000] — one diff of 60 ms, one of 60 ms.
        let f = BeatConsistency.computeFeatures(rrIntervals: [1000, 1060, 1000])
        // 2 diffs, both > 50 → pNN50 = 100%
        XCTAssertEqual(f.pNN50, 100, accuracy: 1e-9)
    }
}
