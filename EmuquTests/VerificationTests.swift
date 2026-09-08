@testable import Emuqu
import XCTest

/// Tests for session data verification (design spec v8.1)
final class VerificationTests: XCTestCase {
    // MARK: - Helpers

    /// Build an RR series with uniform intervals and the given point count and RR value.
    /// Duration in ms = count * rr_ms (approximately).
    private func makeSeries(count: Int, rr_ms: Int = 800) -> RRSeries {
        let points = (0 ..< count).map { i in
            RRPoint(t_ms: Int64(i) * Int64(rr_ms), rr_ms: rr_ms)
        }
        return RRSeries(points: points, sessionId: UUID(), startDate: Date())
    }

    /// Build flags where the first `artifactCount` entries are artifacts.
    private func flagsWithArtifacts(total: Int, artifactCount: Int, type: ArtifactFlags.ArtifactType = .technical) -> [ArtifactFlags] {
        var flags = [ArtifactFlags]()
        for i in 0 ..< total {
            if i < artifactCount {
                flags.append(ArtifactFlags(isArtifact: true, type: type, confidence: 0.9))
            } else {
                flags.append(.clean)
            }
        }
        return flags
    }

    /// Build flags with ectopic artifacts.
    private func flagsWithEctopy(total: Int, ectopyCount: Int) -> [ArtifactFlags] {
        flagsWithArtifacts(total: total, artifactCount: ectopyCount, type: .ectopic)
    }

    // MARK: - Too Few Points

