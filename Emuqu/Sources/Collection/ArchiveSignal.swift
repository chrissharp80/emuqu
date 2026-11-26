import Foundation
import Observation

/// Published signal for archive mutations.
///
/// Separate from `RRCollector` so views and view-models that only care about
/// archive add/update/delete/reanalyze events don't re-render on every BLE /
/// streaming / recording property the collector also publishes.
///
/// **Consumer contract.** Observe this object (not the full collector) when
/// you need to refresh on archive changes:
///
/// ```swift
/// @Environment(ArchiveSignal.self) var archiveSignal
///
/// var body: some View {
///     List(...).onChange(of: archiveSignal.version) { _, _ in reload() }
/// }
/// ```
///
/// **Writer contract.** Internal code that mutates the archive should call
/// `collector.archiveSignal.notifyChanged()` (which forwards here) or
/// `archiveSignal.notifyChanged()` directly. The `version` setter is
/// `private(set)` so views can't accidentally bump it.
@MainActor
@Observable
final class ArchiveSignal {
    /// Monotonically increments on every coalesced archive mutation.
    /// Consumers react via `.onChange(of: archiveSignal.version)`.
    private(set) var version: Int = 0

    @ObservationIgnored private let observers = NotificationTokens()
    /// The centre this signal listens on and posts to. Production uses
    /// `.default`, which is where `SessionArchive.archive(_:)` posts.
    ///
    /// injectable so a test can hand the signal a private
    /// `NotificationCenter()` and count bumps exactly. On the default centre
    /// every archive write in the process (another test's tearDown, a
    /// collector's launch-time repair) also lands here, which would make exact
    /// counts (`testArchiveVersionReadsThroughArchiveSignal`) flaky.
    @ObservationIgnored private let center: NotificationCenter

    /// Coalescing is required: one CloudKit full-sync pull can fire
    /// `sameNightMerge` for dozens of sessions within seconds, each one re-
    /// archiving and posting `.flowRecoveryArchiveChanged`. Without
    /// coalescing, MainTabView reloads the dashboard once per post, back to
    /// back, each one re-decoding the lightweight entries, and every screen hangs.
    ///
    /// 80 ms window — short enough that intentional single-action user
    /// writes (delete a session, save morning feeling) feel
    /// instantaneous, long enough to collapse the back-to-back archive
    /// writes from one CloudKit pull or one morning-processing additive-
    /// merge sequence into a single dashboard refresh.
    private static let coalesceWindow: TimeInterval = 0.08
    @ObservationIgnored private var coalesceTask: Task<Void, Never>?

    /// `queue:` is deliberately `nil`, not `.main`.
    ///
    /// `addObserver(forName:object:queue:using:)` with a non-nil queue posts the
    /// block to that queue **and blocks the posting thread until it finishes**
    /// (`_CFXNotificationPost` → `-[NSOperation waitUntilFinished]`). Because
    /// `SessionArchive.archive(_:)` posts this notification from whatever thread
    /// performed the write, `queue: .main` would turn every background archive write
    /// into a synchronous round-trip through the main queue.
    ///
    /// With the main thread blocked waiting on background archive writes and the
    /// writers blocked waiting on main, neither side can progress: a deadlock.
    /// `testConcurrentAccess` exercises exactly this cycle.
    ///
    /// `queue: nil` runs the block synchronously on the posting thread, which is
    /// all this block needs: it does no main-actor work itself, it just
    /// schedules `Task { @MainActor in … }`.
    init(center: NotificationCenter = .default) {
        self.center = center
        observers.add(center.addObserver(
            forName: .flowRecoveryArchiveChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleCoalescedBump() }
        })
    }

    deinit {
        coalesceTask?.cancel()
        observers.removeAll(from: center)
    }

    /// Schedule a single `version` bump at the end of the current coalesce
    /// window. If another notification arrives before the timer fires, it
    /// cancels this task and its own task bumps instead, so the burst folds
    /// into one bump.
    private func scheduleCoalescedBump() {
        coalesceTask?.cancel()
        coalesceTask = Task { @MainActor [weak self] in
            await sleepQuietly(UInt64(ArchiveSignal.coalesceWindow * 1_000_000_000), context: "scheduleCoalescedBump")
            guard !Task.isCancelled, let self else { return }
            self.version &+= 1
        }
    }

    /// Manually broadcast an archive change. The `version` bump happens via the
    /// observer above (single source of truth); archive writes propagate
    /// automatically via `SessionArchive.archive(_:)`, so most code never
    /// needs this.
    func notifyChanged() {
        center.post(name: .flowRecoveryArchiveChanged, object: nil)
    }
}
