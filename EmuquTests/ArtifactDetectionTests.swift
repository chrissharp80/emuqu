@testable import Emuqu
import XCTest

/// Artifact detection tests
final class ArtifactDetectionTests: XCTestCase {
    // Stored properties rather than implicitly-unwrapped optionals:
    // XCTest builds the test class once per test method, so these are
    // already fresh for every test.
    var detector = ArtifactDetector()

    // MARK: - Clean Beat Detection

    /// Normal physiological RR intervals should be marked clean
    func testCleanBeatsDetection() {
        // Normal RR intervals around 800ms (75 bpm)
        let points = (0 ..< 100).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + Int.random(in: -30 ... 30))
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = detector.detectArtifacts(in: series)

        let cleanCount = flags.filter { !$0.isArtifact }.count
        let cleanPercent = Double(cleanCount) / Double(flags.count) * 100

        XCTAssertGreaterThan(
            cleanPercent,
            95,
            "Normal variability should result in >95% clean beats. Got \(cleanPercent)%"
        )
    }

    // MARK: - Ectopic Detection

    /// Ectopic beats (short RR followed by long compensatory pause) should be detected
    func testEctopicDetection() {
        var points = [RRPoint]()
        var t: Int64 = 0

        // Build sequence with an ectopic
        for i in 0 ..< 50 {
            if i == 25 {
                // Ectopic: short interval followed by long pause
                points.append(RRPoint(t_ms: t, rr_ms: 500)) // Very short
                t += 500
                points.append(RRPoint(t_ms: t, rr_ms: 1100)) // Compensatory pause
                t += 1100
            } else {
                points.append(RRPoint(t_ms: t, rr_ms: 800))
                t += 800
            }
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = detector.detectArtifacts(in: series)

        // Find the ectopic
        var foundShort = false
        var foundLong = false

        for (i, flag) in flags.enumerated() {
            if points[i].rr_ms == 500, flag.isArtifact {
                foundShort = true
                XCTAssertTrue(
                    flag.type == .ectopic || flag.type == .extra,
                    "Short interval should be ectopic or extra"
                )
            }
            if points[i].rr_ms == 1100, flag.isArtifact {
                foundLong = true
                // Compensatory pause can be classified as either ectopic or missed
                XCTAssertTrue(
                    flag.type == .ectopic || flag.type == .missed,
                    "Long interval should be classified as ectopic or missed"
                )
            }
        }

        XCTAssertTrue(foundShort, "Should detect short ectopic interval")
        XCTAssertTrue(foundLong, "Should detect compensatory pause")
    }

    // MARK: - Technical Artifacts

    /// Out-of-range intervals should be marked as technical artifacts
    func testTechnicalArtifacts() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 150), // Below minimum (200ms)
            RRPoint(t_ms: 950, rr_ms: 800),
            RRPoint(t_ms: 1750, rr_ms: 2500), // Above maximum (2000ms)
            RRPoint(t_ms: 4250, rr_ms: 800)
        ]

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = detector.detectArtifacts(in: series)

        XCTAssertEqual(
            flags[1].type,
            .technical,
            "150ms interval should be technical artifact (below 200ms minimum)"
        )
        XCTAssertEqual(
            flags[3].type,
            .technical,
            "2500ms interval should be technical artifact (above 2000ms maximum)"
        )
    }

    // MARK: - Missed Beat Detection

    /// Missed beats (RR interval ~2x normal) should be detected
    func testMissedBeatDetection() {
        var points = [RRPoint]()
        var t: Int64 = 0

        for i in 0 ..< 20 {
            if i == 10 {
                // Missed beat: interval is ~2x normal
                points.append(RRPoint(t_ms: t, rr_ms: 1500))
                t += 1500
            } else {
                points.append(RRPoint(t_ms: t, rr_ms: 800))
                t += 800
            }
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = detector.detectArtifacts(in: series)

        XCTAssertTrue(flags[10].isArtifact, "Missed beat should be flagged")
        XCTAssertEqual(
            flags[10].type,
            .missed,
            "Should be classified as missed beat"
        )
    }

    // MARK: - Artifact Percentage

    /// Artifact percentage calculation should be correct
    func testArtifactPercentage() {
        let points = (0 ..< 100).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800)
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        var flags = detector.detectArtifacts(in: series)

        // Manually mark 10% as artifacts
        for i in 0 ..< 10 {
            flags[i] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)
        }

        let pct = detector.artifactPercentage(flags, start: 0, end: 100)
        XCTAssertEqual(
            pct,
            10.0,
            accuracy: 0.1,
            "Should report 10% artifacts. Got \(pct)%"
        )
    }

    /// Artifact percentage with window bounds
    func testArtifactPercentageWithBounds() {
        var flags = [ArtifactFlags](repeating: .clean, count: 100)

        // Mark indices 20-29 as artifacts (10 out of 100 total, but 100% of window 20-30)
        for i in 20 ..< 30 {
            flags[i] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)
        }

        let pctWindow = detector.artifactPercentage(flags, start: 20, end: 30)
        XCTAssertEqual(
            pctWindow,
            100.0,
            accuracy: 0.1,
            "Window 20-30 should be 100% artifacts"
        )

        let pctClean = detector.artifactPercentage(flags, start: 0, end: 20)
        XCTAssertEqual(
            pctClean,
            0.0,
            accuracy: 0.1,
            "Window 0-20 should be 0% artifacts"
        )
    }

    // MARK: - Search Clamp to 0

    /// Negative start index should be clamped to 0
    func testSearchClampToZero() {
        let flags = [ArtifactFlags](repeating: .clean, count: 50)

        // Should not crash with negative start
        let pct = detector.artifactPercentage(flags, start: -10, end: 20)
        XCTAssertEqual(pct, 0.0, "Should handle negative start gracefully")
    }

    // MARK: - Rolling Median Behavior

    /// Detector should handle edge effects at start/end of series
    func testEdgeEffects() throws {
        // First and last beats should still be analyzed correctly
        let points = (0 ..< 100).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800)
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = detector.detectArtifacts(in: series)

        // First and last should be clean for uniform data
        XCTAssertFalse(
            try XCTUnwrap(flags.first?.isArtifact),
            "First beat should not be artifact for uniform data"
        )
        XCTAssertFalse(
            try XCTUnwrap(flags.last?.isArtifact),
            "Last beat should not be artifact for uniform data"
        )
    }
}
