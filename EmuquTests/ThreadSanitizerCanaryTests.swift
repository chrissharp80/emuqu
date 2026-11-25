import Synchronization
import XCTest

/// A deliberate data race that proves the Thread Sanitizer gate can see one.
///
/// `scripts/check_thread_sanitizer.sh` passes when its log holds no race
/// report, which is evidence only if a race would reach that log and fail the
/// run. Before the suite, the gate runs this test alone with
/// `TEST_RUNNER_EMUQU_TSAN_CANARY=1` and requires a `WARNING: ThreadSanitizer`
/// report and a failed run; without either, it fails instead of passing.
///
/// Without `EMUQU_TSAN_CANARY` (every other run, the suite run under TSan
/// included) the test returns at once, so it never races outside the gate's
/// own check.
final class ThreadSanitizerCanaryTests: XCTestCase {
    /// An integer two threads write with no synchronization: the race.
    private final class UnsynchronizedCounter: @unchecked Sendable {
        var value = 0
    }

    /// How many writer threads are running. Read and written with relaxed
    /// ordering only, which Thread Sanitizer does not count as ordering
    /// anything, so meeting here orders neither thread's writes.
    @available(iOS 18.0, *)
    private final class Arrivals: Sendable {
        let count = Atomic<Int>(0)
    }

    /// Both writers are alive and writing at the same time, on every run.
    ///
    /// A race Thread Sanitizer can see needs two writes from different threads
    /// with nothing ordering them. Started threads that do not overlap can be
    /// ordered by the runtime's own bookkeeping: on a busy runner the first
    /// thread can finish and exit before the second is started, and the lock
    /// Foundation takes on thread exit and again on thread start then orders
    /// the first thread's writes before the second's, which is no race. So each
    /// writer waits, on a relaxed atomic, until both are running, and only
    /// then writes; neither has exited when the other starts writing.
    func testUnsynchronizedWritesRaceWhenTheCanaryIsRequested() throws {
        guard ProcessInfo.processInfo.environment["EMUQU_TSAN_CANARY"] == "1" else { return }
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("The canary needs Synchronization.Atomic, iOS 18 and later.")
        }
        let counter = UnsynchronizedCounter()
        let arrivals = Arrivals()
        let finished = DispatchSemaphore(value: 0)
        for _ in 0..<2 {
            Thread {
                arrivals.count.add(1, ordering: .relaxed)
                while arrivals.count.load(ordering: .relaxed) < 2 {}
                for _ in 0..<10_000 { counter.value += 1 }
                finished.signal()
            }.start()
        }
        finished.wait()
        finished.wait()
        // Reached only if Thread Sanitizer did not end the host on the race.
        XCTFail("The unsynchronized writes ran to the end (count \(counter.value)); Thread Sanitizer did not stop them.")
    }
}
