@testable import Emuqu
import XCTest

/// `analyze_data` does the arithmetic a question needs (an average, the
/// lowest day, a trend, two days or two periods side by side) in the app,
/// from the records the other read tools return. Each figure here is worked
/// out by hand from the seeded nights and workouts.
@MainActor
final class AnalyzeDataTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalyzeDataTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: a test that archived nothing leaves no directory to remove.
            }
        }
        return directory
    }

    /// February of last year: a past month, read by its own dates.
    private let year = Calendar.current.component(.year, from: Date()) - 1

    private var month: String { String(format: "%04d-02", year) }

    private func day(_ dayOfMonth: Int) -> String {
        String(format: "%04d-02-%02d", year, dayOfMonth)
    }

    private func date(day dayOfMonth: Int, hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: 2, day: dayOfMonth, hour: hour)) ?? Date()
    }

    private func analysis(at date: Date, rmssd: Double, nadir: Double) -> HRVAnalysisResult {
        let timeDomain = TimeDomainMetrics(meanRR: 1000, sdnn: 55, rmssd: rmssd, pnn50: 20, sdsd: 40, meanHR: 60, sdHR: 5, triangularIndex: 12)
        let nonlinear = NonlinearMetrics(sd1: 30, sd2: 60, sd1Sd2Ratio: 0.5, sampleEntropy: 1.5, approxEntropy: 1.3, dfaAlpha1: 0.9, dfaAlpha2: 0.8, dfaAlpha1R2: 0.95)
        let ans = ANSMetrics(
            stressIndex: 120, pnsIndex: 0.5, snsIndex: -0.3, readinessScore: 70,
            respirationRate: 14, nocturnalHRDip: 12, daytimeRestingHR: 65, nocturnalMedianHR: 57
        )
        var result = HRVAnalysisResult(
            windowStart: 0, windowEnd: 400, timeDomain: timeDomain,
            frequencyDomain: FrequencyDomainMetrics(vlf: 300, lf: 900, hf: 700, lfHfRatio: 1.3, totalPower: 1900),
            nonlinear: nonlinear, ansMetrics: ans, artifactPercentage: 1, cleanBeatCount: 400, analysisDate: date
        )
        result.overnightNadirHR = nadir
        result.overnightMinHR = nadir - 1
        result.overnightMaxHR = 82
        result.overnightMeanHR = 58
        return result
    }

    /// A night starting at 23:00 on `startDay`, filed under the next day.
    private func night(startDay: Int, rmssd: Double, nadir: Double, restingHR: Double?) -> HRVSession {
        let start = date(day: startDay, hour: 23)
        var session = HRVSession(startDate: start, tags: [], sessionType: .overnight)
        session.endDate = start.addingTimeInterval(8 * 3600)
        session.state = .complete
        session.hrvDataQuality = .good
        session.recoveryScore = 70
        session.analysisResult = analysis(at: start, rmssd: rmssd, nadir: nadir)
        if let restingHR {
            session.vitalsSnapshot = RecoveryVitals(
                respiratoryRate: 14.5, respiratoryRateBaseline: 14, oxygenSaturation: 97, oxygenSaturationMin: 93,
                wristTemperature: 0.2, wristTemperatureBaseline: 0.1, restingHeartRate: restingHR
            )
        }
        return session
    }

    private func workout(_ sport: Sport, day dayOfMonth: Int, distance: Double) -> HRVSession {
        let start = date(day: dayOfMonth, hour: 17)
        var session = HRVSession(startDate: start, tags: [], sessionType: .workout)
        session.endDate = start.addingTimeInterval(45 * 60)
        session.state = .complete
        var metadata = WorkoutMetadata(sport: sport)
        metadata.distanceMeters = distance
        session.workoutMetadata = metadata
        return session
    }

    /// Nights filed Feb 10, 11 and 13 (none on the 12th; the 13th has no
    /// vitals), two runs and a walk.
    private func makeRouter() throws -> CompactToolRouter {
        let archive = SessionArchive(directory: temporaryDirectory())
        let sessions = [
            night(startDay: 9, rmssd: 40, nadir: 50, restingHR: 52),
            night(startDay: 10, rmssd: 44, nadir: 46, restingHR: 50),
            night(startDay: 12, rmssd: 48, nadir: 48, restingHR: nil),
            workout(.run, day: 5, distance: 5000), workout(.walk, day: 6, distance: 3000), workout(.run, day: 7, distance: 8000)
        ]
        for session in sessions {
            _ = try archive.archive(session, skipSameNightMerge: true)
        }
        let registry = AppFactResolverFactory.build(archive: archive, settings: { UserSettings() }, services: FactServices(.current))
        return CompactToolRouter(registry: registry)
    }

    private func analyze(_ router: CompactToolRouter, _ args: [String: String]) async throws -> [String: FactValue] {
        let json = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8) ?? "{}"
        let value = await router.resolveTool(name: "analyze_data", argsJSON: json)
        guard case let .record(fields) = value else {
            XCTFail("analyze_data \(args) gave \(value)")
            return [:]
        }
        return fields
    }

    private func number(_ value: FactValue?) -> Double? {
        switch value {
        case let .double(number)?: number
        case let .integer(number)?: Double(number)
        default: nil
        }
    }

    private func text(_ value: FactValue?) -> String? {
        if case let .string(text)? = value { return text }
        return nil
    }

    private func texts(_ value: FactValue?) -> [String] {
        guard case let .list(items)? = value else { return [] }
        return items.compactMap(text)
    }

    // MARK: - Summary

    func testSummaryOfAPastMonthGivesMeanAndTheLowestAndHighestDays() async throws {
        let fields = try await analyze(makeRouter(), ["metric": "overnight_nadir_hr_bpm", "period": month])
        XCTAssertEqual(number(fields["n"]), 3)
        XCTAssertEqual(number(fields["mean"]), 48)
        XCTAssertEqual(number(fields["median"]), 48)
        XCTAssertEqual(number(fields["sum"]), 144)
        XCTAssertEqual(number(fields["stdev"]), 2)
        XCTAssertEqual(number(fields["min"]), 46)
        XCTAssertEqual(text(fields["min_date"]), day(11), "the lowest nadir is the night filed under the 11th")
        XCTAssertEqual(number(fields["max"]), 50)
        XCTAssertEqual(text(fields["max_date"]), day(10))
        XCTAssertEqual(text(fields["unit"]), "bpm")
        XCTAssertEqual(text(fields["source_lookup"]), "hrv.recent(\(month))")
        guard case let .list(values)? = fields["values"] else { return XCTFail("values are listed for three days") }
        XCTAssertEqual(values.count, 3)
    }

    func testABareValueIsTheMetric() {
        XCTAssertEqual(FactResolverRegistry.stringArgs(fromJSON: CompactToolRouter.normalizedArgs("rmssd_ms", tool: "analyze_data")), ["metric": "rmssd_ms"])
    }

    // MARK: - Missing days

    func testDaysWithoutAValueAndWithoutARecordingAreNamed() async throws {
        let range = "\(day(10))..\(day(13))"
        let fields = try await analyze(makeRouter(), ["metric": "resting_heart_rate_bpm", "period": range])
        XCTAssertEqual(number(fields["n"]), 2)
        XCTAssertEqual(number(fields["mean"]), 51)
        XCTAssertEqual(texts(fields["dates_without_value"]), [day(13)], "the 13th was recorded without vitals")
        XCTAssertEqual(texts(fields["dates_without_recording"]), [day(12)], "nothing was recorded on the 12th")
    }

    // MARK: - Trend

    func testTrendIsTheLeastSquaresSlopeOverTheDays() async throws {
        let fields = try await analyze(makeRouter(), ["metric": "rmssd_ms", "op": "trend", "period": "\(day(10))..\(day(13))"])
        // x = 0, 1, 3 days; y = 40, 44, 48: slope = 12 / (14/3) = 2.5714 per day.
        XCTAssertEqual(number(fields["slope_per_day"]), 2.57)
        XCTAssertEqual(number(fields["slope_per_week"]), 18)
        XCTAssertEqual(number(fields["first_value"]), 40)
        XCTAssertEqual(text(fields["first_date"]), day(10))
        XCTAssertEqual(number(fields["last_value"]), 48)
        XCTAssertEqual(text(fields["last_date"]), day(13))
        XCTAssertEqual(number(fields["change"]), 8)
    }

    // MARK: - Comparisons

    func testCompareDatesGivesEachValueTheDifferenceAndPercent() async throws {
        let fields = try await analyze(makeRouter(), ["metric": "overnight_nadir_hr_bpm", "op": "compare_dates", "date_a": day(10), "date_b": day(11)])
        XCTAssertEqual(number(fields["value_a"]), 50)
        XCTAssertEqual(number(fields["value_b"]), 46)
        XCTAssertEqual(number(fields["difference"]), -4)
        XCTAssertEqual(number(fields["percent_change"]), -8)
        XCTAssertEqual(text(fields["source_lookup_a"]), "hrv.by_date(\(day(10)))")
    }

    func testCompareDatesSaysWhichDayHadNoValue() async throws {
        let fields = try await analyze(makeRouter(), ["metric": "overnight_nadir_hr_bpm", "op": "compare_dates", "date_a": day(10), "date_b": day(12)])
        XCTAssertEqual(number(fields["value_a"]), 50)
        XCTAssertEqual(texts(fields["dates_without_value"]), [day(12)])
        guard case .missing? = fields["difference"] else { return XCTFail("no difference without both values: \(String(describing: fields["difference"]))") }
    }

    func testComparePeriodsGivesEachMeanTheDifferenceAndPercent() async throws {
        let args = ["metric": "rmssd_ms", "op": "compare_periods", "period_a": "\(day(10))..\(day(11))", "period_b": day(13)]
        let fields = try await analyze(makeRouter(), args)
        guard case let .record(first)? = fields["period_a"], case let .record(second)? = fields["period_b"] else { return XCTFail("both periods are records: \(fields)") }
        XCTAssertEqual(number(first["mean"]), 42)
        XCTAssertEqual(number(first["n"]), 2)
        XCTAssertEqual(number(second["mean"]), 48)
        XCTAssertEqual(number(fields["difference"]), 6)
        XCTAssertEqual(number(fields["percent_change"]), 14.3, "6 / 42 = 14.29 percent")
    }

    // MARK: - Workouts

    func testSportKeepsOneSportsWorkouts() async throws {
        let router = try makeRouter()
        let runs = try await analyze(router, ["metric": "distance_m", "period": month, "sport": "run"])
        XCTAssertEqual(number(runs["n"]), 2)
        XCTAssertEqual(number(runs["mean"]), 6500)
        XCTAssertEqual(number(runs["sum"]), 13000)
        XCTAssertEqual(number(runs["min"]), 5000)
        XCTAssertEqual(text(runs["min_date"]), day(5))
        XCTAssertEqual(text(runs["source_lookup"]), "workout.list(\(month),run)")
        let all = try await analyze(router, ["metric": "distance_m", "period": month])
        XCTAssertEqual(number(all["n"]), 3)
        XCTAssertEqual(number(all["min"]), 3000)
    }

    // MARK: - Bad arguments

    func testAnUnknownMetricIsAnInvalidArgument() async throws {
        let router = try makeRouter()
        let value = await router.resolveTool(name: "analyze_data", argsJSON: #"{"metric":"not_a_field"}"#)
        guard case let .missing(reason, _) = value else { return XCTFail("expected missing, got \(value)") }
        XCTAssertEqual(reason, .invalidParameter)
    }
}
