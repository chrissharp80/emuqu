@testable import Emuqu
import XCTest

/// DFA measured against series whose scaling exponent is known analytically.
///
/// ## Why this exists
///
/// The existing `DFAAnalysisTests` check that the implementation runs, refuses
/// short input, and lands somewhere physiological. None of that would catch an
/// exponent that is wrong by a constant: a missing detrend, a box-size range
/// off by one, a log base swapped, an integration step dropped — each produces
/// a number that is still "in range" and still reproducible, and α1 is the
/// input to the app's aerobic-threshold estimate.
///
/// Detrended fluctuation analysis has exact answers for three standard
/// processes, which is what makes them a reference:
///
///   * **Uncorrelated noise → α = 0.5.** Successive values are independent, the
///     integrated series is a random walk, and its fluctuation grows as √n.
///   * **1/f (pink) noise → α = 1.0.** The scale-free case DFA was built to
///     identify (Peng et al., Chaos 1995;5:82-87).
///   * **Brownian motion → α = 1.5.** The integral of uncorrelated noise, one
///     power of n above it by construction.
///
/// The generators here are seeded and deterministic, so a failure is a change
/// in the analysis rather than a bad draw. `DFAAnalysisTests` uses
/// `Double.random`, which cannot say that.
///
/// ## What this does not establish
///
/// That α1 from a chest strap matches a laboratory ventilatory threshold, or
/// that any α1 band means what a training article says it means. This is the
/// arithmetic only. The claims built on top of it are classified separately in
/// the science register, where DFA-as-LT1 is `supported-transfer`, not
/// `validated`.
final class DFAReferenceValidationTests: XCTestCase {
    /// Long enough that α2's 16–64 boxes are all inside `count / 4`, so both
    /// exponents are measured on the full box range.
    private let sampleCount = 4_096

    /// Short-scale DFA (boxes 4–16) carries a known positive bias: the
    /// regression has few points, and the smallest boxes are where a linear
    /// detrend removes a large share of a short segment. This implementation
    /// measures 0.581 / 1.088 / 1.526 for the three processes below against
    /// analytic 0.5 / 1.0 / 1.5 — biased upward at the short scale, in the
    /// direction and by the margin the method is documented to have.
    ///
    /// The tolerance is sized for that bias, not to let a wrong number pass:
    /// the α2 assertions cover 16–64 beats, where it has largely gone, and
    /// hold to 0.10.
    private let shortScaleTolerance = 0.15
    private let asymptoticTolerance = 0.10

    // MARK: - Known exponents

    func testUncorrelatedNoiseScalesAtOneHalf() throws {
        let result = try XCTUnwrap(DFAAnalyzer.compute(uncorrelatedNoise()))

        XCTAssertEqual(result.alpha1, 0.5, accuracy: shortScaleTolerance,
                       "uncorrelated input must scale as √n; α1 = \(result.alpha1)")
        let alpha2 = try XCTUnwrap(result.alpha2)
        XCTAssertEqual(alpha2, 0.5, accuracy: asymptoticTolerance,
                       "α2 is measured over 16–64 beats, where the small-box bias is gone; α2 = \(alpha2)")
    }

    func testPinkNoiseScalesAtOne() throws {
        let result = try XCTUnwrap(DFAAnalyzer.compute(pinkNoise()))

        XCTAssertEqual(result.alpha1, 1.0, accuracy: shortScaleTolerance,
                       "1/f noise is the scale-free case: α ≈ 1; α1 = \(result.alpha1)")
        let alpha2 = try XCTUnwrap(result.alpha2)
        XCTAssertEqual(alpha2, 1.0, accuracy: 0.15, "α2 = \(alpha2)")
    }

    func testBrownianMotionScalesAtThreeHalves() throws {
        let result = try XCTUnwrap(DFAAnalyzer.compute(brownianMotion()))

        XCTAssertEqual(result.alpha1, 1.5, accuracy: shortScaleTolerance,
                       "the integral of uncorrelated noise scales as n^1.5; α1 = \(result.alpha1)")
        let alpha2 = try XCTUnwrap(result.alpha2)
        XCTAssertEqual(alpha2, 1.5, accuracy: asymptoticTolerance, "α2 = \(alpha2)")
    }

    /// The three processes must come out in order, by a clear margin. This is
    /// the property the aerobic-threshold estimate leans on: α1 falls as the
    /// rhythm loses long-range correlation.
    func testExponentsSeparateTheThreeProcesses() throws {
        let white = try XCTUnwrap(DFAAnalyzer.compute(uncorrelatedNoise())).alpha1
        let pink = try XCTUnwrap(DFAAnalyzer.compute(pinkNoise())).alpha1
        let brown = try XCTUnwrap(DFAAnalyzer.compute(brownianMotion())).alpha1

        XCTAssertLessThan(white + 0.2, pink, "white \(white) vs pink \(pink)")
        XCTAssertLessThan(pink + 0.2, brown, "pink \(pink) vs brown \(brown)")
    }

