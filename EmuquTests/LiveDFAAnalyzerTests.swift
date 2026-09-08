@testable import Emuqu
import XCTest

/// Tests for the live DFA α1 artifact cleaning.
///
/// `LiveDFAAnalyzer` computes the
/// α1 value that drives the app's live training-zone guidance — "Easy",
/// "Threshold", "Hard" — so a wrong number tells someone mid-run to push when
/// they should back off. The cleaning below is what stands between a noisy
/// strap and that number: an ectopic beat left in the series drags α1 down and
/// makes an easy run read as hard.
final class LiveDFAAnalyzerTests: XCTestCase {
    /// A steady 60 bpm series.
    private func steady(_ count: Int, rr: Double = 1_000) -> [Double] {
        Array(repeating: rr, count: count)
    }

    // MARK: - Implausible beats

    func testBeatsFasterThan200BPMAreReplaced() {
        // 250 ms ≈ 240 bpm. No healthy heart produces that during exercise;
        // it is a double-count from a noisy strap.
        var rrs = steady(20)
        rrs[10] = 250
        let cleaned = LiveDFAAnalyzer.cleanRRForDFA(rrs).values
        XCTAssertNotEqual(cleaned[10], 250, "an implausibly fast beat must not survive")
        XCTAssertEqual(cleaned[10], 1_000, accuracy: 1, "it should interpolate to its neighbours")
    }

    func testBeatsSlowerThan30BPMAreReplaced() {
        // 2500 ms = 24 bpm — a missed beat, not a real one.
        var rrs = steady(20)
        rrs[10] = 2_500
        let cleaned = LiveDFAAnalyzer.cleanRRForDFA(rrs).values
        XCTAssertEqual(cleaned[10], 1_000, accuracy: 1)
    }

    // MARK: - Ectopic beats

    func testEctopicBeatBeyondTwentyPercentIsReplaced() {
        // A premature beat 30% short of the running median.
        var rrs = steady(20)
        rrs[12] = 700
        let cleaned = LiveDFAAnalyzer.cleanRRForDFA(rrs).values
        XCTAssertEqual(cleaned[12], 1_000, accuracy: 1, "a 30% deviation is ectopic")
    }

    func testNormalVariationIsPreserved() {
        // Real HRV: beats vary by a few percent and must NOT be scrubbed —
        // scrubbing genuine variability is what flattens α1 and makes a hard
        // effort read as easy.
        var rrs = steady(20)
        rrs[12] = 1_080  // 8% off — well within physiological variation
        let cleaned = LiveDFAAnalyzer.cleanRRForDFA(rrs).values
        XCTAssertEqual(cleaned[12], 1_080, accuracy: 0.01, "genuine HRV must survive cleaning")
    }

    // MARK: - Series shape

    func testCleaningPreservesSeriesLength() {
        // DFA window semantics depend on index positions; dropping a beat
        // instead of interpolating would shift every window after it.
        var rrs = steady(40)
        rrs[5] = 250
        rrs[20] = 2_400
        XCTAssertEqual(LiveDFAAnalyzer.cleanRRForDFA(rrs).values.count, 40)
    }

    func testShortSeriesIsReturnedUnchanged() {
        // Under 8 beats there is no reliable median to judge against.
        let rrs: [Double] = [1_000, 250, 1_000]
        XCTAssertEqual(LiveDFAAnalyzer.cleanRRForDFA(rrs).values, rrs)
    }

    func testEmptySeriesIsSafe() {
        XCTAssertEqual(LiveDFAAnalyzer.cleanRRForDFA([]).values, [])
    }

    // MARK: - Artifacts at the edges

    func testArtifactAtSeriesStartUsesTheFollowingCleanBeat() {
        var rrs = steady(20)
        rrs[0] = 250
        let cleaned = LiveDFAAnalyzer.cleanRRForDFA(rrs).values
        XCTAssertEqual(cleaned[0], 1_000, accuracy: 1, "no left neighbour — carry the right one back")
    }

    func testArtifactAtSeriesEndUsesThePrecedingCleanBeat() {
        var rrs = steady(20)
        rrs[19] = 2_400
        let cleaned = LiveDFAAnalyzer.cleanRRForDFA(rrs).values
        XCTAssertEqual(cleaned[19], 1_000, accuracy: 1, "no right neighbour — carry the left one forward")
    }

