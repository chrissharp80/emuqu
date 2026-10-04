@testable import Emuqu
import XCTest

/// Tests for TrendAnalyzer
/// Validates trend calculation, statistics, and insights
@MainActor
final class TrendAnalysisTests: XCTestCase {
    /// The copy these tests assert is English; the app's language follows
    /// the host's unless pinned.
    override func setUp() async throws {
        try await super.setUp()
        pinEnglishLanguage()
    }

    // MARK: - Test Helpers

    private func createMockSession(
        daysAgo: Int,
        rmssd: Double = 45.0,
        sdnn: Double = 55.0,
        meanHR: Double = 58.0,
        stressIndex: Double? = 120.0,
        dfaAlpha1: Double? = 0.9
    ) -> HRVSession {
        let calendar = Calendar.current
        let sessionDate = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()

        // Create time domain metrics
        let timeDomain = TimeDomainMetrics(
            meanRR: 60000.0 / meanHR,
            sdnn: sdnn,
            rmssd: rmssd,
            pnn50: 20.0,
            sdsd: rmssd * 0.9,
            meanHR: meanHR,
            sdHR: 5.0,
            triangularIndex: nil
        )

        // Create frequency domain metrics
        let frequencyDomain = FrequencyDomainMetrics(
            vlf: 500,
            lf: 800,
            hf: 600,
            lfHfRatio: 1.33,
            totalPower: 1900
        )

        // Create nonlinear metrics
        let nonlinear = NonlinearMetrics(
            sd1: 30,
            sd2: 60,
            sd1Sd2Ratio: 0.5,
            sampleEntropy: 1.5,
            approxEntropy: 1.3,
            dfaAlpha1: dfaAlpha1,
            dfaAlpha2: nil,
            dfaAlpha1R2: 0.95
        )

        // Create ANS metrics
        var ansMetrics: ANSMetrics?
        if let stress = stressIndex {
            ansMetrics = ANSMetrics(
                stressIndex: stress,
                pnsIndex: 0.5,
                snsIndex: -0.3,
                readinessScore: 7.0,
                respirationRate: 14.0,
                nocturnalHRDip: 12.0,
                daytimeRestingHR: 65.0,
                nocturnalMedianHR: 57.0
            )
        }

        // Create analysis result
        let analysisResult = HRVAnalysisResult(
            windowStart: 0,
            windowEnd: 500,
            timeDomain: timeDomain,
            frequencyDomain: frequencyDomain,
            nonlinear: nonlinear,
            ansMetrics: ansMetrics,
            artifactPercentage: 2.0,
            cleanBeatCount: 500,
            analysisDate: sessionDate
        )

        // Create and return session using the full initializer
        return HRVSession(
            id: UUID(),
            startDate: sessionDate,
            endDate: sessionDate.addingTimeInterval(28800), // 8 hours
            state: .complete,
            sessionType: .overnight,
            rrSeries: nil,
            analysisResult: analysisResult,
            artifactFlags: nil,
            recoveryScore: 7.0,
            tags: [],
            notes: nil,
            importedMetrics: nil,
            deviceProvenance: nil,
            sleepStartMs: nil,
            sleepEndMs: nil
        )
    }

    private func createSessionsWithTrend(
        count: Int,
        baseRMSSD: Double,
        dailyChange: Double
    ) -> [HRVSession] {
        (0 ..< count).map { i in
            let rmssd = baseRMSSD + (Double(count - 1 - i) * dailyChange)
            return createMockSession(daysAgo: i, rmssd: rmssd)
        }
    }

    // MARK: - Basic Analysis Tests

    func testAnalyzeRequiresMinimumSessions() {
        let oneSession = [createMockSession(daysAgo: 0)]
        let result = TrendAnalyzer.analyze(sessions: oneSession)
        XCTAssertNil(result, "Should return nil with fewer than 2 sessions")
    }

    func testAnalyzeWithTwoSessions() {
        let sessions = [
            createMockSession(daysAgo: 0, rmssd: 50),
            createMockSession(daysAgo: 1, rmssd: 45)
        ]
        let result = TrendAnalyzer.analyze(sessions: sessions)
        XCTAssertNotNil(result, "Should analyze with 2 sessions")
    }

