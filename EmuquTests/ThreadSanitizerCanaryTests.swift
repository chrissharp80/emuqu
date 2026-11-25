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
    /// An integer that several threads write with no synchronization: the race.
    private final class UnsynchronizedCounter: @unchecked Sendable {
        var value = 0
    }

    /// Two threads of its own, not `DispatchQueue.concurrentPerform`. With work
    /// this small, `concurrentPerform` can run every iteration on the calling
    /// thread, and one thread writing alone is no race. Thread Sanitizer
    /// reports two writes from different threads with nothing ordering them,
    /// whether or not they overlap in time. Both threads start before the test
    /// thread waits on either, so nothing orders one thread's writes with the
    /// other's, and the race is there on every run.
    func testUnsynchronizedWritesRaceWhenTheCanaryIsRequested() {
        guard ProcessInfo.processInfo.environment["EMUQU_TSAN_CANARY"] == "1" else { return }
        let counter = UnsynchronizedCounter()
        let finished = DispatchSemaphore(value: 0)
        for _ in 0..<2 {
            Thread {
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
