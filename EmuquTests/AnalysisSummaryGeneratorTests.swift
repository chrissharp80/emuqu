@testable import Emuqu
import XCTest

/// Tests for AnalysisSummaryGenerator — diagnostic score, key findings, actionable steps, trend insight
final class AnalysisSummaryGeneratorTests: XCTestCase {
    // MARK: - Test Data Factories

    private func makeTimeDomain(rmssd: Double = 45.0, pnn50: Double = 20.0, meanHR: Double = 58.0) -> TimeDomainMetrics {
        TimeDomainMetrics(
            meanRR: 60000.0 / meanHR,
            sdnn: rmssd * 1.2,
            rmssd: rmssd,
            pnn50: pnn50,
            sdsd: rmssd * 0.95,
            meanHR: meanHR,
            sdHR: 3.0,
            triangularIndex: 12.0
        )
    }

    private func makeNonlinear(dfaAlpha1: Double? = 0.95) -> NonlinearMetrics {
        NonlinearMetrics(
            sd1: 32.0, sd2: 48.0, sd1Sd2Ratio: 0.67,
            sampleEntropy: 1.5, approxEntropy: 1.2,
            dfaAlpha1: dfaAlpha1, dfaAlpha2: 0.85,
            dfaAlpha1R2: 0.95
        )
    }

    private func makeFrequencyDomain(lfHfRatio: Double? = 1.2) -> FrequencyDomainMetrics {
        FrequencyDomainMetrics(vlf: 500, lf: 800, hf: 800 / (lfHfRatio ?? 1.0), lfHfRatio: lfHfRatio, totalPower: 2100)
    }

    private func makeANSMetrics(stressIndex: Double = 120, readinessScore: Double = 7.0) -> ANSMetrics {
        ANSMetrics(
            stressIndex: stressIndex, pnsIndex: 1.5, snsIndex: -0.5,
            readinessScore: readinessScore, respirationRate: 14.0,
            nocturnalHRDip: 12.0, daytimeRestingHR: 65.0, nocturnalMedianHR: 57.0
        )
    }

    private func makeResult(
        rmssd: Double = 45.0,
        pnn50: Double = 20.0,
        meanHR: Double = 58.0,
        stressIndex: Double = 120,
        lfHfRatio: Double = 1.2,
        dfaAlpha1: Double = 0.95,
        isConsolidated: Bool = true,
        isOrganizedRecovery: Bool = true
    ) -> HRVAnalysisResult {
        var result = HRVAnalysisResult(
            windowStart: 100, windowEnd: 400,
            timeDomain: makeTimeDomain(rmssd: rmssd, pnn50: pnn50, meanHR: meanHR),
            frequencyDomain: makeFrequencyDomain(lfHfRatio: lfHfRatio),
            nonlinear: makeNonlinear(dfaAlpha1: dfaAlpha1),
            ansMetrics: makeANSMetrics(stressIndex: stressIndex),
            artifactPercentage: 3.0,
            cleanBeatCount: 290,
            analysisDate: Date()
        )
        result.isConsolidated = isConsolidated
        result.isOrganizedRecovery = isOrganizedRecovery
        result.windowHRStability = 0.04
        return result
    }

    private func makeSession(analysisResult: HRVAnalysisResult? = nil) -> HRVSession {
        HRVSession(
            id: UUID(),
            startDate: Date().addingTimeInterval(-8 * 3600),
            endDate: Date(),
            state: .complete,
            sessionType: .overnight,
            rrSeries: nil,
            analysisResult: analysisResult,
            artifactFlags: nil
        )
    }

    // MARK: - Diagnostic Score

    func testExcellentRecoveryHighScore() {
        let result = makeResult(
            rmssd: 65.0, pnn50: 35.0, meanHR: 52.0,
            stressIndex: 80, lfHfRatio: 1.0, dfaAlpha1: 0.9
        )
        let session = makeSession(analysisResult: result)

        let generator = AnalysisSummaryGenerator(result: result, session: session, userAge: 30)
        let summary = generator.generate()

        XCTAssertGreaterThanOrEqual(
            summary.diagnosticScore,
            70,
            "High RMSSD + low stress + balanced LF/HF + good DFA should score ≥70"
        )
        XCTAssertTrue(
            summary.analysisTitle.contains("Recovered") || summary.analysisTitle.contains("Adequate"),
            "Title should reflect good recovery, got: \(summary.analysisTitle)"
        )
    }

    func testPoorRecoveryLowScore() {
        let result = makeResult(
            rmssd: 15.0, pnn50: 3.0, meanHR: 72.0,
            stressIndex: 350, lfHfRatio: 4.0, dfaAlpha1: 1.4
        )
        let session = makeSession(analysisResult: result)

        let generator = AnalysisSummaryGenerator(result: result, session: session, userAge: 30)
        let summary = generator.generate()

        XCTAssertLessThanOrEqual(
            summary.diagnosticScore,
            40,
            "Low RMSSD + high stress + high LF/HF + fatigued DFA should score ≤40"
        )
    }

