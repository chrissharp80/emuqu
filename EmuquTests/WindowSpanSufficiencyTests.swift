@testable import Emuqu
import XCTest

/// Every length rule that decides whether a night's HRV is trusted reads the
/// quantity it is written in. The 5-minute floor
/// (`HRVConstants.MinimumDuration.forReliableWindowMs`) is a span of time, so
/// the selector builds each full window to span it at any heart rate, a
/// window's bounds run from its first beat's start to its last beat's end,
/// and the acceptance rule and the baseline's structural gate read that one
/// span. Vitals baselines count the nights they hold, not their samples.
@MainActor
final class WindowSpanSufficiencyTests: XCTestCase {
    private let selector = WindowSelector()
    private let floorMs = HRVConstants.MinimumDuration.forReliableWindowMs

    /// A steady night at `bpm` with small beat-to-beat variation.
    private func night(bpm: Double, beats: Int) -> [RRPoint] {
        let base = 60_000 / bpm
        var t: Int64 = 0
        return (0 ..< beats).map { i in
            let rr = Int((base + 0.03 * base * sin(Double(i) * 0.9)).rounded())
            defer { t += Int64(rr) }
            return RRPoint(t_ms: t, rr_ms: rr)
        }
    }

    private func span(_ points: [RRPoint], _ range: Range<Int>) -> Int64 {
        points[range.upperBound - 1].endMs - points[range.lowerBound].t_ms
    }

    // MARK: - Window geometry

    func testEveryFullWindowSpansFiveMinutesAndFourHundredBeatsAtAnyHeartRate() {
        for bpm in [45.0, 60, 75, 80, 90, 110, 140] {
            let points = night(bpm: bpm, beats: 4000)
            let grid = WindowSelector.ScanGrid(bandStart: 0, bandEnd: points.count, windowSize: 400, stepSize: 40)
            let ranges = selector.windowRanges(points: points, grid: grid)
            XCTAssertFalse(ranges.isEmpty, "\(bpm) bpm")
            for range in ranges {
                XCTAssertGreaterThanOrEqual(span(points, range), floorMs, "\(bpm) bpm window \(range)")
                XCTAssertGreaterThanOrEqual(range.count, 400, "\(bpm) bpm window \(range)")
                XCTAssertLessThanOrEqual(range.upperBound, points.count)
                if range.count > 400 {
                    XCTAssertLessThan(span(points, range.lowerBound ..< range.upperBound - 1), floorMs,
                                      "\(bpm) bpm: a window past 400 beats stops at the first beat that reaches 5 min")
                }
            }
        }
    }

    func testBelowEightyBpmTheWindowIsExactlyTheBeatTarget() {
        let points = night(bpm: 60, beats: 2000)
        let grid = WindowSelector.ScanGrid(bandStart: 0, bandEnd: points.count, windowSize: 400, stepSize: 40)
        let ranges = selector.windowRanges(points: points, grid: grid)
        XCTAssertEqual(ranges.first, 0 ..< 400)
        XCTAssertEqual(ranges.map(\.count), Array(repeating: 400, count: ranges.count))
        XCTAssertEqual(ranges.map(\.lowerBound), Array(stride(from: 0, through: 1600, by: 40)))
    }

    func testABandShorterThanFiveMinutesIsStillScannedOnBeatCount() {
        let points = night(bpm: 60, beats: 250)
        let grid = WindowSelector.ScanGrid(bandStart: 0, bandEnd: points.count, windowSize: 125, stepSize: 12)
        let ranges = selector.windowRanges(points: points, grid: grid)
        XCTAssertEqual(ranges.first, 0 ..< 125)
        XCTAssertTrue(ranges.allSatisfy { $0.count == 125 })
    }

