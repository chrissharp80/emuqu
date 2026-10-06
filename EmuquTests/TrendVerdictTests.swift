@testable import Emuqu
import XCTest

/// The shared trend verdict every trend surface uses (`TrendVerdict`).
///
/// The scenarios are the trend audit's (bugs/trend-load.md): the old Flo rule
/// compared a per-day slope with 0.1 × the series SD, so it called 64 % of
/// pure-noise weeks a trend and read every perfect line of 35+ readings as
/// "stable", a clean 60 → 30 ms halving included; the Trends screen used a
/// second rule and the PDF a third.
@MainActor
final class TrendVerdictTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        pinEnglishLanguage()
    }

    // MARK: - Fixtures

    /// Deterministic standard normals (SplitMix64 + Box-Muller), so the
    /// Monte Carlo bounds are reproducible.
    private struct SeededNormal {
        var state: UInt64

        mutating func next() -> Double {
            let u1 = max(uniform(), .leastNonzeroMagnitude)
            let u2 = uniform()
            return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        }

        private mutating func uniform() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(UInt64(1) << 53)
        }
    }

    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    /// One reading a day, oldest first.
    private func readings(_ values: [Double]) -> [TrendVerdict.Reading] {
        values.enumerated().map { TrendVerdict.Reading(date: origin.addingTimeInterval(Double($0.offset) * 86_400), value: $0.element) }
    }

    private func linear(from start: Double, to end: Double, count: Int) -> [Double] {
        (0 ..< count).map { start + (end - start) * Double($0) / Double(count - 1) }
    }

    private func stepAtMidpoint(count: Int) -> [Double] {
        Array(repeating: 60.0, count: count / 2) + Array(repeating: 30.0, count: count - count / 2)
    }

    /// Overnight sessions with the given RMSSDs, the last one today.
    private func sessions(rmssd values: [Double]) -> [HRVSession] {
        values.enumerated().map { index, rmssd in
            let date = Date().addingTimeInterval(-Double(values.count - 1 - index) * 86_400)
            let result = HRVAnalysisResult(
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
                ansMetrics: nil, artifactPercentage: 2, cleanBeatCount: 500, analysisDate: date
            )
            return HRVSession(
                id: UUID(), startDate: date, endDate: date.addingTimeInterval(28_800),
                state: .complete, sessionType: .overnight, rrSeries: nil,
                analysisResult: result, artifactFlags: nil
            )
        }
    }

    private func noiseRate(count: Int, series: Int, sd: Double, seed: UInt64) -> Double {
        var normal = SeededNormal(state: seed)
        var trends = 0
        for _ in 0 ..< series {
            let values = (0 ..< count).map { _ in 60 * exp(sd * normal.next()) }
            let movement = TrendVerdict.evaluate(readings(values), scale: .logarithmic).movement
            trends += (movement == .up || movement == .down) ? 1 : 0
        }
        return Double(trends) / Double(series)
    }

    // MARK: - Halvings are caught at every window

    func testLinearHalvingIsFallingAtEveryWindowLength() {
        for count in [7, 14, 30, 35, 60, 90, 365] {
            let verdict = TrendVerdict.evaluate(readings(linear(from: 60, to: 30, count: count)), scale: .logarithmic)
            XCTAssertEqual(verdict.movement, .down, "a 60 → 30 ms line over \(count) readings")
        }
    }

    func testStepHalvingIsFallingAtEveryWindowLength() {
        for count in [7, 14, 30, 90, 365] {
            let verdict = TrendVerdict.evaluate(readings(stepAtMidpoint(count: count)), scale: .logarithmic)
            XCTAssertEqual(verdict.movement, .down, "a 60 → 30 ms step halfway through \(count) readings")
        }
    }

    func testRecentStepIsFallingInALongWindow() {
        for (count, low) in [(30, 3), (90, 3), (90, 70), (365, 3), (365, 30)] {
            let values = Array(repeating: 60.0, count: count - low) + Array(repeating: 30.0, count: low)
            XCTAssertEqual(
                TrendVerdict.evaluate(readings(values), scale: .logarithmic).movement, .down,
                "the last \(low) of \(count) readings halved"
            )
        }
    }

    /// Flo's analyzer read every perfect line of 35+ readings as stable.
    func testFloAnalyzerCallsALongHalvingDeclining() throws {
        for count in [35, 90, 365] {
            let summary = try XCTUnwrap(TrendAnalyzer.analyze(sessions: sessions(rmssd: linear(from: 60, to: 30, count: count)), period: .all))
            XCTAssertEqual(summary.rmssdStats.trend, .declining, "\(count) readings")
            XCTAssertEqual(summary.overallTrend, .declining, "\(count) readings")
        }
    }

    // MARK: - Noise stays quiet

    /// Each of the two tests runs at two-sided 2.5 %, so at most 5 % of
    /// pure-noise windows may read as a trend; the bound leaves room for
    /// Monte Carlo error at 2,000 series (SE ≈ 0.5 %).
    func testNoiseFalseTrendRateIsBelowSevenPercent() {
        for (count, seed) in [(7, UInt64(7)), (14, 14), (30, 30), (90, 90)] {
            for sd in [0.07, 0.10, 0.29] {
                let rate = noiseRate(count: count, series: 2_000, sd: sd, seed: seed)
                XCTAssertLessThan(rate, 0.07, "\(count) readings of noise at SD(ln) \(sd): \(rate)")
            }
        }
    }

    /// The same bound through Flo's analyzer, the path that fired on 64 % of
    /// noise weeks.
    func testFloAnalyzerRarelyCallsANoiseWeekATrend() throws {
        var normal = SeededNormal(state: 2_026)
        var trends = 0
        let series = 300
        for _ in 0 ..< series {
            let week = (0 ..< 7).map { _ in 60 * exp(0.10 * normal.next()) }
            let summary = try XCTUnwrap(TrendAnalyzer.analyze(sessions: sessions(rmssd: week), period: .all))
            trends += summary.rmssdStats.trend == .stable ? 0 : 1
        }
        XCTAssertLessThan(Double(trends) / Double(series), 0.12, "noise weeks called a trend: \(trends) of \(series)")
    }

    func testConstantAndNegligibleSeriesAreFlat() {
        XCTAssertEqual(TrendVerdict.evaluate(readings(Array(repeating: 45, count: 14)), scale: .logarithmic).movement, .flat)
        XCTAssertEqual(TrendVerdict.evaluate(readings(Array(repeating: 7, count: 14)), scale: .linear).movement, .flat)
        // 60 → 59.9 ms is far inside the smallest worthwhile change.
        XCTAssertEqual(TrendVerdict.evaluate(readings(linear(from: 60, to: 59.9, count: 40)), scale: .logarithmic).movement, .flat)
    }

    func testFewerThanFourReadingsIsInsufficient() {
        let verdict = TrendVerdict.evaluate(readings([60, 40, 30]), scale: .logarithmic)
        XCTAssertEqual(verdict.movement, .insufficient)
        XCTAssertNil(verdict.recentChangePercent)
    }

    // MARK: - One rule on every surface

    /// Flo's tool says it returns the trend the Trends screen shows.
    func testFloAndTheTrendsScreenAgree() throws {
        for values in [linear(from: 60, to: 30, count: 90), stepAtMidpoint(count: 30), linear(from: 30, to: 60, count: 14), Array(repeating: 50, count: 30)] {
            let scoped = sessions(rmssd: values)
            let summary = try XCTUnwrap(TrendAnalyzer.analyze(sessions: scoped, period: .all))
            let card = TrendsV2View.computeDirection(TrendVerdict.rmssdReadings(scoped), scale: .logarithmic)
            let expectedGlyph = switch summary.overallTrend {
            case .improving: "arrow.up.right"
            case .declining: "arrow.down.right"
            default: "arrow.right"
            }
            XCTAssertEqual(card.glyph, expectedGlyph, "Flo said \(summary.overallTrend.rawValue)")
        }
    }

    func testWeeklyChangeIsReportedOnlyForATrend() throws {
        XCTAssertNil(TrendVerdict.weeklyRMSSDChange(sessions(rmssd: Array(repeating: 50, count: 14))))
        let halving = try XCTUnwrap(TrendVerdict.weeklyRMSSDChange(sessions(rmssd: stepAtMidpoint(count: 14))))
        XCTAssertEqual(halving, -50, accuracy: 0.5)
    }

    func testStudentTCriticalValues() {
        XCTAssertEqual(TrendVerdict.tCritical(degrees: 3), 4.1765, accuracy: 1e-4)
        XCTAssertEqual(TrendVerdict.tCritical(degrees: 10), 2.6338, accuracy: 1e-3)
        XCTAssertEqual(TrendVerdict.tCritical(degrees: 30), 2.3596, accuracy: 1e-3)
        XCTAssertEqual(TrendVerdict.tCritical(degrees: 1_000), 2.2448, accuracy: 1e-3)
    }
}
