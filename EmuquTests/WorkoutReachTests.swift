import CoreLocation
@testable import Emuqu
import XCTest

/// "My run on March 3" on a day that also had an evening walk, "the second
/// workout that day", one workout by its id, and a hill compared with a run
/// further back than the newest few: each reaches the workout asked about.
@MainActor
final class WorkoutReachTests: XCTestCase {
    private let spot = CLLocationCoordinate2D(latitude: 39.781, longitude: -89.652)
    private var run = HRVSession(startDate: Date(), tags: [], sessionType: .workout)
    private var walk = HRVSession(startDate: Date(), tags: [], sessionType: .workout)
    private var olderRun = HRVSession(startDate: Date(), tags: [], sessionType: .workout)

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkoutReachTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: a test that archived nothing leaves no directory to remove.
            }
        }
        return directory
    }

    private func day(_ daysAgo: Int, hour: Int) -> Date {
        let base = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
    }

    private func iso(_ date: Date) -> String {
        FactLocalDay.formatter().string(from: date)
    }

    /// A ten-minute workout heading north through `spot` at minute five, with
    /// a per-second heart rate so its timeline has buckets.
    private func workout(_ sport: Sport, start: Date, feeling: Int, heartRate: Int) -> HRVSession {
        let fixes: [CLLocation] = (0 ... 10).map { minute in
            let coordinate = CLLocationCoordinate2D(latitude: spot.latitude + (Double(minute) - 5) * 0.0008, longitude: spot.longitude)
            return CLLocation(coordinate: coordinate, altitude: 150, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: start.addingTimeInterval(Double(minute) * 60))
        }
        var session = HRVSession(startDate: start, tags: [], sessionType: .workout)
        session.endDate = start.addingTimeInterval(600)
        session.state = .complete
        var metadata = WorkoutMetadata(sport: sport)
        metadata.gpsPolyline = WorkoutAnalyzer.encodePolyline(track: fixes)
        metadata.gpsFixTimes = WorkoutAnalyzer.encodeFixTimes(track: fixes)
        metadata.samples = samples(heartRate: heartRate)
        metadata.workoutFeeling = feeling
        metadata.workoutFeelingNote = "\(sport.rawValue) note"
        session.workoutMetadata = metadata
        return session
    }

    private func samples(heartRate: Int) -> [WorkoutSample] {
        (0 ... 600).map {
            WorkoutSample(
                offsetSec: $0, heartRate: heartRate, distanceMeters: nil, paceSecPerKm: nil,
                cadenceStepsPerMin: nil, altitudeMeters: 150, alpha1: nil, mets: nil, powerWatts: nil
            )
        }
    }

    /// A morning run and an evening walk on one day, and a run 40 days back.
    private func makeRouter() throws -> CompactToolRouter {
        run = workout(.run, start: day(10, hour: 7), feeling: 4, heartRate: 150)
        walk = workout(.walk, start: day(10, hour: 18), feeling: 2, heartRate: 100)
        olderRun = workout(.run, start: day(40, hour: 7), feeling: 5, heartRate: 140)
        let archive = SessionArchive(directory: temporaryDirectory())
        for session in [run, walk, olderRun] {
            _ = try archive.archive(session, skipSameNightMerge: true)
        }
        let registry = AppFactResolverFactory.build(archive: archive, settings: { UserSettings() }, services: FactServices(.current))
        return CompactToolRouter(registry: registry)
    }

    private func record(_ value: FactValue, file: StaticString = #filePath, line: UInt = #line) -> [String: FactValue] {
        guard case let .record(fields) = value else {
            XCTFail("expected a record, got \(value)", file: file, line: line)
            return [:]
        }
        return fields
    }

    private func string(_ value: FactValue?) -> String? {
        if case let .string(text) = value { return text }
        return nil
    }

    private func integer(_ value: FactValue?) -> Int? {
        if case let .integer(number) = value { return number }
        return nil
    }

    // MARK: - Same-day workouts

    func testASportPicksTheRunOnADayThatAlsoHadAWalk() async throws {
        let router = try makeRouter()
        let picked = record(await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"by_date","date":"\#(iso(run.startDate))","sport":"run"}"#))
        XCTAssertEqual(string(picked["sport"]), "Run")
        XCTAssertEqual(string(picked["id"]), run.id.uuidString)
        XCTAssertEqual(integer(picked["workouts_that_day"]), 2)
        XCTAssertEqual(integer(picked["position_that_day"]), 1)
        guard case let .list(others) = picked["other_workout_ids_that_day"] else { return XCTFail("no other ids: \(picked)") }
        XCTAssertEqual(others.compactMap(string), [walk.id.uuidString])
    }

    func testADateAloneStillReadsTheLatestWorkoutThatDay() async throws {
        let router = try makeRouter()
        let latest = record(await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"by_date","date":"\#(iso(run.startDate))"}"#))
        XCTAssertEqual(string(latest["id"]), walk.id.uuidString)
        XCTAssertEqual(integer(latest["position_that_day"]), 2)
    }

    func testAPositionReadsTheFirstWorkoutThatDay() async throws {
        let router = try makeRouter()
        let first = record(await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"by_date","date":"\#(iso(run.startDate))","position":"1"}"#))
        XCTAssertEqual(string(first["id"]), run.id.uuidString)
    }

    func testEveryDatedVariantTakesTheSport() async throws {
        let router = try makeRouter()
        let feeling = await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"feeling","date":"\#(iso(run.startDate))","sport":"running"}"#)
        XCTAssertEqual(integer(feeling), 4, "the run's feeling, not the walk's")
        let deepDive = record(await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"deep_dive","date":"\#(iso(run.startDate))","sport":"run"}"#))
        XCTAssertEqual(string(deepDive["session_id"]), run.id.uuidString)
        XCTAssertEqual(integer(deepDive["workouts_that_day"]), 2)
    }

    func testASportNotDoneThatDayNamesTheWorkoutsThatWere() async throws {
        let router = try makeRouter()
        let value = await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"by_date","date":"\#(iso(run.startDate))","sport":"bike"}"#)
        guard case let .missing(reason, detail) = value else { return XCTFail("a ride was found on a day with none: \(value)") }
        XCTAssertEqual(reason, .notRecorded)
        XCTAssertTrue(detail?.contains(walk.id.uuidString) == true, detail ?? "nil")
        let unknown = await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"by_date","date":"\#(iso(run.startDate))","sport":"juggling"}"#)
        guard case let .missing(unknownReason, _) = unknown else { return XCTFail("an unknown sport answered: \(unknown)") }
        XCTAssertEqual(unknownReason, .invalidParameter)
    }

    // MARK: - By id

    func testAnIdReadsThatWorkoutThroughEveryVariant() async throws {
        let router = try makeRouter()
        let byID = record(await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"by_id","id":"\#(run.id.uuidString)"}"#))
        XCTAssertEqual(string(byID["sport"]), "Run")
        let timeline = record(await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"timeline","id":"\#(walk.id.uuidString)"}"#))
        XCTAssertEqual(string(timeline["id"]), walk.id.uuidString)
        XCTAssertEqual(string(timeline["sport"]), "Walk")
        guard case let .list(buckets) = timeline["buckets"], case let .record(bucket)? = buckets.first else { return XCTFail("no buckets: \(timeline)") }
        XCTAssertEqual(integer(bucket["hr"]), 100, "the walk's heart rate, not the run's")
        let note = await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"feeling_note","id":"\#(olderRun.id.uuidString)"}"#)
        XCTAssertEqual(string(note), "run note")
        let feeling = await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"feeling","id":"\#(olderRun.id.uuidString)"}"#)
        XCTAssertEqual(integer(feeling), 5)
    }

    func testAnUnknownIdIsNotAWorkout() async throws {
        let router = try makeRouter()
        let value = await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"by_id","id":"\#(UUID().uuidString)"}"#)
        guard case let .missing(reason, _) = value else { return XCTFail("a workout was made up: \(value)") }
        XCTAssertEqual(reason, .notRecorded)
    }

    // MARK: - Period lists with a sport

    func testListWorkoutsKeepsOneSport() async throws {
        let router = try makeRouter()
        guard case let .list(items) = await router.resolveTool(name: "list_workouts", argsJSON: #"{"period":"last_90d","sport":"run"}"#) else {
            return XCTFail("no list")
        }
        XCTAssertEqual(Set(items.map { string(record($0)["id"]) }), [run.id.uuidString, olderRun.id.uuidString])
        let count = await router.resolveTool(name: "list_workouts", argsJSON: #"{"which":"count","period":"last_90d","sport":"walk"}"#)
        XCTAssertEqual(integer(count), 1)
    }

    // MARK: - A hill further back

    func testADateBoundComparesTheHillWithThatDaysRunOnly() async throws {
        let router = try makeRouter()
        let point = "\(spot.latitude),\(spot.longitude)"
        let all = await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"segment_compare","point":"\#(point)"}"#)
        guard case let .list(everyMatch) = all else { return XCTFail("no matches: \(all)") }
        XCTAssertEqual(everyMatch.count, 3)
        let bounded = await router.resolveTool(name: "get_workout", argsJSON: #"{"which":"segment_compare","point":"\#(point)","date":"\#(iso(olderRun.startDate))"}"#)
        guard case let .list(matches) = bounded else { return XCTFail("no bounded match: \(bounded)") }
        XCTAssertEqual(matches.map { string(record($0)["id"]) }, [olderRun.id.uuidString])
    }

    func testAPeriodBoundIsParsedAndARadiusStillIs() throws {
        let query = try SegmentQuery.parseSegmentQuery("39.781,-89.652,30,last_90d")
        XCTAssertEqual(query.radius, 30)
        XCTAssertNotNil(query.bound)
        XCTAssertThrowsError(try SegmentQuery.parseSegmentQuery("39.781,-89.652,30,someday"))
    }

    // MARK: - Fields projection

    func testFieldsKeepOnlyWhatWasAskedPlusIdentity() {
        let item = FactValue.record(["date": .string("2026-03-03"), "id": .string("A"), "sport": .string("Run"), "trimp": .double(80)])
        let kept = FactProjection.keep(fields: FactProjection.fieldNames(from: " trimp , "), in: .list([item, item]))
        guard case let .list(items) = kept else { return XCTFail("not a list: \(kept)") }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(record(items[0]).keys), ["date", "id", "trimp"])
        XCTAssertEqual(Set(record(FactProjection.keep(fields: [], in: item)).keys), ["date", "id", "sport", "trimp"], "no fields keeps the whole record")
    }

    func testListWorkoutsProjectsEachItem() async throws {
        let router = try makeRouter()
        guard case let .list(items) = await router.resolveTool(name: "list_workouts", argsJSON: #"{"period":"last_90d","fields":"sport"}"#) else {
            return XCTFail("no list")
        }
        XCTAssertEqual(items.count, 3)
        for item in items {
            XCTAssertEqual(Set(record(item).keys), ["date", "id", "sport"])
        }
    }
}
