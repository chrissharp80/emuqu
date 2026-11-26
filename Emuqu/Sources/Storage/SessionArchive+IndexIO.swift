import CryptoKit
import Foundation

// Index persistence, the archive error taxonomy, and the index-entry factory:
// the layer beneath the lock-free session methods in `ArchiveStore+Internal.swift`
// that reads and writes the index file itself.

extension ArchiveIndexState {
    // MARK: - Private

    /// Resolve the on-disk file URL for an archive entry.
    /// Supports both legacy absolute paths and modern relative filenames.
    ///
    /// A legacy absolute path names the app container of the install that
    /// wrote it, which changes with a reinstall or a restore; when nothing is
    /// there, the file is looked for under the same name in this archive
    /// directory, where it now lives.
    func resolveFileURL(for entry: SessionArchiveEntry) -> URL {
        guard entry.filePath.hasPrefix("/") else { return archiveDirectory.appendingPathComponent(entry.filePath) }
        let legacy = URL(fileURLWithPath: entry.filePath)
        guard !fileManager.fileExists(atPath: legacy.path) else { return legacy }
        return archiveDirectory.appendingPathComponent(legacy.lastPathComponent)
    }

    /// Protection class is `.completeUntilFirstUserAuthentication`,
    /// not `.completeUnlessOpen`. `.completeUnlessOpen`
    /// keeps a file accessible across a screen-lock event ONLY
    /// while the file handle stays open — once closed, the next
    /// open requires the device to be unlocked. iOS reads in
    /// `Data(contentsOf:)` open + close in one go, so any read
    /// that happens while the screen is locked (CloudKit sync,
    /// background AI context build, AssistantContextSource
    /// re-walk) fails with errno=1 ("Operation not permitted"), on
    /// every session file it touches.
    ///
    /// `.completeUntilFirstUserAuthentication` matches what
    /// RawRRBackup and DebugLog use (for the same errno-1
    /// reason in those subsystems). Trade-off:
    /// files become readable post-first-unlock-after-reboot
    /// instead of strict-while-unlocked. For HRV and workout
    /// data this is fine — the data isn't more sensitive than
    /// the rest of the app, and the stricter class breaks
    /// every background read path the app actually depends on.
    ///
    /// LAUNCH PERF. The per-file protection-class walk (recursive
    /// directory enumeration + per-file setAttributes, plus a read+rewrite on
    /// failure) scales with archive file count and must not run here in `init`,
    /// before first paint. It lives in `upgradeExistingFileProtection()`,
    /// which the launch housekeeping phase runs off-main once the dashboard
    /// has loaded. The directory create + directory-level setAttributes stay
    /// in `init` (cheap, and they govern the protection class NEW files
    /// inherit).
    func createArchiveDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: archiveDirectory.path) {
            _ = attempt("SessionArchive+IndexIO.create") { try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true) }
        }
        do {
            try fileManager.setAttributes(Self.protectionAttributes, ofItemAtPath: archiveDirectory.path)
        } catch {
            debugLog("[Archive] WARN: directory-level protection-class downgrade failed at \(archiveDirectory.path): \(error.localizedDescription)", level: .warning)
        }
    }

    /// Computed, not stored: `[FileAttributeKey: Any]` is not `Sendable`, and a
    /// two-entry dictionary costs nothing to rebuild.
    static var protectionAttributes: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }

    /// Walk every existing archive file and upgrade its protection class to
    /// match the directory. Kept out of `createArchiveDirectoryIfNeeded`
    /// so the file walk doesn't block launch; called from the launch
    /// housekeeping phase, off the main thread and after the dashboard's
    /// first read. Idempotent — safe to re-run every launch.
    ///
    /// The directory-level setAttributes only affects NEW files; the 30+
    /// session files already on disk keep whatever class they had at write
    /// time.
    ///
    /// Not `try?`, which would silently
    /// swallow failures: a user's debug log
    /// showed 1,557 EPERM read failures across session JSON files; the
    /// migration was running but `setAttributes` was failing on individual
    /// files and we had no signal. So failures are logged (so future debug
    /// captures show what's stuck) and each one force-rewrites the file with
    /// the explicit protection-class option to break out of the stuck state.
    ///
    /// A session still written in plaintext (`PendingEncryptionLedger`) is
    /// left alone: its `.completeFileProtectionUnlessOpen` stands in for the
    /// encryption it lacks (`archiveWriteOptions`), and the re-encryption that follows
    /// at launch does nothing while the key is unreachable, so lowering it
    /// here left plaintext health data readable whenever the device was
    /// unlocked once. The rewrite that encrypts it sets the class.
    func upgradeExistingFileProtection() {
        var attrFailureCount = 0
        for case let filename as String in fileManager.enumerator(atPath: archiveDirectory.path) ?? .init() {
            let path = archiveDirectory.appendingPathComponent(filename).path
            if !applyProtectionAttributes(at: path, filename: filename, failureCount: attrFailureCount) {
                attrFailureCount += 1
            }
        }
        if attrFailureCount > 5 {
            debugLog("[Archive] WARN: \(attrFailureCount - 5) additional setAttributes failures (capped log)", level: .warning)
        }
    }

    /// False when the attribute write failed and the file was force-rewritten
    /// instead. Log noise is capped at 5 lines; bulk failures surface via the
    /// caller's count log.
    ///
    /// Under `archiveLock`, which every session write holds: a save landing
    /// between the pending check and the attribute write (a plaintext write
    /// joins the ledger), or between the rewrite's read and write, would
    /// otherwise be downgraded or reverted to the bytes read here.
    private func applyProtectionAttributes(at path: String, filename: String, failureCount: Int) -> Bool {
        let failure = archiveLock.withLock { () -> Error? in
            if isPendingPlaintextSessionFile(filename, pending: PendingEncryptionLedger.pending) { return nil }
            do {
                try fileManager.setAttributes(Self.protectionAttributes, ofItemAtPath: path)
                return nil
            } catch {
                rewriteWithProtection(at: path)
                return error
            }
        }
        guard let failure else { return true }
        if failureCount < 5 {
            debugLog("[Archive] WARN: setAttributes failed for \(filename): \(failure.localizedDescription) — rewritten with the protection class", level: .warning)
        }
        return false
    }

    /// Whether the in-memory index lists every session `index.json` held:
    /// false while that file could not be read (`indexReadFailed`) or read
    /// but did not decode this launch (`indexDecodeFailed`). An empty index
    /// is then "unknown", not "no history". Takes `archiveLock`.
    var hasCompleteIndex: Bool {
        archiveLock.withLock { !indexReadFailed && !indexDecodeFailed }
    }

    /// A read error (the file is locked by data protection, EPERM, or sealed
    /// while the key cannot be reached, `readStoredIndex`) is not corruption:
    /// the file is left where it is, `indexReadFailed` is set and the read is
    /// retried at `boot()` and before any save. Only bytes that read but do
    /// not open (`indexJSON`) or decode are moved aside as unreadable. One entry that
    /// does not decode on this build is left out of `index` (`decodeIndex`),
    /// not the whole index, and kept with the newer-schema ones in
    /// `newerBuildIndexEntries` for `saveIndex` to write back. Bytes that
    /// cannot be moved aside either are handled as a failed read, so no save
    /// writes over them until they are.
    func loadIndex() {
        guard fileManager.fileExists(atPath: indexFile.path) else { return }
        let data: Data
        do {
            data = try readStoredIndex()
        } catch {
            debugLog("Failed to read archive index: \(error) — keeping it and retrying before the next save", level: .error)
            indexReadFailed = true
            return
        }
        do {
            (index, newerBuildIndexEntries) = try SessionArchive.decodeIndex(SessionArchive.indexJSON(data, encryption: encryption))
            sortedEntriesCache = nil
            sessionIdLookup = nil
        } catch {
            debugLog("Failed to decode archive index: \(error)", level: .error)
            index = []
            indexDecodeFailed = true
            indexReadFailed = !preserveUnreadableIndex()
        }
    }

    /// Read the index that failed to load at launch and merge it into the
    /// in-memory one, which holds only what was written since. Throws while
    /// the file still cannot be read, or does not decode and cannot be moved
    /// aside, so a save never writes the near-empty in-memory list over the
    /// only list of the user's sessions. Caller holds `archiveLock`.
    func mergeIndexThatFailedToLoad() throws {
        guard indexReadFailed else { return }
        let data = try readStoredIndex()
        indexReadFailed = false
        do {
            let onDisk = try SessionArchive.decodeIndex(SessionArchive.indexJSON(data, encryption: encryption))
            let known = Set(index.map(\.sessionId))
            index += onDisk.entries.filter { !known.contains($0.sessionId) && !deletedSessionIds.contains($0.sessionId) }
            newerBuildIndexEntries.merge(onDisk.newer)
            sortedEntriesCache = nil
            sessionIdLookup = nil
            debugLog("[Archive] index re-read after a failed launch read: \(index.count) sessions")
        } catch {
            debugLog("Failed to decode archive index on retry: \(error)", level: .error)
            indexDecodeFailed = true
            guard preserveUnreadableIndex() else {
                indexReadFailed = true
                throw error
            }
        }
    }

    /// The index file's bytes as stored. Throws when they cannot be read, or
    /// are sealed while the key cannot be reached (before the first unlock,
    /// or a Keychain failure): the index is then unreadable for now, not
    /// corrupt, and stays where it is.
    private func readStoredIndex() throws -> Data {
        let stored = try Data(contentsOf: indexFile)
        guard ArchiveStore.looksEncrypted(stored), !encryption.isAvailable else { return stored }
        throw EncryptionManager.EncryptionError.keyNotFound
    }

    /// The first save after a failed load writes a near-empty index over the
    /// one that failed, and with it the only list of the user's sessions. The
    /// unreadable file is moved aside first — a rename works even when the
    /// bytes cannot be read — and the session files themselves stay put, so
    /// the orphan scan at the end of `boot()` adopts every one of them back.
    /// False when the move failed and the file is still in place.
    private func preserveUnreadableIndex() -> Bool {
        let aside = indexFile.deletingLastPathComponent()
            .appendingPathComponent("\(indexFile.lastPathComponent).unreadable_\(Int(Date().timeIntervalSince1970))")
        guard attempt("Archive.preserveIndex", { try fileManager.moveItem(at: indexFile, to: aside) }) != nil else { return false }
        debugLog("[Archive] unreadable index moved to \(aside.lastPathComponent); sessions will be re-adopted from their files", level: .warning)
        return true
    }

    /// A read error (the file locked by data protection) is not corruption,
    /// as for the index: the file stays where it is, the deletion times kept
    /// beside it stand in, and `deletedIndexReadFailed` makes the next save
    /// (or `boot()`) read it again and merge it first. Only bytes that read
    /// but do not decode are set aside; when that move fails they are handled
    /// as a failed read too, so no save writes over them until they move.
    func loadDeletedIndex() {
        guard fileManager.fileExists(atPath: deletedIndexFile.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: deletedIndexFile)
        } catch {
            debugLog("Failed to read deleted index: \(error) — keeping it and retrying before the next save", level: .error)
            deletedIndexReadFailed = true
            deletedSessionIds = ArchiveStore.idsWithRecordedDeletionTime()
            return
        }
        do {
            deletedSessionIds = try Self.decodeDeletedIds(data)
        } catch {
            deletedIndexReadFailed = !setAsideUnreadableDeletedIndex(error)
            deletedSessionIds = ArchiveStore.idsWithRecordedDeletionTime()
        }
    }

    /// Read the deleted list that failed to load and merge it into the
    /// in-memory one. Throws while the file still cannot be read, or does not
    /// decode and cannot be moved aside, so a save never writes the partial
    /// list over the full one. Caller holds `archiveLock`.
    func mergeDeletedIndexThatFailedToLoad() throws {
        guard deletedIndexReadFailed else { return }
        let data = try Data(contentsOf: deletedIndexFile)
        deletedIndexReadFailed = false
        do {
            deletedSessionIds.formUnion(try Self.decodeDeletedIds(data))
        } catch {
            guard setAsideUnreadableDeletedIndex(error) else {
                deletedIndexReadFailed = true
                throw error
            }
        }
    }

    private static func decodeDeletedIds(_ data: Data) throws -> Set<UUID> {
        Set(try SessionArchive.sessionDecoder.decode([String].self, from: data).compactMap { UUID(uuidString: $0) })
    }

    /// Not emptied and then saved over: the next deletion would write a
    /// one-entry list over every tombstone the pull relies on, and sessions
    /// the user deleted would download again. The file is set aside; the
    /// caller rebuilds the list from the deletion times kept beside it.
    /// False when the move failed and the file is still in place.
    private func setAsideUnreadableDeletedIndex(_ error: Error) -> Bool {
        debugLog("Failed to decode deleted index: \(error) — rebuilding from recorded deletion times", level: .error)
        let aside = deletedIndexFile.deletingLastPathComponent()
            .appendingPathComponent("\(deletedIndexFile.lastPathComponent).unreadable_\(Int(Date().timeIntervalSince1970))")
        return attempt("Archive.preserveDeletedIndex") { try fileManager.moveItem(at: deletedIndexFile, to: aside) } != nil
    }

    /// While "Delete All My Data" runs the save throws `PurgeGate.Refused`
    /// and writes nothing (`PurgeGate`).
    func saveDeletedIndex() throws {
        try PurgeGate.admitWrite {
            try mergeDeletedIndexThatFailedToLoad()
            let uuidStrings = deletedSessionIds.map(\.uuidString)
            let data = try SessionArchive.indexEncoder.encode(uuidStrings)
            try data.write(to: deletedIndexFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Entries a newer build wrote are written back as they were read
    /// (`IndexEntriesFromNewerBuild.indexData`) rather than dropped or
    /// re-encoded without the fields this build does not know.
    ///
    /// Sealed with the archive's key: the entries carry health values
    /// (recovery score, RMSSD, heart rate, stress, sleep minutes, notes and
    /// tags). When the key cannot be reached the index is written unsealed
    /// rather than failing the save it belongs to, as session files fall back
    /// (ADR 001); `resealPlainIndexIfNeeded` seals it once the key is back.
    ///
    /// While "Delete All My Data" runs the save throws `PurgeGate.Refused`
    /// and writes nothing (`PurgeGate`).
    func saveIndex() throws {
        try PurgeGate.admitWrite {
            try mergeIndexThatFailedToLoad()
            sortedEntriesCache = nil
            sessionIdLookup = nil
            let data = try newerBuildIndexEntries.indexData(for: index, deleted: deletedSessionIds)
            try sealedOrPlain(data).write(to: indexFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// `data` sealed with the archive's key, or `data` itself, logged as an
    /// error, when the key cannot be reached.
    private func sealedOrPlain(_ data: Data) -> Data {
        do {
            return try encryption.encrypt(data)
        } catch {
            debugLog("[Archive] index written unsealed, the archive key is unavailable: \(error)", level: .error)
            return data
        }
    }

    /// Rewrites the index sealed when it is on disk as plain JSON (written
    /// while the key was unavailable, or by a build that did not seal it) and
    /// the key can now be reached. Skipped while the index did not load, so a
    /// partial list never replaces it.
    func resealPlainIndexIfNeeded() {
        guard fileManager.fileExists(atPath: indexFile.path),
              encryption.isAvailable, hasCompleteIndex else { return }
        archiveLock.withLock {
            guard let stored = attempt("Archive.readIndexForReseal", { try Data(contentsOf: indexFile) }),
                  !ArchiveStore.looksEncrypted(stored) else { return }
            _ = attempt("Archive.resealIndex") { try saveIndex() }
        }
    }
}

extension SessionArchive {
    /// The index JSON in `stored`: unsealed, or as it is when a build that
    /// did not seal the index wrote it as plain JSON
    /// (`EncryptionManager.openStoredJSON`). Throws when sealed bytes do not
    /// open, which `loadIndex` treats as corruption.
    static func indexJSON(_ stored: Data, encryption: EncryptionManager) throws -> Data {
        try encryption.openStoredJSON(stored)
    }

    /// The index entries in `data`, each decoded on its own: an entry this
    /// build cannot read (a field or case a newer build added, arriving
    /// through a shared container or a restore) is left out and logged, and
    /// the rest of the index still loads. Its session file stays on disk for
    /// a build that can read it. That entry, and one that decoded from a
    /// schema newer than this build writes, come back in `newer` as the JSON
    /// they were read as, so a save does not drop them or their newer fields.
    /// Throws only when `data` is not an index at all.
    static func decodeIndex(_ data: Data) throws -> (entries: [SessionArchiveEntry], newer: IndexEntriesFromNewerBuild) {
        let decoded = try sessionDecoder.decode([LenientIndexEntry].self, from: data).map(\.entry)
        let entries = decoded.compactMap { $0 }
        guard decoded.contains(where: { $0?.isFromNewerSchema ?? true }) else { return (entries, IndexEntriesFromNewerBuild()) }
        guard let objects = try JSONSerialization.jsonObject(with: data) as? [Any], objects.count == decoded.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (entries, try IndexEntriesFromNewerBuild(decoded: decoded, objects: objects))
    }

    // MARK: - Errors

    enum ArchiveError: Error, LocalizedError {
        case hashMismatch
        case fileNotFound
        case sessionWasDeleted
        /// The session payload was decoded from a NEWER schema than this
        /// build writes (associated value = the payload's schema version).
        /// Re-encoding it here would silently drop the newer-schema fields,
        /// so `_archive` refuses the write.
        case newerSchemaVersion(Int)

        var errorDescription: String? {
            let b = LanguageManager.appBundle
            return switch self {
            case .hashMismatch:
                String(localized: "Session data integrity check failed — the file may be corrupted.", bundle: b)
            case .fileNotFound:
                String(localized: "Session file could not be found on disk.", bundle: b)
            case .sessionWasDeleted:
                String(localized: "This session was previously deleted.", bundle: b)
            case .newerSchemaVersion:
                String(localized: "This session was saved by a newer version of the app. Update the app to change it.", bundle: b)
            }
        }

        /// True for failures that retrying can NEVER fix — a corrupt payload
        /// (`hashMismatch`) or an on-disk schema newer than this build can
        /// re-encode. The CloudKit push quarantines these instead of retrying
        /// them every sync forever (see `CloudKitSyncManager.pushPendingSessions`).
        var isPermanentUploadFailure: Bool {
            switch self {
            case .hashMismatch, .newerSchemaVersion: true
            case .fileNotFound, .sessionWasDeleted: false
            }
        }
    }
}

/// The `index.json` entries a newer build wrote that this build would lose
/// by re-encoding them, each kept as the JSON object it was read as:
///
///   • one that does not decode here at all. It is not in the in-memory
///     index, so without this the next save would write the file without it
///     and the newer build would lose the session from its list;
///   • one that decodes but carries a `schemaVersion` above
///     `SessionArchiveEntry.currentSchemaVersion`. Re-encoding it would drop
///     every field this build does not know and stamp it with the older
///     version.
///
/// The same rule as `ArchiveError.newerSchemaVersion` for session files: this
/// build does not rewrite data a newer build owns. An entry this build
/// replaces (re-archives, patches, merges) is written as this build built it,
/// and one it deletes is not written back.
struct IndexEntriesFromNewerBuild: Sendable {
    struct Undecodable: Sendable {
        /// The `sessionId` the object names, when it names a readable one.
        let sessionId: UUID?
        let json: Data
    }

    private(set) var undecodable: [Undecodable] = []
    /// Newer-schema entries that decoded, by session id.
    private(set) var newerSchema: [UUID: Data] = [:]

    init() {}

    /// `decoded[i]` is what `objects[i]` decoded to on this build, nil when
    /// it did not. An object that is not valid JSON on its own (not an
    /// object at all) is not an entry any build wrote, and is not kept.
    init(decoded: [SessionArchiveEntry?], objects: [Any]) throws {
        for (entry, object) in zip(decoded, objects) where entry?.isFromNewerSchema ?? true {
            guard JSONSerialization.isValidJSONObject(object) else { continue }
            let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            if let entry {
                newerSchema[entry.sessionId] = json
            } else {
                undecodable.append(Undecodable(sessionId: Self.sessionId(in: object), json: json))
            }
        }
    }

    private static func sessionId(in object: Any) -> UUID? {
        ((object as? [String: Any])?["sessionId"] as? String).flatMap(UUID.init(uuidString:))
    }

    /// Adds `other`'s entries; one already held is kept as it is.
    mutating func merge(_ other: IndexEntriesFromNewerBuild) {
        let known = Set(undecodable.compactMap(\.sessionId))
        undecodable += other.undecodable.filter { $0.sessionId.map { !known.contains($0) } ?? true }
        newerSchema.merge(other.newerSchema) { current, _ in current }
    }

    /// The bytes of `index.json` for `index`: each entry still as a newer
    /// build wrote it (its `sourceSchemaVersion` is still the newer one, so
    /// this build has not replaced it) goes back as it was read, and each
    /// undecodable entry whose session is neither listed in `index` nor in
    /// `deleted` is appended. With nothing kept, the plain encoding.
    func indexData(for index: [SessionArchiveEntry], deleted: Set<UUID>) throws -> Data {
        let encoded = try SessionArchive.indexEncoder.encode(index)
        guard !undecodable.isEmpty || !newerSchema.isEmpty,
              var objects = try JSONSerialization.jsonObject(with: encoded) as? [Any] else { return encoded }
        for (position, entry) in index.enumerated() where entry.isFromNewerSchema {
            guard let json = newerSchema[entry.sessionId] else { continue }
            objects[position] = try JSONSerialization.jsonObject(with: json)
        }
        objects += try undecodableObjects(notIn: index, deleted: deleted)
        return try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
    }

    /// An undecodable entry for a session this build now lists (an orphan
    /// scan adopted its file) or deleted is not written back: the listed one
    /// replaces it, and a deleted session must not come back.
    private func undecodableObjects(notIn index: [SessionArchiveEntry], deleted: Set<UUID>) throws -> [Any] {
        let superseded = Set(index.map(\.sessionId)).union(deleted)
        return try undecodable
            .filter { $0.sessionId.map { !superseded.contains($0) } ?? true }
            .map { try JSONSerialization.jsonObject(with: $0.json) }
    }
}

/// One index entry, or nil when it does not decode on this build: the
/// array decode goes on to the next entry instead of failing as a whole.
private struct LenientIndexEntry: Decodable {
    let entry: SessionArchiveEntry?

    init(from decoder: Decoder) {
        do {
            entry = try SessionArchiveEntry(from: decoder)
        } catch {
            debugLog("[Archive] index entry skipped — it does not decode on this build: \(error)", level: .warning)
            entry = nil
        }
    }
}

// MARK: - File-scope helpers
//
// Moved out of SessionArchive. Each names no member of the
// type and calls nothing that stayed behind, so none needed to be inside
// it. `private` at file scope is fileprivate, so every call site in this
// file resolves exactly as before.

/// Rewrite the file with the explicit protection-class option.
/// `Data.write(to:options:)` honors
/// `completeFileProtectionUntilFirstUserAuthentication` even when
/// `setAttributes` cannot. While "Delete All My Data" runs the rewrite is
/// refused (`PurgeGate`), logged like any failed write.
private func rewriteWithProtection(at path: String) {
    guard let bytes = attempt("archive.protectionUpgrade.read", {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }) else { return }
    attempt("archive.protectionUpgrade.write") {
        try PurgeGate.admitWrite {
            try bytes.write(to: URL(fileURLWithPath: path), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
