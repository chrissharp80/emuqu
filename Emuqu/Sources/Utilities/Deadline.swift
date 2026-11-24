import Foundation
import os

/// A hard wall clock for async work: the one deadline every bounded call in
/// the app goes through (strap calls, geocoding, workout finalization,
/// CloudKit deletes). `withThrowingTaskGroup` cannot provide one: a group
/// waits for every child, even after the timeout child throws and
/// `cancelAll()` runs, so a call whose continuation never fires (a stale BLE
/// link, a stalled tile search) still hangs the caller. Here the call runs in
/// its own task and the caller resumes at whichever comes first: the result,
/// the deadline, or the caller's own cancellation (the user's Cancel). The
/// call's error is thrown as it is, the deadline throws `timeout`, and the
/// caller's cancellation throws `CancellationError`. At the deadline or on
/// cancellation the call's task is cancelled, and its result, if one still
/// arrives, is ignored. The call itself stops at its next cancellation
/// check; the caller does not wait for that.
enum Deadline {
    static func race<T: Sendable>(
        seconds: TimeInterval,
        timeout: Error,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = DeadlineRace<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                race.begin(ResumeOnce(continuation), seconds: seconds, timeout: timeout, operation: operation)
            }
        } onCancel: {
            race.cancel()
        }
    }
}

/// What `runWithTimeout` reports when the deadline passes.
struct DeadlineExpired: Error, LocalizedError {
    let seconds: TimeInterval
    var errorDescription: String? { "no result within \(seconds) s" }
}

/// The value `operation` returns within `seconds`, or nil: at the deadline,
/// when the operation throws (the reason is logged), or at once when the
/// caller is cancelled. `Deadline.race` underneath, so the caller never
/// waits past the deadline or past its own cancellation. For a caller that
/// only needs a value or nothing; one that must tell a timeout from a
/// failure or a cancellation calls `Deadline.race`.
func runWithTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @Sendable @escaping () async throws -> T
) async -> T? {
    do {
        return try await Deadline.race(seconds: seconds, timeout: DeadlineExpired(seconds: seconds), operation: operation)
    } catch {
        debugLog("[runWithTimeout] no result: \(error.localizedDescription)")
        return nil
    }
}

/// Resumes a continuation once, with whichever result arrives first; later
/// results are dropped. The CloudKit progress watchdog races through it.
final class FirstResultGate<T: Sendable>: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<T?, Never>?>

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    /// True once a result has been delivered.
    var isResolved: Bool {
        continuation.withLock { $0 == nil }
    }

    func resume(_ value: T?) {
        let pending = continuation.withLock { slot -> CheckedContinuation<T?, Never>? in
            defer { slot = nil }
            return slot
        }
        pending?.resume(returning: value)
    }
}

/// One race's moving parts, behind a lock: the caller's continuation, the
/// call's task, and whether the caller was cancelled before the race began.
private final class DeadlineRace<T: Sendable>: Sendable {
    private struct Parts: Sendable {
        var finish: ResumeOnce<T>?
        var tasks: [Task<Void, Never>] = []
        var cancelled = false
    }

    private let parts = OSAllocatedUnfairLock(initialState: Parts())

    func begin(
        _ finish: ResumeOnce<T>,
        seconds: TimeInterval,
        timeout: Error,
        operation: @escaping @Sendable () async throws -> T
    ) {
        let alreadyCancelled = parts.withLock { (state: inout Parts) -> Bool in
            state.finish = finish
            return state.cancelled
        }
        guard !alreadyCancelled else {
            finish(.failure(CancellationError()))
            return
        }
        let clock = Task { await self.expire(after: seconds, with: timeout) }
        let call = Task { await Self.run(operation, finish: finish, clock: clock) }
        let cancelledMeanwhile = parts.withLock { (state: inout Parts) -> Bool in
            state.tasks = [clock, call]
            return state.cancelled
        }
        if cancelledMeanwhile { cancel() }
    }

    /// The caller was cancelled: it resumes now, and the call and its clock
    /// are told to stop.
    func cancel() {
        let (finish, tasks) = parts.withLock { (state: inout Parts) -> (ResumeOnce<T>?, [Task<Void, Never>]) in
            state.cancelled = true
            return (state.finish, state.tasks)
        }
        finish?(.failure(CancellationError()))
        tasks.forEach { $0.cancel() }
    }

    /// Fails the race at the deadline and cancels the call, unless the call
    /// already finished and cancelled the clock.
    private func expire(after seconds: TimeInterval, with timeout: Error) async {
        do {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        } catch {
            return // swallow-ok: the call finished first and cancelled the clock
        }
        let (finish, tasks) = parts.withLock { ($0.finish, $0.tasks) }
        finish?(.failure(timeout))
        tasks.forEach { $0.cancel() }
    }

    private static func run(
        _ operation: @Sendable () async throws -> T,
        finish: ResumeOnce<T>,
        clock: Task<Void, Never>
    ) async {
        do {
            let value = try await operation()
            finish(.success(value))
        } catch {
            finish(.failure(error))
        }
        clock.cancel()
    }
}

/// Resumes a continuation with the first result it is given; later ones are
/// dropped.
private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: CheckedContinuation<T, Error>
    private let resumed = OSAllocatedUnfairLock(initialState: false)

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func callAsFunction(_ result: Result<T, Error>) {
        if resumed.setIfClear() { continuation.resume(with: result) }
    }
}
