import Synchronization
import XCTest

/// A deliberate data race that proves the Thread Sanitizer gate can see one.
///
/// `scripts/check_thread_sanitizer.sh` passes when its log holds no race
/// report, which is evidence only if that same process could see a race. The
/// gate runs the whole suite with `TEST_RUNNER_EMUQU_TSAN_CANARY=1`, this test
/// races inside it, and the run counts only if this file's race is reported
/// in its log. A race does not end the host, so the test then passes.
///
/// Without `EMUQU_TSAN_CANARY` (every other test run) the test returns at
/// once, so it never races outside the gate.
final class ThreadSanitizerCanaryTests: XCTestCase {
    /// An integer two threads write with no synchronization: the race.
    private final class UnsynchronizedCounter: @unchecked Sendable {
        var value = 0
    }

    /// Whether the test host links the Thread Sanitizer runtime, looked up by
    /// its entry point (`RTLD_DEFAULT` is -2 on Darwin).
    private static var sanitizerRuntimeIsLoaded: Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil
    }

    /// How many writer threads are running. Read and written with relaxed
    /// ordering only, which Thread Sanitizer does not count as ordering
    /// anything, so meeting here orders neither thread's writes.
    @available(iOS 18.0, *)
    private final class Arrivals: Sendable {
        let count = Atomic<Int>(0)
    }

    /// Two writer threads, alive and writing at the same time: each waits on
    /// a relaxed atomic until both are running, so their writes overlap and
    /// nothing orders one thread's writes with the other's.
    func testUnsynchronizedWritesRaceWhenTheCanaryIsRequested() {
        guard ProcessInfo.processInfo.environment["EMUQU_TSAN_CANARY"] == "1" else { return }
        // A failure with no race report fails the gate, as a missed race does.
        guard #available(iOS 18.0, *) else {
            return XCTFail("The canary needs Synchronization.Atomic, iOS 18 and later.")
        }
        // A host built without the sanitizer cannot report anything; say so
        // rather than leave a missed race unexplained.
        let options = ProcessInfo.processInfo.environment["TSAN_OPTIONS"] ?? "unset"
        guard Self.sanitizerRuntimeIsLoaded else {
            return XCTFail("The Thread Sanitizer runtime is not loaded in the test host (TSAN_OPTIONS \(options)).")
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
        XCTAssertGreaterThan(counter.value, 0, "The writers ran (TSAN_OPTIONS \(options)).")
    }
}
