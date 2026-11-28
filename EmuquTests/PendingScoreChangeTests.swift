@testable import Emuqu
import XCTest

/// The score-changed banner belongs to one overnight: a screen that shows no
/// overnight, or another one, shows no notice.
final class PendingScoreChangeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PendingScoreChange.clear()
    }

    override func tearDown() {
        PendingScoreChange.clear()
        super.tearDown()
    }

    private func entry(for id: UUID, at time: Date = Date()) -> PendingScoreChange.Entry {
        .init(sessionId: id, priorScore: 8.8, newScore: 5.5, reason: "sleep", timestamp: time)
    }

    func testAScreenWithNoOvernightShowsNoNotice() {
        let id = UUID()
        PendingScoreChange.write(entry(for: id))
        XCTAssertNil(PendingScoreChange.shown(forSession: nil))
        XCTAssertFalse(PendingScoreChange.applies(entry(for: id), toShownSession: nil))
    }

    func testTheNoticeShowsOnlyForTheOvernightItNames() {
        let id = UUID()
        PendingScoreChange.write(entry(for: id))
        XCTAssertEqual(PendingScoreChange.shown(forSession: id)?.sessionId, id)
        XCTAssertTrue(PendingScoreChange.applies(entry(for: id), toShownSession: id))
        XCTAssertFalse(PendingScoreChange.applies(entry(for: id), toShownSession: UUID()))
    }
}
