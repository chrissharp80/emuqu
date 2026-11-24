import Foundation

/// What `RawBackupSealer` reads and changes in the backup store whose files
/// it repairs: the index rows, the points files of a session, and the
/// one-shot write that adopts a fuller file. `RawRRBackup` provides it.
protocol SealableBackupStore: AnyObject {
    /// Merges an index the launch could not read; throws while it still
    /// cannot be read.
    func mergeIndexIfLaunchReadFailed() throws
    /// The index row of `sessionId`, or nil.
    func existingIndexEntry(_ sessionId: UUID) -> RawRRBackup.BackupIndex?
    /// The points file of the session and any set aside from it.
    func appendPointFiles(of sessionId: UUID) -> [URL]
    /// Writes `points` as the session's one-shot backup and indexes it.
    /// The caller is on the store's `appendQueue`.
    @discardableResult
    func backupOnAppendQueue(points: [RRPoint], sessionId: UUID, deviceId: String?, captureDate: Date?) throws -> RawRRBackup.BackupEntry
    /// Sets the archived flag of the session's row.
    func markAsArchived(_ sessionId: UUID)
}

/// Keeps the raw backups in one folder encrypted at rest.
///
/// A one-shot file is written sealed when the key is reachable; otherwise
/// it is written in plain JSON under `BackupProtection.plaintext` and the
/// session is queued in `PendingEncryptionLedger` (`.rawBackup`). Streamed
/// points files queue their session the same way when a line could not be
/// sealed (`RawRRBackup.encodedLines`). Once the key is back, `reencrypt`
/// rewrites every queued backup sealed and takes it off the queue.
///
/// The repair runs on the store's `appendQueue` (`RawRRBackup
/// .reencryptPendingBackups` at launch, `repairAfterUnlock` on unlock and
/// activation), so no append or discard runs during a rewrite; index rows
/// are read and changed only through the store, under its `indexLock`.
struct RawBackupSealer {
    /// The folder whose backups this seals.
    let directory: URL
    /// The key they are sealed with.
    let encryption: EncryptionManager

