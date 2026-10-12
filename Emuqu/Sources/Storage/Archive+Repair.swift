import Foundation

// MARK: - Archive Repair & Integrity

extension SessionArchive {
    /// Repair a corrupted archive by rebuilding the index from the .json files.
    /// Call this manually from Settings > Debug when needed
    /// - Returns: Number of sessions recovered
    ///
    /// Files with other extensions (`*.encrypted`, which no current writer
    /// produces) are left alone: the repair never deletes a file it has not
    /// read.
    ///
    /// The rebuild is seeded with a snapshot of the current index keyed by
    /// sessionId. When a session file is present on disk but can't be
    /// decoded/decrypted THIS pass (a transient decrypt failure — Keychain
    /// briefly unavailable, device just booted), the existing index entry is
    /// preserved instead of dropped. Dropping it erased real history:
    /// replacing the whole index made a session missing from the rebuild
    /// vanish from the user's timeline even though its file was sitting right
    /// there, intact. Only genuinely missing files (no entry to fall back to)
    /// get dropped.
    @discardableResult
    func repairArchive() -> Int {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(at: archiveDirectory, includingPropertiesForKeys: nil)
        } catch {
            debugLog("[Archive] Repair: Could not list directory: \(error.localizedDescription)")
            return 0
        }
        index = rebuiltIndex(from: files).sorted { $0.date > $1.date }
        // Dropped now, not by `saveIndex`: a save that fails before it gets
        // there would leave them serving the index this repair replaced.
        sortedEntriesCache = nil
        sessionIdLookup = nil
        do {
            try saveIndex()
        } catch {
            debugLog("[Archive] ⚠️ Failed to save index after repair: \(error)")
        }
        return index.count
    }

    private func rebuiltIndex(from files: [URL]) -> [SessionArchiveEntry] {
        let existingEntriesById = Dictionary(index.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
        return files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" && $0.lastPathComponent != "deleted.json" }
            .compactMap { rebuiltEntry(for: $0, existing: existingEntriesById) }
    }

    /// Rebuild one file's index entry. Skips files that aren't UUID-named and
    /// sessions the user deleted.
    ///
    /// A read failure on a file that WAS enumerated (so it exists on disk)
    /// preserves the existing index entry rather than dropping it — a
    /// transient read error must not erase real history. Same when decode AND
    /// decrypt both fail. Only files genuinely absent from disk (never
    /// enumerated) are gone.
    ///
    /// The hash is over the bytes-as-stored, matching `_retrieve`'s integrity
    /// check and every write path's hash contract — see SessionFileCodec.
    ///
    /// Entry built by the shared factory, so repair-built
    /// entries carry meanSDNN + the sleep-stage/dip
    /// mirror fields instead of drifting from `_archive`'s index
    /// shape — see SessionArchiveEntry.make. The
    /// filename-derived sessionId and readiness-score fallback are
    /// repair-specific behaviors preserved via the overrides.
    private func rebuiltEntry(
        for fileURL: URL, existing: [UUID: SessionArchiveEntry]
    ) -> SessionArchiveEntry? {
        let filename = fileURL.deletingPathExtension().lastPathComponent
        guard let sessionId = UUID(uuidString: filename) else { return nil }
        // Skip deleted sessions
        if deletedSessionIds.contains(sessionId) { return nil }
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            return preserved(existing[sessionId], filename: filename, error: error, verb: "read")
        }
        guard let session = Self.decodeRepairable(fileData, id: sessionId) else {
            return preserved(existing[sessionId], filename: filename, error: nil, verb: "decrypt")
        }
        return SessionArchiveEntry.make(
            from: session,
            hash: SessionFileCodec.sha256Hex(fileData),
            filePath: fileURL.lastPathComponent,
            overridingSessionId: sessionId,
            recoveryScoreFallback: session.readinessScore
        )
    }

    /// Decoded through the archive's own dual-format reader
    /// (`ArchiveStore.plaintextBytes`, the one `_retrieve` and
    /// `loadAndDecodeSessionFile` use): encrypted files are decrypted, legacy
    /// plaintext passes through. Nil, logged, when it does not decode. The
    /// file on disk is left untouched either way so we don't downgrade
    /// protection.
    ///
    /// Do NOT reassign `jsonData = decrypted`
    /// and hash the plaintext: the file on disk stays as ciphertext, and
    /// `_retrieve` hashes the bytes-as-stored, so every subsequent read of a
    /// repaired encrypted session would fail with `ArchiveError.hashMismatch`
    /// (a tester's debug log showed exactly that on a session
    /// after running repair). Always hash the bytes-as-stored, matching the
    /// write-path contract in `_archive` / `batchArchive` /
    /// `relinkSameNightSessions`.
    private static func decodeRepairable(_ fileData: Data, id: UUID) -> HRVSession? {
        do {
            return try sessionDecoder.decode(HRVSession.self, from: ArchiveStore.plaintextBytes(fileData, id: id))
        } catch {
            debugLog("[Archive] Repair: \(id.uuidString.prefix(8)) does not decode: \(error)", level: .warning)
            return nil
        }
    }

    private func preserved(
        _ existing: SessionArchiveEntry?, filename: String, error: Error?, verb: String
    ) -> SessionArchiveEntry? {
        let detail = error.map { ": \($0)" } ?? ""
        guard let existing else {
            debugLog("[Archive] Repair: Could not \(verb) \(filename)\(detail) — no existing index entry to preserve", level: .warning)
            return nil
        }
        debugLog("[Archive] Repair: Could not \(verb) \(filename)\(detail) — preserving existing index entry (file present)", level: .warning)
        return existing
    }

    /// Targeted, self-healing repair for a SINGLE session whose stored
    /// `fileHash` no longer matches its file bytes (the `ArchiveError.hashMismatch`
    /// the sync path throws). A mismatch is usually a STALE fingerprint on
    /// otherwise-good data — an older write path (`relinkSameNightSessions`)
    /// rewrote the file without updating the hash; see the note in `_retrieve`.
    ///
    /// Decode-and-validate FIRST: only refresh the hash if the file still yields
    /// a real `HRVSession`, so genuinely-corrupt bytes are NEVER laundered into a
    /// "valid" fingerprint. `.repaired` when the fingerprint now matches the
    /// file (so it passes the integrity check and can sync again);
    /// `.undecodable` when the bytes were read and won't decode — the caller
    /// should quarantine it rather than bless garbage; `.notNow` when nothing
    /// can be judged yet (the file can't be read or decrypted at the moment —
    /// locked device, key unreachable — or the index save failed), which is
    /// no reason for a permanent quarantine. Hashes the bytes-as-stored,
    /// matching `_retrieve` and every write path (see the note in
    /// `repairArchive`).
    func repairSessionHashIfDecodable(sessionId: UUID) -> HashRepair {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        guard let idx = index.firstIndex(where: { $0.sessionId == sessionId }) else { return .notNow }
        let entry = index[idx]
        let fileURL = resolveFileURL(for: entry)
        guard let fileData = Self.bytesForRepair(at: fileURL, id: sessionId) else { return .notNow }
        // Only re-hash a file that decodes to a real session.
        guard let session = Self.decodeRepairable(fileData, id: sessionId) else {
            debugLog("[Archive] Repair: session \(sessionId.uuidString.prefix(8)) will not decode — NOT re-hashing (genuine corruption, caller should quarantine)", level: .warning)
            return .undecodable
        }
        // Already matches? Nothing to repair (defensive — caller only calls on mismatch).
        let currentHash = SessionFileCodec.sha256Hex(fileData)
        if currentHash == entry.fileHash { return .repaired }
        index[idx] = SessionArchiveEntry.make(
            from: session, hash: currentHash, filePath: fileURL.lastPathComponent,
            overridingSessionId: sessionId, recoveryScoreFallback: session.readinessScore
        )
        return persistRehash(sessionId: sessionId, from: entry.fileHash, to: currentHash) ? .repaired : .notNow
    }

    /// What `repairSessionHashIfDecodable` found.
    enum HashRepair: Equatable {
        case repaired
        case undecodable
        case notNow
    }

    /// The stored bytes, or nil (logged) while they cannot be judged: the
    /// read fails, or they are encrypted and the key is unreachable.
    private static func bytesForRepair(at fileURL: URL, id: UUID) -> Data? {
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            debugLog("[Archive] Repair: \(id.uuidString.prefix(8)) cannot be read now: \(error) — will retry", level: .warning)
            return nil
        }
        guard !ArchiveStore.looksEncrypted(fileData) || AppDependencies.current.storage.encryptionManager.isAvailable else {
            debugLog("[Archive] Repair: \(id.uuidString.prefix(8)) is encrypted and the key is unavailable — will retry", level: .warning)
            return nil
        }
        return fileData
    }

    /// Persist the refreshed fingerprint, logging the before/after so a stale
    /// hash that blocked syncing leaves a trace of having been healed. The
    /// in-memory index already holds the new fingerprint when the save
    /// fails; the next successful save writes it.
    private func persistRehash(sessionId: UUID, from oldHash: String, to currentHash: String) -> Bool {
        do {
            try saveIndex()
        } catch {
            debugLog("[Archive] Repair: failed to save index after re-hashing \(sessionId.uuidString.prefix(8)): \(error)", level: .warning)
            return false
        }
        debugLog("[Archive] Repaired STALE HASH for session \(sessionId.uuidString.prefix(8)) — file decoded to a valid session; fingerprint refreshed \(oldHash.prefix(8))… → \(currentHash.prefix(8))…, now syncable", level: .warning)
        return true
    }

    /// Verify archive integrity
    func verifyIntegrity() -> [UUID: Bool] {
        archiveLock.lock()
        let entriesToVerify = index
        archiveLock.unlock()

        var results: [UUID: Bool] = [:]

        for entry in entriesToVerify {
            do {
                let data = try Data(contentsOf: resolveFileURL(for: entry))
                results[entry.sessionId] = (SessionFileCodec.sha256Hex(data) == entry.fileHash)
            } catch {
                results[entry.sessionId] = false
            }
        }

        return results
    }
}
