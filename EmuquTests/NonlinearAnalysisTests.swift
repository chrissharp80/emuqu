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

    // MARK: - Removed beats and recording breaks

    /// Beats laid back to back from their intervals.
    private func contiguousPoints(_ rrs: [Int], from start: Int64 = 0) -> [RRPoint] {
        var t = start
        return rrs.map { rr in
            defer { t += Int64(rr) }
            return RRPoint(t_ms: t, rr_ms: rr)
        }
    }

    private func flags(count: Int, flagged: Set<Int>) -> [ArtifactFlags] {
        (0 ..< count).map {
            flagged.contains($0) ? ArtifactFlags(isArtifact: true, type: .technical, confidence: 1.0) : .clean
        }
    }

    private func series(_ points: [RRPoint]) -> RRSeries {
        RRSeries(points: points, sessionId: UUID(), startDate: Date())
    }

    private func nonlinear(_ points: [RRPoint], flagged: Set<Int> = []) throws -> NonlinearMetrics {
        try XCTUnwrap(NonlinearAnalyzer.computeNonlinear(
            series(points), flags: flags(count: points.count, flagged: flagged),
            windowStart: 0, windowEnd: points.count
        ))
    }

    /// Twenty constant blocks of ten beats, 800 and 900 ms in turn, each
    /// followed by one flagged 1500 ms beat.
    private func constantBlocks() -> (points: [RRPoint], flagged: Set<Int>) {
        var rrs: [Int] = []
        var flagged = Set<Int>()
        for block in 0 ..< 20 {
            rrs += Array(repeating: block.isMultiple(of: 2) ? 800 : 900, count: 10)
            flagged.insert(rrs.count)
            rrs.append(1_500)
        }
        return (contiguousPoints(rrs), flagged)
    }

    /// Every pair of neighbouring clean beats differs by 0, so SD1 is 0, as
    /// RMSSD is. Differencing the clean beats joined across the flagged ones
    /// made each 800/900 boundary a neighbour pair and read SD1 ≈ 22 ms.
    func testSD1IsZeroForConstantBlocksSeparatedByRemovedBeats() throws {
        let (points, flagged) = constantBlocks()
        let metrics = try nonlinear(points, flagged: flagged)
        XCTAssertEqual(metrics.sd1, 0, accuracy: 1e-9)
        // Half the clean beats at 800 and half at 900: Var(RR) = 50², and
        // SD2² = 2·Var(RR) − SD1².
        XCTAssertEqual(metrics.sd2, (5_000.0).squareRoot(), accuracy: 1e-9)
        let timeDomain = try XCTUnwrap(TimeDomainAnalyzer.computeTimeDomain(
            series(points), flags: flags(count: points.count, flagged: flagged),
            windowStart: 0, windowEnd: points.count
        ))
        XCTAssertEqual(timeDomain.rmssd, 0, accuracy: 1e-9)
    }

    /// SD1 comes from the same neighbouring pairs as SDSD. SD1² is half
    /// their population variance and SDSD² their sample variance, so over
    /// n pairs SD1² = SDSD²·(n − 1)/(2n), with beats removed.
    func testSD1MatchesSDSDOverTheSameAdjacentPairs() throws {
        var generator = DFAReferenceValidationTests.SeededGenerator(seed: 0xB1)
        let rrs = (0 ..< 200).map { _ in 800 + Int.random(in: -30 ... 30, using: &generator) }
        let flagged: Set<Int> = [20, 21, 57, 90, 133, 170]
        let points = contiguousPoints(rrs)
        let metrics = try nonlinear(points, flagged: flagged)
        let timeDomain = try XCTUnwrap(TimeDomainAnalyzer.computeTimeDomain(
            series(points), flags: flags(count: points.count, flagged: flagged),
            windowStart: 0, windowEnd: points.count
        ))
        // ±30 ms around 800 stays inside the 20% ectopic gate, so every
        // pair of neighbouring clean beats counts.
        let n = Double((1 ..< rrs.count).count { !flagged.contains($0) && !flagged.contains($0 - 1) })
        XCTAssertEqual(metrics.sd1 * metrics.sd1, timeDomain.sdsd * timeDomain.sdsd * (n - 1) / (2 * n), accuracy: 1e-6)
    }

    /// Two constant runs, 800 then 900 ms, the second starting a minute
    /// after the first ends: a recording break, so no Poincaré point pairs
    /// them and SD1 is 0. Back to back they are neighbours, and SD1 is not.
    func testSD1DoesNotPairBeatsAcrossARecordingBreak() throws {
        let first = contiguousPoints(Array(repeating: 800, count: 30))
        let resume = (first.last?.endMs ?? 0) + 60_000
        let second = contiguousPoints(Array(repeating: 900, count: 30), from: resume)
        XCTAssertEqual(try nonlinear(first + second).sd1, 0, accuracy: 1e-9)
        let backToBack = contiguousPoints(Array(repeating: 800, count: 30) + Array(repeating: 900, count: 30))
        XCTAssertGreaterThan(try nonlinear(backToBack).sd1, 1)
    }

    /// Entropy templates stay inside a run of neighbouring beats. Within a
    /// constant block every template matches every other at its level, so
    /// both entropies are 0; templates spanning a flagged beat would mix the
    /// two levels and read sample entropy ≈ 0.21.
    func testEntropyTemplatesDoNotSpanARemovedBeat() throws {
        let (points, flagged) = constantBlocks()
        let metrics = try nonlinear(points, flagged: flagged)
        XCTAssertEqual(try XCTUnwrap(metrics.sampleEntropy), 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(metrics.approxEntropy), 0, accuracy: 1e-12)
    }

    /// DFA boxes stay on one side of a recording break: α1 is the DFA of
    /// the two runs as separate segments, not of the runs joined, whose
    /// 150 ms level step the boxes spanning it would read as correlation.
    func testDFADoesNotBoxAcrossARecordingBreak() throws {
        let firstRR = (0 ..< 200).map { 800 + Int(40 * sin(Double($0) * 2.3)) }
        let secondRR = (200 ..< 400).map { 950 + Int(40 * sin(Double($0) * 2.3)) }
        let first = contiguousPoints(firstRR)
        let second = contiguousPoints(secondRR, from: (first.last?.endMs ?? 0) + 60_000)
        let alpha1 = try XCTUnwrap(nonlinear(first + second).dfaAlpha1)
        let segments = [firstRR.map(Double.init), secondRR.map(Double.init)]
        let segmented = try XCTUnwrap(DFAAnalyzer.compute(segments: segments)).alpha1
        let joined = try XCTUnwrap(DFAAnalyzer.compute(segments.flatMap { $0 })).alpha1
        XCTAssertEqual(alpha1, segmented, accuracy: 1e-12)
        XCTAssertNotEqual(alpha1, joined, accuracy: 0.1)
    }

    /// A flagged beat keeps its place in the beat index for DFA, filled by
    /// linear interpolation between its kept neighbours.
    func testDFAInterpolatesRemovedBeats() throws {
        var rrs = (0 ..< 300).map { 800 + Int(40 * sin(Double($0) * 2.3)) }
        let flagged: Set<Int> = [50, 51, 120, 200]
        var expected = rrs.map(Double.init)
        expected[50] = expected[49] + (expected[52] - expected[49]) / 3
        expected[51] = expected[49] + (expected[52] - expected[49]) * 2 / 3
        expected[120] = (expected[119] + expected[121]) / 2
        expected[200] = (expected[199] + expected[201]) / 2
        for i in flagged {
            rrs[i] = 1_600
        }
        let alpha1 = try XCTUnwrap(nonlinear(contiguousPoints(rrs), flagged: flagged).dfaAlpha1)
        XCTAssertEqual(alpha1, try XCTUnwrap(DFAAnalyzer.compute(expected)).alpha1, accuracy: 1e-9)
    }
}