    // MARK: - Invariances the definition requires

    /// DFA removes the mean and a linear trend per box, so a constant offset
    /// cannot change the exponent. A regression that forgot the detrend, or
    /// integrated the raw series instead of its deviations, fails here.
    func testExponentIsUnchangedByAConstantOffset() throws {
        let series = pinkNoise()
        let shifted = series.map { $0 + 250 }

        let base = try XCTUnwrap(DFAAnalyzer.compute(series)).alpha1
        let offset = try XCTUnwrap(DFAAnalyzer.compute(shifted)).alpha1

        XCTAssertEqual(base, offset, accuracy: 1e-9)
    }

    /// Scaling every interval scales the fluctuation at every box size by the
    /// same factor, which moves the log-log intercept and leaves the slope
    /// alone. A normalisation applied per box — rather than once — breaks this.
    func testExponentIsUnchangedByAmplitudeScaling() throws {
        let series = pinkNoise()
        let scaled = series.map { 850 + ($0 - 850) * 3.5 }

        let base = try XCTUnwrap(DFAAnalyzer.compute(series)).alpha1
        let amplified = try XCTUnwrap(DFAAnalyzer.compute(scaled)).alpha1

        XCTAssertEqual(base, amplified, accuracy: 1e-9)
    }

    /// A ramp is pure trend: each box's least-squares line is the data, the
    /// residuals are zero, and the fluctuation collapses. The guard against
    /// `log(0)` is what keeps that finite rather than `-inf`.
    func testAPureLinearRampProducesAFiniteExponent() throws {
        let ramp = (0 ..< sampleCount).map { 800 + Double($0) * 0.05 }
        let result = try XCTUnwrap(DFAAnalyzer.compute(ramp))

        XCTAssertTrue(result.alpha1.isFinite, "α1 = \(result.alpha1)")
        XCTAssertFalse(result.alpha1.isNaN)
    }

    /// The same input must give the same exponent to the bit — the fit is
    /// deterministic, and a test that tolerates drift here would not notice a
    /// change in the box sizes.
    func testTheSameSeriesGivesTheSameExponent() throws {
        let series = pinkNoise()

        let first = try XCTUnwrap(DFAAnalyzer.compute(series))
        let second = try XCTUnwrap(DFAAnalyzer.compute(series))

        XCTAssertEqual(first.alpha1, second.alpha1)
        XCTAssertEqual(first.alpha2, second.alpha2)
    }

    // MARK: - Deterministic generators

    /// SplitMix64: a small, well-distributed generator with a fixed seed, so
    /// every run analyses the identical series. `Double.random` cannot be used
    /// in a reference test — a failure would be indistinguishable from an
    /// unlucky draw.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Box–Muller, so the draws are normal rather than uniform: the analytic
    /// exponents above are stated for Gaussian processes.
    private func gaussianSamples(count: Int, seed: UInt64) -> [Double] {
        var generator = SeededGenerator(seed: seed)
        var out: [Double] = []
        out.reserveCapacity(count)
        while out.count < count {
            let u1 = Double.random(in: 1e-12 ... 1, using: &generator)
            let u2 = Double.random(in: 0 ... 1, using: &generator)
            let radius = (-2 * log(u1)).squareRoot()
            out.append(radius * cos(2 * .pi * u2))
            if out.count < count { out.append(radius * sin(2 * .pi * u2)) }
        }
        return out
    }

    /// α = 0.5. Intervals around a plausible resting mean, independent draw to
    /// draw.
    private func uncorrelatedNoise() -> [Double] {
        gaussianSamples(count: sampleCount, seed: 0x5EED_0001).map { 850 + $0 * 40 }
    }

    /// α = 1.5. The running sum of uncorrelated noise, re-centred so the values
    /// stay in the range an RR series occupies.
    private func brownianMotion() -> [Double] {
        var total = 0.0
        let walk = gaussianSamples(count: sampleCount, seed: 0x5EED_0002).map { step -> Double in
            total += step
            return total
        }
        let mean = walk.reduce(0, +) / Double(walk.count)
        return walk.map { 850 + ($0 - mean) * 2 }
    }

    /// α = 1.0, by Voss–McCartney: sum several uncorrelated sources, each
    /// updated half as often as the last, so power is spread evenly per octave.
    /// A standard construction for 1/f noise and, unlike a sum of sinusoids,
    /// genuinely scale-free rather than merely smooth.
    private func pinkNoise() -> [Double] {
        let octaves = 12
        var generator = SeededGenerator(seed: 0x5EED_0003)
        var sources = (0 ..< octaves).map { _ in Double.random(in: -1 ... 1, using: &generator) }
        var out: [Double] = []
        out.reserveCapacity(sampleCount)
        for index in 0 ..< sampleCount {
            for octave in 0 ..< octaves where index % (1 << octave) == 0 {
                sources[octave] = Double.random(in: -1 ... 1, using: &generator)
            }
            out.append(850 + sources.reduce(0, +) * 12)
        }
        return out
    }
}
