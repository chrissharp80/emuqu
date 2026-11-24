@testable import Emuqu
import XCTest

/// Never resumes and ignores cancellation: a stale link or a stalled search.
@Sendable private func neverAnswers() async -> Int {
    await withUnsafeContinuation { (_: UnsafeContinuation<Int, Never>) in }
}

/// The one deadline every bounded call goes through (`Deadline.race`) and
/// its nil-returning form (`runWithTimeout`): the caller resumes at the
/// result, at the deadline, or at once on its own cancellation, even when the
/// call never answers; and the call's own error is not mistaken for a
/// timeout.
final class DeadlineTests: XCTestCase {
    private struct Planted: Error, Equatable {}
    private struct TimedOut: Error {}

    func testTheRaceReturnsTheCallsValue() async throws {
        let value = try await Deadline.race(seconds: 5, timeout: TimedOut()) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testTheRaceThrowsTheCallsOwnErrorNotTheTimeout() async {
        do {
            _ = try await Deadline.race(seconds: 5, timeout: TimedOut()) { () async throws -> Int in throw Planted() }
            XCTFail("a throwing call returned")
        } catch {
            XCTAssertEqual(error as? Planted, Planted())
        }
    }

    /// The caller's cancellation resumes it at once, long before the
    /// deadline, though the call never answers.
    func testACancelledCallerResumesAtOnce() async throws {
        let started = Date()
        let task = Task { try await Deadline.race(seconds: 60, timeout: TimedOut(), operation: neverAnswers) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled race returned a value")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testRunWithTimeoutGivesTheValueOrNil() async {
        let value = await runWithTimeout(seconds: 5) { 7 }
        XCTAssertEqual(value, 7)
        let failed = await runWithTimeout(seconds: 5) { () async throws -> Int in throw Planted() }
        XCTAssertNil(failed)
        let late = await runWithTimeout(seconds: 0.2, operation: neverAnswers)
        XCTAssertNil(late)
    }

    /// `runWithTimeout` no longer holds a cancelled caller until the
    /// deadline.
    func testRunWithTimeoutReturnsAtOnceWhenTheCallerIsCancelled() async throws {
        let started = Date()
        let task = Task { await runWithTimeout(seconds: 60, operation: neverAnswers) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let value = await task.value
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
