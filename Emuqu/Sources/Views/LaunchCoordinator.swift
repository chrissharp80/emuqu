import SwiftUI

// MARK: - Launch Coordinator
//
// Single source of truth for cold-launch background work ordering. Instead of
// scattered `Task(priority:) { try? await Task.sleep(2…8s); work }` sites, whose
// hand-tuned delays overlap and compete with the interactive window, this is a
// phase-gated, QoS-correct, bounded pipeline:
//
//   • Interactive-phase jobs (prewarms the user may need soon) run once the
//     first frame is up, at `.utility`.
//   • Housekeeping-phase jobs (migrations, backfills, training rebuild, iCloud
//     sync) run at `.background` and ONLY after the interactive window is over —
//     signalled by the dashboard's first data load landing (or a 6 s safety
//     timeout), never a guessed `sleep`.
//   • A small concurrency cap keeps the launch window from thrashing all cores.
//
// Archive-write safety is already handled by `SessionArchive`'s own lock, so no
// per-resource mutex is needed here.
@MainActor
final class LaunchCoordinator {
    static let shared = LaunchCoordinator()
    private init() {}

    enum Phase { case interactive, housekeeping }

    private var didBegin = false
    private var housekeepingOpen = false
    private var housekeepingWaiters: [CheckedContinuation<Void, Never>] = []
    private var dashboardReady = false
    private var dashboardReadyWaiter: CheckedContinuation<Void, Never>?

    private let maxConcurrent = 2
    private var inFlight = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    /// Call once, post-first-frame. Opens the housekeeping phase when the
    /// dashboard reports its first data load (or after a safety timeout).
    func begin() {
        guard !didBegin else { return }
        didBegin = true
        Task { @MainActor in
            await self.awaitDashboardReadyOrTimeout()
            self.housekeepingOpen = true
            let waiters = self.housekeepingWaiters
            self.housekeepingWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    /// The real "UI has its data, we're interactive" signal — called by the
    /// dashboard when its first session load lands. Idempotent.
    func signalDashboardReady() {
        guard !dashboardReady else { return }
        dashboardReady = true
        dashboardReadyWaiter?.resume()
        dashboardReadyWaiter = nil
    }

    /// Either the dashboard signals ready or the 6 s ceiling fires — whichever
    /// lands first wins and the other child is cancelled.
    private func awaitDashboardReadyOrTimeout() async {
        if dashboardReady { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.awaitDashboardReadySignal() }
            group.addTask { try? await Task.sleep(nanoseconds: 6_000_000_000) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Parks on a continuation the dashboard resumes when it finishes loading.
    @MainActor
    private func awaitDashboardReadySignal() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if dashboardReady { c.resume() } else { dashboardReadyWaiter = c }
        }
    }

    /// Schedule a launch job.
    func run(
        phase: Phase,
        priority: TaskPriority,
        skipInLowPower: Bool,
        lowPower: Bool,
        _ work: @escaping @Sendable () async -> Void
    ) {
        if skipInLowPower, lowPower { return }
        Task.detached(priority: priority) {
            await Self.runCoordinated(phase: phase, work)
        }
    }

    /// Housekeeping waits for its gate to open; every job then takes a
    /// concurrency slot for the duration of its work.
    private static func runCoordinated(phase: Phase, _ work: @Sendable () async -> Void) async {
        if phase == .housekeeping { await AppDependencies.current.app.launchCoordinator.awaitHousekeepingOpen() }
        await AppDependencies.current.app.launchCoordinator.acquireSlot()
        await work()
        AppDependencies.current.app.launchCoordinator.releaseSlot()
    }

    private func awaitHousekeepingOpen() async {
        if housekeepingOpen { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if housekeepingOpen { c.resume() } else { housekeepingWaiters.append(c) }
        }
    }

    private func acquireSlot() async {
        while inFlight >= maxConcurrent {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                slotWaiters.append(c)
            }
        }
        inFlight += 1
    }

    private func releaseSlot() {
        inFlight -= 1
        if !slotWaiters.isEmpty {
            slotWaiters.removeFirst().resume()
        }
    }
}
