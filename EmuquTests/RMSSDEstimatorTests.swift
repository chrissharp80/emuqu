@testable import Emuqu
import XCTest

/// Pins the two RMSSD estimators in `TimeDomainAnalyzer` and, more importantly,
/// the relationship between them.
///
/// There is one canonical clean-array estimator and one genuinely *different*
/// estimator that skips artifact-adjacent pairs. The masked one feeds the value
/// written to Apple Health (which Athlytic and Training Today read) and the
/// live RMSSD chart; it is deliberately more artifact-robust and is *supposed*
/// to read lower on noisy nights, so "make them all return the same number" is
/// wrong. Each algorithm has a name and is shared rather than transcribed by
/// hand at call sites, and the relationship is written down here so a reader
/// can tell a deliberate divergence from a drift.
final class RMSSDEstimatorTests: XCTestCase {
    // MARK: - Canonical clean-array estimator

    /// Task Force ESC/NASPE definition: RMSSD = √(mean of squared successive ΔRR).
    /// Differences of 10, 10, 10 → √100 = 10.
    func testCleanEstimatorMatchesTheTextbookDefinition() throws {
        let rr = [800.0, 810.0, 820.0, 830.0]
        let value = try XCTUnwrap(TimeDomainAnalyzer.rmssd(fromCleanRRs: rr))
        XCTAssertEqual(value, 10.0, accuracy: 1e-9)
    }

    func testCleanEstimatorNeedsTwoBeats() {
        XCTAssertNil(TimeDomainAnalyzer.rmssd(fromCleanRRs: []))
        XCTAssertNil(TimeDomainAnalyzer.rmssd(fromCleanRRs: [800.0]))
        XCTAssertNotNil(TimeDomainAnalyzer.rmssd(fromCleanRRs: [800.0, 810.0]))
    }

    // MARK: - Masked estimator

    /// With nothing masked out, the two must agree exactly. If this ever fails,
    /// the estimators have drifted apart rather than being deliberately different.
    func testEstimatorsAgreeWhenNothingIsInvalid() throws {
        let rr = [800.0, 812.0, 795.0, 830.0, 806.0, 819.0]
        let clean = try XCTUnwrap(TimeDomainAnalyzer.rmssd(fromCleanRRs: rr))
        let masked = try XCTUnwrap(TimeDomainAnalyzer.rmssd(fromRRs: rr, isValid: { _ in true }))
        XCTAssertEqual(clean, masked, accuracy: 1e-9)
    }

    /// The reason the masked estimator exists.
    ///
    /// A single artifact beat sits between two normal ones. Collapsing the array
    /// to its valid beats makes those two neighbours adjacent, and the jump
    /// between them enters the sum as one large spurious successive difference.
    /// Skipping the pair instead does not. So on an artifact night the masked
    /// value reads LOWER — and that is the correct, more robust number, not a bug.
    func testMaskedEstimatorIsLowerAcrossAnArtifactGap() throws {
        // The artifact separates two stretches at genuinely different RR levels,
        // so collapsing it away fabricates an 810 -> 900 jump that never happened.
        //                       0      1      2       3(bad)  4      5
        let rr: [Double] = [800.0, 805.0, 810.0, 1_400.0, 900.0, 905.0]
        let isValid: (Int) -> Bool = { $0 != 3 }

        let masked = try XCTUnwrap(TimeDomainAnalyzer.rmssd(fromRRs: rr, isValid: isValid))
        // What the collapse-then-difference approach would have produced.
        let collapsed = try XCTUnwrap(
            TimeDomainAnalyzer.rmssd(fromCleanRRs: rr.enumerated().filter { isValid($0.offset) }.map(\.element))
        )

        XCTAssertLessThan(
            masked, collapsed,
            "Skipping artifact-adjacent pairs must not inflate RMSSD the way collapsing does"
        )
        // Only the 800→805, 805→810 and 900→905 pairs survive: all ΔRR = 5.
        XCTAssertEqual(masked, 5.0, accuracy: 1e-9)
        // Collapsing invents a 90 ms difference and reports ~9x the true value.
        XCTAssertEqual(collapsed, 45.2078, accuracy: 1e-3)
    }

    func testMaskedEstimatorNeedsOneAdjacentValidPair() {
        let rr = [800.0, 810.0, 820.0, 830.0]
        // Alternating validity leaves no two valid beats adjacent.
        XCTAssertNil(TimeDomainAnalyzer.rmssd(fromRRs: rr, isValid: { $0 % 2 == 0 }))
        XCTAssertNil(TimeDomainAnalyzer.rmssd(fromRRs: rr, isValid: { _ in false }))
        XCTAssertNotNil(TimeDomainAnalyzer.rmssd(fromRRs: rr, isValid: { $0 < 2 }))
    }

    func testMaskedEstimatorIgnoresLeadingAndTrailingInvalidBeats() throws {
        let core = [800.0, 810.0, 820.0]
        let padded = [9_999.0] + core + [9_999.0]
        let expected = try XCTUnwrap(TimeDomainAnalyzer.rmssd(fromCleanRRs: core))
        let actual = try XCTUnwrap(
            TimeDomainAnalyzer.rmssd(fromRRs: padded, isValid: { $0 >= 1 && $0 <= 3 })
        )
        XCTAssertEqual(actual, expected, accuracy: 1e-9)
    }

    // MARK: - Shape

    func testBothEstimatorsAreFiniteAndNonNegative() throws {
        let rr = (0 ..< 200).map { i -> Double in
            let jitter: Double = Double((i * 37) % 90)
            return 800.0 + jitter
        }
        let clean = try XCTUnwrap(TimeDomainAnalyzer.rmssd(fromCleanRRs: rr))
        let masked = try XCTUnwrap(TimeDomainAnalyzer.rmssd(fromRRs: rr, isValid: { $0 % 7 != 0 }))
        for value in [clean, masked] {
            XCTAssertTrue(value.isFinite)
            XCTAssertGreaterThanOrEqual(value, 0)
        }
    }
}