    func testConsecutiveArtifactsInterpolateAcrossTheGap() {
        var rrs = steady(20, rr: 1_000)
        rrs[9] = 250
        rrs[10] = 250
        rrs[11] = 250
        let cleaned = LiveDFAAnalyzer.cleanRRForDFA(rrs).values
        for i in 9 ... 11 {
            XCTAssertEqual(cleaned[i], 1_000, accuracy: 1, "beat \(i) should bridge the gap")
        }
    }

    // MARK: - No artifacts

    func testCleanSeriesIsUnchanged() {
        let rrs = (0 ..< 30).map { 950.0 + 30 * sin(Double($0) / 4) }
        let cleaned = LiveDFAAnalyzer.cleanRRForDFA(rrs).values
        for (a, b) in zip(rrs, cleaned) {
            XCTAssertEqual(a, b, accuracy: 0.001, "a clean series must pass through untouched")
        }
    }

    // MARK: - How much was corrected
    //
    // These exist because of a defect that survived for months in code
    // written specifically to detect it. Both callers of
    // `cleanRRForDFA` measured artifact load as `raw.count - cleaned.count`
    // while `testCleaningPreservesSeriesLength` above asserted, on purpose,
    // that cleaning cannot change the count. The subtraction was identically
    // zero, so the "too much artifact" guard could never fire and the
    // diagnostic log added to investigate over-correction at HR 150–170 could
    // only ever print `rejected=0 (0%)`.
    //
    // The lesson the tests encode: a quantity that is deliberately invariant
    // cannot also be the measurement. So every test below asserts the count
    // ALONGSIDE the invariant, never through it.

    func testCorrectionCountIsReportedIndependentlyOfLength() {
        // The regression, stated directly: length preserved AND corrections
        // visible, in the same assertion pair. Either one alone passes on the
        // broken implementation.
        var rrs = steady(20)
        rrs[5] = 250
        rrs[11] = 2_400
        rrs[15] = 700
        let cleaned = LiveDFAAnalyzer.cleanRRForDFA(rrs)
        XCTAssertEqual(cleaned.values.count, 20, "interpolation must preserve length")
        XCTAssertEqual(cleaned.correctedCount, 3, "and must still report what it corrected")
    }

    func testCorrectedFractionMatchesTheCorrectedShare() {
        var rrs = steady(20)
        rrs[4] = 250
        rrs[9] = 250
        let cleaned = LiveDFAAnalyzer.cleanRRForDFA(rrs)
        XCTAssertEqual(cleaned.correctedFraction, 0.10, accuracy: 0.0001)
    }

    func testCleanSeriesReportsNoCorrections() {
        let rrs = (0 ..< 30).map { 950.0 + 30 * sin(Double($0) / 4) }
        let cleaned = LiveDFAAnalyzer.cleanRRForDFA(rrs)
        XCTAssertEqual(cleaned.correctedCount, 0)
        XCTAssertEqual(cleaned.correctedFraction, 0, accuracy: 0.0001)
    }

    func testEmptySeriesFractionIsZeroNotNaN() {
        // `correctedFraction` is compared against a threshold. A NaN here would
        // make both `<=` and `>` false and send the caller down whichever
        // branch it happened to write first.
        let fraction = LiveDFAAnalyzer.cleanRRForDFA([]).correctedFraction
        XCTAssertFalse(fraction.isNaN)
        XCTAssertEqual(fraction, 0)
    }

    func testShortSeriesReportsNoCorrections() {
        // Under 8 beats the cleaner returns early without judging anything, so
        // it must not claim to have corrected anything either.
        let cleaned = LiveDFAAnalyzer.cleanRRForDFA([1_000, 250, 1_000])
        XCTAssertEqual(cleaned.correctedCount, 0)
    }

    // MARK: - The rejection thresholds