    /// Write one entry, choosing the protection class from whether it
    /// encrypted. Atomic: `reencrypt` rewrites the only copy of a backup in
    /// place, and a process killed mid-write must not leave it truncated.
    ///
    /// Unencrypted bytes get `BackupProtection.plaintext`, which can be
    /// created while the device is locked (when the key is most often out of
    /// reach) and is unreadable once closed until the next unlock, and the
    /// backup is queued for re-encryption; an encrypted write, under
    /// `BackupProtection.appendable`, takes it off that queue.
    ///
    /// The queue changes only as far as the write succeeded. Plaintext is
    /// queued before its write, so a process killed between the two leaves
    /// it queued, and taken off again if the write throws, since nothing new
    /// reached disk. An encrypted write clears the entry only once it has
    /// landed: cleared first, a failed rewrite would leave the old plaintext
    /// on disk with nothing queued to repair it.
    func writeEntry(_ entry: RawRRBackup.BackupEntry, to url: URL, sessionId: UUID) throws {
        let encoded = try encodedEntry(entry)
        let wasPending = Self.isPending(sessionId)
        if !encoded.encrypted { PendingEncryptionLedger.record(sessionId, in: .rawBackup) }
        let protection = encoded.encrypted ? BackupProtection.appendable : BackupProtection.plaintext
        do {
            try encoded.bytes.write(to: url, options: [.atomic, protection])
        } catch {
            if !wasPending { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
            throw error
        }
        if encoded.encrypted { PendingEncryptionLedger.clear(sessionId, in: .rawBackup) }
    }

    /// Whether the session is queued for re-encryption.
    static func isPending(_ sessionId: UUID) -> Bool {
        PendingEncryptionLedger.pending(in: .rawBackup).contains(sessionId)
    }

    /// Encode one backup entry, reporting whether encryption happened. A
    /// failed encrypt is logged and the plaintext returned, so the caller
    /// picks the plaintext protection class and queues re-encryption rather
    /// than losing the write. Drained in an autoreleasepool: the entry holds
    /// the full night's points.
    private func encodedEntry(_ entry: RawRRBackup.BackupEntry) throws -> (bytes: Data, encrypted: Bool) {
        try autoreleasepool {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let plaintext = try encoder.encode(entry)
            let manager = encryption
            guard manager.isAvailable else { return (plaintext, false) }
            do {
                return (try manager.encrypt(plaintext), true)
            } catch {
                debugLog("[RawRRBackup] encrypt failed for \(entry.id.uuidString.prefix(8)): \(error)", level: .error)
                return (plaintext, false)
            }
        }
    }

    /// Removes the one-shot file `old` a new backup replaced (nothing for nil
    /// or `current`). One that will not go while it may be plaintext (the
    /// session was queued before the write that cleared it) queues the
    /// session again, and `reencrypt` removes it.
    func removeReplacedFile(_ old: String?, keeping current: String, of sessionId: UUID, wasPending: Bool) {
        guard let old, old != current else { return }
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(old))
        } catch {
            debugLog("[RawRRBackup] ⚠️ Failed to remove replaced backup \(old): \(error)")
            if wasPending { PendingEncryptionLedger.record(sessionId, in: .rawBackup) }
        }
    }

    /// Repairs every queued backup of `store` (`reencrypt`); a no-op when
    /// nothing is queued or the key is still out of reach (the next launch,
    /// unlock or activation tries again). Run on the store's `appendQueue`.
    func reencryptPending(in store: some SealableBackupStore) {
        let pending = PendingEncryptionLedger.pending(in: .rawBackup)
        guard !pending.isEmpty, encryption.isAvailable else { return }
        debugLog("[RawRRBackup] re-encrypting \(pending.count) backup(s) written under a locked Keychain")
        for sessionId in pending { reencrypt(sessionId, in: store) }
    }

    /// A backup leaves the queue once none of its files holds plaintext: a
    /// fuller one-shot file is adopted, the indexed one re-encrypted, an
    /// unindexed plain one removed once provably replaced (`isSuperseded`),
    /// and every plain line of its points files sealed; else it stays
    /// queued. A failure is logged and the session stays queued.
    ///
    /// A session this store holds nothing of stays queued: the ledger is
    /// shared, so it may be another store's. A backup that is deleted leaves
    /// the queue through `RawRRBackup.removeEveryFile`.
    func reencrypt(_ sessionId: UUID, in store: some SealableBackupStore) {
        do {
            try store.mergeIndexIfLaunchReadFailed()
            adoptFullerBackup(sessionId, in: store)
            let entry = store.existingIndexEntry(sessionId)
            guard try holdsAnything(of: sessionId, entry: entry, in: store) else { return }
            let staleRemain = try removeSupersededPlaintext(of: sessionId, entry: entry)
            if let fileName = entry?.fileName {
                let url = directory.appendingPathComponent(fileName)
                try writeEntry(try RawRRBackup.decodeLegacyBackup(at: url, encryption: encryption), to: url, sessionId: sessionId)
            }
            let pointsSealed = try resealPointFiles(store.appendPointFiles(of: sessionId))
            if staleRemain || !pointsSealed {
                PendingEncryptionLedger.record(sessionId, in: .rawBackup)
            } else if entry?.fileName == nil {
                PendingEncryptionLedger.clear(sessionId, in: .rawBackup)
            }
        } catch {
            debugLog("[RawRRBackup] re-encryption deferred for \(sessionId.uuidString.prefix(8)): \(error)", level: .warning)
        }
    }

    /// Whether this store has a row or any file of the session.
    private func holdsAnything(
        of sessionId: UUID, entry: RawRRBackup.BackupIndex?, in store: some SealableBackupStore
    ) throws -> Bool {
        guard entry == nil else { return true }
        let files = try OneShotBackupName.files(of: sessionId, in: directory) + store.appendPointFiles(of: sessionId)
        return files.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Removes the plain one-shot files of the session the index does not
    /// name that `entry` provably replaced; true when a plain one is left.
    private func removeSupersededPlaintext(of sessionId: UUID, entry: RawRRBackup.BackupIndex?) throws -> Bool {
        let stale = try OneShotBackupName.plaintextFiles(of: sessionId, in: directory, except: entry?.fileName)
        let superseded = stale.filter { OneShotBackupName.isSuperseded($0, by: entry, encryption: encryption) }
        for url in superseded { try FileManager.default.removeItem(at: url) }
        return superseded.count < stale.count
    }

    /// Whether none of `files` that exist holds a plain line once each one
    /// that does is rewritten sealed (`SealedJSONLines.resealFile`). True
    /// when none exists; false, with nothing rewritten, while the key is out
    /// of reach.
    private func resealPointFiles(_ files: [URL]) throws -> Bool {
        let present = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !present.isEmpty else { return true }
        guard let manager = SealedJSONLines.availableManager(encryption) else { return false }
        return try present.map { try SealedJSONLines.resealFile(at: $0, with: manager) }.allSatisfy { $0 }
    }

    /// The fullest unindexed one-shot file of the session becomes the backup
    /// via the store's `backupOnAppendQueue`, archived flag kept; a failure is logged.
    private func adoptFullerBackup(_ sessionId: UUID, in store: some SealableBackupStore) {
        do {
            guard let indexed = store.existingIndexEntry(sessionId),
                  let fuller = try OneShotBackupName.fullerUnindexedBackup(than: indexed, in: directory, encryption: encryption) else { return }
            try store.backupOnAppendQueue(points: fuller.points, sessionId: sessionId, deviceId: fuller.deviceId, captureDate: fuller.captureDate)
            if indexed.archived { store.markAsArchived(sessionId) }
        } catch {
            debugLog("[RawRRBackup] adopting a fuller backup of \(sessionId.uuidString.prefix(8)) failed: \(error)", level: .warning)
        }
    }
}