    func testTooFewPointsRejection() {
        let verification = Verification()
        let series = makeSeries(count: 100, rr_ms: 800) // 100 points < 300 minimum
        let flags = cleanFlags(count: 100)

        let result = verification.verify(series, flags: flags)

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.isRejectedFor(.tooFewPoints))
        XCTAssertEqual(result.rejectionReasons.count, 1)
        XCTAssertEqual(result.metrics.pointCount, 100)
    }

    func testExactMinimumPointsPasses() {
        // 300 points at 800ms = 240s = 0.067h — below default 0.083h min,
        // so this will be rejected for tooShort but NOT for tooFewPoints
        let verification = Verification()
        let series = makeSeries(count: 300, rr_ms: 800)
        let flags = cleanFlags(count: 300)

        let result = verification.verify(series, flags: flags)

        XCTAssertFalse(result.isRejectedFor(.tooFewPoints), "300 points should meet the minimum")
    }

    func testZeroPointsRejection() {
        let verification = Verification()
        let series = RRSeries(points: [], sessionId: UUID(), startDate: Date())

        let result = verification.verify(series, flags: [])

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.isRejectedFor(.tooFewPoints))
    }

    // MARK: - Too Short Duration

    func testTooShortDurationRejection() {
        // 300 points at 800ms = 240,000ms = 0.067h < 0.083h minimum
        let verification = Verification()
        let series = makeSeries(count: 300, rr_ms: 800)
        let flags = cleanFlags(count: 300)

        let result = verification.verify(series, flags: flags)

        XCTAssertTrue(result.isRejectedFor(.tooShort))
    }

    func testAdequateDurationPasses() {
        // 400 points at 800ms = 320,000ms = 0.089h > 0.083h minimum
        let verification = Verification()
        let series = makeSeries(count: 400, rr_ms: 800)
        let flags = cleanFlags(count: 400)

        let result = verification.verify(series, flags: flags)

        XCTAssertFalse(result.isRejectedFor(.tooShort))
    }

    // MARK: - Excessive Artifacts

    func testExcessiveArtifactsRejection() {
        // 20% artifacts > 15% default max
        let verification = Verification()
        let count = 500
        let series = makeSeries(count: count, rr_ms: 1000) // 500s = 0.139h, enough duration
        let artifactCount = 100 // 20%
        let flags = flagsWithArtifacts(total: count, artifactCount: artifactCount)

        let result = verification.verify(series, flags: flags)

        XCTAssertTrue(result.isRejectedFor(.excessiveArtifacts))
    }

    func testArtifactsBelowThresholdPasses() {
        // 3% artifacts < 5% warn threshold
        let verification = Verification()
        let count = 500
        let series = makeSeries(count: count, rr_ms: 1000)
        let artifactCount = 15 // 3%
        let flags = flagsWithArtifacts(total: count, artifactCount: artifactCount)

        let result = verification.verify(series, flags: flags)

        XCTAssertFalse(result.isRejectedFor(.excessiveArtifacts))
        XCTAssertTrue(result.warnings.isEmpty || !result.warnings.contains(where: { $0.contains("Artifacts") }))
    }

    func testArtifactsInWarningRange() {
        // 8% artifacts: above 5% warn but below 15% max
        let verification = Verification()
        let count = 500
        let series = makeSeries(count: count, rr_ms: 1000)
        let artifactCount = 40 // 8%
        let flags = flagsWithArtifacts(total: count, artifactCount: artifactCount)

        let result = verification.verify(series, flags: flags)

        XCTAssertFalse(result.isRejectedFor(.excessiveArtifacts), "8% should not be rejected")
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("Artifacts") }), "8% should produce a warning")
    }

    // MARK: - Excessive Ectopy

    func testExcessiveEctopyRejection() {
        // >10% ectopic beats
        let verification = Verification()
        let count = 500
        let series = makeSeries(count: count, rr_ms: 1000)
        let ectopyCount = 60 // 12%
        let flags = flagsWithEctopy(total: count, ectopyCount: ectopyCount)

        let result = verification.verify(series, flags: flags)

        XCTAssertTrue(result.isRejectedFor(.excessiveEctopy))
    }

    func testModerateEctopyWarning() {
        // >100 ectopic beats but <10% → warning not rejection
        let verification = Verification()
        let count = 5000
        let series = makeSeries(count: count, rr_ms: 1000)
        let ectopyCount = 150 // 3% but >100 count
        let flags = flagsWithEctopy(total: count, ectopyCount: ectopyCount)

        let result = verification.verify(series, flags: flags)

        XCTAssertFalse(result.isRejectedFor(.excessiveEctopy))
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("ectopy") }))
    }

    // MARK: - Signal Loss (Gap Detection)

    func testSignalLossRejection() {
        // Insert a >5 second gap
        let verification = Verification()
        var points = [RRPoint]()
        var t: Int64 = 0
        for _ in 0 ..< 250 {
            points.append(RRPoint(t_ms: t, rr_ms: 800))
            t += 800
        }
        // 10-second gap
        t += 10000
        for _ in 0 ..< 250 {
            points.append(RRPoint(t_ms: t, rr_ms: 800))
            t += 800
        }
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = cleanFlags(count: 500)

        let result = verification.verify(series, flags: flags)

        XCTAssertTrue(result.isRejectedFor(.signalLoss))
    }

    func testNoSignalLossWithSmallGaps() {
        // Gaps under 5s should not trigger signalLoss
        let verification = Verification()
        var points = [RRPoint]()
        var t: Int64 = 0
        for _ in 0 ..< 250 {
            points.append(RRPoint(t_ms: t, rr_ms: 800))
            t += 800
        }
        t += 3000 // 3-second gap — under threshold
        for _ in 0 ..< 250 {
            points.append(RRPoint(t_ms: t, rr_ms: 800))
            t += 800
        }
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = cleanFlags(count: 500)

        let result = verification.verify(series, flags: flags)

        XCTAssertFalse(result.isRejectedFor(.signalLoss))
    }

    // MARK: - Excessive Drift

    func testExcessiveDriftRejection() {
        // First 10% at 600ms, last 10% at 1100ms → drift of 500ms > 400ms threshold
        let verification = Verification()
        let count = 500
        var points = [RRPoint]()
        var t: Int64 = 0
        for i in 0 ..< count {
            let rr = if i < 50 {
                600 // First 10%
            } else if i >= 450 {
                1100 // Last 10%
            } else {
                800
            }
            points.append(RRPoint(t_ms: t, rr_ms: rr))
            t += Int64(rr)
        }
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = cleanFlags(count: count)

        let result = verification.verify(series, flags: flags)

        XCTAssertTrue(result.isRejectedFor(.excessiveDrift))
    }

    func testModerateDriftWarningOnly() {
        // First 10% at 700ms, last 10% at 1000ms → drift of 300ms: warning but not rejection
        let verification = Verification()
        let count = 500
        var points = [RRPoint]()
        var t: Int64 = 0
        for i in 0 ..< count {
            let rr = if i < 50 {
                700
            } else if i >= 450 {
                1000
            } else {
                800
            }
            points.append(RRPoint(t_ms: t, rr_ms: rr))
            t += Int64(rr)
        }
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = cleanFlags(count: count)

        let result = verification.verify(series, flags: flags)

        XCTAssertFalse(result.isRejectedFor(.excessiveDrift))
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("drift") }))
    }

    // MARK: - Out of Bounds Intervals

    func testOutOfBoundsRejection() {
        // >5% out of physiological range
        let verification = Verification()
        let count = 500
        var points = [RRPoint]()
        var t: Int64 = 0
        // 30 points (6%) with very short intervals (<300ms)
        for _ in 0 ..< 30 {
            points.append(RRPoint(t_ms: t, rr_ms: 200))
            t += 200
        }
        for _ in 30 ..< count {
            points.append(RRPoint(t_ms: t, rr_ms: 800))
            t += 800
        }
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        // Flag the short ones as technical artifacts
        var flags = [ArtifactFlags]()
        for i in 0 ..< count {
            if i < 30 {
                flags.append(ArtifactFlags(isArtifact: true, type: .technical, confidence: 0.9))
            } else {
                flags.append(.clean)
            }
        }

        let result = verification.verify(series, flags: flags)

        XCTAssertTrue(result.isRejectedFor(.outOfBoundsIntervals))
    }

    // MARK: - Multiple Rejection Reasons

    func testMultipleRejectionReasons() {
        // Short duration + excessive artifacts
        let verification = Verification()
        let count = 300 // Just at minimum points
        let series = makeSeries(count: count, rr_ms: 500) // 150s = 0.042h < 0.083h
        let artifactCount = 60 // 20% > 15% max
        let flags = flagsWithArtifacts(total: count, artifactCount: artifactCount)

        let result = verification.verify(series, flags: flags)

        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.rejectionReasons.count >= 2)
        XCTAssertTrue(result.isRejectedFor(.tooShort))
        XCTAssertTrue(result.isRejectedFor(.excessiveArtifacts))
    }

    // MARK: - Passing Verification

    func testCleanSessionPasses() {
        // 500 points at 1000ms = 500s = 0.139h > 0.083h, no artifacts
        let verification = Verification()
        let series = makeSeries(count: 500, rr_ms: 1000)
        let flags = cleanFlags(count: 500)

        let result = verification.verify(series, flags: flags)

        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.rejectionReasons.isEmpty)
        XCTAssertEqual(result.metrics.pointCount, 500)
        XCTAssertEqual(result.metrics.artifactPercent, 0, accuracy: 0.01)
    }

    // MARK: - Custom Config

    func testStreamingConfigRelaxedThresholds() {
        let config = Verification.Config(
            minPoints: 120,
            minDurationHours: 0.025,
            maxArtifactPercent: 20.0,
            warnArtifactPercent: 10.0
        )
        let verification = Verification(config: config)

        // 150 points at 1000ms = 150s = 0.042h > 0.025h
        let series = makeSeries(count: 150, rr_ms: 1000)
        let flags = cleanFlags(count: 150)

        let result = verification.verify(series, flags: flags)

        XCTAssertTrue(result.passed, "Streaming config should accept shorter sessions")
    }

    func testStrictConfigRejectsShortDuration() {
        let verification = Verification(config: .strict)

        // 500 points at 1000ms = 500s = 0.139h < 4.0h strict minimum
        let series = makeSeries(count: 500, rr_ms: 1000)
        let flags = cleanFlags(count: 500)

        let result = verification.verify(series, flags: flags)

        XCTAssertTrue(result.isRejectedFor(.tooShort))
    }

    // MARK: - Metrics Accuracy

    func testMetricsAreAccurate() {
        let verification = Verification()
        let count = 500
        let artifactCount = 25 // 5%
        let series = makeSeries(count: count, rr_ms: 1000)
        let flags = flagsWithArtifacts(total: count, artifactCount: artifactCount, type: .ectopic)

        let result = verification.verify(series, flags: flags)

        XCTAssertEqual(result.metrics.pointCount, count)
        XCTAssertEqual(result.metrics.nnCount, count - artifactCount)
        XCTAssertEqual(result.metrics.ectopyCount, artifactCount)
        XCTAssertEqual(result.metrics.artifactPercent, 5.0, accuracy: 0.01)
    }

    // MARK: - Result Summary

    func testPassedSummary() {
        let verification = Verification()
        let series = makeSeries(count: 500, rr_ms: 1000)
        let flags = cleanFlags(count: 500)

        let result = verification.verify(series, flags: flags)

        XCTAssertTrue(result.summary.contains("Passed"))
    }

    func testRejectedSummaryContainsReasonNames() {
        let verification = Verification()
        let series = makeSeries(count: 50) // too few
        let flags = cleanFlags(count: 50)

        let result = verification.verify(series, flags: flags)

        XCTAssertTrue(result.summary.contains("Rejected"))
        XCTAssertTrue(result.summary.contains("Insufficient Data Points"))
    }
}
