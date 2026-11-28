import CoreLocation
@testable import Emuqu
import XCTest

/// What the app stores about a night or a workout must be readable by the
/// assistant: asked for a run's splits, the weather on it, or which nights
/// were partial, it reads them from the session and workout records instead
/// of saying the app has no such data.
@MainActor
final class SessionRecordReachTests: XCTestCase {
    private struct Fixture {
        let registry: FactResolverRegistry
        let night: HRVSession
        let partial: HRVSession
        let run: HRVSession
        let walk: HRVSession
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionRecordReachTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: a test that archived nothing leaves no directory to remove.
            }
        }
        return directory
    }

    private func start(daysAgo: Int, hour: Int) -> Date {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    private func day(_ date: Date) -> String {
        FactLocalDay.formatter().string(from: date)
    }

    private func analysis(at date: Date) -> HRVAnalysisResult {
        HRVAnalysisResult(
            windowStart: 0, windowEnd: 400,
            timeDomain: TimeDomainMetrics(meanRR: 1000, sdnn: 55, rmssd: 45, pnn50: 20, sdsd: 40, meanHR: 60, sdHR: 5, triangularIndex: 12),
            frequencyDomain: nil,
            nonlinear: NonlinearMetrics(sd1: 30, sd2: 60, sd1Sd2Ratio: 0.5, sampleEntropy: 1.5, approxEntropy: 1.3, dfaAlpha1: 0.9, dfaAlpha2: 0.8, dfaAlpha1R2: 0.95),
            ansMetrics: nil, artifactPercentage: 1, cleanBeatCount: 400, analysisDate: date
        )
    }

    private func overnight(startingAt start: Date, hours: Double, quality: HRVDataQuality) -> HRVSession {
        var session = HRVSession(startDate: start, tags: [], sessionType: .overnight)
        session.endDate = start.addingTimeInterval(hours * 3600)
        session.state = .complete
        session.hrvDataQuality = quality
        session.recoveryScore = 7
        session.analysisResult = analysis(at: start)
        return session
    }

    /// A tagged night recorded on a strap, with a note and an import source.
    private func taggedNight() -> HRVSession {
        var night = overnight(startingAt: start(daysAgo: 3, hour: 23), hours: 8, quality: .good)
        night.tags = [ReadingTag(name: "Alcohol", colorHex: "#FF0000")]
        night.notes = "late dinner"
        night.importedMetrics = HRVSession.ImportedMetrics(rmssd: 45, rmssdRaw: 46, artifactPercent: 1, source: HRVSession.ImportedMetrics.eliteHRVSource)
        night.deviceProvenance = DeviceProvenance(
            deviceId: "Polar H10 A1B2C3D4", deviceModel: "Polar H10", firmwareVersion: "5.0.0",
            recordingMode: .streaming, appVersion: "1.0", osVersion: "26.0", capturedAt: night.startDate
        )
        night.dataSourceSummary = HRVSession.DataSourceSummary(
            selectedSource: "streaming", streamingBeats: 30_000, deviceBeats: nil, totalBeats: 30_000, beatDifferencePercent: nil, reconnectCount: 2
        )
        return night
    }

    private func snapshot() -> WorkoutAnalysisSnapshot {
        WorkoutAnalysisSnapshot(
            hrZoneSeconds: [60, 600, 700, 120, 20], slowestSplitIndex: 3, slowestSplitPaceSecPerKm: 312,
            movingTimeSec: 1_480, movingTimePercent: 98, powerHRRatio: 1.6,
            relativeEffortLabel: "Moderate", heroNarrative: "Steady tempo run."
        )
    }

    private func split(_ index: Int) -> Split {
        Split(index: index, distanceMeters: 1_000, durationSeconds: 290 + Double(index), averageHR: 150, averagePaceSecPerKm: 290 + Double(index), elevationGainMeters: 4)
    }

    /// A workout with every detail the record reads.
    private func detailedWorkout(_ sport: Sport, daysAgo: Int, splitCount: Int) -> HRVSession {
        let begin = start(daysAgo: daysAgo, hour: 7)
        var session = HRVSession(startDate: begin, tags: [ReadingTag(name: "Race", colorHex: "#00FF00")], sessionType: .workout)
        session.endDate = begin.addingTimeInterval(1_600)
        session.state = .complete
        session.notes = "felt strong"
        session.analysisResult = analysis(at: begin)
        let track = [CLLocation(latitude: 39.78171, longitude: -89.65012), CLLocation(latitude: 39.78271, longitude: -89.65112)]
        var meta = WorkoutMetadata(sport: sport, gpsPolyline: WorkoutAnalyzer.encodePolyline(track: track), distanceMeters: 5_000, splits: (1 ... splitCount).map { split($0) })
        meta.laps = [Lap(index: 1, startOffsetSec: 0, endOffsetSec: 600, distanceMeters: 2_000, averageHR: 148, maxHR: 160, averagePaceSecPerKm: 300)]
        meta.activeSeconds = 1_500
        meta.intensityFactor = 0.85
        meta.variabilityIndex = 1.04
        meta.partialDataReason = .strapDisconnected
        meta.analysisSnapshot = snapshot()
        meta.weatherSnapshot = WorkoutWeatherSnapshot(
            temperatureC: 24, apparentTemperatureC: 26, relativeHumidityPercent: 60, windKMH: 12, conditions: "Partly cloudy", observedAt: begin, backfilled: false
        )
        session.workoutMetadata = meta
        return session
    }

    private func row() -> HRVSession {
        let begin = start(daysAgo: 5, hour: 7)
        var session = HRVSession(startDate: begin, tags: [], sessionType: .workout)
        session.endDate = begin.addingTimeInterval(1_200)
        session.state = .complete
        var meta = WorkoutMetadata(sport: .row, distanceMeters: 4_000)
        meta.strokeCount = 560
        meta.averageSplitSecPer500m = 118
        meta.dragFactor = 120
        session.workoutMetadata = meta
        return session
    }

    private func makeFixture() throws -> Fixture {
        let archive = SessionArchive(directory: temporaryDirectory())
        let night = taggedNight()
        let partial = overnight(startingAt: start(daysAgo: 1, hour: 23), hours: 0.4, quality: .preSleep)
        let run = detailedWorkout(.run, daysAgo: 1, splitCount: 3)
        let walk = detailedWorkout(.walk, daysAgo: 4, splitCount: 40)
        for session in [night, partial, run, walk, row()] {
            _ = try archive.archive(session, skipSameNightMerge: true)
        }
        let registry = AppFactResolverFactory.build(archive: archive, settings: { UserSettings() }, services: FactServices(.current))
        return Fixture(registry: registry, night: night, partial: partial, run: run, walk: walk)
    }

    private func call(_ registry: FactResolverRegistry, _ tool: String, _ args: String) async -> FactValue {
        await CompactToolRouter(registry: registry).resolveTool(name: tool, argsJSON: args)
    }

    private func record(_ value: FactValue, file: StaticString = #filePath, line: UInt = #line) -> [String: FactValue] {
        guard case let .record(fields) = value else {
            XCTFail("expected a record, got \(value)", file: file, line: line)
            return [:]
        }
        return fields
    }

    private func items(_ value: FactValue?) -> [[String: FactValue]] {
        guard case let .list(list)? = value else { return [] }
        return list.compactMap { fields($0) }
    }

    private func fields(_ value: FactValue) -> [String: FactValue]? {
        if case let .record(fields) = value { return fields }
        return nil
    }

    private func flag(_ value: FactValue?) -> Bool? {
        if case let .boolean(flag)? = value { return flag }
        return nil
    }

    private func number(_ value: FactValue?) -> Double? {
        switch value {
        case let .double(number)?: return number
        case let .integer(number)?: return Double(number)
        default: return nil
        }
    }

    private func text(_ value: FactValue?) -> String? {
        if case let .string(text)? = value { return text }
        return nil
    }

    private func strings(_ value: FactValue?) -> [String] {
        guard case let .list(list)? = value else { return [] }
        return list.compactMap { text($0) }
    }

    // MARK: - Overnight record

    func testANightCarriesItsTagsNotesImportSourceAndStrap() async throws {
        let fixture = try makeFixture()
        let nightDay = day(fixture.night.startDate.addingTimeInterval(4 * 3600))
        let night = record(await call(fixture.registry, "get_session", #"{"which":"by_date","date":"\#(nightDay)"}"#))
        XCTAssertEqual(strings(night["tags"]), ["Alcohol"])
        XCTAssertEqual(text(night["notes"]), "late dinner")
        XCTAssertEqual(text(night["import_source"]), "Elite HRV")
        XCTAssertEqual(text(night["strap_model"]), "Polar H10")
        XCTAssertEqual(text(night["strap_firmware"]), "5.0.0")
        XCTAssertEqual(number(night["beat_count"]), 30_000)
        XCTAssertEqual(number(night["reconnect_count"]), 2)
    }

    // MARK: - session.recent

    func testRecentListsThePartialNightTheOtherListsLeaveOut() async throws {
        let fixture = try makeFixture()
        let nights = items(await call(fixture.registry, "lookup_fact", #"{"key":"session.recent(last_30d)"}"#))
        XCTAssertEqual(nights.count, 2, "both overnights, the partial one included: \(nights)")
        let partial = try XCTUnwrap(nights.first { text($0["id"]) == fixture.partial.id.uuidString }, "the partial night is listed")
        XCTAssertEqual(flag(partial["reliable_for_trends"]), false)
        XCTAssertEqual(text(partial["data_quality"]), "preSleep")
        XCTAssertEqual(number(partial["ordinal"]), 0, "the newest night is ordinal 0")
        let tagged = try XCTUnwrap(nights.first { text($0["id"]) == fixture.night.id.uuidString })
        XCTAssertEqual(strings(tagged["tags"]), ["Alcohol"])
        XCTAssertEqual(text(tagged["notes"]), "late dinner")
        let byDay = record(await fixture.registry.resolveAsync("session.by_date(\(text(tagged["day"]) ?? ""))"))
        XCTAssertEqual(text(byDay["id"]), fixture.night.id.uuidString, "an item's day reads that night by date")
    }

    // MARK: - Workout record

    func testAWorkoutRecordCarriesPaceIntensityWeatherAndItsNotes() async throws {
        let fixture = try makeFixture()
        let run = record(await call(fixture.registry, "get_workout", #"{"which":"by_date","date":"\#(day(fixture.run.startDate))"}"#))
        XCTAssertEqual(number(run["avg_pace_sec_per_km"]), 300, "1500 s of active time over 5 km")
        XCTAssertNotNil(text(run["avg_pace_display"]), "the router adds the pace in the user's units")
        XCTAssertEqual(number(run["intensity_factor"]), 0.85)
        XCTAssertEqual(number(run["variability_index"]), 1.04)
        XCTAssertEqual(text(run["partial_data_reason"]), "strapDisconnected")
        XCTAssertEqual(number(run["weather_temperature_c"]), 24)
        XCTAssertEqual(number(run["weather_humidity_percent"]), 60)
        XCTAssertEqual(number(run["weather_wind_kmh"]), 12)
        XCTAssertEqual(text(run["weather_conditions"]), "Partly cloudy")
        XCTAssertEqual(strings(run["tags"]), ["Race"])
        XCTAssertEqual(text(run["notes"]), "felt strong")
        XCTAssertEqual(number(run["start_latitude"]), 39.7817)
        XCTAssertEqual(number(run["start_longitude"]), -89.6501)
        XCTAssertEqual(number(run["hrv_rmssd_ms"]), 45)
    }

    func testAWorkoutRecordCarriesTheRestOfItsAnalysis() async throws {
        let fixture = try makeFixture()
        let run = record(await fixture.registry.resolveAsync("workout.by_date(\(day(fixture.run.startDate)))"))
        guard case let .list(zones)? = run["hr_zone_seconds"] else { return XCTFail("hr_zone_seconds missing: \(run)") }
        XCTAssertEqual(zones.compactMap { number($0) }, [60, 600, 700, 120, 20])
        XCTAssertEqual(number(run["slowest_split_index"]), 3)
        XCTAssertEqual(number(run["slowest_split_pace_sec_per_km"]), 312)
        XCTAssertEqual(number(run["moving_time_sec"]), 1_480)
        XCTAssertEqual(number(run["moving_percent"]), 98)
        XCTAssertEqual(number(run["power_hr_ratio"]), 1.6)
        XCTAssertEqual(text(run["relative_effort_label"]), "Moderate")
        XCTAssertEqual(text(run["hero_narrative"]), "Steady tempo run.")
    }

    func testAWorkoutRecordCarriesItsSplitsAndLaps() async throws {
        let fixture = try makeFixture()
        let run = record(await call(fixture.registry, "get_workout", #"{"which":"by_date","date":"\#(day(fixture.run.startDate))"}"#))
        let splits = items(run["splits"])
        XCTAssertEqual(splits.count, 3)
        XCTAssertEqual(number(run["split_count"]), 3)
        XCTAssertEqual(number(splits.first?["pace_sec_per_km"]), 291)
        XCTAssertEqual(number(splits.first?["mean_hr_bpm"]), 150)
        XCTAssertNotNil(text(splits.first?["pace_display"]), "each split's pace comes in the user's units too")
        let laps = items(run["laps"])
        XCTAssertEqual(number(laps.first?["max_hr_bpm"]), 160)
    }

    func testALongWorkoutsSplitsAreCappedWithTheirTotal() async throws {
        let fixture = try makeFixture()
        let walk = record(await fixture.registry.resolveAsync("workout.by_date(\(day(fixture.walk.startDate)))"))
        XCTAssertEqual(items(walk["splits"]).count, SessionNamespace.maxRecordSplits)
        XCTAssertEqual(number(walk["split_count"]), 40)
    }

    func testARowCarriesItsStrokesSplitAndDrag() async throws {
        let fixture = try makeFixture()
        let row = record(await fixture.registry.resolveAsync("workout.by_ordinal(2)"))
        XCTAssertEqual(text(row["sport"]), Sport.row.displayName)
        XCTAssertEqual(number(row["stroke_count"]), 560)
        XCTAssertEqual(number(row["avg_split_sec_per_500m"]), 118)
        XCTAssertEqual(number(row["drag_factor"]), 120)
    }

    // MARK: - A workout id on session.by_id

    func testAWorkoutIdNamesTheLookupForExactlyThatWorkout() async throws {
        let fixture = try makeFixture()
        let value = await call(fixture.registry, "get_session", #"{"which":"by_id","id":"\#(fixture.run.id.uuidString)"}"#)
        guard case let .missing(.invalidParameter, detail) = value else { return XCTFail("a workout id is not an overnight: \(value)") }
        XCTAssertTrue(detail?.contains("workout.by_id(\(fixture.run.id.uuidString))") == true, "it names the by-id workout lookup: \(detail ?? "nil")")
    }

    // MARK: - Every field is named

    private func description(of pattern: String, in registry: FactResolverRegistry) -> String {
        registry.namespaces.flatMap(\.entries).first { $0.keyPattern == pattern }?.entryDescription ?? ""
    }

    func testTheLookupsNameEveryFieldTheyReturn() async throws {
        let fixture = try makeFixture()
        let nightDay = day(fixture.night.startDate.addingTimeInterval(4 * 3600))
        let lookups: [(pattern: String, key: String)] = [
            ("walks.list($period)", "walks.list(last_30d)"), ("walks.hardest($period)", "walks.hardest(last_30d)"),
            ("session.recent($period)", "session.recent(last_30d)"), ("session.by_date($date)", "session.by_date(\(nightDay))"),
            ("session.by_id($id)", "session.by_id(\(fixture.night.id.uuidString))")
        ]
        for lookup in lookups {
            let text = description(of: lookup.pattern, in: fixture.registry)
            let value = await fixture.registry.resolveAsync(lookup.key)
            let fields = items(value).first ?? record(value)
            XCTAssertFalse(fields.isEmpty, "\(lookup.key) returned nothing")
            for field in fields.keys {
                XCTAssertTrue(text.contains(field), "\(lookup.pattern) returns \(field) but its description never names it")
            }
        }
        let run = record(await fixture.registry.resolveAsync("workout.by_date(\(day(fixture.run.startDate)))"))
        let workoutByDate = description(of: "workout.by_date($date)", in: fixture.registry)
        for field in run.keys {
            XCTAssertTrue(workoutByDate.contains(field), "workout.by_date returns \(field) but its description never names it")
        }
    }
}
