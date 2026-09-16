@testable import Emuqu
import XCTest

/// Tests for the wake-up that code waiting on the strap suspends on.
///
/// A waiter that is never resumed is a recording that never starts; one
/// resumed twice is a crash. Both are exercised here.
@MainActor
final class StrapSignalTests: XCTestCase {
    func testFireResumesAWaiterWithTrue() async {
        let signal = StrapSignal()
        let waiter = Task { await signal.wait(timeout: 30) }
        await Task.yield()
        signal.fire()

        let fired = await waiter.value
        XCTAssertTrue(fired)
    }

    func testFireResumesEveryWaiter() async {
        let signal = StrapSignal()
        let waiters = (0 ..< 3).map { _ in Task { await signal.wait(timeout: nil) } }
        await Task.yield()
        signal.fire()

        for waiter in waiters {
            let fired = await waiter.value
            XCTAssertTrue(fired)
        }
    }

    func testATimeoutResumesWithFalse() async {
        let signal = StrapSignal()

        let fired = await signal.wait(timeout: 0.05)
        XCTAssertFalse(fired)
    }

    /// Firing after the timeout already resumed the waiter must not resume it
    /// again — a checked continuation resumed twice traps.
    func testFiringAfterATimeoutIsHarmless() async {
        let signal = StrapSignal()
        let fired = await signal.wait(timeout: 0.01)
        signal.fire()

        XCTAssertFalse(fired)
    }

    func testCancellationResumesWithFalse() async {
        let signal = StrapSignal()
        let waiter = Task { await signal.wait(timeout: nil) }
        await Task.yield()
        waiter.cancel()

        let fired = await waiter.value
        XCTAssertFalse(fired)
    }

    func testAnAlreadyCancelledTaskDoesNotSuspend() async {
        let signal = StrapSignal()
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await signal.wait(timeout: nil)
        }

        let fired = await waiter.value
        XCTAssertFalse(fired)
    }

    /// A fire with nobody waiting is not remembered: waiters re-read state
    /// before they wait, so a latched fire would only cause a spurious wake.
    func testAFireWithNoWaitersIsNotLatched() async {
        let signal = StrapSignal()
        signal.fire()

        let fired = await signal.wait(timeout: 0.05)
        XCTAssertFalse(fired)
    }
}
