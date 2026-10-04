@testable import Emuqu
import Foundation
import PDFKit
import XCTest

/// Smoke tests for the PDF export path.
///
/// This is deliberately not a pixel or layout test — it is a *does it survive*
/// test. `PDFReportGenerator` and its five extension files are ~4,000 lines of
/// drawing code that ran at zero coverage: index arithmetic over metric arrays,
/// optional chains through half-populated sessions, chart scaling that divides
/// by a range that can be zero. Every one of those fails by trapping, and the
/// user-visible symptom is the Share button killing the app with their night's
/// data on screen.
///
/// So each case builds a session, renders a report, and asserts a real PDF
/// came back. The assertions are shallow on purpose; the coverage is the point.
/// The nastiest inputs get their own cases: no RR series, flat-line data with
/// zero variance, a single beat, and every section toggled on alone.
@MainActor
final class PDFReportGeneratorSmokeTests: XCTestCase {
    // MARK: - Fixtures

    private func makeGenerator() -> PDFReportGenerator {
        // The injectable settings provider is what makes this testable at all:
        // the default reads `SettingsManager.shared`, which would drag real
        // user defaults into the test.
        PDFReportGenerator(settingsProvider: { UserSettings() })
    }

    private func rrSeries(
        beats: Int = 600,
        rrMs: Int = 1_000,
        jitter: Int = 30,
        sessionId: UUID = UUID()
    ) -> RRSeries {
        var t: Int64 = 0
        var points: [RRPoint] = []
        points.reserveCapacity(beats)
        for i in 0 ..< beats {
            // Deterministic pseudo-jitter: a sine wave, so the series has real
            // variance without the test depending on a random seed.
            let wobble = jitter == 0 ? 0 : Int((Double(jitter) * sin(Double(i) / 12.0)).rounded())
            let rr = Swift.max(300, rrMs + wobble)
            points.append(RRPoint(
                t_ms: t,
                rr_ms: rr,
                wallClockMs: nil,
                hr: Int((60_000.0 / Double(rr)).rounded())
            ))
            t += Int64(rr)
        }
        return RRSeries(
            points: points,
            sessionId: sessionId,
            startDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func analysisResult(
        rmssd: Double = 45,
        dfaAlpha1: Double? = 0.95,
        lfHfRatio: Double? = 1.2
    ) -> HRVAnalysisResult {
        var result = HRVAnalysisResult(
            windowStart: 0,
            windowEnd: 600_000,
            timeDomain: TimeDomainMetrics(
                meanRR: 1_000,
                sdnn: rmssd * 1.2,
                rmssd: rmssd,
                pnn50: 20,
                sdsd: rmssd * 0.95,
                meanHR: 60,
                sdHR: 3,
                triangularIndex: 12
            ),
            frequencyDomain: FrequencyDomainMetrics(
                vlf: 500,
                lf: 800,
                hf: 800 / (lfHfRatio ?? 1.0),
                lfHfRatio: lfHfRatio,
                totalPower: 2_100
            ),
            nonlinear: NonlinearMetrics(
                sd1: 32, sd2: 48, sd1Sd2Ratio: 0.67,
                sampleEntropy: 1.5, approxEntropy: 1.2,
                dfaAlpha1: dfaAlpha1, dfaAlpha2: 0.85,
                dfaAlpha1R2: 0.95
            ),
            ansMetrics: ANSMetrics(
                stressIndex: 120, pnsIndex: 1.5, snsIndex: -0.5,
                readinessScore: 7, respirationRate: 14,
                nocturnalHRDip: 12, daytimeRestingHR: 65, nocturnalMedianHR: 57
            ),
            artifactPercentage: 3.0,
            cleanBeatCount: 590,
            analysisDate: Date(timeIntervalSince1970: 1_700_010_000)
        )
        result.isConsolidated = true
        result.isOrganizedRecovery = true
        result.windowHRStability = 0.04
        return result
    }

    private func session(
        result: HRVAnalysisResult? = nil,
        series: RRSeries? = nil,
        type: SessionType = .overnight
    ) -> HRVSession {
        let id = UUID()
        return HRVSession(
            id: id,
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_028_800),
            state: .complete,
            sessionType: type,
            rrSeries: series,
            analysisResult: result ?? analysisResult(),
            artifactFlags: nil
        )
    }

    private func fullSession() -> HRVSession {
        session(result: analysisResult(), series: rrSeries())
    }

    private var vitals: PDFReportGenerator.VitalsData {
        PDFReportGenerator.VitalsData(
            respiratoryRate: 14.2,
            respiratoryRateBaseline: 13.8,
            oxygenSaturation: 96,
            oxygenSaturationMin: 91,
            wristTemperature: -0.2,
            restingHeartRate: 52
        )
    }

    private var sleep: PDFReportGenerator.SleepData {
        PDFReportGenerator.SleepData(
            sleepStart: Date(timeIntervalSince1970: 1_700_000_000),
            sleepEnd: Date(timeIntervalSince1970: 1_700_028_800),
            totalSleepMinutes: 452,
            inBedMinutes: 480,
            deepSleepMinutes: 82,
            remSleepMinutes: 96,
            awakeMinutes: 28,
            sleepEfficiency: 94
        )
    }

    private var sleepTrend: PDFReportGenerator.SleepTrendData {
        PDFReportGenerator.SleepTrendData(
            averageSleepMinutes: 441,
            averageDeepSleepMinutes: 78,
            averageEfficiency: 92,
            trend: .stable,
            nightsAnalyzed: 14
        )
    }

    private var heartRate: HeartRateStats {
        HeartRateStats(
            mean: 58,
            min: 48,
            max: 74,
            nadirTime: Date(timeIntervalSince1970: 1_700_014_000)
        )
    }

    /// Renders and asserts a real, openable, non-trivial PDF came back.
    @discardableResult
    private func assertRendersPDF(
        _ data: Data?,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> PDFDocument? {
        guard let data else {
            XCTFail("\(label): generator returned nil", file: file, line: line)
            return nil
        }
        XCTAssertGreaterThan(data.count, 1_000, "\(label): suspiciously small PDF", file: file, line: line)
        guard let document = PDFDocument(data: data) else {
            XCTFail("\(label): output is not a readable PDF", file: file, line: line)
            return nil
        }
        XCTAssertGreaterThan(document.pageCount, 0, "\(label): no pages", file: file, line: line)
        return document
    }

    // MARK: - The guard

    func testNoReportWithoutAnAnalysisResult() {
        // An un-analysed session has nothing to report on. Returning nil is
        // what lets the Share button stay disabled instead of exporting a
        // blank clinical document.
        let unanalysed = HRVSession(
            id: UUID(),
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_028_800),
            state: .complete,
            sessionType: .overnight,
            rrSeries: rrSeries(),
            analysisResult: nil,
            artifactFlags: nil
        )
        XCTAssertNil(makeGenerator().generateReport(for: unanalysed))
    }

    // MARK: - Styles

    func testComprehensiveReportRenders() {
        let document = assertRendersPDF(
            makeGenerator().generateReport(
                for: fullSession(),
                sleepData: sleep,
                sleepTrend: sleepTrend,
                healthKitHR: heartRate,
                vitals: vitals,
                compositeRecoveryScore: 78,
                style: .comprehensive,
                sections: .all
            ),
            "comprehensive"
        )
        // The clinical report is the long one — if it ever collapses to a
        // single page, a whole section stopped drawing silently.
        XCTAssertGreaterThan(document?.pageCount ?? 0, 2)
    }

    func testSummaryReportRenders() {
        assertRendersPDF(
            makeGenerator().generateReport(
                for: fullSession(),
                sleepData: sleep,
                vitals: vitals,
                compositeRecoveryScore: 78,
                style: .summary,
                sections: .summaryPreset
            ),
            "summary"
        )
    }

    func testSummaryIsShorterThanComprehensive() {
        let generator = makeGenerator()
        let full = generator.generateReport(
            for: fullSession(),
            sleepData: sleep,
            sleepTrend: sleepTrend,
            healthKitHR: heartRate,
            vitals: vitals,
            style: .comprehensive,
            sections: .all
        )
        let brief = generator.generateReport(
            for: fullSession(),
            sleepData: sleep,
            style: .summary,
            sections: .summaryPreset
        )
        guard let fullDoc = assertRendersPDF(full, "comprehensive"),
              let briefDoc = assertRendersPDF(brief, "summary")
        else { return }
        XCTAssertGreaterThan(
            fullDoc.pageCount,
            briefDoc.pageCount,
            "the deep-dive sections should add pages"
        )
    }

    // MARK: - Section presets

    func testSleepPresetRenders() {
        assertRendersPDF(
            makeGenerator().generateReport(
                for: fullSession(),
                sleepData: sleep,
                sleepTrend: sleepTrend,
                sections: .sleepPreset
            ),
            "sleep preset"
        )
    }

    func testEverySectionRendersOnItsOwn() {
        // Sections are an OptionSet, so any one of them can arrive alone from
        // the custom-report picker. Each has to be able to draw without the
        // others having run first.
        let sections: [(PDFReportGenerator.ReportSections, String)] = [
            (.hrvSummary, "hrvSummary"),
            (.overnightStats, "overnightStats"),
            (.sleep, "sleep"),
            (.trainingLoad, "trainingLoad"),
            (.vitals, "vitals"),
            (.scoreBreakdown, "scoreBreakdown"),
            (.charts, "charts"),
            (.deepDive, "deepDive")
        ]
        for (section, name) in sections {
            assertRendersPDF(
                makeGenerator().generateReport(
                    for: fullSession(),
                    sleepData: sleep,
                    sleepTrend: sleepTrend,
                    healthKitHR: heartRate,
                    vitals: vitals,
                    compositeRecoveryScore: 78,
                    sections: section
                ),
                "section \(name)"
            )
        }
    }

    func testNoSectionsStillProducesADocument() {
        assertRendersPDF(
            makeGenerator().generateReport(for: fullSession(), sections: []),
            "no sections"
        )
    }

    // MARK: - Sparse and degenerate inputs

    func testReportRendersWithoutAnRRSeries() {
        // Imported sessions and RR-purged archives have metrics but no beats.
        // The chart pages have to degrade rather than divide by an empty range.
        assertRendersPDF(
            makeGenerator().generateReport(
                for: session(result: analysisResult(), series: nil),
                sections: .all
            ),
            "no rr series"
        )
    }

    func testReportRendersWithNoOptionalDataAtAll() {
        // Nothing but the session itself: no sleep, no vitals, no HR stats,
        // no score, no history. This is a first-ever session on a phone with
        // HealthKit denied.
        assertRendersPDF(
            makeGenerator().generateReport(for: fullSession(), sections: .all),
            "bare session"
        )
    }

    func testReportRendersWithAFlatlineSeries() {
        // Zero variance is the classic divide-by-range crash in chart code:
        // min == max, so the y-axis scale denominator is 0.
        assertRendersPDF(
            makeGenerator().generateReport(
                for: session(result: analysisResult(), series: rrSeries(beats: 300, jitter: 0)),
                sections: .all
            ),
            "flatline series"
        )
    }

    func testReportRendersWithASingleBeat() {
        assertRendersPDF(
            makeGenerator().generateReport(
                for: session(result: analysisResult(), series: rrSeries(beats: 1)),
                sections: .all
            ),
            "single beat"
        )
    }

    func testReportRendersWithMissingNonlinearMetrics() {
        // DFA α1 is nil whenever the window was too short or too noisy to fit.
        // Every deep-dive page that quotes α1 has to cope.
        assertRendersPDF(
            makeGenerator().generateReport(
                for: session(result: analysisResult(dfaAlpha1: nil, lfHfRatio: nil)),
                sections: .all
            ),
            "missing nonlinear metrics"
        )
    }

    func testReportRendersForEverySessionType() {
        // A two-minute quick reading and a workout capture go through the same
        // renderer as an eight-hour overnight, with far less to draw.
        for type in [SessionType.overnight, .nap, .quick, .breathe, .workout] {
            assertRendersPDF(
                makeGenerator().generateReport(
                    for: session(
                        result: analysisResult(),
                        series: rrSeries(beats: 120),
                        type: type
                    ),
                    sections: .all
                ),
                "session type \(type)"
            )
        }
    }

    // MARK: - History

    func testReportRendersWithRecentSessionHistory() {
        let history = (1 ... 14).map { day in
            session(
                result: analysisResult(rmssd: 40 + Double(day)),
                series: rrSeries(beats: 300)
            )
        }
        assertRendersPDF(
            makeGenerator().generateReport(
                for: fullSession(),
                sleepData: sleep,
                sleepTrend: sleepTrend,
                recentSessions: history,
                sections: .all
            ),
            "with history"
        )
    }

    // MARK: - File output

    func testReportURLWritesAReadableFile() {
        guard let url = makeGenerator().generateReportURL(
            for: fullSession(),
            sleepData: sleep,
            vitals: vitals,
            sections: .all
        ) else {
            return XCTFail("generateReportURL returned nil")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension.lowercased(), "pdf")
        guard let onDisk = PDFDocument(url: url) else {
            return XCTFail("file at \(url.lastPathComponent) is not a readable PDF")
        }
        XCTAssertGreaterThan(onDisk.pageCount, 0)
    }
}
