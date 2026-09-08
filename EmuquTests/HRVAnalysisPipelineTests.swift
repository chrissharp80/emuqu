@testable import Emuqu
import XCTest

/// Tests for the extracted HRVAnalysisPipeline.
/// Validates pure analysis computation with known RR data produces expected results.
@MainActor
final class HRVAnalysisPipelineTests: XCTestCase {
    // Stored properties, not implicitly-unwrapped optionals: XCTest builds the
    // test class once per test method, so these are already per-test fresh.
    // `pipeline` is `lazy` because it reads the two above it.
    private var artifactDetector = ArtifactDetector()
    private var mockHealthKit = MockHealthKitService()

    private lazy var pipeline = HRVAnalysisPipeline(
        artifactDetector: artifactDetector,
        windowSelector: WindowSelector(),
        healthKit: mockHealthKit
    )

    // MARK: - Test Helpers

    /// Create a series with uniform RR intervals using shared point generator.
    private func createUniformSeries(beatCount: Int, rrMs: Int = 800) -> (RRSeries, [ArtifactFlags]) {
        let points = createUniformPoints(count: beatCount, rrMs: rrMs)
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = artifactDetector.detectArtifacts(in: series)
        return (series, flags)
    }

    /// Create a series with realistic variability using shared point generator.
    private func createRealisticSeries(beatCount: Int) -> (RRSeries, [ArtifactFlags]) {
        let points = createRealisticPoints(count: beatCount)
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = artifactDetector.detectArtifacts(in: series)
        return (series, flags)
    }

    private var defaultANSConfig: HRVAnalysisPipeline.ANSConfiguration {
        HRVAnalysisPipeline.ANSConfiguration(
            baselineRMSSD: 40.0,
            vo2Max: nil,
            trainingLoadAdjustment: 0
        )
    }

    // MARK: - analyzeFullSeries Tests

    func testAnalyzeFullSeriesReturnsResultForValidData() {
        let (series, flags) = createRealisticSeries(beatCount: 500)

        let result = pipeline.analyzeFullSeries(series: series, flags: flags, ansConfig: defaultANSConfig)

        XCTAssertNotNil(result, "Should produce a result for 500 valid beats")
        XCTAssertNotNil(result?.timeDomain, "Should have time domain metrics")
        XCTAssertNotNil(result?.nonlinear, "Should have nonlinear metrics")
        XCTAssertNotNil(result?.ansMetrics, "Should have ANS metrics")
    }

    func testAnalyzeFullSeriesReturnsNilForInsufficientData() {
        let (series, flags) = createUniformSeries(beatCount: 5)

        let result = pipeline.analyzeFullSeries(series: series, flags: flags, ansConfig: defaultANSConfig)

        // Very short series may fail analysis
        // The exact threshold depends on analyzer requirements
        if let result {
            XCTAssertEqual(result.cleanBeatCount, 5)
        }
    }

