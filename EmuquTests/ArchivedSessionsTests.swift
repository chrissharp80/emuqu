@testable import Emuqu
import XCTest

/// A bulk pass picks its sessions from the index and decodes each in full
/// only when it reaches it.
final class ArchivedSessionsTests: XCTestCase {
    private lazy var directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ArchivedSessionsTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: directory)

    override func tearDown() async throws {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            // swallow-ok: a test that archived nothing leaves no directory to remove.
        }
        try await super.tearDown()
    }

    private func archived(_ type: SessionType, daysAgo: Double) throws -> HRVSession {
        let id = UUID()
        let start = Date().addingTimeInterval(-daysAgo * 86400)
        let points = (0 ..< 120).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: 1000) }
        let session = HRVSession(
            id: id, startDate: start, endDate: start.addingTimeInterval(3600), state: .complete,
            sessionType: type, rrSeries: RRSeries(points: points, sessionId: id, startDate: start),
            analysisResult: nil, artifactFlags: nil
        )
        _ = try archive.archive(session, skipSameNightMerge: true)
        return session
    }

    func testDecodesTheFullSessionWithItsBeats() async throws {
        let night = try archived(.overnight, daysAgo: 1)
        let sessions = ArchivedSessions(archive: archive, caller: "test")

        let decoded = await sessions.session(at: 0)

        XCTAssertEqual(decoded?.id, night.id)
        XCTAssertEqual(decoded?.rrSeries?.points.count, 120)
    }

    func testFiltersOnTheIndexBeforeDecoding() throws {
        _ = try archived(.workout, daysAgo: 2)
        let night = try archived(.overnight, daysAgo: 1)

        let overnights = ArchivedSessions(archive: archive, caller: "test").filter { $0.sessionType == .overnight }

        XCTAssertEqual(overnights.entries.map(\.sessionId), [night.id])
    }

    /// The upper bound of a range runs to the end of its day.
    func testARangeIncludesTheWholeOfItsLastDay() throws {
        let recent = try archived(.overnight, daysAgo: 1)
        _ = try archived(.overnight, daysAgo: 10)
        let all = ArchivedSessions(archive: archive, caller: "test")

        let inRange = ReanalysisService.sessionsInRange(all, from: Date().addingTimeInterval(-3 * 86400), to: recent.startDate)

        XCTAssertEqual(inRange.entries.map(\.sessionId), [recent.id])
    }
}
