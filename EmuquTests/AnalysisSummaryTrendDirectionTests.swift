@testable import Emuqu
import XCTest

/// The morning report's 7-day HRV trend line and the "Upward Trend" cause say
/// what the shared trend verdict (`TrendVerdict`) says, not a second rule.
///
/// Before, the report compared arithmetic means of the last 7 days and the
/// days before and printed a direction past ±10 %: noisy nights at +12.3 %
/// read "improving" though the verdict calls them flat, and a clean +8 % rise
/// the verdict calls rising was never mentioned.
@MainActor
final class AnalysisSummaryTrendDirectionTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        pinEnglishLanguage()
    }

    private let today = Date()

    private func result(rmssd: Double) -> HRVAnalysisResult {
        HRVAnalysisResult(
            windowStart: 0, windowEnd: 500,
            timeDomain: TimeDomainMetrics(
                meanRR: 1_000, sdnn: rmssd * 1.2, rmssd: rmssd, pnn50: 20,
                sdsd: rmssd * 0.9, meanHR: 58, sdHR: 5, triangularIndex: nil
            ),
            frequencyDomain: nil,
            nonlinear: NonlinearMetrics(
                sd1: 30, sd2: 60, sd1Sd2Ratio: 0.5, sampleEntropy: 1.5,
                approxEntropy: 1.3, dfaAlpha1: 0.9, dfaAlpha2: nil, dfaAlpha1R2: 0.95
            ),
            ansMetrics: nil, artifactPercentage: 2, cleanBeatCount: 500, analysisDate: today
        )
    }

    private func night(daysAgo: Int, rmssd: Double) -> HRVSession {
        let start = today.addingTimeInterval(-Double(daysAgo) * 86_400 - 8 * 3600)
        return HRVSession(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(8 * 3600),
            state: .complete, sessionType: .overnight, rrSeries: nil,
            analysisResult: result(rmssd: rmssd), artifactFlags: nil
        )
    }

    /// Tonight plus fourteen earlier nights, oldest first.
    private func summary(earlier rmssd: [Double]) -> AnalysisSummaryGenerator.AnalysisSummary {
        let tonight = night(daysAgo: 0, rmssd: 55)
        let history = rmssd.enumerated().map { night(daysAgo: rmssd.count - $0.offset, rmssd: $0.element) }
        return AnalysisSummaryGenerator(
            result: tonight.analysisResult ?? result(rmssd: 55), session: tonight, recentSessions: history
        ).generate()
    }

    private func mentionsWeeklyTrend(_ summary: AnalysisSummaryGenerator.AnalysisSummary) -> Bool {
        (summary.keyFindings + [summary.trendInsight]).contains { $0.contains("7-day HRV trend") }
    }

    /// Earlier week 49.5/50.5 ms, recent week 53.5/54.5 ms: +8 %, well clear
    /// of the 0.5 × SD band with almost no noise, so the verdict is rising.
    func testACleanRiseUnderTenPercentIsReported() {
        let earlier = (0 ..< 7).map { $0.isMultiple(of: 2) ? 49.5 : 50.5 }
        let recent = (0 ..< 7).map { $0.isMultiple(of: 2) ? 53.5 : 54.5 }
        let report = summary(earlier: earlier + recent)
        XCTAssertTrue(mentionsWeeklyTrend(report))
        XCTAssertTrue(report.keyFindings.contains { $0.contains("improving") })
    }

    /// 40/60 ms nights whose last six average 12.3 % above the eight before
    /// them: the level and slope tests are nowhere near significant (t 0.5
    /// and 0.7), so the verdict is flat and nothing announces a trend.
    func testANoisyWeekPastTenPercentIsNotReported() {
        let values: [Double] = [40, 60, 40, 60, 40, 60, 40, 40, 60, 40, 60, 60, 40, 60]
        let report = summary(earlier: values)
        XCTAssertFalse(mentionsWeeklyTrend(report))
        XCTAssertFalse(report.probableCauses.contains { $0.cause == "Upward Trend" })
    }
}

// MARK: - Sleep trend from archived nights

/// The sleep trend the summary, the report and the assistant read was never
/// set (`MorningResultsViewModel.sleepTrendStats` had no writer, the other
/// callers passed nil), so every multi-night sleep finding was dead. It is now
/// built from the sleep archived with the nights before the session.
extension AnalysisSummaryTrendDirectionTests {
    private func sleptNight(daysAgo: Int, minutes: Int) -> HRVSession {
        var session = night(daysAgo: daysAgo, rmssd: 40)
        session.sleepSnapshot = SleepData(
            date: session.endDate ?? session.startDate, totalSleepMinutes: minutes, inBedMinutes: minutes + 30,
            awakeMinutes: 30, sleepEfficiency: 90, boundarySource: .healthKit
        )
        return session
    }

    /// Three 5-hour nights after three 8-hour ones, a shorter duplicate of one
    /// night, a quick reading with sleep on it, and a night outside the week.
    private func priorWeek() -> [HRVSession] {
        var quick = HRVSession(startDate: today.addingTimeInterval(-2 * 86_400), sessionType: .quick)
        quick.sleepSnapshot = sleptNight(daysAgo: 2, minutes: 600).sleepSnapshot
        let nights = [1, 2, 3].map { sleptNight(daysAgo: $0, minutes: 300) }
            + [4, 5, 6].map { sleptNight(daysAgo: $0, minutes: 480) }
        return nights + [sleptNight(daysAgo: 1, minutes: 200), quick, sleptNight(daysAgo: 9, minutes: 480)]
    }

    func testTheTrendIsBuiltFromTheWeekOfArchivedNightsBeforeTheSession() throws {
        let stats = try XCTUnwrap(SleepTrendStats.recentNights(before: sleptNight(daysAgo: 0, minutes: 300), in: priorWeek()))
        XCTAssertEqual(stats.nightsAnalyzed, 6)
        XCTAssertEqual(stats.averageSleepMinutes, 390, accuracy: 1e-9)
        XCTAssertEqual(stats.trend, .declining)
        XCTAssertEqual(try XCTUnwrap(stats.averageEfficiency), 90, accuracy: 1e-9)
    }

    func testNoArchivedNightMeansNoTrend() {
        XCTAssertNil(SleepTrendStats.recentNights(before: sleptNight(daysAgo: 0, minutes: 300), in: []))
        XCTAssertNil(AnalysisSleepTrendInput.recentNights(before: nil, in: priorWeek()))
    }

    func testTheMorningReportReadsTheTrend() {
        let tonight = sleptNight(daysAgo: 0, minutes: 300)
        let vm = MorningResultsViewModel(session: tonight, result: result(rmssd: 40), recentSessions: priorWeek())
        XCTAssertEqual(vm.sleepTrendStats?.nightsAnalyzed, 6)
    }

    func testTheSummaryReportsADecliningWeek() {
        let tonight = sleptNight(daysAgo: 0, minutes: 300)
        let recent = priorWeek()
        let summary = AnalysisSummaryGenerator(
            result: result(rmssd: 40), session: tonight, recentSessions: recent,
            sleep: AnalysisSleepInput(from: tonight.sleepSnapshot),
            sleepTrend: .recentNights(before: tonight, in: recent)
        ).generate()
        XCTAssertTrue(summary.keyFindings.contains { $0.contains("Sleep trending down") })
    }
}
