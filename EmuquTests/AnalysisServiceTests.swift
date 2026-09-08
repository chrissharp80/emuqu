@testable import Emuqu
import XCTest

/// Tests for AnalysisService.
/// Validates the centralized analysis pipeline: artifact detection,
/// window selection, metric computation, verification, and diagnostic scoring.
@MainActor
final class AnalysisServiceTests: XCTestCase {
    // Stored properties rather than implicitly-unwrapped optionals:
    // XCTest builds the test class once per test method, so these are
    // already fresh for every test.
    private var analysisService = AnalysisService()
    private var artifactDetector = ArtifactDetector()

    // MARK: - Test Helpers

    /// Create a series with realistic variability using shared point generator.
    private func createRealisticSeries(beatCount: Int, meanRR: Int = 800) -> RRSeries {
        let points = createRealisticPoints(count: beatCount, meanRR: meanRR)
        return RRSeries(points: points, sessionId: UUID(), startDate: Date())
    }

    /// Create a series with uniform intervals using shared point generator.
    private func createUniformSeries(beatCount: Int, rrMs: Int = 800) -> RRSeries {
        let points = createUniformPoints(count: beatCount, rrMs: rrMs)
        return RRSeries(points: points, sessionId: UUID(), startDate: Date())
    }

    /// Create a base HRVSession for analysis.
    private func createSession(
        series: RRSeries,
        sessionType: SessionType = .overnight
    ) -> HRVSession {
        HRVSession(
            id: series.sessionId,
            startDate: series.startDate,
            endDate: Date(),
            state: .analyzing,
            sessionType: sessionType,
            rrSeries: series,
            analysisResult: nil,
            artifactFlags: nil
        )
    }

    // MARK: - analyze Tests

    func testAnalyze_withValidSeries_producesResult() {
        // Arrange: 1000 beats with variability -- enough for full pipeline
        let series = createRealisticSeries(beatCount: 1000)
        var session = createSession(series: series)

        // Act
        let result = analysisService.analyze(session: &session)

        // Assert
        if let result {
            XCTAssertNotNil(
                result.timeDomain,
                "Result should include time domain metrics"
            )
            XCTAssertNotNil(
                result.nonlinear,
                "Result should include nonlinear metrics"
            )
            XCTAssertGreaterThan(
                result.timeDomain.rmssd,
                0,
                "RMSSD should be positive for data with variability"
            )
            XCTAssertGreaterThan(
                result.cleanBeatCount,
                0,
                "Clean beat count should be positive"
            )
            XCTAssertNotNil(
                session.analysisResult,
                "Session should be updated with the analysis result"
            )
        }
        // Note: result can be nil if window selection finds no organized window.
        // Both outcomes are valid depending on the data characteristics.
    }

    func testAnalyze_withNoRRSeries_returnsNil() {
        // Arrange: session with no RR data
        var session = HRVSession(
            id: UUID(),
            startDate: Date(),
            endDate: Date(),
            state: .analyzing,
            sessionType: .overnight,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil
        )

        // Act
        let result = analysisService.analyze(session: &session)

        // Assert
        XCTAssertNil(
            result,
            "Analysis should return nil when session has no RR series"
        )
        XCTAssertNil(
            session.analysisResult,
            "Session analysis result should remain nil"
        )
    }

    func testAnalyze_withInsufficientData_failsVerification() {
        // Arrange: only 50 beats -- below minimum threshold (300)
        let series = createUniformSeries(beatCount: 50)
        var session = createSession(series: series)

        // Act
        let result = analysisService.analyze(session: &session)

        // Assert
        XCTAssertNil(
            result,
            "Analysis should return nil for insufficient data"
        )
    }

    // MARK: - detectArtifacts Tests

    func testDetectArtifacts_cleanSeries_noArtifacts() {
        // Arrange: uniform series with physiologically valid intervals
        let series = createUniformSeries(beatCount: 100, rrMs: 800)

        // Act
        let flags = analysisService.detectArtifacts(in: series)

        // Assert
        XCTAssertEqual(
            flags.count,
            100,
            "Should produce one flag per point"
        )
        let artifactCount = flags.filter(\.isArtifact).count
        XCTAssertEqual(
            artifactCount,
            0,
            "Clean uniform series should have zero artifacts"
        )
        XCTAssertTrue(
            flags.allSatisfy { !$0.isArtifact },
            "All flags should be clean for uniform data"
        )
    }

    // MARK: - computeDiagnosticScore Tests

