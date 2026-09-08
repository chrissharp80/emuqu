@testable import Emuqu
import XCTest

final class AnalysisPerformanceTests: XCTestCase {

    /// True when the binary is running under Thread Sanitizer.
    ///
    /// TSan instruments every memory access and costs roughly 5–15× in wall
    /// clock. Any `XCTClockMetric` baseline is therefore guaranteed to fail
    /// under it — as this test did, and it was the *only* failure in a
    /// 1,444-test TSan run that reported zero data races. A timing test failing
    /// for timing reasons is noise that buries the signal the run exists to
    /// produce, so it is skipped instead.
    ///
    /// Detected via `dlsym` on the TSan runtime's own init symbol rather than
    /// an environment variable: `__tsan_init` is present if and only if the
    /// sanitizer is linked, whereas `TSAN_OPTIONS` is only set when someone
    /// chose to set it.
    private var isRunningUnderThreadSanitizer: Bool {
        // RTLD_DEFAULT is (void *)-2 on Darwin.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        return dlsym(rtldDefault, "__tsan_init") != nil
    }

    /// Deliberately not an `XCTSkipIf`.
    ///
    /// Under Thread Sanitizer the *timing* assertion is meaningless, but the
    /// computation itself still is not: a 30,000-sample DFA run over the whole
    /// analyzer is one of the widest code paths in the app and exactly the kind
    /// of work a race hides in. Skipping would have removed it from the
    /// sanitizer's view for the sake of a clock.
    ///
    /// So the body always runs and always asserts; only the `measure` wrapper
    /// is conditional. Instrumented runs contribute race coverage, ordinary
    /// runs contribute the performance baseline.
    func testDFAAnalyzerPerformanceOnOvernightSizedInput() {
        let rrValues = (0 ..< 30000).map { index in
            900.0 + Double((index % 21) - 10)
        }

        guard !isRunningUnderThreadSanitizer else {
            XCTAssertNotNil(
                DFAAnalyzer.compute(rrValues),
                "DFA must still compute under instrumentation — only the timing baseline is skipped"
            )
            return
        }

        measure(metrics: [XCTClockMetric()]) {
            XCTAssertNotNil(DFAAnalyzer.compute(rrValues))
        }
    }
}
