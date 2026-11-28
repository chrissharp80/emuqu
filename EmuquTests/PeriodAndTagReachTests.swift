import CoreLocation
@testable import Emuqu
import XCTest

/// The assistant has to reach any stretch of the user's history: a month
/// last year reads that month and nothing after it, a long list keeps the
/// field asked for or comes back cut with markers instead of failing, tags
/// are filed under the same night `session.by_date` uses, and archived
/// trails are reachable by day and by period.
@MainActor
final class PeriodAndTagReachTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeriodAndTagReachTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: a test that archived nothing leaves no directory to remove.
            }
        }
        return directory
    }

    /// Last year, so every seeded month is in the past.
    private let year = Calendar.current.component(.year, from: Date()) - 1

    private func date(month: Int, day: Int, hour: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? Date()
    }

    private func iso(month: Int, day: Int) -> String {
        FactLocalDay.formatter().string(from: date(month: month, day: day, hour: 12))
    }

    private var february: String { String(format: "%04d-02", year) }

    private func analysis(at date: Date) -> HRVAnalysisResult {
        let timeDomain = TimeDomainMetrics(meanRR: 1000, sdnn: 55, rmssd: 45, pnn50: 20, sdsd: 40, meanHR: 60, sdHR: 5, triangularIndex: 12)
        let nonlinear = NonlinearMetrics(sd1: 30, sd2: 60, sd1Sd2Ratio: 0.5, sampleEntropy: 1.5, approxEntropy: 1.3, dfaAlpha1: 0.9, dfaAlpha2: 0.8, dfaAlpha1R2: 0.95)
        var result = HRVAnalysisResult(
            windowStart: 0, windowEnd: 400, timeDomain: timeDomain,
            frequencyDomain: FrequencyDomainMetrics(vlf: 300, lf: 900, hf: 700, lfHfRatio: 1.3, totalPower: 1900),
            nonlinear: nonlinear, ansMetrics: nil, artifactPercentage: 1, cleanBeatCount: 400, analysisDate: date
        )
        result.overnightMinHR = 46
        return result
    }

    private func night(startingAt start: Date, tags: [ReadingTag] = []) -> HRVSession {
        var session = HRVSession(startDate: start, tags: tags, sessionType: .overnight)
        session.endDate = start.addingTimeInterval(8 * 3600)
        session.state = .complete
        session.hrvDataQuality = .good
        session.recoveryScore = 7
        session.analysisResult = analysis(at: start)
        return session
    }

    /// Nights around February: one starting Jan 31 at 23:00 (its midpoint is
    /// Feb 1), Feb 10, one starting Feb 28 at 23:00 (filed under Mar 1) and
    /// Mar 5. Only the first two are February's.
    private func makeRegistry(services: FactServices = FactServices(.current)) throws -> (FactResolverRegistry, [HRVSession]) {
        let archive = SessionArchive(directory: temporaryDirectory())
        let alcohol = ReadingTag(name: "Alcohol", colorHex: "#FF0000")
        let nights = [
            night(startingAt: date(month: 1, day: 31, hour: 23), tags: [alcohol]),
            night(startingAt: date(month: 2, day: 10, hour: 1)),
            night(startingAt: date(month: 2, day: 28, hour: 23), tags: [alcohol]),
            night(startingAt: date(month: 3, day: 5, hour: 1))
        ]
        for item in nights {
            _ = try archive.archive(item, skipSameNightMerge: true)
        }
        return (AppFactResolverFactory.build(archive: archive, settings: { UserSettings() }, services: services), nights)
    }

    private func items(_ value: FactValue, file: StaticString = #filePath, line: UInt = #line) -> [[String: FactValue]] {
        guard case let .list(list) = value else {
            XCTFail("expected a list, got \(value)", file: file, line: line)
            return []
        }
        return list.compactMap { item in
            if case let .record(fields) = item { return fields }
            return nil
        }
    }

    private func dates(_ records: [[String: FactValue]]) -> Set<Date> {
        Set(records.compactMap { record in
            if case let .date(date) = record["date"] { return date }
            return nil
        })
    }

    private func strings(_ records: [[String: FactValue]], _ field: String) -> [String] {
        records.compactMap { record in
            if case let .string(text) = record[field] { return text }
            return nil
        }
    }

    // MARK: - Past date ranges

    func testAMonthLastYearReadsOnlyThatMonthsNightsAndEndsInThePast() async throws {
        let (registry, nights) = try makeRegistry()
        let interval = try XCTUnwrap(PeriodParser.interval(for: february))
        XCTAssertEqual(interval.start, date(month: 2, day: 1))
        XCTAssertEqual(interval.end, date(month: 3, day: 1), "the month ends after its last day")
        XCTAssertLessThan(interval.end, Date(), "a past month ends in the past, not now")
        XCTAssertNil(PeriodParser.invalidPeriod(february))
        let router = CompactToolRouter(registry: registry)
        let value = await router.resolveTool(name: "get_hrv", argsJSON: #"{"which":"recent","period":"\#(february)"}"#)
        XCTAssertEqual(dates(items(value)), [nights[0].startDate, nights[1].startDate], "February's nights by midpoint, none from March")
    }

    func testADayRangeIsInclusiveAndAYearCoversItsNights() async throws {
        let (registry, nights) = try makeRegistry()
        let range = "\(iso(month: 2, day: 1))..\(iso(month: 2, day: 10))"
        let ranged = await registry.resolveAsync("hrv.recent(\(range))")
        XCTAssertEqual(dates(items(ranged)), [nights[0].startDate, nights[1].startDate], "both end days are in the range")
        let year = await registry.resolveAsync("hrv.recent(\(self.year))")
        XCTAssertEqual(items(year).count, 4)
        XCTAssertNotNil(PeriodParser.invalidPeriod("\(iso(month: 2, day: 10))..\(iso(month: 2, day: 1))"), "a range that runs backwards is invalid")
    }

    // MARK: - Field projection

    func testAFieldTailKeepsTheAskedFieldAndWhichNightItIs() async throws {
        let (registry, _) = try makeRegistry()
        let router = CompactToolRouter(registry: registry)
        let value = await router.resolveTool(name: "lookup_fact", argsJSON: #"{"key":"hrv.recent(\#(february)).overnight_min_hr_bpm"}"#)
        let records = items(value)
        XCTAssertEqual(records.count, 2)
        for record in records {
            guard case .double(46) = record["overnight_min_hr_bpm"] else { return XCTFail("the asked field is kept, got \(record)") }
            XCTAssertEqual(Set(record.keys), ["date", "session_type", "overnight_min_hr_bpm"], "only the field and the night's identity")
        }
    }

    // MARK: - Oversize lists

    func testAnOversizeListComesBackAsTheNewestItemsWithMarkers() throws {
        let (registry, _) = try makeRegistry()
        let padding = String(repeating: "x", count: 400)
        let list: [FactValue] = (0 ..< 400).map { offset in
            .record(["date": .date(Date(timeIntervalSince1970: Double(1_000_000 - offset) * 86400)), "note": .string(padding)])
        }
        let value = registry.gatedReadResult(toolName: "get_hrv", argsJSON: "{}", value: .list(list), elapsed: 0)
        guard case let .record(fields) = value, case let .list(kept) = fields["items"] else {
            return XCTFail("an oversize list is cut, not refused; got \(value)")
        }
        guard case .boolean(true) = fields["truncated"], case let .integer(omitted) = fields["omitted_count"] else {
            return XCTFail("the cut list carries truncated and omitted_count")
        }
        XCTAssertGreaterThan(omitted, 0)
        XCTAssertEqual(kept.count + omitted, list.count)
        XCTAssertLessThanOrEqual(value.toolResultJSON.utf8.count, FactResolverRegistry.outputSizeCapBytes)
        guard case let .record(first) = kept.first, case let .record(newest) = list.first else { return XCTFail("records expected") }
        XCTAssertEqual(first["date"].map(String.init(describing:)), newest["date"].map(String.init(describing:)), "the newest items are kept")
    }

    // MARK: - Tags by the midpoint day

    func testTagsAreFiledUnderTheNightsMidpointDay() async throws {
        let (registry, nights) = try makeRegistry()
        let startDay = await registry.resolveAsync("tags.list_active(\(iso(month: 1, day: 31)))")
        guard case .missing = startDay else { return XCTFail("a night starting at 23:00 is not its start day's, got \(startDay)") }
        let midpointDay = await registry.resolveAsync("tags.list_active(\(iso(month: 2, day: 1)))")
        guard case let .list(names) = midpointDay, names.count == 1, case .string("Alcohol") = names.first else {
            return XCTFail("the night is filed under its midpoint day, got \(midpointDay)")
        }
        let listed = items(await registry.resolveAsync("tags.list(\(february))"))
        XCTAssertEqual(strings(listed, "session_id"), [nights[0].id.uuidString], "only February's tagged night; Feb 28's is March's")
        XCTAssertEqual(strings(listed, "date"), [iso(month: 2, day: 1)])
        let tagged = items(await registry.resolveAsync("tags.tagged_in_period(Alcohol,\(year))"))
        XCTAssertEqual(strings(tagged, "session_id"), [nights[2].id.uuidString, nights[0].id.uuidString], "every tagged night in the period, newest first")
        let counted = await registry.resolveAsync("tags.count_in_period(Alcohol,\(february))")
        guard case .integer(1) = counted else { return XCTFail("the count uses the same day rule, got \(counted)") }
    }

    // MARK: - Breadcrumbs by date

    private func trail(startedAt start: Date, label: String) -> BreadcrumbTrail {
        let fixes = (0 ..< 3).map { step in
            BreadcrumbFix(from: CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 45 + Double(step) * 0.001, longitude: -122),
                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1, course: -1, speed: -1,
                timestamp: start.addingTimeInterval(Double(step) * 600)
            ))
        }
        return BreadcrumbTrail(startedAt: start, origin: fixes.first, fixes: fixes, label: label)
    }

    func testArchivedTrailsResolveByDateAndByPeriod() async throws {
        let store = BreadcrumbStore(fileURL: temporaryDirectory().appendingPathComponent("Breadcrumbs/active.json"))
        store.archive(trail(startedAt: date(month: 2, day: 20, hour: 9), label: "Cedar Falls"))
        store.archive(trail(startedAt: date(month: 3, day: 2, hour: 9), label: "River loop"))
        let dependencies = AppDependencies()
        dependencies.overrides.breadcrumbStore = store
        let (registry, _) = try makeRegistry(services: FactServices(dependencies))
        let router = CompactToolRouter(registry: registry)
        let onDay = items(await router.resolveTool(name: "get_breadcrumbs", argsJSON: #"{"field":"by_date(\#(iso(month: 2, day: 20)))"}"#))
        XCTAssertEqual(strings(onDay, "label"), ["Cedar Falls"])
        XCTAssertEqual(strings(onDay, "date"), [iso(month: 2, day: 20)])
        guard case let .integer(seconds) = onDay.first?["duration_seconds"] else { return XCTFail("the trail's duration is given") }
        XCTAssertEqual(seconds, 1200)
        let inFebruary = items(await registry.resolveAsync("breadcrumb.list(\(february))"))
        XCTAssertEqual(strings(inFebruary, "label"), ["Cedar Falls"], "March's trail is outside February")
    }
}
