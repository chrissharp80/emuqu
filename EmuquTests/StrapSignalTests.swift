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
        let waiters = await startedWaiters(1, on: signal, timeout: 30)
        signal.fire()

        for waiter in waiters {
            let fired = await waiter.value
            XCTAssertTrue(fired)
        }
    }

    func testFireResumesEveryWaiter() async {
        let signal = StrapSignal()
        let waiters = await startedWaiters(3, on: signal, timeout: nil)
        signal.fire()

        for waiter in waiters {
            let fired = await waiter.value
            XCTAssertTrue(fired)
        }
    }

    /// Starts `count` waiters and returns once every one is parked in
    /// `wait`. A fire is not latched, so firing before a waiter registers
    /// would leave it waiting. Each waiter counts itself and then calls `wait`
    /// in the same main-actor turn (no suspension before it registers), so
    /// once all have counted, all are registered.
    private func startedWaiters(_ count: Int, on signal: StrapSignal, timeout: TimeInterval?) async -> [Task<Bool, Never>] {
        let arrived = ArrivalCount()
        let waiters = (0 ..< count).map { _ in
            Task { () -> Bool in
                arrived.value += 1
                return await signal.wait(timeout: timeout)
            }
        }
        for _ in 0 ..< 1_000 where arrived.value < count {
            await Task.yield()
        }
        XCTAssertEqual(arrived.value, count, "every waiter must have reached wait before the fire")
        return waiters
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

/// How many waiters have reached `StrapSignal.wait`; main-actor state, like
/// the signal itself.
@MainActor
private final class ArrivalCount {
    var value = 0
}