    func testAnalyzeReturnsCorrectDataPointCount() {
        let sessions = (0 ..< 10).map { createMockSession(daysAgo: $0) }
        let result = TrendAnalyzer.analyze(sessions: sessions)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.dataPoints.count, 10)
    }

    // MARK: - Period Filtering Tests

    func testWeekPeriodFiltering() throws {
        let sessions = (0 ..< 30).map { createMockSession(daysAgo: $0) }
        let result = TrendAnalyzer.analyze(sessions: sessions, period: .week)

        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(result?.dataPoints.count),
            7,
            "Week period should include at most 7 days"
        )
    }

    func testMonthPeriodFiltering() throws {
        let sessions = (0 ..< 60).map { createMockSession(daysAgo: $0) }
        let result = TrendAnalyzer.analyze(sessions: sessions, period: .month)

        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(result?.dataPoints.count),
            30,
            "Month period should include at most 30 days"
        )
    }

    func testAllPeriodIncludesEverything() {
        let sessions = (0 ..< 100).map { createMockSession(daysAgo: $0) }
        let result = TrendAnalyzer.analyze(sessions: sessions, period: .all)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.dataPoints.count, 100)
    }

    // MARK: - Trend Direction Tests

    func testImprovingTrendDetection() throws {
        // RMSSD increasing over time (newer days have higher values)
        let sessions = createSessionsWithTrend(count: 14, baseRMSSD: 35, dailyChange: 2)
        let result = TrendAnalyzer.analyze(sessions: sessions, period: .twoWeeks)

        XCTAssertNotNil(result)
        XCTAssertEqual(
            try XCTUnwrap(result?.rmssdStats.trend),
            .improving,
            "Increasing RMSSD should be detected as improving"
        )
    }

    func testDecliningTrendDetection() throws {
        // RMSSD decreasing over time
        let sessions = createSessionsWithTrend(count: 14, baseRMSSD: 60, dailyChange: -2)
        let result = TrendAnalyzer.analyze(sessions: sessions, period: .twoWeeks)

        XCTAssertNotNil(result)
        XCTAssertEqual(
            try XCTUnwrap(result?.rmssdStats.trend),
            .declining,
            "Decreasing RMSSD should be detected as declining"
        )
    }

    func testStableTrendDetection() throws {
        // RMSSD staying consistent
        let sessions = (0 ..< 14).map { createMockSession(daysAgo: $0, rmssd: 45) }
        let result = TrendAnalyzer.analyze(sessions: sessions, period: .twoWeeks)

        XCTAssertNotNil(result)
        XCTAssertEqual(
            try XCTUnwrap(result?.rmssdStats.trend),
            .stable,
            "Consistent RMSSD should be detected as stable"
        )
    }

    // MARK: - Statistics Tests

    func testRMSSDStatisticsCalculation() throws {
        let sessions = [
            createMockSession(daysAgo: 0, rmssd: 50),
            createMockSession(daysAgo: 1, rmssd: 40),
            createMockSession(daysAgo: 2, rmssd: 60),
            createMockSession(daysAgo: 3, rmssd: 45),
            createMockSession(daysAgo: 4, rmssd: 55)
        ]
        let result = TrendAnalyzer.analyze(sessions: sessions)

        XCTAssertNotNil(result)
        let stats = try XCTUnwrap(result?.rmssdStats)

        XCTAssertEqual(stats.count, 5)
        XCTAssertEqual(stats.mean, 50, accuracy: 0.1) // (50+40+60+45+55)/5 = 50
        XCTAssertEqual(stats.min, 40)
        XCTAssertEqual(stats.max, 60)
    }

    func testPercentilesCalculation() throws {
        let sessions = (0 ..< 20).map { i in
            createMockSession(daysAgo: i, rmssd: Double(30 + i * 2)) // 30, 32, 34...68
        }
        let result = TrendAnalyzer.analyze(sessions: sessions)

        XCTAssertNotNil(result)
        let stats = try XCTUnwrap(result?.rmssdStats)

        XCTAssertLessThan(stats.percentile25, stats.mean)
        XCTAssertGreaterThan(stats.percentile75, stats.mean)
        XCTAssertLessThan(stats.percentile25, stats.percentile75)
    }

    func testCoefficientOfVariation() throws {
        // High variability sessions
        let highVarSessions = [
            createMockSession(daysAgo: 0, rmssd: 20),
            createMockSession(daysAgo: 1, rmssd: 80),
            createMockSession(daysAgo: 2, rmssd: 30),
            createMockSession(daysAgo: 3, rmssd: 70)
        ]

        // Low variability sessions
        let lowVarSessions = [
            createMockSession(daysAgo: 0, rmssd: 48),
            createMockSession(daysAgo: 1, rmssd: 52),
            createMockSession(daysAgo: 2, rmssd: 49),
            createMockSession(daysAgo: 3, rmssd: 51)
        ]

        let highVarResult = TrendAnalyzer.analyze(sessions: highVarSessions)
        let lowVarResult = TrendAnalyzer.analyze(sessions: lowVarSessions)

        XCTAssertNotNil(highVarResult)
        XCTAssertNotNil(lowVarResult)

        XCTAssertGreaterThan(
            try XCTUnwrap(highVarResult?.rmssdStats.coefficientOfVariation),
            try XCTUnwrap(lowVarResult?.rmssdStats.coefficientOfVariation),
            "High variability should have higher CV"
        )
    }

    // MARK: - Rolling Baseline Tests

    func testRollingBaselineComputation() {
        let values = [40.0, 42.0, 45.0, 43.0, 48.0, 50.0, 47.0]
        let dates = (0 ..< 7).map { i in
            TestDate.adding(.day, -6 + i, to: Date())
        }

        let baselines = TrendAnalyzer.computeRollingBaseline(
            values: values,
            dates: dates,
            windowDays: 3
        )

        XCTAssertEqual(baselines.count, values.count)
        // First value has no prior data, so baseline equals value
        XCTAssertEqual(baselines[0], values[0])
    }

    func testRollingBaselineSmoothsData() throws {
        let spikyValues = [40.0, 80.0, 35.0, 75.0, 42.0, 70.0, 38.0]
        let dates = (0 ..< 7).map { i in
            TestDate.adding(.day, -6 + i, to: Date())
        }

        let baselines = TrendAnalyzer.computeRollingBaseline(
            values: spikyValues,
            dates: dates,
            windowDays: 3
        )

        // Baselines should be less variable than raw values
        let rawRange = try XCTUnwrap(spikyValues.max()) - (try XCTUnwrap(spikyValues.min()))
        let baselineRange = try XCTUnwrap(baselines.suffix(5).max()) - (try XCTUnwrap(baselines.suffix(5).min()))

        XCTAssertLessThan(
            baselineRange,
            rawRange,
            "Baseline should smooth out spikes"
        )
    }

    // MARK: - Insights Tests

    func testInsightsGeneratedForImprovingTrend() throws {
        let sessions = createSessionsWithTrend(count: 14, baseRMSSD: 35, dailyChange: 2)
        let result = TrendAnalyzer.analyze(sessions: sessions)

        XCTAssertNotNil(result)
        XCTAssertFalse(try XCTUnwrap(result?.insights.isEmpty), "Should generate insights")

        let hasImprovingInsight = try XCTUnwrap(result?.insights.contains { $0.lowercased().contains("improving") || $0.lowercased().contains("upward") })
        XCTAssertTrue(hasImprovingInsight, "Should mention improving trend")
    }

    func testInsightsGeneratedForDecliningTrend() throws {
        let sessions = createSessionsWithTrend(count: 14, baseRMSSD: 60, dailyChange: -2)
        let result = TrendAnalyzer.analyze(sessions: sessions)

        XCTAssertNotNil(result)
        XCTAssertFalse(try XCTUnwrap(result?.insights.isEmpty))

        let hasDecliningInsight = try XCTUnwrap(result?.insights.contains { $0.lowercased().contains("declining") || $0.lowercased().contains("reducing") })
        XCTAssertTrue(hasDecliningInsight, "Should mention declining trend")
    }

    // MARK: - Chart Data Tests

    func testChartDataExtraction() throws {
        let sessions = (0 ..< 10).map { createMockSession(daysAgo: $0) }
        let result = TrendAnalyzer.analyze(sessions: sessions)

        XCTAssertNotNil(result)

        let rmssdData = try TrendAnalyzer.chartData(from: XCTUnwrap(result?.dataPoints), metric: .rmssd)
        let hrData = try TrendAnalyzer.chartData(from: XCTUnwrap(result?.dataPoints), metric: .meanHR)
        let stressData = try TrendAnalyzer.chartData(from: XCTUnwrap(result?.dataPoints), metric: .stressIndex)

        XCTAssertEqual(rmssdData.count, 10)
        XCTAssertEqual(hrData.count, 10)
        XCTAssertEqual(stressData.count, 10)
    }

    func testChartDataWithMissingValues() throws {
        var sessions = (0 ..< 5).map { createMockSession(daysAgo: $0) }
        // Add session without stress index
        sessions.append(createMockSession(daysAgo: 5, stressIndex: nil))

        let result = TrendAnalyzer.analyze(sessions: sessions)
        XCTAssertNotNil(result)

        let stressData = try TrendAnalyzer.chartData(from: XCTUnwrap(result?.dataPoints), metric: .stressIndex)
        // Should only include sessions with stress data
        XCTAssertEqual(stressData.count, 5)
    }

    // MARK: - Time Period Tests

    func testTimePeriodDays() {
        XCTAssertEqual(TrendAnalyzer.TimePeriod.week.days, 7)
        XCTAssertEqual(TrendAnalyzer.TimePeriod.twoWeeks.days, 14)
        XCTAssertEqual(TrendAnalyzer.TimePeriod.month.days, 30)
        XCTAssertEqual(TrendAnalyzer.TimePeriod.threeMonths.days, 90)
        XCTAssertNil(TrendAnalyzer.TimePeriod.all.days)
    }

    func testTimePeriodDisplayNames() {
        XCTAssertEqual(TrendAnalyzer.TimePeriod.week.displayName, "7 Days")
        XCTAssertEqual(TrendAnalyzer.TimePeriod.month.displayName, "30 Days")
        XCTAssertEqual(TrendAnalyzer.TimePeriod.all.displayName, "All Time")
    }

    // MARK: - Edge Cases

    func testAnalyzeWithEmptyArray() {
        let result = TrendAnalyzer.analyze(sessions: [])
        XCTAssertNil(result)
    }

    func testAnalyzeExcludesNapSessions() throws {
        var sessions = (0 ..< 5).map { createMockSession(daysAgo: $0) }
        // Add a nap session (should be excluded from trends)
        let napSession = HRVSession(
            id: UUID(),
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            state: .complete,
            sessionType: .nap,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil,
            recoveryScore: nil,
            tags: [],
            notes: nil,
            importedMetrics: nil,
            deviceProvenance: nil,
            sleepStartMs: nil,
            sleepEndMs: nil
        )
        sessions.append(napSession)

        let result = TrendAnalyzer.analyze(sessions: sessions)
        XCTAssertNotNil(result)
        XCTAssertEqual(try XCTUnwrap(result?.dataPoints.count), 5, "Nap sessions should be excluded")
    }

    func testAnalyzeExcludesSessionsWithoutResults() throws {
        var sessions = (0 ..< 5).map { createMockSession(daysAgo: $0) }
        // Add session without analysis result
        let incompleteSession = HRVSession(
            id: UUID(),
            startDate: Date(),
            endDate: Date().addingTimeInterval(28800),
            state: .complete,
            sessionType: .overnight,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil,
            recoveryScore: nil,
            tags: [],
            notes: nil,
            importedMetrics: nil,
            deviceProvenance: nil,
            sleepStartMs: nil,
            sleepEndMs: nil
        )
        sessions.append(incompleteSession)

        let result = TrendAnalyzer.analyze(sessions: sessions)
        XCTAssertNotNil(result)
        XCTAssertEqual(try XCTUnwrap(result?.dataPoints.count), 5, "Sessions without results should be excluded")
    }
}