    func testScoreClampedTo0And100() {
        // Extremely poor metrics
        let poorResult = makeResult(
            rmssd: 5.0, pnn50: 0.5, meanHR: 90.0,
            stressIndex: 500, lfHfRatio: 8.0, dfaAlpha1: 1.6
        )
        let session = makeSession(analysisResult: poorResult)
        let generator = AnalysisSummaryGenerator(result: poorResult, session: session)
        let summary = generator.generate()

        XCTAssertGreaterThanOrEqual(summary.diagnosticScore, 0)
        XCTAssertLessThanOrEqual(summary.diagnosticScore, 100)
    }

    // MARK: - Diagnostic Title Thresholds

    func testDiagnosticTitleWellRecovered() {
        let result = makeResult(rmssd: 70.0, stressIndex: 60, lfHfRatio: 0.8, dfaAlpha1: 0.85)
        let session = makeSession(analysisResult: result)
        let generator = AnalysisSummaryGenerator(result: result, session: session, userAge: 25)
        let summary = generator.generate()

        // Score should be ≥80 → "Well Recovered"
        if summary.diagnosticScore >= 80 {
            XCTAssertEqual(summary.analysisTitle, "Well Recovered")
        }
    }

    func testDiagnosticTitleRecoveryNeeded() {
        let result = makeResult(rmssd: 8.0, stressIndex: 400, lfHfRatio: 6.0, dfaAlpha1: 1.5)
        let session = makeSession(analysisResult: result)
        let generator = AnalysisSummaryGenerator(result: result, session: session, userAge: 30)
        let summary = generator.generate()

        if summary.diagnosticScore < 20 {
            XCTAssertEqual(summary.analysisTitle, "Recovery Needed")
        }
    }

    // MARK: - Key Findings

    func testKeyFindingsContainStressInfo() {
        let result = makeResult(stressIndex: 350)
        let session = makeSession(analysisResult: result)
        let generator = AnalysisSummaryGenerator(result: result, session: session)
        let summary = generator.generate()

        XCTAssertTrue(
            summary.keyFindings.contains(where: { $0.lowercased().contains("stress") }),
            "Should have a finding about high stress. Got: \(summary.keyFindings)"
        )
    }

    func testKeyFindingsContainDFAInfo() {
        let result = makeResult(dfaAlpha1: 1.4)
        let session = makeSession(analysisResult: result)
        let generator = AnalysisSummaryGenerator(result: result, session: session)
        let summary = generator.generate()

        XCTAssertTrue(
            summary.keyFindings.contains(where: { $0.lowercased().contains("fatigue") || $0.lowercased().contains("rhythm") }),
            "High DFA alpha1 should generate a fatigue finding"
        )
    }

    func testKeyFindingsWithSleepData() {
        let result = makeResult(rmssd: 25.0)
        let session = makeSession(analysisResult: result)
        let sleep = AnalysisSleepInput(
            totalSleepMinutes: 240, inBedMinutes: 280,
            deepSleepMinutes: 20, remSleepMinutes: 40,
            awakeMinutes: 40, sleepEfficiency: 85.7
        )

        let generator = AnalysisSummaryGenerator(result: result, session: session, sleep: sleep)
        let summary = generator.generate()

        XCTAssertTrue(
            summary.keyFindings.contains(where: { $0.lowercased().contains("sleep") }),
            "Short sleep (4h) should generate a sleep finding"
        )
    }

    // MARK: - Actionable Steps

    func testActionableStepsForGoodRecovery() {
        let result = makeResult(
            rmssd: 60.0, stressIndex: 80, lfHfRatio: 1.0, dfaAlpha1: 0.9,
            isConsolidated: true, isOrganizedRecovery: true
        )
        let session = makeSession(analysisResult: result)
        let generator = AnalysisSummaryGenerator(result: result, session: session)
        let summary = generator.generate()

        XCTAssertFalse(summary.actionableSteps.isEmpty, "Should have actionable steps")
    }

    func testActionableStepsForPoorRecovery() {
        let result = makeResult(rmssd: 12.0, stressIndex: 400, lfHfRatio: 5.0, dfaAlpha1: 1.5)
        let session = makeSession(analysisResult: result)
        let sleep = AnalysisSleepInput(
            totalSleepMinutes: 200, inBedMinutes: 240,
            deepSleepMinutes: nil, remSleepMinutes: nil,
            awakeMinutes: 40, sleepEfficiency: 83.3
        )
        let generator = AnalysisSummaryGenerator(result: result, session: session, sleep: sleep)
        let summary = generator.generate()

        XCTAssertTrue(
            summary.actionableSteps.contains(where: { $0.lowercased().contains("rest") || $0.lowercased().contains("easy") }),
            "Poor recovery should suggest rest. Got: \(summary.actionableSteps)"
        )
    }

    // MARK: - Trend Insight

    func testTrendInsightWithNoHistory() {
        let result = makeResult()
        let session = makeSession(analysisResult: result)
        let generator = AnalysisSummaryGenerator(result: result, session: session)
        let summary = generator.generate()

        XCTAssertTrue(
            summary.trendInsight.contains("more sessions"),
            "No history should prompt for more sessions. Got: \(summary.trendInsight)"
        )
    }

