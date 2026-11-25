@testable import Emuqu
import XCTest

/// A tool answer built while session files could not be read says so: a
/// "no data" answer becomes `.unreadable`, so the assistant never tells the
/// user they recorded nothing, and a list or total carries the count left out.
final class SessionReadWatchTests: XCTestCase {
    func testNoDataBecomesUnreadableWhenAReadFailed() {
        let value = FactValue.missing(reason: .notRecorded, detail: "no overnight session matched")
        guard case .missing(reason: .unreadable, _) = value.accountingFor(unreadSessions: 1) else {
            return XCTFail("a failed read was reported as no data")
        }
    }

    func testAnAnswerCarriesHowManySessionsItLeftOut() {
        let value = FactValue.record(["workout_count": .integer(3)])
        guard case let .record(fields) = value.accountingFor(unreadSessions: 2) else { return XCTFail("not a record") }
        guard case .integer(2) = fields["unreadable_sessions"] else { return XCTFail("the count left out is missing") }
        guard case .integer(3) = fields["workout_count"] else { return XCTFail("the answer itself was lost") }
    }

    func testAListIsWrappedWithTheCount() {
        let value = FactValue.list([.integer(1)])
        guard case let .record(fields) = value.accountingFor(unreadSessions: 1),
              case .integer(1) = fields["unreadable_sessions"], case .list = fields["value"] else {
            return XCTFail("a partial list was not marked")
        }
    }

    func testNothingChangesWithoutAFailedRead() {
        guard case .missing(reason: .notRecorded, _) = FactValue.missing(reason: .notRecorded).accountingFor(unreadSessions: 0) else {
            return XCTFail("a real no-data answer was changed")
        }
    }

    /// The archive reports a file it could not read to the tool call
    /// resolving on this task.
    func testTheArchiveReportsAnUnreadableFileToTheCallResolving() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SessionReadWatchTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let archive = SessionArchive(directory: directory)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let night = HRVSession(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(8 * 3600),
            state: .complete, sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        _ = try archive.archive(night, skipSameNightMerge: true)
        try Data("not a session".utf8).write(to: directory.appendingPathComponent("\(night.id.uuidString).json"))

        let failures = SessionReadFailures()
        let read = SessionReadWatch.$failures.withValue(failures) { archive.retrieveLightweightOrLog(night.id) }

        XCTAssertNil(read)
        XCTAssertEqual(failures.count, 1)
    }
}
