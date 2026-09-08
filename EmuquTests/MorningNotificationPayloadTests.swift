@testable import Emuqu
import XCTest

/// Tests for the fixed-time daily fallback push.
///
/// iOS freezes a repeating `UNCalendarNotificationTrigger`'s content at
/// schedule time and replays it unchanged every morning, so a recovery score
/// baked into it is correct for at most one day and stale on every fire after
/// that. That has happened. The rule — this payload carries no number
/// — was written in a comment and asserted nowhere.
final class MorningNotificationPayloadTests: XCTestCase {
    /// The property the bug turned on: a repeating payload that names a score
    /// is wrong the next morning and every morning after.
    func testTheRepeatingFallbackPayloadCarriesNoNumber() {
        let (title, body) = MorningNotificationScheduler.buildPayload()
        for text in [title, body] {
            XCTAssertFalse(
                text.contains(where: \.isNumber),
                "the repeating push is replayed unchanged for weeks; a number in it goes stale: \(text)"
            )
        }
    }

    /// It still has to say something — an empty push is a worse bug than a
    /// stale one, and would be the obvious way to "fix" the rule above.
    func testTheRepeatingFallbackPayloadIsNotEmpty() {
        let (title, body) = MorningNotificationScheduler.buildPayload()
        XCTAssertFalse(title.trimmingCharacters(in: .whitespaces).isEmpty)
        XCTAssertFalse(body.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Lock-screen previews truncate. The body has to survive that.
    func testTheRepeatingFallbackBodyFitsALockScreenPreview() {
        let (_, body) = MorningNotificationScheduler.buildPayload()
        XCTAssertLessThanOrEqual(body.count, 120, "would truncate on the lock screen: \(body)")
    }
}
