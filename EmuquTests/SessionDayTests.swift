@testable import Emuqu
import XCTest

/// Every screen puts a reading on the same day (`SessionDay`).
final class SessionDayTests: XCTestCase {
    private let calendar = Calendar.current

    private func session(_ type: SessionType, start: Date, hours: Double, sleepEndMs: Int64? = nil) -> HRVSession {
        var session = HRVSession(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(hours * 3600), state: .complete,
            sessionType: type, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        session.sleepEndMs = sleepEndMs
        return session
    }

    private var lateEvening: Date {
        calendar.startOfDay(for: Date()).addingTimeInterval(-2 * 86400 + 23 * 3600)
    }

    /// A workout that crosses midnight belongs to the day it started.
    func testAReadingThatCrossesMidnightBelongsToTheDayItStarted() {
        let workout = session(.workout, start: lateEvening, hours: 2)
        XCTAssertTrue(calendar.isDate(SessionDay.date(of: workout), inSameDayAs: lateEvening))
    }

    /// An overnight belongs to the morning its sleep ended, even when the
    /// recording ran on into the next day.
    func testAnOvernightBelongsToTheMorningSleepEnded() {
        let night = session(.overnight, start: lateEvening, hours: 30, sleepEndMs: 8 * 3_600_000)
        let wake = lateEvening.addingTimeInterval(8 * 3600)
        XCTAssertEqual(SessionDay.date(of: night), wake)
    }

    func testAnOvernightWithoutASleepEndBelongsToTheDayTheRecordingEnded() {
        let night = session(.overnight, start: lateEvening, hours: 8)
        XCTAssertEqual(SessionDay.date(of: night), night.endDate)
    }

    /// The archive index and the session it mirrors agree.
    func testTheIndexAndTheSessionAgree() throws {
        for item in [session(.workout, start: lateEvening, hours: 2), session(.overnight, start: lateEvening, hours: 9, sleepEndMs: 7 * 3_600_000)] {
            let entry = SessionArchiveEntry.make(from: item, hash: "", filePath: "x.json")
            XCTAssertEqual(SessionDay.date(of: entry), SessionDay.date(of: item), "\(item.sessionType)")
        }
    }
}
