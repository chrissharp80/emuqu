import Foundation

// Bringing the backup index in line with what is on disk and in the
// archive: lowering a beat count to what a torn write left, and setting the
// archived flag. `persistReconciledCount` stays `private` to this file;
// everything else here was internal already.

extension RawRRBackup {
    /// Beats recorded in the raw backup for `sessionId`, if a backup exists.
    /// The recovery archiver consults this before marking a backup archived so
    /// a truncated device fetch can't retire a backup that holds materially
    /// more data than what was archived.
    func backedUpBeatCount(_ sessionId: UUID) -> Int? {
        indexLock.lock()
        defer { indexLock.unlock() }
        return index.first(where: { $0.id == sessionId })?.beatCount
    }

    /// Lower a backup's stored beat counts to what actually survived on disk.
    /// Used to reconcile a torn/truncated append-only write, where the index
    /// claims more beats than the points file holds (index says 4380, disk has
    /// 147). Only ever LOWERS the count — we never fabricate beats we don't
    /// have. After reconciling, the backup stops mismatching on every read and
    /// the recovery archiver can retire it normally.
    func reconcileBeatCount(sessionId: UUID, to actualCount: Int, claimed: Int) {
        indexLock.lock()
        guard let idx = index.firstIndex(where: { $0.id == sessionId }) else {
            indexLock.unlock()
            return
        }
        let entry = index[idx]
        // Only act when it actually lowers something.
        guard (entry.backedUpCount ?? entry.beatCount) > actualCount else {
            indexLock.unlock()
            return
        }
        index[idx] = BackupIndex(
            id: entry.id, captureDate: entry.captureDate, fileName: entry.fileName,
            beatCount: actualCount, hash: entry.hash, archived: entry.archived,
            lastBackupTime: entry.lastBackupTime, backedUpCount: actualCount
        )
        indexLock.unlock()
        persistReconciledCount(sessionId: sessionId, to: actualCount, claimed: claimed)
    }

    private func persistReconciledCount(sessionId: UUID, to actualCount: Int, claimed: Int) {
        do {
            try saveIndex()
            debugLog("[RawRRBackup] Reconciled truncated backup \(sessionId.uuidString.prefix(8)): stored beat count lowered \(claimed) → \(actualCount) (torn write; missing beats are unrecoverable)")
        } catch {
            debugLog("[RawRRBackup] ⚠️ Failed to save index after reconcile: \(error)", level: .warning)
        }
    }

    /// Mark every backup whose session the archive already holds.
    ///
    /// `markAsArchived` is called on each successful archive path, so the flag
    /// is right for anything that completed in one go. It is wrong for anything
    /// that reached the archive by another route — a CloudKit pull, a launch
    /// recovery, a merge that reused a different session id — because no
    /// archive call ever passed through the backup's own id.
    ///
    /// Those entries then sit flagged forever, and the Data settings page
    /// renders them as a red "Unarchived recordings" count for a user whose
    /// data is, in fact, safely archived. The count is meant to mean "beats that
    /// exist only in a backup"; without this reconciliation it means "beats
    /// that did not take the usual path", which is not a thing anyone can act
    /// on.
    ///
    /// Returns how many it corrected, so the caller can log a real number.
    @discardableResult
    func reconcileArchived(against archivedSessionIds: Set<UUID>) -> Int {
        indexLock.lock()
        let corrected = Self.indicesNeedingArchivedFlag(index, archivedSessionIds: archivedSessionIds)
        for idx in corrected { index[idx].archived = true }
        indexLock.unlock()
        guard !corrected.isEmpty else { return 0 }
        do {
            try saveIndex()
        } catch {
            debugLog("[RawRRBackup] ⚠️ Failed to save index after reconcile: \(error)", level: .warning)
        }
        return corrected.count
    }

    /// Which index positions are flagged unarchived while the archive holds
    /// their session. Pure, so the reconciliation rule is testable without a
    /// backup directory or an archive.
    nonisolated static func indicesNeedingArchivedFlag(
        _ index: [BackupIndex],
        archivedSessionIds: Set<UUID>
    ) -> [Int] {
        index.indices.filter { !index[$0].archived && archivedSessionIds.contains(index[$0].id) }
    }

    /// Mark a backup as successfully archived (still kept for safety)
    func markAsArchived(_ sessionId: UUID) {
        indexLock.lock()
        guard let idx = index.firstIndex(where: { $0.id == sessionId }) else {
            indexLock.unlock()
            return
        }
        index[idx].archived = true
        indexLock.unlock()
        do {
            try saveIndex()
        } catch {
            debugLog("[RawRRBackup] ⚠️ Failed to save index after marking archived: \(error)")
        }
        // No logging needed - archival is already logged in Archive.swift
    }
}
