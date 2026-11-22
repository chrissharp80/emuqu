import Foundation
import os

/// The process-wide lock "Delete All My Data" holds while it runs.
///
/// A purge empties the archive's files and its in-memory index. A write that
/// lands meanwhile puts a session back: a rescore finishing its pass, a
/// reading being accepted, a CloudKit pull, a migration. So while a purge
/// runs every writer is refused, and the purge itself starts only once the
/// writes already under way have finished.
///
/// Writers are the archive's disk writes, which run their write through
/// `admitWrite`: session files (`writeArchiveBytes`), the index
/// (`SessionArchive.saveIndex`), the deleted-session list
/// (`SessionArchive.saveDeletedIndex`), the re-encryption of a Trash or
/// quarantine copy, and the protection-class rewrite of an archive file at
/// launch; and the CloudKit sync manager, which checks `isPurging` before a
/// full sync or an upload runs. Every archive write path (archiving,
/// `update`, batch imports, merges, migrations, deletions, re-encryption)
/// writes session or index bytes through one of those, so none has to know
/// about the purge. Moving or removing a file that is already there (into the
/// Trash or quarantine) is not gated: it brings nothing back.
///
/// A refused write throws `Refused`; its caller handles it as it handles any
/// other failed write (logs it, reports the save as failed), so nothing is
/// reported as saved that was not.
///
/// Overlapping purges are counted: the gate stays closed until the last one
/// opens it.
enum PurgeGate {
    /// Why a write was refused.
    struct Refused: Error, LocalizedError {
        var errorDescription: String? {
            String(localized: "Your data is being deleted. Nothing can be saved until that has finished.", bundle: LanguageManager.appBundle)
        }
    }

    private struct State: Sendable {
        /// Purges running.
        var purges = 0
        /// Writes admitted and not yet finished.
        var writers = 0
        /// Purges waiting for those writes to finish.
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Whether a purge is running, so writes are refused.
    static var isPurging: Bool {
        state.withLock { $0.purges > 0 }
    }

    /// Runs `write` unless a purge is running, and counts it as in flight
    /// until it returns, so a purge that starts meanwhile waits for it.
    /// Throws `Refused` without running it while a purge runs.
    static func admitWrite<T>(_ write: () throws -> T) throws -> T {
        let admitted = state.withLock { gate -> Bool in
            guard gate.purges == 0 else { return false }
            gate.writers += 1
            return true
        }
        guard admitted else {
            debugLog("[PurgeGate] Write refused: Delete All My Data is running", level: .warning)
            throw Refused()
        }
        defer { finishWrite() }
        return try write()
    }

    /// The last write in flight wakes the purges waiting for it.
    private static func finishWrite() {
        let drained = state.withLock { gate -> [CheckedContinuation<Void, Never>] in
            gate.writers -= 1
            guard gate.writers == 0 else { return [] }
            let waiting = gate.waiting
            gate.waiting = []
            return waiting
        }
        for purge in drained { purge.resume() }
    }

    /// Closes the gate for a purge: from now on every write is refused.
    /// Returns once the writes already admitted have finished. Each call is
    /// paired with one `endPurge()`.
    static func beginPurge() async {
        await withCheckedContinuation { (purge: CheckedContinuation<Void, Never>) in
            if !close(resumingWhenDrained: purge) { purge.resume() }
        }
    }

    /// Counts the purge in and, when writes are in flight, keeps `purge` to
    /// be resumed by the last of them. Returns whether it was kept.
    private static func close(resumingWhenDrained purge: CheckedContinuation<Void, Never>) -> Bool {
        state.withLock { gate in
            gate.purges += 1
            guard gate.writers > 0 else { return false }
            gate.waiting.append(purge)
            return true
        }
    }

    /// Opens the gate again once the last running purge has finished.
    static func endPurge() {
        state.withLock { gate in
            gate.purges = max(0, gate.purges - 1)
        }
    }
}
