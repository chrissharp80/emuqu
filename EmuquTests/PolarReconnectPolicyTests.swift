@testable import Emuqu
import XCTest

/// Tests for the reconnect schedule — how long the app keeps trying to get a
/// dropped strap back.
///
/// This was a `private func` inside the reconnect loop at 0% coverage. It is
/// the schedule that decides whether a mid-night BLE dropout costs the night:
/// the H10 keeps recording to its own memory throughout, so the night survives
/// exactly as long as the phone keeps trying to reach it.
final class PolarReconnectPolicyTests: XCTestCase {
    // MARK: - The schedule

    /// Front-loaded on purpose: most dropouts recover in seconds, so the early
    /// attempts are cheap and fast.
    func testEarlyAttemptsRetryQuickly() {
        for attempt in 1 ... 5 {
            XCTAssertEqual(PolarReconnectPolicy.backoffSeconds(forAttempt: attempt), 2.0)
        }
    }

    func testTheScheduleStepsAtItsDocumentedBoundaries() {
        XCTAssertEqual(PolarReconnectPolicy.backoffSeconds(forAttempt: 5), 2.0)
        XCTAssertEqual(PolarReconnectPolicy.backoffSeconds(forAttempt: 6), 5.0)
        XCTAssertEqual(PolarReconnectPolicy.backoffSeconds(forAttempt: 15), 5.0)
        XCTAssertEqual(PolarReconnectPolicy.backoffSeconds(forAttempt: 16), 15.0)
        XCTAssertEqual(PolarReconnectPolicy.backoffSeconds(forAttempt: 30), 15.0)
        XCTAssertEqual(PolarReconnectPolicy.backoffSeconds(forAttempt: 31), 30.0)
    }

    /// The tail spaces out so the radio is not burning battery for the rest of
    /// the night on a strap that has been taken off.
    func testTheTailIsSpacedOut() {
        XCTAssertEqual(PolarReconnectPolicy.backoffSeconds(forAttempt: 60), 30.0)
        XCTAssertEqual(PolarReconnectPolicy.backoffSeconds(forAttempt: 500), 30.0)
    }

    /// Never faster as attempts go up — a schedule that got quicker under
    /// sustained failure would be a battery bug on a strap that is off-body.
    func testBackoffNeverDecreases() {
        var previous = 0.0
        for attempt in 1 ... PolarReconnectPolicy.maxAttempts {
            let wait = PolarReconnectPolicy.backoffSeconds(forAttempt: attempt)
            XCTAssertGreaterThanOrEqual(wait, previous, "attempt \(attempt) waits less than the one before")
            previous = wait
        }
    }

    /// Zero and negative attempt numbers can only come from a counter bug, and
    /// must not produce a zero wait that spins the radio.
    func testANonPositiveAttemptStillWaits() {
        XCTAssertGreaterThan(PolarReconnectPolicy.backoffSeconds(forAttempt: 0), 0)
        XCTAssertGreaterThan(PolarReconnectPolicy.backoffSeconds(forAttempt: -1), 0)
    }

    // MARK: - Giving up

    func testItKeepsTryingUpToTheAttemptLimit() {
        XCTAssertFalse(PolarReconnectPolicy.shouldGiveUp(afterAttempt: 1))
        XCTAssertFalse(PolarReconnectPolicy.shouldGiveUp(afterAttempt: PolarReconnectPolicy.maxAttempts))
        XCTAssertTrue(PolarReconnectPolicy.shouldGiveUp(afterAttempt: PolarReconnectPolicy.maxAttempts + 1))
    }

    // MARK: - The number that actually matters

    /// The property a user would care about: how long the strap can be out of
    /// range and still have its night recovered. Stated explicitly so that
    /// shortening any tier shows up here rather than passing unnoticed.
    ///
    /// 5×2s + 10×5s + 15×15s + 30×30s = 1,185s ≈ 19.75 minutes.
    func testTheTotalReconnectWindowIsAboutTwentyMinutes() {
        XCTAssertEqual(PolarReconnectPolicy.totalWindowSeconds, 1_185, accuracy: 0.001)
        XCTAssertEqual(PolarReconnectPolicy.totalWindowSeconds / 60, 19.75, accuracy: 0.01)
    }

    /// A floor rather than an exact figure, so re-tuning the tiers is allowed
    /// but quietly collapsing the window is not. Ten minutes is roughly the
    /// longest a strap sits out of range during a normal night (bathroom trip,
    /// phone left in another room) and still gets recovered.
    func testTheWindowCannotCollapseBelowTenMinutes() {
        XCTAssertGreaterThan(
            PolarReconnectPolicy.totalWindowSeconds, 600,
            "a shorter window turns an ordinary out-of-range stretch into a lost night"
        )
    }
}
