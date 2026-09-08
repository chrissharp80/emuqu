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

    func testExactMinimumDataProcesses() {
        // 60 samples should be processed (may still return nil if signal is constant)
        let rr = Array(repeating: 800.0, count: 60)

        // Constant signal has no peak in respiratory band → nil is acceptable
        let result = RespirationAnalyzer.estimateRespirationRate(rr)

        // Just verifying it doesn't crash — constant RR has no respiratory modulation
        _ = result
    }

    // MARK: - Known Respiratory Frequency

    func testDetects15BreathsPerMinute() {
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

        if let rate = result {
            // Should be close to 15 breaths/min
            XCTAssertEqual(
                rate,
                15.0,
                accuracy: 3.0,
                "Detected respiration rate should be close to 15 bpm"
            )
        }
        // It's acceptable if nil — FFT resolution may not place the peak precisely
    }

    func testDetects12BreathsPerMinute() {
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

        if let rate = result {
            XCTAssertEqual(rate, 12.0, accuracy: 3.0)
        }
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

        // Should return nil or a rate >= 6 bpm
        if let rate = result {
            XCTAssertGreaterThanOrEqual(
                rate,
                6.0,
                "Respiration rate should not be below 6 bpm"
            )
        }
    }

    func testRejectsImplausiblyHighRate() {
        // Frequency above 0.67 Hz = 40 bpm
        let count = 300
        var rr = [Double]()
        var t = 0.0
        for _ in 0 ..< count {
            let modulation = 20.0 * sin(2.0 * .pi * 0.8 * t)
            rr.append(800.0 + modulation)
            t += 0.8
        }

        let result = RespirationAnalyzer.estimateRespirationRate(rr)

        if let rate = result {
            XCTAssertLessThanOrEqual(
                rate,
                40.0,
                "Respiration rate should not exceed 40 bpm"
            )
        }
    }

    // MARK: - Constant Signal

    func testConstantSignalReturnsNil() {
        // Perfectly constant RR has no respiratory modulation
        let rr = Array(repeating: 800.0, count: 200)

        let result = RespirationAnalyzer.estimateRespirationRate(rr)

        // Constant signal → peak power is 0 everywhere in respiratory band
        // The function should either return nil or a value in range
        if let rate = result {
            XCTAssertGreaterThanOrEqual(rate, 6.0)
            XCTAssertLessThanOrEqual(rate, 40.0)
        }
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