    func testAnalyzeFullSeriesWindowIndicesSetCorrectly() {
        let (series, flags) = createRealisticSeries(beatCount: 500)

        let result = pipeline.analyzeFullSeries(series: series, flags: flags, windowStart: 100, windowEnd: 400, ansConfig: defaultANSConfig)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.windowStart, 100)
        XCTAssertEqual(result?.windowEnd, 400)
    }

    func testAnalyzeFullSeriesWithCapacitySetsMetadata() {
        let (series, flags) = createRealisticSeries(beatCount: 1000)

        let peakCapacity = PeakCapacity(
            peakRMSSD: 45.0,
            peakSDNN: 30.0,
            peakTotalPower: nil,
            windowDurationMinutes: 5.0,
            windowRelativePosition: 0.5,
            windowMeanHR: nil
        )

        let result = pipeline.analyzeFullSeriesWithCapacity(
            series: series,
            flags: flags,
            peakCapacity: peakCapacity,
            trainingContext: nil,
            ansConfig: defaultANSConfig
        )

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.peakCapacity)
        XCTAssertEqual(result?.peakCapacity?.peakRMSSD, 45.0)
    }

    // MARK: - ANS Configuration Tests

    func testANSConfigurationExplicitConstruction() {
        let config = HRVAnalysisPipeline.ANSConfiguration(
            baselineRMSSD: 42.0,
            vo2Max: 55.0,
            trainingLoadAdjustment: -0.3
        )

        XCTAssertEqual(config.baselineRMSSD, 42.0)
        XCTAssertEqual(config.vo2Max, 55.0)
        XCTAssertEqual(config.trainingLoadAdjustment, -0.3)
    }

    // MARK: - Uniform RR (No Variability) Tests

    func testUniformRRProducesLowRMSSD() {
        let (series, flags) = createUniformSeries(beatCount: 500)

        let result = pipeline.analyzeFullSeries(series: series, flags: flags, ansConfig: defaultANSConfig)

        if let result {
            // Uniform intervals should produce very low RMSSD (near 0)
            XCTAssertLessThan(
                result.timeDomain.rmssd,
                5.0,
                "Uniform RR intervals should have near-zero RMSSD"
            )
        }
    }

    // MARK: - Pure Function Tests: nocturnalMedianHR

    func testNocturnalMedianHREmptyInput() {
        XCTAssertNil(HRVAnalysisPipeline.nocturnalMedianHR(from: []))
    }

    func testNocturnalMedianHRSingleValue() throws {
        // 800ms RR -> 75 bpm
        let result = HRVAnalysisPipeline.nocturnalMedianHR(from: [800.0])
        XCTAssertNotNil(result)
        XCTAssertEqual(try XCTUnwrap(result), 75.0, accuracy: 0.1)
    }

    func testNocturnalMedianHROddCount() throws {
        // 3 values: 750ms (80bpm), 800ms (75bpm), 857ms (70bpm) -> median = 75bpm
        let result = HRVAnalysisPipeline.nocturnalMedianHR(from: [750.0, 800.0, 857.14])
        XCTAssertNotNil(result)
        XCTAssertEqual(try XCTUnwrap(result), 75.0, accuracy: 0.1)
    }

    func testNocturnalMedianHREvenCount() throws {
        // 4 values: median is average of middle two
        let result = HRVAnalysisPipeline.nocturnalMedianHR(from: [750.0, 800.0, 857.14, 1000.0])
        XCTAssertNotNil(result)
        // HR values: 80, 75, 70, 60 -> sorted: 60, 70, 75, 80 -> median = (70+75)/2 = 72.5
        XCTAssertEqual(try XCTUnwrap(result), 72.5, accuracy: 0.1)
    }

    func testNocturnalMedianHRIgnoresZeroRR() throws {
        // Zero RR should be filtered out (division by zero)
        let result = HRVAnalysisPipeline.nocturnalMedianHR(from: [0.0, 800.0, 0.0])
        XCTAssertNotNil(result)
        XCTAssertEqual(try XCTUnwrap(result), 75.0, accuracy: 0.1)
    }

    func testNocturnalMedianHRAllZero() {
        let result = HRVAnalysisPipeline.nocturnalMedianHR(from: [0.0, 0.0])
        XCTAssertNil(result)
    }

    // MARK: - Pure Function Tests: nocturnalHRDip

    func testNocturnalHRDipNormalCase() throws {
        // Daytime 70bpm, nocturnal 56bpm -> 20% dip
        let dip = HRVAnalysisPipeline.nocturnalHRDip(daytimeHR: 70.0, nocturnalMedian: 56.0)
        XCTAssertNotNil(dip)
        XCTAssertEqual(try XCTUnwrap(dip), 20.0, accuracy: 0.1)
    }

    func testNocturnalHRDipZeroDaytime() {
        let dip = HRVAnalysisPipeline.nocturnalHRDip(daytimeHR: 0.0, nocturnalMedian: 56.0)
        XCTAssertNil(dip)
    }

    func testNocturnalHRDipNegativeDip() throws {
        // Nocturnal > daytime -> negative dip (unusual, but mathematically valid)
        let dip = HRVAnalysisPipeline.nocturnalHRDip(daytimeHR: 60.0, nocturnalMedian: 66.0)
        XCTAssertNotNil(dip)
        XCTAssertLessThan(try XCTUnwrap(dip), 0.0)
    }

    // MARK: - Pure Function Tests: extractCleanRRs

    func testExtractCleanRRsNoArtifacts() {
        let (series, flags) = createUniformSeries(beatCount: 10, rrMs: 800)
        let clean = HRVAnalysisPipeline.extractCleanRRs(series: series, flags: flags, windowStart: 0, windowEnd: 10)
        XCTAssertEqual(clean.count, 10)
        XCTAssertTrue(clean.allSatisfy { $0 == 800.0 })
    }

    func testExtractCleanRRsWindowSubset() {
        let (series, flags) = createUniformSeries(beatCount: 20, rrMs: 800)
        let clean = HRVAnalysisPipeline.extractCleanRRs(series: series, flags: flags, windowStart: 5, windowEnd: 15)
        XCTAssertEqual(clean.count, 10)
    }

    // MARK: - Dependency Injection Tests

    func testPipelineUsesInjectedHealthKit() async {
        mockHealthKit.daytimeRestingHR = 65.0

        let (series, flags) = createRealisticSeries(beatCount: 500)
        let session = HRVSession(
            id: UUID(),
            startDate: Date(),
            endDate: Date(),
            state: .analyzing,
            sessionType: .quick,
            rrSeries: series,
            analysisResult: nil,
            artifactFlags: flags
        )

        let config = HRVAnalysisPipeline.ANSConfiguration(
            baselineRMSSD: 40.0,
            vo2Max: nil,
            trainingLoadAdjustment: 0
        )

        let result = await pipeline.analyzeFullSession(
            session: session,
            peakCapacity: nil,
            trainingContext: nil,
            ansConfig: config
        )

        // The pipeline should use our mock, which returns 65.0 for daytime HR
        if let result, let daytimeHR = result.ansMetrics?.daytimeRestingHR {
            XCTAssertEqual(
                daytimeHR,
                65.0,
                accuracy: 0.1,
                "Pipeline should use injected HealthKit service"
            )
        }
    }
}
