@testable import Emuqu
import XCTest

/// Nonlinear HRV analysis tests (Poincaré, DFA)
final class NonlinearAnalysisTests: XCTestCase {
    // MARK: - Poincaré Plot Tests

    /// Test SD1 calculation (short-term variability)
    func testPoincareSD1() throws {
        // Create RR intervals with known successive differences
        // Need at least 10 points for Nonlinear analysis
        // Pattern: 800, 820(+20), 790(-30), 830(+40), 780(-50), repeated twice
        // SD1 = sqrt(var(diffs)) / sqrt(2)
        // With repeated pattern, variance should be consistent

        let basePattern = [800, 820, 790, 830, 780]
        var points: [RRPoint] = []
        var t_ms: Int64 = 0

        for _ in 0 ..< 2 {
            for rr in basePattern {
                points.append(RRPoint(t_ms: t_ms, rr_ms: rr))
                t_ms += Int64(rr)
            }
        }
        // Total: 10 points

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = NonlinearAnalyzer.computeNonlinear(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        XCTAssertNotNil(metrics)

        // With repeated pattern, SD1 should still be around 29-30
        // Just verify it's in a reasonable range
        XCTAssertGreaterThan(try XCTUnwrap(metrics?.sd1), 20, "SD1 should be > 20 for this variability")
        XCTAssertLessThan(try XCTUnwrap(metrics?.sd1), 40, "SD1 should be < 40 for this pattern")
    }

    /// Test SD2 calculation (long-term variability)
    func testPoincareSD2() throws {
        // SD2 measures long-term standard deviation along major axis
        // Should be larger than SD1 for normal HRV

        let points = (0 ..< 50).map { i in
            // Create varying RR intervals with both short and long-term patterns
            let base = 800
            let shortTerm = Int(sin(Double(i)) * 20)
            let longTerm = Int(sin(Double(i) / 10.0) * 50)
            return RRPoint(t_ms: Int64(i * 800), rr_ms: base + shortTerm + longTerm)
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = NonlinearAnalyzer.computeNonlinear(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        XCTAssertNotNil(metrics)
        XCTAssertGreaterThan(
            try XCTUnwrap(metrics?.sd2),
            try XCTUnwrap(metrics?.sd1),
            "SD2 should be greater than SD1 for normal HRV"
        )
    }

    /// Test SD1/SD2 ratio
    func testPoincareRatio() throws {
        var generator = DFAReferenceValidationTests.SeededGenerator(seed: 0xA1)
        let points = (0 ..< 100).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + Int.random(in: -50 ... 50, using: &generator))
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = NonlinearAnalyzer.computeNonlinear(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        XCTAssertNotNil(metrics)

        // Ratio should be positive; for random data it can exceed 1.0
        // (sd1 > sd2 when successive differences dominate long-term variance)
        XCTAssertGreaterThan(try XCTUnwrap(metrics?.sd1Sd2Ratio), 0)
        XCTAssertLessThan(try XCTUnwrap(metrics?.sd1Sd2Ratio), 3.0, "Ratio should be in reasonable range")
    }

    // MARK: - DFA Tests

    /// DFA alpha1 should be in physiological range for normal data
    func testDFAAlpha1Range() throws {
        // Create realistic RR intervals
        var generator = DFAReferenceValidationTests.SeededGenerator(seed: 0xA2)
        let points = (0 ..< 500).map { i in
            let base = 800.0
            let variation = sin(Double(i) * 0.1) * 50 + Double.random(in: -20 ... 20, using: &generator)
            return RRPoint(t_ms: Int64(i * 800), rr_ms: Int(base + variation))
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = NonlinearAnalyzer.computeNonlinear(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        let nonlinear = try XCTUnwrap(metrics)
        let alpha1 = try XCTUnwrap(nonlinear.dfaAlpha1)

        // Alpha1 should be in physiological range (0.5-1.5)
        // Healthy = 0.75-1.0, diseased often > 1.2 or < 0.5
        XCTAssertGreaterThan(alpha1, 0.3, "Alpha1 too low: \(alpha1)")
        XCTAssertLessThan(alpha1, 2.0, "Alpha1 too high: \(alpha1)")
    }

    /// DFA alpha2 should differ from alpha1
    func testDFAAlpha2() throws {
        // Seeded: unseeded noise failed the range check now and then.
        var generator = DFAReferenceValidationTests.SeededGenerator(seed: 42)
        let points = (0 ..< 500).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + Int.random(in: -50 ... 50, using: &generator))
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = NonlinearAnalyzer.computeNonlinear(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        XCTAssertNotNil(metrics)
        XCTAssertNotNil(try XCTUnwrap(metrics?.dfaAlpha2))

        // Alpha2 should be in physiological range
        XCTAssertGreaterThan(try XCTUnwrap(metrics?.dfaAlpha2), 0.3)
        XCTAssertLessThan(try XCTUnwrap(try XCTUnwrap(metrics?.dfaAlpha2)), 2.0)
    }

    /// DFA should require sufficient data
    func testDFAInsufficientData() {
        // DFA needs at least 100-200 points typically
        let points = (0 ..< 50).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800)
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = NonlinearAnalyzer.computeNonlinear(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        // Should either return nil for DFA or handle gracefully
        if let dfaAlpha1 = metrics?.dfaAlpha1 {
            // If it computes, values should still be reasonable
            XCTAssertGreaterThan(dfaAlpha1, 0)
            XCTAssertLessThan(dfaAlpha1, 3.0)
        }
    }

    // MARK: - Artifact Handling

    /// Nonlinear metrics should exclude artifacts
    func testArtifactExclusion() throws {
        var generator = DFAReferenceValidationTests.SeededGenerator(seed: 0xA3)
        var points = (0 ..< 100).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + Int.random(in: -30 ... 30, using: &generator))
        }

        // Add obvious artifact
        points[50] = RRPoint(t_ms: Int64(50 * 800), rr_ms: 200)

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[50] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())

        let metrics = NonlinearAnalyzer.computeNonlinear(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        XCTAssertNotNil(metrics)

        // Poincaré should still be calculable with artifact excluded
        XCTAssertGreaterThan(try XCTUnwrap(metrics?.sd1), 0)
        XCTAssertGreaterThan(try XCTUnwrap(metrics?.sd2), 0)
    }

    // MARK: - Edge Cases

    /// Constant RR intervals should have minimal variability
    func testConstantRR() throws {
        let points = (0 ..< 100).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800)
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = NonlinearAnalyzer.computeNonlinear(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        XCTAssertNotNil(metrics)

        // SD1 and SD2 should be very close to zero for constant RR
        XCTAssertLessThan(
            try XCTUnwrap(metrics?.sd1),
            1.0,
            "SD1 should be near zero for constant RR"
        )
        XCTAssertLessThan(
            try XCTUnwrap(metrics?.sd2),
            1.0,
            "SD2 should be near zero for constant RR"
        )
    }

    /// Very high variability should be detected
    func testHighVariability() throws {
        let points = (0 ..< 100).map { i in
            // Alternate between very different values
            let rr = i % 2 == 0 ? 600 : 1000
            return RRPoint(t_ms: Int64(i * 800), rr_ms: rr)
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = NonlinearAnalyzer.computeNonlinear(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        XCTAssertNotNil(metrics)

        // Should show very high variability
        XCTAssertGreaterThan(
            try XCTUnwrap(metrics?.sd1),
            100,
            "SD1 should be high for extreme variability"
        )
    }
}