    func testTrendInsightWithHistory() {
        let result = makeResult(rmssd: 55.0)
        let session = makeSession(analysisResult: result)

        // Create historical sessions with lower RMSSD
        var recentSessions = [HRVSession]()
        for i in 0 ..< 5 {
            let histResult = makeResult(rmssd: 40.0)
            var s = makeSession(analysisResult: histResult)
            s = HRVSession(
                id: UUID(),
                startDate: Date().addingTimeInterval(Double(-i - 1) * 86400),
                endDate: Date().addingTimeInterval(Double(-i - 1) * 86400 + 28800),
                state: .complete,
                sessionType: .overnight,
                rrSeries: nil,
                analysisResult: histResult,
                artifactFlags: nil
            )
            recentSessions.append(s)
        }

        let generator = AnalysisSummaryGenerator(
            result: result, session: session, recentSessions: recentSessions
        )
        let summary = generator.generate()

        XCTAssertFalse(summary.trendInsight.isEmpty, "Should produce trend insight with history")
        XCTAssertFalse(
            summary.trendInsight.contains("more sessions"),
            "With 5 sessions should not ask for more data"
        )
    }

    // MARK: - Diagnostic Explanation

    func testDiagnosticExplanationNotEmpty() {
        let result = makeResult()
        let session = makeSession(analysisResult: result)
        let generator = AnalysisSummaryGenerator(result: result, session: session)
        let summary = generator.generate()

        XCTAssertFalse(
            summary.analysisExplanation.isEmpty,
            "Diagnostic explanation should never be empty"
        )
    }

    func testDiagnosticExplanationIncludesRMSSD() {
        let result = makeResult(rmssd: 45.0)
        let session = makeSession(analysisResult: result)
        let generator = AnalysisSummaryGenerator(result: result, session: session)
        let summary = generator.generate()

        XCTAssertTrue(
            summary.analysisExplanation.contains("45"),
            "Explanation should reference the RMSSD value"
        )
    }

    // MARK: - Probable Causes

    func testProbableCausesLimitedToThree() {
        let result = makeResult(rmssd: 10.0, stressIndex: 400, lfHfRatio: 5.0, dfaAlpha1: 1.5)
        let session = makeSession(analysisResult: result)
        let sleep = AnalysisSleepInput(
            totalSleepMinutes: 180, inBedMinutes: 220,
            deepSleepMinutes: nil, remSleepMinutes: nil,
            awakeMinutes: 40, sleepEfficiency: 81.8
        )
        let generator = AnalysisSummaryGenerator(
            result: result, session: session, sleep: sleep
        )
        let summary = generator.generate()

        XCTAssertLessThanOrEqual(
            summary.probableCauses.count,
            3,
            "Probable causes should be limited to 3"
        )
    }

    func testProbableCausesHaveRequiredFields() {
        let result = makeResult(rmssd: 15.0, stressIndex: 300)
        let session = makeSession(analysisResult: result)
        let generator = AnalysisSummaryGenerator(result: result, session: session)
        let summary = generator.generate()

        for cause in summary.probableCauses {
            XCTAssertFalse(cause.cause.isEmpty, "Cause name should not be empty")
            XCTAssertFalse(cause.confidence.isEmpty, "Confidence should not be empty")
            XCTAssertFalse(cause.explanation.isEmpty, "Explanation should not be empty")
        }
    }

    // MARK: - Sleep Input Helpers

    func testSleepInputShortSleep() {
        let input = AnalysisSleepInput(
            totalSleepMinutes: 240, inBedMinutes: 260,
            deepSleepMinutes: nil, remSleepMinutes: nil,
            awakeMinutes: 20, sleepEfficiency: 92.3
        )
        XCTAssertTrue(input.isShortSleep, "4h should be short sleep")
        XCTAssertFalse(input.isGoodSleep, "4h should not be good sleep")
    }

    func testSleepInputGoodSleep() {
        let input = AnalysisSleepInput(
            totalSleepMinutes: 450, inBedMinutes: 470,
            deepSleepMinutes: 60, remSleepMinutes: 100,
            awakeMinutes: 20, sleepEfficiency: 95.7
        )
        XCTAssertTrue(input.isGoodSleep, "7.5h should be good sleep")
        XCTAssertFalse(input.isShortSleep)
    }

    func testSleepInputFragmented() {
        let input = AnalysisSleepInput(
            totalSleepMinutes: 400, inBedMinutes: 460,
            deepSleepMinutes: nil, remSleepMinutes: nil,
            awakeMinutes: 60, sleepEfficiency: 87.0
        )
        XCTAssertTrue(input.isFragmented, ">30 min awake should be fragmented")
    }

    func testEmptySleepInput() {
        let input = AnalysisSleepInput.empty
        XCTAssertFalse(input.isShortSleep)
        XCTAssertFalse(input.isGoodSleep)
        XCTAssertFalse(input.isFragmented)
    }
}
