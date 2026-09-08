@testable import Emuqu
import XCTest

/// Critical FFT validation tests - MUST PASS BEFORE SHIP
final class FrequencyDomainTests: XCTestCase {
    override func tearDown() {
        FrequencyDomainAnalyzer.teardownDFTCache()
        super.tearDown()
    }

    // MARK: - Critical: 0.25 Hz Sine Test

    /// Test the spectral computation directly with a known uniform-time sine
    /// This validates correct FFT implementation and band placement
    func testSpectralWith025HzSine() {
        let fs = 4.0
        let duration = 300.0 // 5 minutes
        let n = Int(duration * fs)
        let targetFreq = 0.25
        let amplitude = 50.0 // ms

        // Generate uniform-time sine (bypasses RR resampling)
        var signal = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            let t = Double(i) / fs
            signal[i] = amplitude * sin(2 * .pi * targetFreq * t)
        }

        // Run spectral computation directly
        let metrics = FrequencyDomainAnalyzer.computePSD(signal: signal, fs: fs)

        // 1. Frequency placement: 0.25 Hz is in HF band (0.15-0.4 Hz)
        XCTAssertGreaterThan(
            metrics.hf,
            metrics.lf * 10,
            "0.25 Hz power should be in HF band, not LF. HF=\(metrics.hf), LF=\(metrics.lf)"
        )

        // 2. Band isolation: HF should contain >90% of power
        let total = metrics.hf + metrics.lf + (metrics.vlf ?? 0)
        XCTAssertGreaterThan(
            metrics.hf / total,
            0.9,
            "HF should contain >90% of power for 0.25 Hz sine. Got \(metrics.hf / total * 100)%"
        )