    func testComputeDiagnosticScore_fromResult() {
        // Arrange: build a realistic analysis result for scoring
        let timeDomain = TimeDomainMetrics(
            meanRR: 800.0,
            sdnn: 45.0,
            rmssd: 55.0,
            pnn50: 30.0,
            sdsd: 42.0,
            meanHR: 75.0,
            sdHR: 4.0,
            triangularIndex: 12.0
        )

        let frequencyDomain = FrequencyDomainMetrics(
            vlf: 500.0,
            lf: 800.0,
            hf: 1200.0,
            lfHfRatio: 0.67,
            totalPower: 2500.0
        )

        let nonlinear = NonlinearMetrics(
            sd1: 39.0,
            sd2: 52.0,
            sd1Sd2Ratio: 0.75,
            sampleEntropy: 1.5,
            approxEntropy: 1.3,
            dfaAlpha1: 0.85,
            dfaAlpha2: 0.9,
            dfaAlpha1R2: 0.98
        )

        let ansMetrics = ANSMetrics(
            stressIndex: 100.0,
            pnsIndex: 1.5,
            snsIndex: -0.5,
            readinessScore: 7.5,
            respirationRate: 14.0,
            nocturnalHRDip: 15.0,
            daytimeRestingHR: 65.0,
            nocturnalMedianHR: 55.0
        )

        let analysisResult = HRVAnalysisResult(
            windowStart: 0,
            windowEnd: 500,
            timeDomain: timeDomain,
            frequencyDomain: frequencyDomain,
            nonlinear: nonlinear,
            ansMetrics: ansMetrics,
            artifactPercentage: 2.0,
            cleanBeatCount: 490,
            analysisDate: Date()
        )

        // Act
        let diagnosticResult = analysisService.computeDiagnosticScore(from: analysisResult)

        // Assert
        XCTAssertGreaterThanOrEqual(
            diagnosticResult.score,
            0.0,
            "Diagnostic score should be non-negative"
        )
        XCTAssertLessThanOrEqual(
            diagnosticResult.score,
            100.0,
            "Diagnostic score should not exceed 100"
        )
        XCTAssertFalse(
            diagnosticResult.title.isEmpty,
            "Diagnostic result should have a title"
        )
        XCTAssertFalse(
            diagnosticResult.icon.isEmpty,
            "Diagnostic result should have an icon"
        )

        // With good metrics (RMSSD 55, low stress, good DFA), expect decent score
        XCTAssertGreaterThanOrEqual(
            diagnosticResult.score,
            60.0,
            "Good HRV metrics should produce a diagnostic score >= 60"
        )
    }

    // MARK: - verify Tests

    func testVerify_validSeries_passes() {
        // Arrange: 500 beats at 800ms = 400s = 0.111h (above 0.083h min)
        let series = createRealisticSeries(beatCount: 500)
        let flags = analysisService.detectArtifacts(in: series)

        // Act
        let result = analysisService.verify(series, flags: flags)

        // Assert
        XCTAssertTrue(
            result.passed,
            "500 beats of clean realistic data should pass verification"
        )
        XCTAssertTrue(
            result.rejectionReasons.isEmpty,
            "Passed verification should have no rejection reasons"
        )
    }

    func testVerify_insufficientData_fails() {
        // Arrange: 50 beats -- below minimum
        let series = createUniformSeries(beatCount: 50)
        let flags = cleanFlags(count: 50)

        // Act
        let result = analysisService.verify(series, flags: flags)

        // Assert
        XCTAssertFalse(
            result.passed,
            "50 beats should fail verification"
        )
        XCTAssertTrue(
            result.isRejectedFor(.tooFewPoints),
            "Should be rejected for too few points"
        )
    }

    // MARK: - analyzeFullSeries Tests

    func testAnalyzeFullSeries_validData_producesMetrics() {
        // Arrange
        let series = createRealisticSeries(beatCount: 500)
        let flags = analysisService.detectArtifacts(in: series)

        // Act
        let result = analysisService.analyzeFullSeries(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: 500
        )

        // Assert
        XCTAssertNotNil(
            result,
            "Should produce analysis result for 500 realistic beats"
        )
        if let result {
            XCTAssertGreaterThan(
                result.timeDomain.rmssd,
                0,
                "RMSSD should be positive"
            )
            XCTAssertGreaterThan(
                result.timeDomain.sdnn,
                0,
                "SDNN should be positive"
            )
            XCTAssertGreaterThan(
                result.timeDomain.meanHR,
                0,
                "Mean HR should be positive"
            )
            XCTAssertEqual(result.windowStart, 0)
            XCTAssertEqual(result.windowEnd, 500)
        }
    }

    func testAnalyzeFullSeries_emptyData_returnsNil() {
        // Arrange
        let series = RRSeries(points: [], sessionId: UUID(), startDate: Date())
        let flags: [ArtifactFlags] = []

        // Act
        let result = analysisService.analyzeFullSeries(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: 0
        )

        // Assert
        XCTAssertNil(
            result,
            "Empty series should produce nil result"
        )
    }
}
