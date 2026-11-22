@testable import Emuqu
import XCTest

/// Tests for ECG-derived respiration rate analysis
final class RespirationAnalysisTests: XCTestCase {
    // MARK: - Minimum Data Requirements

    func testInsufficientDataReturnsNil() {
        // Fewer than 60 samples should return nil
        let shortRR = Array(repeating: 800.0, count: 59)

        let result = RespirationAnalyzer.estimateRespirationRate(shortRR)

        XCTAssertNil(result, "Should return nil for <60 samples")
    }

    /// Sixty beats, the minimum, are analysed: a 15 breaths/min modulation
    /// over exactly 60 beats (48 s) is found, where 59 beats return nil above.
    func testExactMinimumDataProcesses() throws {
        let rr = (0 ..< 60).map { 800.0 + 30.0 * sin(2.0 * .pi * 0.25 * Double($0) * 0.8) }

        let rate = try XCTUnwrap(RespirationAnalyzer.estimateRespirationRate(rr),
                                 "60 beats is the minimum the estimator analyses")
        XCTAssertEqual(rate, 15.0, accuracy: 3.0)
    }

    // MARK: - Known Respiratory Frequency

    func testDetects15BreathsPerMinute() throws {
        // Create RR series with 0.25 Hz modulation (15 breaths/min)
        // RR varies sinusoidally: 800ms ± 30ms at respiratory frequency
        let fs = 4.0 // Resampling rate
        let respiratoryFreq = 0.25 // Hz = 15 breaths/min
        let count = 240 // 60 seconds of data at ~4 Hz sampling

        var rr = [Double]()
        var t = 0.0
        for _ in 0 ..< count {
            let modulation = 30.0 * sin(2.0 * .pi * respiratoryFreq * t)
            rr.append(800.0 + modulation)
            t += 0.8 // ~800ms per beat
        }

        let result = RespirationAnalyzer.estimateRespirationRate(rr, fs: fs)

        // 0.25 Hz sits inside the 0.15-0.5 Hz search band, so a rate comes back.
        let rate = try XCTUnwrap(result, "A clean 15 breaths/min modulation must be detected")
        XCTAssertEqual(rate, 15.0, accuracy: 3.0, "Detected respiration rate should be close to 15 bpm")
    }

    func testDetects12BreathsPerMinute() throws {
        // 0.2 Hz = 12 breaths/min
        let respiratoryFreq = 0.2
        let count = 300

        var rr = [Double]()
        var t = 0.0
        for _ in 0 ..< count {
            let modulation = 40.0 * sin(2.0 * .pi * respiratoryFreq * t)
            rr.append(900.0 + modulation)
            t += 0.9
        }

        let result = RespirationAnalyzer.estimateRespirationRate(rr)

        let rate = try XCTUnwrap(result, "A clean 12 breaths/min modulation must be detected")
        XCTAssertEqual(rate, 12.0, accuracy: 3.0)
    }

    // MARK: - Sanity Check Boundaries

    func testRejectsImplausiblyLowRate() {
        // Frequency below 0.1 Hz = 6 bpm — should be rejected or filtered
        // A signal with only very low frequency modulation
        let count = 300
        var rr = [Double]()
        var t = 0.0
        for _ in 0 ..< count {
            // Very slow modulation at 0.05 Hz = 3 bpm
            let modulation = 50.0 * sin(2.0 * .pi * 0.05 * t)
            rr.append(800.0 + modulation)
            t += 0.8
        }

        let result = RespirationAnalyzer.estimateRespirationRate(rr)

        // The band's largest bin is leakage from the slow rhythm (8.9 at the
        // band's edge, a millionth of its power), not breathing.
        XCTAssertNil(result, "a 3 breaths/min modulation was reported as \(result.map { String($0) } ?? "nil") breaths/min")
    }

    /// Beat-to-beat noise with no breathing in it has a largest bin like any
    /// spectrum; that is not a breathing rate.
    func testNoiseWithoutBreathingReturnsNil() {
        var state: UInt64 = 12_345
        func uniform() -> Double {
            state = (1_103_515_245 &* state &+ 12_345) % 2_147_483_648
            return Double(state) / 2_147_483_648
        }
        // Sum of 12 uniforms minus 6: approximately normal, unit variance.
        let rr = (0 ..< 360).map { _ in 950.0 + 40.0 * ((0 ..< 12).reduce(0.0) { sum, _ in sum + uniform() } - 6.0) }

        XCTAssertNil(RespirationAnalyzer.estimateRespirationRate(rr))
    }

    /// The estimator reports only rates inside its 9-30 breaths/min search
    /// band. A 0.8 Hz (48/min) modulation sampled once per 0.8 s beat
    /// (1.25 Hz) aliases to 0.45 Hz, inside the band, so a rate comes back,
    /// and it is the band's, never one above 40.
    func testRejectsImplausiblyHighRate() throws {
        let rr = (0 ..< 300).map { 800.0 + 20.0 * sin(2.0 * .pi * 0.8 * Double($0) * 0.8) }

        let rate = try XCTUnwrap(RespirationAnalyzer.estimateRespirationRate(rr))
        XCTAssertTrue((9.0 ... 30.0).contains(rate), "A rate outside the search band was reported: \(rate)")
    }

    // MARK: - Constant Signal

    func testConstantSignalReturnsNil() {
        // Perfectly constant RR has no respiratory modulation
        let rr = Array(repeating: 800.0, count: 200)

        let result = RespirationAnalyzer.estimateRespirationRate(rr)

        // Constant signal → peak power is 0 everywhere in the respiratory
        // band, so there is no breathing to report.
        XCTAssertNil(result, "No respiratory modulation, no rate")
    }

    // MARK: - Resampling Edge Cases

    func testVeryShortSeriesForResampling() {
        // 3 points — below the resampling minimum of 4
        let rr = [800.0, 810.0, 790.0]

        // Should not crash, should return nil
        let result = RespirationAnalyzer.estimateRespirationRate(rr)
        XCTAssertNil(result)
    }
}
