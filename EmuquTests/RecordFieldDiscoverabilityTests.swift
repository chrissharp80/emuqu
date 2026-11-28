@testable import Emuqu
import XCTest

/// The model picks a lookup by its description. A field a record returns but
/// its description never names is invisible: asked "my lowest heart rate this
/// week", the model finds only last night's record and says it has no data.
/// Every overnight lookup here must name every field it returns, and the
/// per-night lists must answer the questions people ask of a week.
@MainActor
final class RecordFieldDiscoverabilityTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordFieldDiscoverabilityTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: a test that archived nothing leaves no directory to remove.
            }
        }
        return directory
    }

    /// The seeded last night's id, for the by-id lookups.
    private var lastNightID = ""

    private var nightStart: Date {
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date()
        return Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: twoDaysAgo) ?? twoDaysAgo
    }

    private var nightDay: String {
        FactLocalDay.formatter().string(from: nightStart.addingTimeInterval(4 * 3600))
    }

    private func analysis(at date: Date) -> HRVAnalysisResult {
        let timeDomain = TimeDomainMetrics(meanRR: 1000, sdnn: 55, rmssd: 45, pnn50: 20, sdsd: 40, meanHR: 60, sdHR: 5, triangularIndex: 12)
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
        result.overnightNadirHR = 47
        result.overnightMinHR = 46
        result.overnightMaxHR = 82
        result.overnightMeanHR = 58
        return result
    }

    private func night(startingAt start: Date? = nil, nadir: Double = 47) -> HRVSession {
        let nightStart = start ?? self.nightStart
        var session = HRVSession(startDate: nightStart, tags: [], sessionType: .overnight)
        session.endDate = nightStart.addingTimeInterval(8 * 3600)
        session.state = .complete
        session.hrvDataQuality = .good
        session.recoveryScore = 70
        session.analysisResult = analysis(at: nightStart)
        session.analysisResult?.overnightNadirHR = nadir
        session.sleepSnapshot = SleepData(
            date: nightStart, sleepStart: nightStart.addingTimeInterval(600), sleepEnd: nightStart.addingTimeInterval(7.5 * 3600),
            totalSleepMinutes: 420, inBedMinutes: 450, napSleepMinutes: nil, awakeMinutes: 30,
            sleepEfficiency: 93, boundarySource: .healthKit
        )
        session.vitalsSnapshot = RecoveryVitals(
            respiratoryRate: 14.5, respiratoryRateBaseline: 14, oxygenSaturation: 97, oxygenSaturationMin: 93,
            wristTemperature: 0.2, wristTemperatureBaseline: 0.1, restingHeartRate: 52
        )
        return session
    }

    /// A February night months back, for the comparison a user asks of a
    /// date they remember.
    private var februaryNightStart: Date {
        let year = Calendar.current.component(.year, from: Date()) - 1
        return Calendar.current.date(from: DateComponents(year: year, month: 2, day: 19, hour: 23)) ?? Date()
    }

    private var februaryDay: String {
        FactLocalDay.formatter().string(from: februaryNightStart.addingTimeInterval(4 * 3600))
    }

    private func activity(_ sport: Sport, daysAgo: Int) -> HRVSession {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        let start = Calendar.current.date(bySettingHour: 17, minute: 30, second: 0, of: day) ?? day
        var session = HRVSession(startDate: start, tags: [], sessionType: .workout)
        session.endDate = start.addingTimeInterval(45 * 60)
        session.state = .complete
        session.workoutMetadata = WorkoutMetadata(sport: sport)
        return session
    }

    private var activityDay: String {
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return FactLocalDay.formatter().string(from: day)
    }

    private func makeRegistry() throws -> FactResolverRegistry {
        let archive = SessionArchive(directory: temporaryDirectory())
        let lastNight = night()
        lastNightID = lastNight.id.uuidString
        for session in [lastNight, night(startingAt: februaryNightStart, nadir: 51), activity(.run, daysAgo: 1), activity(.walk, daysAgo: 3)] {
            _ = try archive.archive(session, skipSameNightMerge: true)
        }
        return AppFactResolverFactory.build(archive: archive, settings: { UserSettings() }, services: FactServices(.current))
    }

    private func description(of pattern: String, in registry: FactResolverRegistry) -> String? {
        registry.namespaces.flatMap(\.entries).first { $0.keyPattern == pattern }?.entryDescription
    }

    /// The record's field names; a list gives its first item's.
    private func fieldNames(_ value: FactValue) -> [String] {
        switch value {
        case let .record(fields): return Array(fields.keys)
        case let .list(items): return items.first.map(fieldNames) ?? []
        default: return []
        }
    }

    private func number(_ value: FactValue?) -> Double? {
        if case let .double(number) = value { return number }
        return nil
    }

    // MARK: - Every returned field is named

    func testEveryOvernightLookupNamesEveryFieldItReturns() async throws {
        let registry = try makeRegistry()
        let lookups: [(pattern: String, key: String)] = [
            ("hrv.latest", "hrv.latest"), ("hrv.by_date($date)", "hrv.by_date(\(nightDay))"), ("hrv.recent($period)", "hrv.recent(last_30d)"),
            ("sleep.latest", "sleep.latest"), ("sleep.by_date($date)", "sleep.by_date(\(nightDay))"), ("sleep.recent($period)", "sleep.recent(last_30d)"),
            ("vitals.latest", "vitals.latest"), ("vitals.by_date($date)", "vitals.by_date(\(nightDay))"), ("vitals.recent($period)", "vitals.recent(last_30d)")
        ]
        for lookup in lookups {
            let text = try XCTUnwrap(description(of: lookup.pattern, in: registry), "\(lookup.pattern) is not in the catalog")
            let fields = fieldNames(await registry.resolveAsync(lookup.key))
            XCTAssertFalse(fields.isEmpty, "\(lookup.key) returned no record for the seeded night")
            for field in fields {
                XCTAssertTrue(text.contains(field), "\(lookup.pattern) returns \(field) but its description never names it")
            }
        }
    }

    // MARK: - Every recorded-history lookup names what it returns

    /// The namespaces that read the user's recorded history. Live workout and
    /// live recording facts, web, routes and app state are other surfaces.
    private static let historyPrefixes = ["session.", "walks.", "training.", "sleep.", "hrv.", "vitals.", "recovery.", "baseline.", "workout.", "hrr.", "tags."]
    private static let livePrefixes = ["hrv.live", "workout.live"]

    /// The argument each parameter name takes on the seeded archive; nil for
    /// a parameter this archive can't answer (a tag name, a projection).
    private func arguments(for parameter: String, nightID: String) -> [String]? {
        let table: [String: [String]] = [
            "date": [nightDay, activityDay], "period": ["last_30d"], "id": [nightID], "n": ["0"], "ordinal": ["0"], "sport": ["run"]
        ]
        return table[parameter]
    }

    /// Keys to resolve for an entry: its key, or its pattern with each
    /// argument the seeded archive answers.
    private func keys(for entry: FactEntry, nightID: String) -> [String] {
        let display = entry.keyPattern
        guard let open = display.range(of: "($"), display.hasSuffix(")") else { return [display] }
        let parameter = String(display[open.upperBound ..< display.index(before: display.endIndex)])
        let stem = String(display[..<open.lowerBound])
        return arguments(for: parameter, nightID: nightID)?.map { "\(stem)(\($0))" } ?? []
    }

    func testEveryHistoryLookupNamesEveryFieldItReturns() async throws {
        let registry = try makeRegistry()
        let nightID = lastNightID
        let entries = registry.namespaces.flatMap(\.entries).filter { entry in
            !entry.isAction && Self.historyPrefixes.contains { entry.keyPattern.hasPrefix($0) }
                && !Self.livePrefixes.contains { entry.keyPattern.hasPrefix($0) }
        }
        var unnamed: [String] = []
        for entry in entries {
            for key in keys(for: entry, nightID: nightID) {
                let fields = fieldNames(await registry.resolveAsync(key))
                unnamed += fields.filter { !entry.entryDescription.contains($0) }.map { "\(entry.keyPattern) returns \($0)" }
            }
        }
        XCTAssertGreaterThan(entries.count, 30, "the history namespaces went missing from the catalog")
        XCTAssertEqual(Set(unnamed).sorted(), [], "fields returned but never named in the lookup's description")
    }

    // MARK: - Two dates compared in one turn

    /// "How does tonight compare with Feb 20": both nights by date, each
    /// with its own numbers.
    func testANightMonthsBackComparesWithLastNight() async throws {
        let router = CompactToolRouter(registry: try makeRegistry())
        let recent = await router.resolveTool(name: "get_hrv", argsJSON: #"{"which":"by_date","date":"\#(nightDay)"}"#)
        let february = await router.resolveTool(name: "get_hrv", argsJSON: #"{"which":"by_date","date":"\#(februaryDay)"}"#)
        guard case let .record(last) = recent, case let .record(old) = february else {
            return XCTFail("both nights must resolve by date: \(recent) / \(february)")
        }
        XCTAssertEqual(number(last["overnight_nadir_hr_bpm"]), 47)
        XCTAssertEqual(number(old["overnight_nadir_hr_bpm"]), 51)
        let session = await router.resolveTool(name: "get_session", argsJSON: #"{"which":"by_date","date":"\#(februaryDay)"}"#)
        guard case .record = session else { return XCTFail("get_session must read the February night: \(session)") }
        let found = try makeRegistry().entries(matching: "how does tonight compare with february 20", limit: CompactToolRouter.findDataLimit).map(\.display)
        XCTAssertTrue(found.contains { $0.contains("by_date") }, "a dated comparison must find a by-date lookup: \(found)")
    }

    /// The question from a real conversation: one call answers every night.
    func testThePerNightListCarriesEachNightsHeartRate() async throws {
        let registry = try makeRegistry()
        let router = CompactToolRouter(registry: registry)
        let value = await router.resolveTool(name: "get_hrv", argsJSON: #"{"which":"recent","period":"last_week"}"#)
        let recent = await router.resolveTool(name: "get_hrv", argsJSON: #"{"which":"recent","period":"last_30d"}"#)
        guard case let .list(items) = recent, case let .record(first) = items.first else {
            return XCTFail("expected one record per night, got \(recent) (last_week gave \(value))")
        }
        XCTAssertEqual(number(first["overnight_nadir_hr_bpm"]), 47)
        XCTAssertEqual(number(first["overnight_mean_hr_bpm"]), 58)
    }

    // MARK: - get_vitals reads a week

    func testGetVitalsListsAPeriodReadsADateAndDefaultsToTheLatest() async throws {
        let router = CompactToolRouter(registry: try makeRegistry())
        let period = await router.resolveTool(name: "get_vitals", argsJSON: #"{"period":"last_30d"}"#)
        guard case let .list(items) = period, case let .record(first) = items.first else {
            return XCTFail("a period lists the nights, got \(period)")
        }
        XCTAssertEqual(number(first["resting_heart_rate_bpm"]), 52)
        let date = await router.resolveTool(name: "get_vitals", argsJSON: #"{"date":"\#(nightDay)"}"#)
        guard case .record = date else { return XCTFail("a date reads one night, got \(date)") }
        let latest = await router.resolveTool(name: "get_vitals", argsJSON: #"{}"#)
        guard case .record = latest else { return XCTFail("no argument reads the latest night, got \(latest)") }
    }

    // MARK: - Week questions find the per-night lists

    func testWeekQuestionsFindThePerNightLookups() throws {
        let registry = try makeRegistry()
        let cases: [(String, String)] = [
            ("what's my lowest heart rate of the last week", "hrv.recent"),
            ("heart rate during the night, what was the nadir for every night", "hrv.recent"),
            ("resting heart rate this week", "vitals.recent"),
            ("how much deep sleep did I get each night this week", "sleep.recent")
        ]
        for (query, expected) in cases {
            let found = registry.entries(matching: query, limit: CompactToolRouter.findDataLimit).map(\.display)
            XCTAssertTrue(found.contains { $0.hasPrefix(expected) }, "'\(query)' did not find \(expected): \(found)")
        }
    }

    /// The typed tools' own descriptions are what the model reads first.
    func testTheTypedToolsSayTheyAnswerPerNightHeartRate() {
        let tools = Dictionary(uniqueKeysWithValues: CompactToolRouter.readTools().map { ($0.name, $0) })
        let hrv = tools["get_hrv"]?.description.lowercased() ?? ""
        XCTAssertTrue(hrv.contains("heart rate") && hrv.contains("nadir"), "get_hrv must say it holds overnight heart rate")
        XCTAssertNotNil(tools["get_vitals"]?.inputSchema.properties["period"], "get_vitals must take a period")
        XCTAssertEqual(tools["get_vitals"]?.inputSchema.required ?? [], [])
    }
}