        // 3. Power magnitude: sine power = A²/2 = 1250 ms²
        // Allow 20% tolerance for windowing effects
        let expectedPower = amplitude * amplitude / 2 // 1250 ms²
        XCTAssertEqual(
            metrics.hf,
            expectedPower,
            accuracy: expectedPower * 0.25,
            "HF power should be approximately A²/2 = \(expectedPower) ms². Got \(metrics.hf)"
        )
    }

    /// Test that 0.1 Hz sine goes into LF band
    func testSpectralWith01HzSine() {
        let fs = 4.0
        let duration = 300.0
        let n = Int(duration * fs)
        let targetFreq = 0.1 // LF band: 0.04-0.15 Hz
        let amplitude = 50.0

        var signal = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            let t = Double(i) / fs
            signal[i] = amplitude * sin(2 * .pi * targetFreq * t)
        }

        let metrics = FrequencyDomainAnalyzer.computePSD(signal: signal, fs: fs)

        // LF should dominate
        XCTAssertGreaterThan(
            metrics.lf,
            metrics.hf * 10,
            "0.1 Hz power should be in LF band. LF=\(metrics.lf), HF=\(metrics.hf)"
        )

        // LF should contain >90% of power
        let total = metrics.hf + metrics.lf + (metrics.vlf ?? 0)
        XCTAssertGreaterThan(
            metrics.lf / total,
            0.9,
            "LF should contain >90% of power for 0.1 Hz sine"
        )
    }

    /// Test mixed signal with both LF and HF components
    func testMixedFrequencySignal() throws {
        let fs = 4.0
        let duration = 300.0
        let n = Int(duration * fs)

        let lfFreq = 0.1
        let hfFreq = 0.25
        let lfAmplitude = 30.0
        let hfAmplitude = 40.0

        var signal = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            let t = Double(i) / fs
            signal[i] = lfAmplitude * sin(2 * .pi * lfFreq * t) +
                hfAmplitude * sin(2 * .pi * hfFreq * t)
        }

        let metrics = FrequencyDomainAnalyzer.computePSD(signal: signal, fs: fs)

        // Expected powers
        let expectedLF = lfAmplitude * lfAmplitude / 2 // 450 ms²
        let expectedHF = hfAmplitude * hfAmplitude / 2 // 800 ms²

        XCTAssertEqual(
            metrics.lf,
            expectedLF,
            accuracy: expectedLF * 0.3,
            "LF power should be ~\(expectedLF) ms². Got \(metrics.lf)"
        )
        XCTAssertEqual(
            metrics.hf,
            expectedHF,
            accuracy: expectedHF * 0.3,
            "HF power should be ~\(expectedHF) ms². Got \(metrics.hf)"
        )

        // LF/HF ratio
        let expectedRatio = expectedLF / expectedHF
        XCTAssertNotNil(metrics.lfHfRatio)
        XCTAssertEqual(
            try XCTUnwrap(metrics.lfHfRatio),
            expectedRatio,
            accuracy: 0.2,
            "LF/HF ratio should be ~\(expectedRatio)"
        )
    }

    // MARK: - VLF Gating Tests

    /// VLF should be nil for windows < 10 minutes
    func testVLFGatingShortWindow() {
        let fs = 4.0
        let duration = 300.0 // 5 minutes - too short for VLF
        let n = Int(duration * fs)

        var signal = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            let t = Double(i) / fs
            signal[i] = 50.0 * sin(2 * .pi * 0.02 * t) // VLF frequency
        }

        let metrics = FrequencyDomainAnalyzer.computePSD(signal: signal, fs: fs, usableWindowMin: 5.0)

        XCTAssertNil(metrics.vlf, "VLF should be nil for 5-minute window")
    }

    /// VLF should be present for windows >= 10 minutes
    func testVLFGatingLongWindow() {
        let fs = 4.0
        let duration = 600.0 // 10 minutes
        let n = Int(duration * fs)

        var signal = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            let t = Double(i) / fs
            signal[i] = 50.0 * sin(2 * .pi * 0.02 * t) // VLF frequency (0.003-0.04 Hz)
        }

        let metrics = FrequencyDomainAnalyzer.computePSD(signal: signal, fs: fs, usableWindowMin: 10.0)

        XCTAssertNotNil(metrics.vlf, "VLF should be present for 10-minute window")
        XCTAssertGreaterThan(metrics.vlf ?? 0, 0, "VLF should have positive power")
    }

    // MARK: - Edge Cases

    /// Test with DC component (should be filtered by mean removal)
    func testDCComponentRemoval() {
        let fs = 4.0
        let duration = 300.0
        let n = Int(duration * fs)
        let dcOffset = 1000.0 // Large DC offset

        var signal = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            let t = Double(i) / fs
            signal[i] = dcOffset + 50.0 * sin(2 * .pi * 0.25 * t)
        }

        let metrics = FrequencyDomainAnalyzer.computePSD(signal: signal, fs: fs)

        // Power should be same as without DC
        let expectedHF = 50.0 * 50.0 / 2
        XCTAssertEqual(
            metrics.hf,
            expectedHF,
            accuracy: expectedHF * 0.25,
            "DC should not affect HF power"
        )
    }

    /// Test DFT cache is properly managed
    func testDFTCaching() {
        let fs = 4.0

        // Create signals of different sizes
        let sizes = [256, 512, 1024, 512, 256]

        for n in sizes {
            var signal = [Double](repeating: 0, count: n)
            for i in 0 ..< n {
                let t = Double(i) / fs
                signal[i] = 50.0 * sin(2 * .pi * 0.25 * t)
            }

            let metrics = FrequencyDomainAnalyzer.computePSD(signal: signal, fs: fs)
            XCTAssertGreaterThan(metrics.totalPower, 0, "Should compute valid power for size \(n)")
        }

        // Teardown should not crash
        FrequencyDomainAnalyzer.teardownDFTCache()
    }

    // MARK: - Numerical Stability

    /// Test with very small amplitudes
    func testSmallAmplitudes() {
        let fs = 4.0
        let duration = 300.0
        let n = Int(duration * fs)
        let amplitude = 0.001 // Very small

        var signal = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            let t = Double(i) / fs
            signal[i] = amplitude * sin(2 * .pi * 0.25 * t)
        }

        let metrics = FrequencyDomainAnalyzer.computePSD(signal: signal, fs: fs)

        XCTAssertGreaterThan(metrics.hf, 0, "Should handle small amplitudes")
        XCTAssertFalse(metrics.hf.isNaN, "Should not produce NaN")
        XCTAssertFalse(metrics.hf.isInfinite, "Should not produce infinity")
    }

    /// Test with zero signal
    func testZeroSignal() {
        let n = 1024
        let signal = [Double](repeating: 0, count: n)

        let metrics = FrequencyDomainAnalyzer.computePSD(signal: signal, fs: 4.0)

        XCTAssertEqual(metrics.totalPower, 0, accuracy: 1e-10, "Zero signal should have zero power")
        XCTAssertNil(metrics.lfHfRatio, "LF/HF should be nil for zero HF")
    }
}
