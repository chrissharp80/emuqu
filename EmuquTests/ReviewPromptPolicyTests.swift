@testable import Emuqu
import XCTest

/// Tests for `ReviewPromptPolicy` — when the dashboard may ask for an App
/// Store rating.
final class ReviewPromptPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ask(
        nights: Int = ReviewPromptPolicy.minimumScoredNights,
        hasScore: Bool = true,
        version: String = "1.0.2",
        lastVersion: String? = nil,
        lastDate: Date? = nil
    ) -> Bool {
        ReviewPromptPolicy.shouldRequest(
            baselineNights: nights, hasScore: hasScore, currentVersion: version,
            lastRequestedVersion: lastVersion, lastRequestedDate: lastDate, now: now
        )
    }

    func testAsksOnceEnoughScoredNightsAndAScore() {
        XCTAssertTrue(ask())
    }

    func testWaitsForEnoughScoredNights() {
        XCTAssertFalse(ask(nights: ReviewPromptPolicy.minimumScoredNights - 1))
    }

    func testNeedsAScoreOnScreen() {
        XCTAssertFalse(ask(hasScore: false))
    }

    func testAsksAtMostOncePerVersion() {
        XCTAssertFalse(ask(lastVersion: "1.0.2", lastDate: now.addingTimeInterval(-400 * 86_400)))
    }

    func testWaitsBetweenRequestsAcrossVersions() {
        let recent = now.addingTimeInterval(-Double(ReviewPromptPolicy.minimumDaysBetweenRequests - 1) * 86_400)
        XCTAssertFalse(ask(lastVersion: "1.0.1", lastDate: recent))
        let old = now.addingTimeInterval(-Double(ReviewPromptPolicy.minimumDaysBetweenRequests) * 86_400)
        XCTAssertTrue(ask(lastVersion: "1.0.1", lastDate: old))
    }
}
