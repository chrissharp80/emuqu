import Foundation

/// Rebuilds the recovery baseline from what the archive holds: at boot into
/// an empty baseline, after a CloudKit pull, and after a night the baseline
/// had already taken in leaves the archive (`BaselineArchiveSync`, a discard).
///
/// The archive is decrypted off the main actor; the tracker is changed on it.
@MainActor
final class BaselineRebuilder {
    private let archive: SessionArchive
    private let baselineTracker: BaselineTracker
    private let settingsManager: SettingsManager

    init(archive: SessionArchive, baselineTracker: BaselineTracker, settingsManager: SettingsManager) {
        self.archive = archive
        self.baselineTracker = baselineTracker
        self.settingsManager = settingsManager
    }

    /// Decrypt the archive OFF the main actor. `boot()` runs
    /// synchronously on the main actor right after first paint
    /// (`EmuquApp.runDeferredBoot` → `timedBoot("collector")`), and this walk
    /// does an AES-GCM decrypt + JSON decode PER archived session, which on a
    /// full archive stalls the main thread for seconds and freezes the
    /// dashboard. The rebuild is best-effort recovery from CloudKit-restored
    /// state (see the note on `boot()`), so deferring it a few frames off-main
    /// is correctness-neutral. Decrypt on a utility task, then hop back to
    /// mutate the MainActor-isolated `baselineTracker`.
    /// Also the rebuild after a CloudKit pull into an empty baseline
    /// (`CollectorSessionControl.bindCloudSyncBaseline`), and the boot rebuild
    /// (`RRCollector.boot()`).
    func rebuildOffMain(replacing: Bool = false) {
        rebuildOffMain(replacing: replacing, reusing: [:])
    }

    /// Rebuild the baseline from what the archive holds now. Used after a
    /// night the baseline had already taken in is discarded.
    func rebuildFromArchive() {
        rebuildOffMain(replacing: true)
    }

    /// A replacing rebuild starts from a tracker holding only the readings
    /// of the nights it could not read (a file that fails to decrypt for a
    /// moment must not drop its night from every later score); one whose archive
    /// changed while it decoded starts over instead, so a night archived or
    /// rewritten (a newer iCloud copy under the same id) in the meantime is
    /// neither wiped from the baseline nor scored from its old copy. The pass
    /// that starts over reuses what this one decoded whose stored file is
    /// unchanged (`ArchivedCopy`: id and file hash) and decrypts only what is
    /// new or rewritten, so an archive that keeps changing (a run of iCloud
    /// pulls) costs a few sessions per pass, not the whole archive again. A
    /// boot rebuild re-checks: if a live session landed while we were
    /// decrypting, it already seeded the tracker, so the rebuild must not
    /// clobber it.
    private func commitRebuiltBaseline(_ sessions: [HRVSession], decoded: [ArchivedCopy: HRVSession], copies: [ArchivedCopy], replacing: Bool) {
        if replacing {
            guard archive.store.entries.map(ArchivedCopy.init) == copies else { return restartReplacingRebuild(reusing: decoded) }
            baselineTracker.reset(keepingReadingsOf: Set(copies.filter { decoded[$0] == nil }.map(\.sessionId)))
        } else if baselineTracker.daysCollected > 0 {
            return
        }
        baselineTracker.rebuildFromSessions(
            sessions,
            sleepSchedule: settingsManager.settings.sleepSchedule // injected, never resolved here
        )
    }

    /// One stored copy of an archived session: its id and the hash of its
    /// file, which every rewrite of the session changes.
    struct ArchivedCopy: Hashable, Sendable {
        let sessionId: UUID
        let fileHash: String

        init(_ entry: SessionArchiveEntry) {
            sessionId = entry.sessionId
            fileHash = entry.fileHash
        }
    }

    /// A replacing rebuild whose archive changed while it decoded starts
    /// over, handing on what it decoded by stored copy.
    private func restartReplacingRebuild(reusing decoded: [ArchivedCopy: HRVSession]) {
        rebuildOffMain(replacing: true, reusing: decoded)
    }

    /// The off-main decode behind `rebuildOffMain(replacing:)`.
    /// Sessions in `decoded` (an earlier pass's, by id and file hash) are
    /// taken as they are; the archive's other entries, new or rewritten since,
    /// are decrypted.
    private func rebuildOffMain(replacing: Bool, reusing decoded: [ArchivedCopy: HRVSession]) {
        let archive = self.archive
        let copies = archive.store.entries.map(ArchivedCopy.init)
        Task.detached(priority: .utility) {
            let read = Self.decodedSessions(of: copies, reusing: decoded, from: archive)
            let sessions = read.map { $0.1 }
            let byCopy = Dictionary(read, uniquingKeysWith: { first, _ in first })
            await MainActor.run { [weak self] in
                self?.commitRebuiltBaseline(sessions, decoded: byCopy, copies: copies, replacing: replacing)
            }
        }
    }

    /// Each copy's session: the one decoded earlier for that same copy, else
    /// decrypted lightweight; an unreadable copy is left out.
    nonisolated private static func decodedSessions(
        of copies: [ArchivedCopy], reusing decoded: [ArchivedCopy: HRVSession], from archive: SessionArchive
    ) -> [(ArchivedCopy, HRVSession)] {
        copies.compactMap { copy in
            (decoded[copy] ?? archive.retrieveLightweightOrLog(copy.sessionId, caller: "baselineRebuild")).map { (copy, $0) }
        }
    }
}
