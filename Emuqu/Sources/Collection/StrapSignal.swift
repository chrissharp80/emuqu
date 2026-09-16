import Foundation

/// A main-actor wake-up for code waiting on strap state.
///
/// Readiness, connection and feed changes arrive as SDK callbacks. Code that
/// needs one of them — "record once the H10's recording feature is ready",
/// "re-subscribe when the strap reports HR" — suspends here and is resumed by
/// the change itself, instead of polling the state on a timer.
///
/// `fire()` resumes every waiter; each re-reads the state it cares about and
/// waits again if it is not there yet.
@MainActor
final class StrapSignal {
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]

    /// Resume every waiter with `true`.
    func fire() {
        let pending = waiters
        waiters.removeAll()
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        pending.values.forEach { $0.resume(returning: true) }
    }

    /// Suspends until `fire()` (true), the timeout elapses (false), or the
    /// calling task is cancelled (false).
    func wait(timeout: TimeInterval?) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                register(id, continuation, timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id, fired: false) }
        }
    }

    /// Runs synchronously inside the waiting task, so a cancellation that
    /// already happened is seen here and the continuation never parks.
    private func register(_ id: UUID, _ continuation: CheckedContinuation<Bool, Never>, timeout: TimeInterval?) {
        guard !Task.isCancelled else {
            continuation.resume(returning: false)
            return
        }
        waiters[id] = continuation
        guard let timeout else { return }
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(timeout, 0)))
            guard !Task.isCancelled else { return }
            self?.resolve(id, fired: false)
        }
    }

    private func resolve(_ id: UUID, fired: Bool) {
        timers.removeValue(forKey: id)?.cancel()
        waiters.removeValue(forKey: id)?.resume(returning: fired)
    }
}
