@testable import Emuqu
import XCTest

/// Tests that pin the barometric elevation algorithm's *symmetry* —
/// the user (item #14) wanted verification that gain and loss are
/// captured equally well in both directions. The algorithm uses the
/// same threshold and sustained-run logic for ascents and descents,
/// and these tests prove it on synthetic and field-shaped signals.
final class BarometricAltitudeProcessorTests: XCTestCase {

    private func makeSamples(_ altitudes: [Double], hzInterval: TimeInterval = 1.0) -> [(Date, Double)] {
        let start = Date()
        return altitudes.enumerated().map {
            (start.addingTimeInterval(TimeInterval($0.offset) * hzInterval), $0.element)
        }
    }

    // MARK: - Symmetry on a clean ramp

    func testSymmetricRampGainsAndLossesAreEqual() {
        // 100-sample ascent +50 m, then 100-sample descent -50 m.
        let up = stride(from: 0.0, through: 50.0, by: 0.5).map { $0 }
        let down = stride(from: 50.0, through: 0.0, by: -0.5).map { $0 }
        let altitudes = up + Array(down.dropFirst()) // avoid duplicate peak point
        let result = BarometricAltitudeProcessor.process(samples: makeSamples(altitudes))

        // Both numbers should be in the same ballpark — within 5 % of each other
        // (smoother edge effects produce minor asymmetry but nothing material).
        XCTAssertGreaterThan(result.gainMeters, 40)
        XCTAssertGreaterThan(result.lossMeters, 40)
        let asymmetry = abs(result.gainMeters - result.lossMeters)
        XCTAssertLessThan(asymmetry, max(result.gainMeters, result.lossMeters) * 0.05,
                          "gain/loss should be symmetric on a symmetric signal — got gain=\(result.gainMeters), loss=\(result.lossMeters)")
    }

    // MARK: - Slow climb counts (was the previous bug)

    func testSlowClimbCountsEvenWithSubMeterPerSampleDeltas() {
        // 30-min ramp from 0 m → 200 m. Per-second delta ≈ 0.11 m,
        // well below any per-sample threshold. The sustained-run
        // algorithm should still capture all 200 m.
        var altitudes: [Double] = []
        let totalSamples = 30 * 60
        for i in 0 ..< totalSamples {
            altitudes.append(Double(i) * (200.0 / Double(totalSamples - 1)))
        }
        let result = BarometricAltitudeProcessor.process(samples: makeSamples(altitudes))
        XCTAssertGreaterThan(result.gainMeters, 195, "slow climb should yield ~200 m gain, got \(result.gainMeters)")
        XCTAssertLessThan(result.lossMeters, 5, "no descent should be detected on a pure climb")
    }

    func testSlowDescentCountsEvenWithSubMeterPerSampleDeltas() {
        // Mirror of the climb test — pure descent.
        var altitudes: [Double] = []
        let totalSamples = 30 * 60
        for i in 0 ..< totalSamples {
            altitudes.append(200.0 - Double(i) * (200.0 / Double(totalSamples - 1)))
        }
        let result = BarometricAltitudeProcessor.process(samples: makeSamples(altitudes))
        XCTAssertGreaterThan(result.lossMeters, 195, "slow descent should yield ~200 m loss, got \(result.lossMeters)")
        XCTAssertLessThan(result.gainMeters, 5, "no climb should be detected on a pure descent")
    }

    // MARK: - HVAC / pressure-blip rejection (was the over-count bug)

    func testIsolatedNoiseBlipsDoNotAccumulate() {
        // Flat baseline with brief 1.5 m spikes that revert. Sustained
        // runs should never clear the 2 m threshold, so neither gain
        // nor loss accumulate.
        var altitudes: [Double] = Array(repeating: 100.0, count: 600) // 10 min flat
        // Inject small spikes that immediately revert.
        for i in stride(from: 60, to: 540, by: 60) {
            altitudes[i] = 101.5
            altitudes[i + 1] = 100.0
        }
        let result = BarometricAltitudeProcessor.process(samples: makeSamples(altitudes))
        XCTAssertLessThan(result.gainMeters, 2)
        XCTAssertLessThan(result.lossMeters, 2)
    }

    // MARK: - Real-world shape

    func testClimbDescendClimbDescendMatchesExpectedTotals() {
        // 4 segments: +100 m, -50 m, +30 m, -80 m → expected 130 / 130.
        var current = 0.0
        var altitudes: [Double] = [current]
        // Ramp by `step` metres per sample. Tracking the running altitude
        // directly beats re-reading `altitudes.last`, which is never nil here
        // but needed a force-unwrap to say so.
        func ramp(samples: Int, step: Double) {
            for _ in 1 ... samples {
                current += step
                altitudes.append(current)
            }
        }
        ramp(samples: 200, step: 0.5)   // +100 m
        ramp(samples: 100, step: -0.5)  // -50 m
        ramp(samples: 60, step: 0.5)    // +30 m
        ramp(samples: 160, step: -0.5)  // -80 m
        let result = BarometricAltitudeProcessor.process(samples: makeSamples(altitudes))
        // Expect gain ≈ 130, loss ≈ 130, with smoother-edge tolerance.
        XCTAssertGreaterThan(result.gainMeters, 120)
        XCTAssertLessThan(result.gainMeters, 140)
        XCTAssertGreaterThan(result.lossMeters, 120)
        XCTAssertLessThan(result.lossMeters, 140)
    }

    // MARK: - Noisy slow climb

    func testNoisySlowClimbIsNotSplitIntoDiscardedRuns() {
        // A slow hike: 100 m over ~40 min (≈0.04 m/s) with ±0.5 m sensor
        // noise, so single smoothed deltas often turn negative. Hysteresis
        // must still see one climb.
        var seed: UInt64 = 12345
        func noise() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double(seed >> 33) / Double(UInt64(1) << 31) - 0.5)
        }
        let totalSamples = 2400
        let altitudes = (0 ..< totalSamples).map { Double($0) * (100.0 / Double(totalSamples - 1)) + noise() }
        let result = BarometricAltitudeProcessor.process(samples: makeSamples(altitudes))
        XCTAssertGreaterThan(result.gainMeters, 95, "noisy slow climb should yield ~100 m gain, got \(result.gainMeters)")
        XCTAssertLessThan(result.lossMeters, 2, "noise alone should not produce descent")
    }
}
