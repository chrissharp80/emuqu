import Foundation
import Observation

/// Published signal for archive mutations.
///
/// Split out from `RRCollector` so views and view-models that only care about
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
/// `collector.notifyArchiveChanged()` (which forwards here) or
/// `archiveSignal.notifyChanged()` directly. The `version` setter is
/// `private(set)` so views can't accidentally bump it.
@MainActor
@Observable
final class ArchiveSignal {
    /// Monotonically increments on every coalesced archive mutation.
    /// Consumers react via `$version` / `.onChange(of:)`.
    private(set) var version: Int = 0

    @ObservationIgnored private let observers = NotificationTokens()
    /// The centre this signal listens on and posts to. Production uses
    /// `.default`, which is where `SessionArchive.archive(_:)` posts.
    ///
    /// injectable so a test can hand the signal a private
    /// `NotificationCenter()` and count bumps exactly. On the default centre
    /// every archive write in the process (another test's tearDown, a
    /// collector's launch-time repair) also lands here, which is what made
    /// `testArchiveVersionReadsThroughArchiveSignal` flaky.
    @ObservationIgnored private let center: NotificationCenter

    /// Coalescing is required, per a user's actual log:
    /// on a single app launch, CloudKit's full-sync pull fired
    /// `sameNightMerge` for 37 sessions in 5 seconds (each one re-
    /// archives → posts `.flowRecoveryArchiveChanged`). Without
    /// coalescing, MainTabView reloads the dashboard 37 times back to
    /// back, each one re-decoding 35 lightweight entries. That's the
    /// "every screen hangs" the user reported.
    ///
    /// 80 ms window — short enough that intentional single-action user
    /// writes (delete a session, save morning feeling) feel
    /// instantaneous, long enough to collapse the back-to-back archive
    /// writes from one CloudKit pull or one morning-processing additive-
    /// merge sequence into a single dashboard refresh.
    private static let coalesceWindow: TimeInterval = 0.08
    @ObservationIgnored private var pendingBump = false
    @ObservationIgnored private var coalesceTask: Task<Void, Never>?

    /// `queue:` is deliberately `nil`, not `.main`.
    ///
    /// `addObserver(forName:object:queue:using:)` with a non-nil queue posts the
    /// block to that queue **and blocks the posting thread until it finishes**
    /// (`_CFXNotificationPost` → `-[NSOperation waitUntilFinished]`). Because
    /// `SessionArchive.archive(_:)` posts this notification from whatever thread
    /// performed the write, `queue: .main` turned every background archive write
    /// into a synchronous round-trip through the main queue.
    ///
    /// That was a real deadlock, not a theoretical one: with the main thread
    /// blocked waiting on background archive writes, the writers blocked waiting
    /// on main, and neither side could progress. `testConcurrentAccess` hung the
    /// whole test suite indefinitely on exactly this cycle. It is also the most
    /// likely mechanism behind the "every screen hangs" report described below —
    /// 37 CloudKit-pull archive writes × one blocking main-queue round-trip each,
    /// multiplied by the five observers of this notification.
    ///
    /// `queue: nil` runs the block synchronously on the posting thread, which is
    /// all this block ever needed: it does no main-actor work itself, it just
    /// schedules `Task { @MainActor in … }`. Behaviour is identical; the blocking
    /// wait is gone.
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
    /// gets folded into the same bump.
    private func scheduleCoalescedBump() {
        pendingBump = true
        coalesceTask?.cancel()
        coalesceTask = Task { @MainActor [weak self] in
            await sleepQuietly(UInt64(ArchiveSignal.coalesceWindow * 1_000_000_000), context: "scheduleCoalescedBump")
            guard !Task.isCancelled, let self else { return }
            if self.pendingBump {
                self.pendingBump = false
                self.version &+= 1
            }
        }
    }

    /// Manually broadcast an archive change. Kept for legacy callers;
    /// the `version` bump happens via the observer above (single source
    /// of truth). New code shouldn't need to call this; archive writes
    /// propagate automatically via `SessionArchive.archive(_:)`.
    func notifyChanged() {
        center.post(name: .flowRecoveryArchiveChanged, object: nil)
    }
}