    func testAScoredBlockEndsWhereItsLastBeatEnds() throws {
        let points = night(bpm: 60, beats: 1000)
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)
        let block = try XCTUnwrap(selector.evaluateWindow(
            series: series, flags: flags, startIdx: 100, endIdx: 500,
            sessionStartMs: 0, sessionEndMs: points[999].endMs
        ))
        XCTAssertEqual(block.startMs, points[100].t_ms)
        XCTAssertEqual(block.endMs, points[499].endMs)
        XCTAssertEqual(block.endMs - block.startMs, Int64(points[100 ..< 500].map(\.rr_ms).reduce(0, +)))
    }

    // MARK: - The window and the acceptance rule agree

    /// A night at 90 bpm, with RMSSD below baseline and organized recovery:
    /// the selector's full window reaches the 5-minute floor, so the reading
    /// is trusted and the baseline is admitted, instead of the baseline's own
    /// RMSSD being scored in its place.
    func testAFullWindowAtHighHeartRateIsNeitherInsufficientNorExcludedFromTheBaseline() throws {
        for bpm in [80.0, 90, 110] {
            let points = night(bpm: bpm, beats: 4 * 3600 * Int(bpm) / 60)
            let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
            let flags = [ArtifactFlags](repeating: .clean, count: points.count)
            let window = try XCTUnwrap(selector.selectWindowByMethod(.peakRMSSD, in: series, flags: flags), "\(bpm) bpm")
            XCTAssertGreaterThanOrEqual(window.endMs - window.startMs, floorMs, "\(bpm) bpm")
            var result = analysis(rmssd: 20)
            result.windowStartMs = window.startMs
            result.windowEndMs = window.endMs
            result.isOrganizedRecovery = true
            XCTAssertFalse(SessionAcceptanceService.isInsufficientData(result: result, baselineRmssd: 40, sessionDuration: 4 * 3600), "\(bpm) bpm")
            XCTAssertTrue(BaselineTracker.isStructurallySound(result: result, sessionDuration: 4 * 3600), "\(bpm) bpm")
        }
    }

    func testTheAcceptanceRuleAndTheBaselineGateReadOneSpan() {
        let cases: [(windowMs: Int64?, sessionSeconds: TimeInterval, sound: Bool)] = [
            (floorMs - 1, 4 * 3600, false),
            (floorMs, 4 * 3600, true),
            (nil, 299, false),
            (nil, 300, true)
        ]
        for c in cases {
            var result = analysis(rmssd: 20)
            result.isOrganizedRecovery = true
            if let windowMs = c.windowMs {
                result.windowStartMs = 1_000
                result.windowEndMs = 1_000 + windowMs
            }
            XCTAssertEqual(BaselineTracker.isStructurallySound(result: result, sessionDuration: c.sessionSeconds), c.sound, "\(c)")
            XCTAssertEqual(
                SessionAcceptanceService.isInsufficientData(result: result, baselineRmssd: 40, sessionDuration: c.sessionSeconds),
                !c.sound, "\(c)"
            )
        }
    }

    func testATappedWindowAtHighHeartRateSpansFiveMinutes() throws {
        let points = night(bpm: 100, beats: 6000)
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)
        for target in [points[3000].t_ms, points[5990].t_ms] {
            let window = try XCTUnwrap(selector.analyzeAtPosition(in: series, flags: flags, targetMs: target))
            XCTAssertGreaterThanOrEqual(window.endMs - window.startMs, floorMs, "tap at \(target)")
        }
    }

    // MARK: - Vitals baselines count nights

    func testAVitalsBaselineNeedsReadingsFromThreeNights() throws {
        let morning = Date(timeIntervalSince1970: 1_700_000_000)
        let nightEnd = { (n: Int, hour: Double) in morning.addingTimeInterval(Double(-n) * 86_400 + hour * 3600) }
        let oneNight = (0 ..< 20).map { (end: nightEnd(1, Double($0) * 0.3), value: 14.0) }
        XCTAssertNil(VitalsScoring.baselineMean(oneNight), "many samples from one night are not a baseline")
        let acrossMidnight = [(end: nightEnd(1, -1), value: 14.0), (end: nightEnd(1, 1), value: 16.0), (end: nightEnd(2, 0), value: 15.0)]
        XCTAssertNil(VitalsScoring.baselineMean(acrossMidnight), "readings either side of midnight are one night")
        let threeNights = [(end: nightEnd(1, 0), value: 14.0), (end: nightEnd(2, 0), value: 15.0), (end: nightEnd(3, 0), value: 16.0)]
        XCTAssertEqual(try XCTUnwrap(VitalsScoring.baselineMean(threeNights)), 15.0, accuracy: 1e-9)
        XCTAssertNil(VitalsScoring.baselineMean([]))
    }

    private func analysis(rmssd: Double) -> HRVAnalysisResult {
        HRVAnalysisResult(
            windowStart: 0, windowEnd: 600_000,
            timeDomain: TimeDomainMetrics(
                meanRR: 1_000, sdnn: rmssd * 1.2, rmssd: rmssd, pnn50: 20,
                sdsd: rmssd * 0.95, meanHR: 60, sdHR: 3, triangularIndex: 12
            ),
            frequencyDomain: nil,
            nonlinear: NonlinearMetrics(
                sd1: rmssd * 0.7, sd2: rmssd * 1.1, sd1Sd2Ratio: 0.64,
                sampleEntropy: 1.5, approxEntropy: 1.2,
                dfaAlpha1: 0.95, dfaAlpha2: 0.85, dfaAlpha1R2: 0.95
            ),
            ansMetrics: nil, artifactPercentage: 2, cleanBeatCount: 500, analysisDate: Date()
        )
    }
}
