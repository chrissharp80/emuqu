@testable import Emuqu
import XCTest

/// Extended artifact detection and correction tests
final class ArtifactCorrectionTests: XCTestCase {
    let detector = ArtifactDetector()

    // MARK: - Correction Method Tests

    /// Test deletion correction
    func testDeletionCorrection() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 810),
            RRPoint(t_ms: 1610, rr_ms: 300), // Artifact
            RRPoint(t_ms: 1910, rr_ms: 820),
            RRPoint(t_ms: 2730, rr_ms: 800)
        ]

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[2] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)

        let rrValues = points.map(\.rr_ms)

        let (corrected, newFlags) = ArtifactCorrector.correct(
            rrValues: rrValues,
            flags: flags,
            method: .deletion
        )

        // Should have one fewer value
        XCTAssertEqual(corrected.count, points.count - 1)

        // Artifact should be gone
        XCTAssertFalse(newFlags.contains { $0.isArtifact })
    }

    /// Test linear interpolation correction
    func testLinearInterpolation() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 810),
            RRPoint(t_ms: 1610, rr_ms: 300), // Artifact - should interpolate to ~820
            RRPoint(t_ms: 1910, rr_ms: 830),
            RRPoint(t_ms: 2740, rr_ms: 840)
        ]

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[2] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)

        let rrValues = points.map(\.rr_ms)

        let (corrected, newFlags) = ArtifactCorrector.correct(
            rrValues: rrValues,
            flags: flags,
            method: .linearInterpolation
        )

        // Should maintain same length
        XCTAssertEqual(corrected.count, points.count)

        // Corrected value should be reasonable (between 810 and 830)
        XCTAssertGreaterThan(corrected[2], 800)
        XCTAssertLessThan(corrected[2], 850)

        // Flag should show correction
        XCTAssertTrue(newFlags[2].corrected)
        XCTAssertFalse(newFlags[2].isArtifact)
    }

    /// Test cubic interpolation
    func testCubicInterpolation() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 820),
            RRPoint(t_ms: 1620, rr_ms: 850),
            RRPoint(t_ms: 2470, rr_ms: 200), // Artifact
            RRPoint(t_ms: 2670, rr_ms: 900),
            RRPoint(t_ms: 3570, rr_ms: 920),
            RRPoint(t_ms: 4490, rr_ms: 930)
        ]

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[3] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)

        let rrValues = points.map(\.rr_ms)

        let (corrected, newFlags) = ArtifactCorrector.correct(
            rrValues: rrValues,
            flags: flags,
            method: .cubicSpline
        )

        // Should maintain length
        XCTAssertEqual(corrected.count, points.count)

        // Cubic should provide smooth interpolation
        XCTAssertGreaterThan(corrected[3], 850)
        XCTAssertLessThan(corrected[3], 920)

        XCTAssertTrue(newFlags[3].corrected)
    }

    /// Test median replacement
    func testMedianReplacement() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 795),
            RRPoint(t_ms: 795, rr_ms: 800),
            RRPoint(t_ms: 1595, rr_ms: 805),
            RRPoint(t_ms: 2400, rr_ms: 200), // Artifact
            RRPoint(t_ms: 2600, rr_ms: 810),
            RRPoint(t_ms: 3410, rr_ms: 815),
            RRPoint(t_ms: 4225, rr_ms: 820)
        ]

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[3] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)

        let rrValues = points.map(\.rr_ms)

        let (corrected, newFlags) = ArtifactCorrector.correct(
            rrValues: rrValues,
            flags: flags,
            method: .median
        )

        // Median of surrounding clean values should be ~808
        XCTAssertGreaterThan(corrected[3], 795)
        XCTAssertLessThan(corrected[3], 820)

        XCTAssertTrue(newFlags[3].corrected)
    }

    // MARK: - Multiple Consecutive Artifacts

    /// Test handling consecutive artifacts
    func testConsecutiveArtifacts() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 810),
            RRPoint(t_ms: 1610, rr_ms: 200), // Artifact 1
            RRPoint(t_ms: 1810, rr_ms: 250), // Artifact 2
            RRPoint(t_ms: 2060, rr_ms: 220), // Artifact 3
            RRPoint(t_ms: 2280, rr_ms: 830),
            RRPoint(t_ms: 3110, rr_ms: 840)
        ]

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[2] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)
        flags[3] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)
        flags[4] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)

        let rrValues = points.map(\.rr_ms)

        let (corrected, newFlags) = ArtifactCorrector.correct(
            rrValues: rrValues,
            flags: flags,
            method: .linearInterpolation
        )

        // All three should be corrected
        for i in 2 ... 4 {
            XCTAssertTrue(
                newFlags[i].corrected,
                "Artifact at index \(i) should be corrected"
            )
            XCTAssertGreaterThan(
                corrected[i],
                700,
                "Corrected value should be reasonable"
            )
            XCTAssertLessThan(
                corrected[i],
                900,
                "Corrected value should be reasonable"
            )
        }
    }

    /// Test very long artifact sequence
    func testLongArtifactSequence() {
        var points = [RRPoint]()
        points.append(RRPoint(t_ms: 0, rr_ms: 800))
        points.append(RRPoint(t_ms: 800, rr_ms: 810))

        // Add 20 consecutive artifacts
        for i in 0 ..< 20 {
            points.append(RRPoint(t_ms: Int64(1600 + i * 300), rr_ms: 200))
        }

        points.append(RRPoint(t_ms: 7600, rr_ms: 820))
        points.append(RRPoint(t_ms: 8420, rr_ms: 830))

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        for i in 2 ..< 22 {
            flags[i] = ArtifactFlags(isArtifact: true, type: .technical, confidence: 1.0)
        }

        let rrValues = points.map(\.rr_ms)

        let (corrected, _) = ArtifactCorrector.correct(
            rrValues: rrValues,
            flags: flags,
            method: .linearInterpolation
        )

        // Should interpolate smoothly across long gap
        for i in 2 ..< 22 {
            XCTAssertGreaterThan(corrected[i], 700)
            XCTAssertLessThan(corrected[i], 900)
        }
    }

    // MARK: - Edge Case Correction

    /// Test artifact at beginning
    func testArtifactAtBeginning() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 200), // Artifact at start
            RRPoint(t_ms: 200, rr_ms: 800),
            RRPoint(t_ms: 1000, rr_ms: 810),
            RRPoint(t_ms: 1810, rr_ms: 820)
        ]

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[0] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)

        let rrValues = points.map(\.rr_ms)

        let (corrected, newFlags) = ArtifactCorrector.correct(
            rrValues: rrValues,
            flags: flags,
            method: .linearInterpolation
        )

        // Should handle gracefully
        XCTAssertEqual(corrected.count, points.count)
        XCTAssertTrue(newFlags[0].corrected || newFlags[0].isArtifact)
    }

    /// Test artifact at end
    func testArtifactAtEnd() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 810),
            RRPoint(t_ms: 1610, rr_ms: 820),
            RRPoint(t_ms: 2430, rr_ms: 200) // Artifact at end
        ]

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[3] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)

        let rrValues = points.map(\.rr_ms)

        let (corrected, newFlags) = ArtifactCorrector.correct(
            rrValues: rrValues,
            flags: flags,
            method: .linearInterpolation
        )

        // Should handle gracefully
        XCTAssertEqual(corrected.count, points.count)
        XCTAssertTrue(newFlags[3].corrected || newFlags[3].isArtifact)
    }

    // MARK: - Correction Quality

    /// Test that correction preserves HRV metrics reasonably
    func testCorrectionPreservesMetrics() throws {
        // Create clean data
        var points = (0 ..< 200).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + Int.random(in: -30 ... 30))
        }

        _ = points.map(\.rr_ms)
        let originalFlags = [ArtifactFlags](repeating: .clean, count: points.count)

        // Calculate original RMSSD
        let originalMetrics = TimeDomainAnalyzer.computeTimeDomain(
            RRSeries(points: points, sessionId: UUID(), startDate: Date()),
            flags: originalFlags,
            windowStart: 0,
            windowEnd: points.count
        )

        // Add some artifacts
        var artifactFlags = originalFlags
        for i in [20, 50, 80, 120, 150] {
            points[i] = RRPoint(t_ms: points[i].t_ms, rr_ms: 200)
            artifactFlags[i] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)
        }

        // Correct artifacts
        let artifactRR = points.map(\.rr_ms)
        let (corrected, correctedFlags) = ArtifactCorrector.correct(
            rrValues: artifactRR,
            flags: artifactFlags,
            method: .cubicSpline
        )

        // Calculate corrected RMSSD
        let correctedPoints = corrected.enumerated().map { i, rr in
            RRPoint(t_ms: Int64(i * 800), rr_ms: rr)
        }

        let correctedMetrics = TimeDomainAnalyzer.computeTimeDomain(
            RRSeries(points: correctedPoints, sessionId: UUID(), startDate: Date()),
            flags: correctedFlags,
            windowStart: 0,
            windowEnd: correctedPoints.count
        )

        let originalTimeDomain = try XCTUnwrap(originalMetrics)
        let correctedTimeDomain = try XCTUnwrap(correctedMetrics)

        // Corrected metrics should be reasonably close to original
        let rmssdDifference = abs(correctedTimeDomain.rmssd - originalTimeDomain.rmssd)
        let rmssdPercentDiff = (rmssdDifference / originalTimeDomain.rmssd) * 100

        XCTAssertLessThan(
            rmssdPercentDiff,
            20.0,
            "Corrected RMSSD should be within 20% of original clean data"
        )
    }

    // MARK: - Performance Tests

    /// Test correction performance on large dataset
    func testCorrectionPerformance() {
        let points = (0 ..< 10000).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + Int.random(in: -50 ... 50))
        }

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)

        // Add 5% artifacts randomly
        for _ in 0 ..< 500 {
            let idx = Int.random(in: 0 ..< points.count)
            flags[idx] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)
        }

        let rrValues = points.map(\.rr_ms)

        measure {
            _ = ArtifactCorrector.correct(
                rrValues: rrValues,
                flags: flags,
                method: .cubicSpline
            )
        }
    }
}
