@testable import Emuqu
import XCTest

/// The phone-side Watch transport rules that need no paired Watch: the
/// send-timeout circuit breaker, and which queued user-info transfer a new one
/// replaces.
final class WatchSendTransportTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func breaker(timeoutsAt offsets: [TimeInterval]) -> WatchSendTimeoutBreaker {
        var breaker = WatchSendTimeoutBreaker()
        for offset in offsets { breaker.noteTimeout(at: start.addingTimeInterval(offset)) }
        return breaker
    }

    // MARK: - Circuit breaker

    func testBreakerStaysClosedBelowTheThreshold() {
        let twice = breaker(timeoutsAt: [0, 1])
        XCTAssertFalse(twice.isOpen(at: start.addingTimeInterval(2)))
    }

    func testBreakerOpensAtTheThreshold() {
        let thrice = breaker(timeoutsAt: [0, 1, 2])
        XCTAssertTrue(thrice.isOpen(at: start.addingTimeInterval(3)))
    }

    /// The defect this pins: with no success signal to reset it, the breaker
    /// stayed open for the rest of a workout once three timeouts had
    /// happened, and live Watch updates stopped.
    func testBreakerClosesWhenItsCooldownRunsOut() {
        let thrice = breaker(timeoutsAt: [0, 1, 2])
        let afterCooldown = start.addingTimeInterval(2 + WatchSendTimeoutBreaker.cooldown)
        XCTAssertFalse(thrice.isOpen(at: afterCooldown))
    }

    /// Once it has opened, one more timeout after the cooldown opens it again
    /// at once rather than waiting for another three.
    func testOneTimeoutAfterTheCooldownReopensIt() {
        let reopenAt = 2 + WatchSendTimeoutBreaker.cooldown + 1
        let reopened = breaker(timeoutsAt: [0, 1, 2, reopenAt])
        XCTAssertTrue(reopened.isOpen(at: start.addingTimeInterval(reopenAt + 1)))
    }

    /// A timeout while it is already open does not push its cooldown back.
    func testTimeoutsWhileOpenDoNotExtendTheCooldown() {
        let held = breaker(timeoutsAt: [0, 1, 2, 10, 20])
        XCTAssertFalse(held.isOpen(at: start.addingTimeInterval(2 + WatchSendTimeoutBreaker.cooldown)))
    }

    // MARK: - Superseded user-info transfers

    /// Start and stop both carry the workout's state, so each replaces a
    /// queued one of either.
    @MainActor
    func testWorkoutStartAndStopSupersedeEachOther() {
        let startType = WatchConnectivityBridge.MessageType.startWorkout.rawValue
        let stopType = WatchConnectivityBridge.MessageType.stopWorkout.rawValue
        XCTAssertTrue(WatchConnectivityBridge.userInfoSupersedes(startType, queued: stopType))
        XCTAssertTrue(WatchConnectivityBridge.userInfoSupersedes(stopType, queued: startType))
        XCTAssertTrue(WatchConnectivityBridge.userInfoSupersedes(startType, queued: startType))
    }

    @MainActor
    func testStrapAndVoiceStatesSupersedeOnlyTheirOwnType() {
        let strapType = WatchConnectivityBridge.MessageType.strapState.rawValue
        let startType = WatchConnectivityBridge.MessageType.startWorkout.rawValue
        XCTAssertTrue(WatchConnectivityBridge.userInfoSupersedes(strapType, queued: strapType))
        XCTAssertTrue(WatchConnectivityBridge.userInfoSupersedes("voiceChatState", queued: "voiceChatState"))
        XCTAssertFalse(WatchConnectivityBridge.userInfoSupersedes(strapType, queued: startType))
        XCTAssertFalse(WatchConnectivityBridge.userInfoSupersedes(startType, queued: strapType))
        XCTAssertFalse(WatchConnectivityBridge.userInfoSupersedes("voiceChatState", queued: strapType))
    }

    /// A type this rule does not know, or a transfer with no type, is never
    /// cancelled: nothing says it carries a whole state.
    @MainActor
    func testUnknownOrMissingTypesAreNeverSuperseded() {
        XCTAssertFalse(WatchConnectivityBridge.userInfoSupersedes("someFutureType", queued: "someFutureType"))
        XCTAssertFalse(WatchConnectivityBridge.userInfoSupersedes(nil, queued: nil))
        XCTAssertFalse(WatchConnectivityBridge.userInfoSupersedes(nil, queued: "strapState"))
        XCTAssertFalse(WatchConnectivityBridge.userInfoSupersedes("strapState", queued: nil))
    }
}
