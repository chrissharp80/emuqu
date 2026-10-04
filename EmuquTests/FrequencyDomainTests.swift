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
        // Allow 25% tolerance for windowing effects
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

    /// VLF is measured, at the right size, from the long-segment pass: a
    /// 0.02 Hz sine of amplitude A carries A²/2 of power.
    func testVLFPowerMatchesASineInTheBand() throws {
        let fs = 4.0
        let n = Int(600.0 * fs)
        let signal = (0 ..< n).map { 50.0 * sin(2 * .pi * 0.02 * Double($0) / fs) }

        let metrics = FrequencyDomainAnalyzer.computePSD(signal: signal, fs: fs, usableWindowMin: 10.0)

        XCTAssertEqual(try XCTUnwrap(metrics.vlf), 1250, accuracy: 1250 * 0.25)
    }

    /// Slow drift is not VLF power. With 64-s segments and only the window
    /// mean removed, each segment's leftover offset leaked through the Hann
    /// main lobe into bin 1 (0.0156 Hz, inside VLF): a 200 ms ramp over ten
    /// minutes read as ~900 ms² of VLF. Per-segment detrending and the
    /// long-segment VLF pass leave it near zero.
    func testLinearDriftDoesNotReadAsVLF() throws {
        let fs = 4.0
        let n = Int(600.0 * fs)
        let signal = (0 ..< n).map { i -> Double in
            50.0 * sin(2 * .pi * 0.25 * Double(i) / fs) + 200.0 * Double(i) / Double(n)
        }

        let metrics = FrequencyDomainAnalyzer.computePSD(signal: signal, fs: fs, usableWindowMin: 10.0)

        XCTAssertLessThan(try XCTUnwrap(metrics.vlf), metrics.hf * 0.01, "A ramp leaked into VLF: \(metrics.vlf ?? -1)")
        XCTAssertEqual(metrics.hf, 1250, accuracy: 1250 * 0.25, "Detrending must not eat the HF sine")
    }

    /// Below one Welch segment the single-window periodogram runs. The taper
    /// used to span the zero padding too, so a 35-s window got only part of
    /// the Hann shape and the power was scaled by the padded length: a sine
    /// of A²/2 = 1250 ms² read ~750.
    func testShortWindowPowerIsScaledToTheSignalNotThePadding() {
        let fs = 4.0
        let signal = (0 ..< 140).map { 50.0 * sin(2 * .pi * 0.25 * Double($0) / fs) }

        let metrics = FrequencyDomainAnalyzer.computePSD(signal: signal, fs: fs)

        XCTAssertEqual(metrics.hf, 1250, accuracy: 1250 * 0.1)
    }

    /// The detrend removes exactly a straight line.
    func testLinearDetrendRemovesOffsetAndSlope() {
        let line = (0 ..< 64).map { 3.0 + 0.5 * Double($0) }
        for value in FrequencyDomainAnalyzer.linearlyDetrended(line) {
            XCTAssertEqual(value, 0, accuracy: 1e-9)
        }
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

    // MARK: - VLF gating and the short-signal paths

    /// A window long enough to report VLF (10 min) but a signal shorter than
    /// one 1024-sample VLF segment: VLF is not reported from 64-s segments.
    func testVLFIsNilBelowOneLongSegment() {
        let fs = 4.0
        let signal = (0 ..< 1_000).map { 50.0 * sin(2 * .pi * 0.25 * Double($0) / fs) }

        let metrics = FrequencyDomainAnalyzer.computePSD(signal: signal, fs: fs, usableWindowMin: 10.0)

        XCTAssertNil(metrics.vlf, "1,000 samples is under the 1,024-sample VLF segment")
        XCTAssertGreaterThan(metrics.hf, 0)
    }

    /// Under 256 samples Welch cannot run and the single-window periodogram
    /// answers instead; it reports VLF only when the usable window reaches
    /// the 10-minute VLF minimum.
    func testSingleWindowPathGatesVLFOnTheUsableWindow() throws {
        let fs = 4.0
        let signal = (0 ..< 200).map { 50.0 * sin(2 * .pi * 0.25 * Double($0) / fs) }

        let long = FrequencyDomainAnalyzer.computePSD(signal: signal, fs: fs, usableWindowMin: 10.0)
        let short = FrequencyDomainAnalyzer.computePSD(signal: signal, fs: fs, usableWindowMin: 5.0)

        let vlf = try XCTUnwrap(long.vlf, "A 10-minute window reports VLF from the single-window spectrum")
        XCTAssertTrue(vlf.isFinite && vlf >= 0)
        XCTAssertNil(short.vlf, "A 5-minute window does not")
        XCTAssertGreaterThan(long.hf, long.lf, "The 0.25 Hz sine lands in HF on this path too")
    }

    /// The (time, RR) entry point resamples to 4 Hz itself: a 0.25 Hz
    /// modulation of real beat timings lands in HF.
    func testComputeFromCleanPairsPlacesRespiratoryModulationInHF() throws {
        var times: [Double] = []
        var rr: [Double] = []
        var t = 0.0
        for _ in 0 ..< 400 {
            let value = 800 + 40 * sin(2 * .pi * 0.25 * t)
            t += value / 1_000
            times.append(t)
            rr.append(value)
        }

        let metrics = try XCTUnwrap(FrequencyDomainAnalyzer.computeFromCleanPairs(times: times, rrValues: rr))

        XCTAssertGreaterThan(metrics.hf, metrics.lf)
    }

    /// Fewer than 60 pairs, or no elapsed time, is not enough to estimate a
    /// spectrum.
    func testComputeFromCleanPairsRejectsTooLittleData() {
        let few = (0 ..< 59).map { Double($0) * 0.8 }
        XCTAssertNil(FrequencyDomainAnalyzer.computeFromCleanPairs(times: few, rrValues: few.map { _ in 800 }))
        let still = [Double](repeating: 5, count: 100)
        XCTAssertNil(FrequencyDomainAnalyzer.computeFromCleanPairs(times: still, rrValues: still.map { _ in 800 }))
    }
}
