@testable import Emuqu
import XCTest

/// `get_session` is described to the model as an overnight lookup, and it
/// must resolve as one.
///
/// It used to search workouts only: "How was my session last night?" came
/// back as the afternoon run, a night that existed came back "not recorded",
/// and an id lookup returned a night dressed in a workout's fields with no
/// HRV in it. The archive here holds what made that visible — overnights
/// that start, end and are filed on the same local day as a run.
@MainActor
final class GetSessionOvernightTests: XCTestCase {
    private struct Fixture {
        let registry: FactResolverRegistry
        let morningNight: HRVSession
        let eveningNight: HRVSession
        let partial: HRVSession
        let run: HRVSession
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GetSessionOvernightTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: a test that archived nothing leaves no directory to remove.
            }
        }
        return directory
    }

    private func makeArchive(includeOvernights: Bool = true) throws -> Fixture {
        let archive = SessionArchive(directory: temporaryDirectory())
        // Filed under October 5th: the night that ends that morning.
        let morningNight = session(.overnight, start: (5, 0, 5), hours: 6, quality: .good)
        // Starts on the 5th too, but its midpoint is on the 6th.
        let eveningNight = session(.overnight, start: (5, 22, 40), hours: 8, quality: .good)
        // A partial recording that started later than the evening night, on its day.
        let partial = session(.overnight, start: (6, 21, 0), hours: 0.4, quality: .preSleep)
        var run = session(.workout, start: (5, 17, 30), hours: 0.75, quality: nil)
        run.workoutMetadata = WorkoutMetadata(sport: .run)
        let stored = includeOvernights ? [morningNight, eveningNight, partial, run] : [run]
        for item in stored {
            _ = try archive.archive(item, skipSameNightMerge: true)
        }
        let registry = AppFactResolverFactory.build(archive: archive, settings: { UserSettings() })
        return Fixture(registry: registry, morningNight: morningNight, eveningNight: eveningNight, partial: partial, run: run)
    }

    private func session(_ type: SessionType, start: (day: Int, hour: Int, minute: Int), hours: Double, quality: HRVDataQuality?) -> HRVSession {
        let components = DateComponents(year: 2026, month: 10, day: start.day, hour: start.hour, minute: start.minute)
        let startDate = Calendar.current.date(from: components) ?? Date()
        var session = HRVSession(startDate: startDate, tags: [], sessionType: type)
        session.endDate = startDate.addingTimeInterval(hours * 3600)
        session.state = .complete
        session.hrvDataQuality = quality
        if type == .overnight { session.recoveryScore = 7 }
        return session
    }

    private func getSession(_ registry: FactResolverRegistry, _ args: String) async -> FactValue {
        await CompactToolRouter(registry: registry).resolveTool(name: "get_session", argsJSON: args)
    }

    private func fields(_ value: FactValue, file: StaticString = #filePath, line: UInt = #line) -> [String: FactValue] {
        guard case let .record(fields) = value else {
            XCTFail("expected an overnight record, got \(value)", file: file, line: line)
            return [:]
        }
        return fields
    }

    private func id(_ value: FactValue) -> String? {
        guard case let .string(id) = fields(value)["id"] else { return nil }
        return id
    }

    func testLatestIsTheHeadlineNightNotTheRun() async throws {
        let archive = try makeArchive()
        let latest = await getSession(archive.registry, "{}")
        XCTAssertEqual(id(latest), archive.eveningNight.id.uuidString, "the newest reliable overnight, not a later partial or the run")
        let record = fields(latest)
        guard case .string("overnight") = record["session_type"] else { return XCTFail("session_type must say overnight") }
        for nested in ["hrv", "recovery", "sleep", "vitals"] {
            XCTAssertNotNil(record[nested], "the overnight record carries \(nested)")
        }
        XCTAssertNil(record["sport"], "no workout-shaped fields on an overnight")
        guard case .integer(2) = record["overnights_that_day"] else { return XCTFail("the partial shares the evening night's day") }
    }

    func testByDateUsesTheMidpointDayAndNeverReturnsTheRun() async throws {
        let archive = try makeArchive()
        let fifth = await getSession(archive.registry, #"{"which":"by_date","date":"2026-10-05"}"#)
        XCTAssertEqual(id(fifth), archive.morningNight.id.uuidString)
        let sixth = await getSession(archive.registry, #"{"which":"by_date","date":"2026-10-06"}"#)
        XCTAssertEqual(id(sixth), archive.eveningNight.id.uuidString, "the main recording leads its day, ahead of the partial")
        let byRecovery = await archive.registry.resolveAsync("recovery.score.by_date(2026-10-05)")
        guard case let .record(scoreFields) = byRecovery, case let .date(scoredNight) = scoreFields["date"] else {
            return XCTFail("recovery.score.by_date should resolve; got \(byRecovery)")
        }
        XCTAssertEqual(scoredNight, archive.morningNight.startDate, "get_session and the by_date overnight facts file a night under the same day")
    }

    func testOrdinalsWalkOvernightsOnly() async throws {
        let archive = try makeArchive()
        let expected = [archive.eveningNight, archive.partial, archive.morningNight].map(\.id.uuidString)
        for (n, want) in expected.enumerated() {
            let value = await getSession(archive.registry, #"{"which":"by_ordinal","n":"\#(n)"}"#)
            XCTAssertEqual(id(value), want, "ordinal \(n)")
        }
        let past = await getSession(archive.registry, #"{"which":"by_ordinal","n":"3"}"#)
        guard case .missing(.notRecorded, _) = past else { return XCTFail("only three overnights exist, got \(past)") }
    }

    func testIdLookupChecksTheSessionType() async throws {
        let archive = try makeArchive()
        let night = await getSession(archive.registry, #"{"which":"by_id","id":"\#(archive.morningNight.id.uuidString)"}"#)
        XCTAssertEqual(id(night), archive.morningNight.id.uuidString)
        let run = await getSession(archive.registry, #"{"which":"by_id","id":"\#(archive.run.id.uuidString)"}"#)
        guard case let .missing(.invalidParameter, detail) = run else { return XCTFail("a workout id must be rejected, got \(run)") }
        XCTAssertTrue(detail?.contains("get_workout") == true, "the rejection names the tool that covers workouts: \(detail ?? "nil")")
        let tail = await archive.registry.resolveAsync("session.by_id(\(archive.morningNight.id.uuidString)).session_type")
        guard case .string("overnight") = tail else { return XCTFail("tail tokens reach the record's fields, got \(tail)") }
    }

    func testAWorkoutOnlyArchiveHasNoSession() async throws {
        let archive = try makeArchive(includeOvernights: false)
        let latest = await getSession(archive.registry, "{}")
        guard case .missing(.notRecorded, _) = latest else { return XCTFail("a run is not an overnight session, got \(latest)") }
    }

    /// The one compact spec and its resolver must say the same thing.
    func testTheToolDescriptionSaysOvernight() throws {
        let spec = try XCTUnwrap(CompactToolRouter.readTools().first { $0.name == "get_session" })
        XCTAssertTrue(spec.description.contains("overnight"))
        XCTAssertTrue(spec.description.contains("get_workout"), "it points workouts at the tool that has them")
    }
}
