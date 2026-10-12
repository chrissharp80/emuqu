import Foundation

// Writing many sessions at once (imports): one lock, one index save.

extension ArchiveStore {
    // MARK: - Batch archive

    /// The result of walking one batch: entries to append, and how many
    /// existing sessions were content-merged.
    ///
    /// `updatedIds` are the existing sessions whose CONTENT
    /// changed via the merge path. They go through `_archive` directly (no
    /// per-id `.flowRecoveryArchiveChanged` post like the public `archive(_:)`
    /// wrapper does), and the batch-level nil post does not imply
    /// "invalidate everything" to per-session caches
    /// (BeatConsistencyPriorsCache reconciles instead of nuking). Posting
    /// per-id for these invalidates merged sessions' cached features.
    private struct BatchOutcome {
        var newEntries: [SessionArchiveEntry] = []
        var updatedIds: [UUID] = []
    }

    /// Batch archive multiple sessions efficiently.
    /// Each new session joins the in-memory index as its file is written, and
    /// the index is saved once at the end.
    /// - Parameter sessions: Array of sessions to archive
    /// - Returns: How many sessions were written, new and updated together
    @discardableResult
    func archiveBatch(_ sessions: [HRVSession]) throws -> Int {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        var outcome = BatchOutcome()
        do {
            for session in sessions {
                try archiveOne(session, into: &outcome)
            }
        } catch {
            savePartialBatch(outcome.newEntries)
            throw error
        }
        if !outcome.newEntries.isEmpty {
            try archive.saveIndex()
        }
        postBatchChangeNotifications(outcome)
        return outcome.newEntries.count + outcome.updatedIds.count
    }

    /// Files already written for a failed batch are in the in-memory index;
    /// it is saved before the error goes up — a disk that filled halfway
    /// through an import otherwise left them on disk with nothing pointing at
    /// them.
    private func savePartialBatch(_ newEntries: [SessionArchiveEntry]) {
        guard !newEntries.isEmpty else { return }
        _ = attempt("Archive.saveIndexAfterFailedBatch") { try archive.saveIndex() }
    }

    /// A batch-written entry joins the in-memory index at once, so a later
    /// session in the same batch finds it: a copy of it or a segment of the
    /// same sleep then merges into it as `_archive` would merge it. The
    /// derived caches are dropped, as `saveIndex` would drop them.
    private func indexBatchEntry(_ entry: SessionArchiveEntry, into outcome: inout BatchOutcome) {
        archive.index.append(entry)
        archive.sortedEntriesCache = nil
        archive.sessionIdLookup = nil
        outcome.newEntries.append(entry)
    }

    /// One session's turn through the batch: skip tombstones and duplicates,
    /// merge into an archived copy or same-sleep segment, or write it out fresh.
    ///
    /// The tombstone gate mirrors `_archive`'s. Without it, a
    /// batch import (file restore, recovery flow) could silently resurrect
    /// sessions the user explicitly deleted.
    ///
    /// The merge decision is `_archive`'s (`mergeTarget`): a copy of the same
    /// recording, of the same type, merges; so does an overnight segment of
    /// the same sleep within the user's merge gap — including one written
    /// earlier in this batch. Two readings that do not
    /// overlap and are not one sleep are both kept, however close.
    private func archiveOne(_ session: HRVSession, into outcome: inout BatchOutcome) throws {
        if archive.deletedSessionIds.contains(session.id) {
            debugLog("[Archive] archiveBatch: skipping tombstoned session \(session.id.uuidString.prefix(8))")
            return
        }
        // Skip exact duplicates by ID
        if archive.index.contains(where: { $0.sessionId == session.id }) { return }
        if let existingEntry = mergeTarget(for: session, sameSleepGap: sameSleepGap(for: session)) {
            try mergeIntoExisting(session, entry: existingEntry, outcome: &outcome)
            return
        }
        // A copy of a recording written earlier in this batch that the merge
        // rule does not pair with it (linked either way)
        if outcome.newEntries.contains(where: { Self.isCopy($0, of: session) }) {
            return
        }
        indexBatchEntry(try writeBatchSession(session), into: &outcome)
    }

    /// Load the existing copy or same-sleep segment and fold the incoming one
    /// into it. A read or write failure ends the batch with that error, as a
    /// failed write of a new session does: the incoming session is not written
    /// as a near-duplicate, and the caller learns it was not saved.
    private func mergeIntoExisting(
        _ session: HRVSession, entry: SessionArchiveEntry, outcome: inout BatchOutcome
    ) throws {
        do {
            guard var existingSession = try _retrieve(entry.sessionId) else {
                throw SessionArchive.ArchiveError.fileNotFound
            }
            // Update with any new/better data from import
            guard archive.mergeSessionData(from: session, into: &existingSession) else { return }
            try _archive(existingSession)
            outcome.updatedIds.append(existingSession.id)
        } catch {
            debugLog("[Archive] archiveBatch: could not merge \(session.id.uuidString.prefix(8)) into \(entry.sessionId.uuidString.prefix(8)): \(error)", level: .warning)
            throw error
        }
    }

    /// Write one new session's file and build its archive.index entry.
    ///
    /// Uses the archive.index encoder (pretty-printed) — a historical divergence
    /// from `_archive`'s compact `archive.sessionEncoder`: batch-written session
    /// files are pretty-printed and therefore hash differently than the
    /// same session written by `_archive`. Deliberately preserved
    /// — the hash-over-bytes-as-written contract makes the
    /// formatting self-consistent on read, and changing the encoder
    /// would change the bytes a re-write produces. See SessionArchive.SessionFileCodec.
    ///
    /// The write carries an explicit protection-class option for the same
    /// reason `_archive` does — see the note there.
    ///
    /// Entry built by the shared factory, so batch-built
    /// entries carry meanSDNN + the sleep-stage/dip
    /// mirror fields exactly as `_archive`'s do (no archive.index
    /// drift) — see SessionArchiveEntry.make.
    private func writeBatchSession(_ session: HRVSession) throws -> SessionArchiveEntry {
        let fileName = "\(session.id.uuidString).json"
        let filePath = archive.archiveDirectory.appendingPathComponent(fileName)
        let result = try SessionArchive.SessionFileCodec.encodeForDisk(session, encoder: SessionArchive.indexEncoder)
        try writeArchiveBytes(result.bytes, to: filePath, format: result.format, sessionID: session.id)
        return SessionArchiveEntry.make(from: session, hash: result.hash, filePath: fileName)
    }

    /// Same propagation as `archive(_:)`. Batch archiving (import
    /// paths, recovery flows) needs to wake up observers too. Posted once for
    /// the batch since they all happened together.
    ///
    /// Also posts per-id for content-merged sessions (see
    /// `BatchOutcome.updatedIds`) so per-session caches invalidate precisely.
    private func postBatchChangeNotifications(_ outcome: BatchOutcome) {
        for id in outcome.updatedIds {
            NotificationCenter.default.post(name: .flowRecoveryArchiveChanged, object: id)
        }
        if !outcome.newEntries.isEmpty || !outcome.updatedIds.isEmpty {
            NotificationCenter.default.post(name: .flowRecoveryArchiveChanged, object: nil)
        }
    }
}
