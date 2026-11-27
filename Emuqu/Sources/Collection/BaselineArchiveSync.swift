import Foundation

/// Keeps the baseline to what the archive holds when a night arrives or
/// leaves by a path that does not update the baseline itself: a delete from
/// History, Trends or Fitness, a deletion made on another device, a Trash
/// restore, a recovered night, an iCloud import. Every archive change is
/// announced by session id (`.flowRecoveryArchiveChanged`); the ids of a
/// burst are gathered for `settleSeconds`, and when any of them is out of
/// step the baseline is rebuilt from the archive once (`rebuild`).
///
/// Out of step: a night the baseline holds that the archive no longer does,
/// a scored overnight the archive holds that the baseline does not, or a
/// night both hold whose archived reading changed (`storedReadingDiffers`). The
/// paths that update the baseline themselves (acceptance, reanalysis) have
/// done so by the time the burst settles, so they cause no rebuild.
@MainActor
final class BaselineArchiveSync {
    static let settleSeconds: Double = 2

    private let archive: SessionArchive
    private let baseline: BaselineTracker
    private let rebuild: @MainActor () -> Void
    private var pending: Set<UUID> = []
    private var settleTask: Task<Void, Never>?

    init(archive: SessionArchive, baseline: BaselineTracker, rebuild: @escaping @MainActor () -> Void) {
        self.archive = archive
        self.baseline = baseline
        self.rebuild = rebuild
    }

    /// The observer for `.flowRecoveryArchiveChanged`. `queue: nil` runs it on
    /// the posting thread, which may be a background archive write; it only
    /// hops to the main actor (see `ArchiveSignal.init` for why not `.main`).
    func observe(in center: NotificationCenter = .default) -> NSObjectProtocol {
        center.addObserver(forName: .flowRecoveryArchiveChanged, object: nil, queue: nil) { [weak self] note in
            guard let id = note.object as? UUID else { return }
            Task { @MainActor in self?.note(id) }
        }
    }

    /// Adds `id` to the burst, starting the settle wait if none is running.
    func note(_ id: UUID) {
        pending.insert(id)
        guard settleTask == nil else { return }
        settleTask = Task { @MainActor [weak self] in
            await sleepQuietly(UInt64(Self.settleSeconds * 1_000_000_000), context: "BaselineArchiveSync.settle")
            self?.settle()
        }
    }

    /// Rebuilds once if any id of the burst is out of step.
    func settle() {
        let ids = pending
        pending.removeAll()
        settleTask = nil
        guard ids.contains(where: isOutOfStep) else { return }
        debugLog("[Baseline] The archive changed by a path that does not update the baseline — rebuilding from the archive")
        rebuild()
    }

    /// Whether the baseline and the archive disagree about the night `id`:
    /// one side holds it and the other does not, or both hold it but the
    /// archive's copy was re-analysed elsewhere (a reanalysis synced from
    /// another device replaces the night under the same id) to a different
    /// RMSSD or to a reading no longer reliable enough for the baseline.
    func isOutOfStep(_ id: UUID) -> Bool {
        let held = baseline.heldRMSSD(of: id)
        guard let entry = archive.store.entries.first(where: { $0.sessionId == id }) else { return held != nil }
        guard let held else {
            return entry.sessionType == .overnight && entry.recoveryScore != nil && entry.meanRMSSD != nil
        }
        return Self.storedReadingDiffers(held: held, entry: entry)
    }

    /// A held night whose archived copy now reads differently, or is now
    /// unreliable or no longer an overnight, is stale in the baseline.
    static func storedReadingDiffers(held: Double, entry: SessionArchiveEntry) -> Bool {
        guard entry.sessionType == .overnight, entry.isReliableForHRVAggregates, let archived = entry.meanRMSSD else { return true }
        return abs(archived - held) > rmssdTolerance
    }

    /// Below this (ms) two RMSSD values are the same reading stored twice.
    static let rmssdTolerance = 0.001
}