    func testRejectionThresholdsMatchThePublishedBias() {
        // Gronwald & Rogers 2022 (Front. Physiol. 13:879071): artifact
        // correction biases α1 minimally below 3 %, with negligible shift in
        // the derived threshold even at 6 %. Pinning them here means moving a
        // threshold requires saying so, rather than drifting.
        XCTAssertEqual(LiveDFAAnalyzer.lowConfidenceCorrectedFraction, 0.03, accuracy: 0.0001)
        XCTAssertEqual(LiveDFAAnalyzer.maxCorrectedFraction, 0.06, accuracy: 0.0001)
    }

    func testAHeavilyCorruptedWindowExceedsTheRejectionThreshold() {
        // Every fourth beat implausible: 25 % corrected, four times the
        // rejection threshold. Accounting that misses these corrections
        // reports 0 % and publishes the window's α1 as if clean.
        var rrs = steady(40)
        for i in stride(from: 0, to: 40, by: 4) { rrs[i] = 250 }
        let cleaned = LiveDFAAnalyzer.cleanRRForDFA(rrs)
        XCTAssertEqual(cleaned.correctedCount, 10)
        XCTAssertGreaterThan(cleaned.correctedFraction, LiveDFAAnalyzer.maxCorrectedFraction)
    }

    func testARealisticStrapGlitchStaysUnderTheRejectionThreshold() {
        // One dropped beat in 100 is 1 % — normal strap behaviour, well inside
        // the band where correction is known not to bias α1. Guards against a
        // threshold set so tight that ordinary sessions stop reporting α1.
        var rrs = steady(100)
        rrs[50] = 2_400
        let cleaned = LiveDFAAnalyzer.cleanRRForDFA(rrs)
        XCTAssertEqual(cleaned.correctedCount, 1)
        XCTAssertLessThan(cleaned.correctedFraction, LiveDFAAnalyzer.lowConfidenceCorrectedFraction)
    }

    // MARK: - The two-minute gate
    //
    // `recompute` requires the rolling window to SPAN two minutes, not just to
    // hold 64 beats — at HR 160 those arrive in about 24 s, and every comment
    // in the analyzer (and the offline re-analyzer that claims to reproduce it)
    // says two minutes.
    //
    // The gate is easy to write one comparison too strictly. `trimToWindow`
    // drops beats strictly older than the cutoff, so the oldest RETAINED beat
    // sits up to one RR interval after it and the span never quite reaches
    // `windowSec`. A bare `>= windowSec` test compiles, passes every existing
    // test, and silently means α1 never appears in a real workout. These two
    // pin both sides of it.

    @MainActor
    func testAlpha1IsNotProducedBeforeTheWindowIsFull() {
        let analyzer = LiveDFAAnalyzer()
        let start = Date()
        analyzer.reset(sessionStart: start)
        // 80 beats at 400 ms — over the 64-beat minimum, but only 32 s of data.
        // This is the HR-160 case: enough beats, nowhere near enough time.
        let points = (1 ... 80).map { RRPoint(t_ms: Int64($0) * 400, rr_ms: 400) }
        analyzer.ingest(points: points, now: start.addingTimeInterval(32))
        XCTAssertNil(analyzer.currentAlpha1, "64 beats is not two minutes at 150 bpm")
        XCTAssertLessThan(analyzer.bufferFillFraction, 1.0)
    }

    @MainActor
    func testAlpha1IsProducedOnceTheWindowIsFull() {
        let analyzer = LiveDFAAnalyzer()
        let start = Date()
        analyzer.reset(sessionStart: start)
        // 130 s of physiologically-plausible beats: ~1000 ms with a few percent
        // of variation, well inside the ±20 % ectopic filter.
        var points: [RRPoint] = []
        var t: Int64 = 0
        var i = 0
        while t < 130_000 {
            let rr = 1_000 + Int(30 * sin(Double(i) / 4))
            t += Int64(rr)
            points.append(RRPoint(t_ms: t, rr_ms: rr))
            i += 1
        }
        analyzer.ingest(points: points, now: start.addingTimeInterval(130))
        XCTAssertEqual(analyzer.bufferFillFraction, 1.0, accuracy: 0.001,
                       "a window holding 120 s of beats must read as full")
        XCTAssertNotNil(analyzer.currentAlpha1,
                        "with a full window and a clean series, α1 must be produced")
    }
}
