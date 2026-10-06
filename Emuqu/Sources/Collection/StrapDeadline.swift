import Foundation
import os

/// A hard wall clock for strap calls. `withThrowingTaskGroup` cannot provide
/// one: a group waits for every child, even after the timeout child throws
/// and `cancelAll()` runs, so an SDK call whose continuation never fires (a
/// stale BLE link) still hangs the caller. Here the call runs in its own
/// task and the caller resumes at whichever comes first: the result, the
/// deadline, or the caller's own cancellation (the user's Cancel). At the
/// deadline or on cancellation the call's task is cancelled, and its result,
/// if one still arrives, is ignored. The call itself stops at its next
/// cancellation check; the caller does not wait for that.
enum StrapDeadline {
    static func race<T: Sendable>(
        seconds: UInt64,
        timeout: Error,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = StrapRace<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                race.begin(ResumeOnce(continuation), seconds: seconds, timeout: timeout, operation: operation)
            }
        } onCancel: {
            race.cancel()
        }
    }
}

/// One race's moving parts, behind a lock: the caller's continuation, the
/// call's task, and whether the caller was cancelled before the race began.
private final class StrapRace<T: Sendable>: Sendable {
    private struct Parts: Sendable {
        var finish: ResumeOnce<T>?
        var tasks: [Task<Void, Never>] = []
        var cancelled = false
    }

    private let parts = OSAllocatedUnfairLock(initialState: Parts())

    func begin(
        _ finish: ResumeOnce<T>,
        seconds: UInt64,
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
    private func expire(after seconds: UInt64, with timeout: Error) async {
        do {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
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
        let first = resumed.withLock { (done: inout Bool) -> Bool in
            let wasFirst = !done
            done = true
            return wasFirst
        }
        if first { continuation.resume(with: result) }
    }
}
