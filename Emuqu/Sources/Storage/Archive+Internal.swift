import CryptoKit
import Foundation

// The archive's internals. The underscored and private helpers assume the
// caller already holds `archive.archiveLock`; the public entry points further
// down (`exists`, `delete`, `archiveBatch`, …) take it themselves.
// `Archive.swift` is the public API and its initialisation.

extension ArchiveStore {
    // MARK: - Internal Methods (caller must hold archive.archiveLock)

    /// Internal archive — caller must hold archive.archiveLock.
    @discardableResult
    func _archive(_ session: HRVSession, skipSameNightMerge: Bool = false) throws -> SessionArchiveEntry {
        try guardWritable(session)
        let session = preservingRRSeries(session)
        if let handled = try sameNightMerge(of: session, skipSameNightMerge: skipSameNightMerge) {
            return handled
        }
        return try writeAndIndex(session)
    }

    /// Refuse writes that would destroy data.
    ///
    /// Prevent re-archiving sessions that were intentionally deleted —
    /// CloudKit sync can race with local deletes and try to re-add the session.
    ///
    /// Schema-version write gate. A payload from a NEWER
    /// schema (e.g. a v2 session pulled from CloudKit onto an older build)
    /// decodes lossily on this build: unknown v2-only keys are silently
    /// dropped by `decodeIfPresent`. Display is fine, but re-archiving
    /// that lossy copy would overwrite the on-disk/cloud file and
    /// permanently destroy the v2-only fields. Refuse the write; the
    /// newer build that understands the payload remains its only writer.
    private func guardWritable(_ session: HRVSession) throws {
        if archive.deletedSessionIds.contains(session.id) {
            debugLog("[Archive] Blocked re-archive of deleted session \(session.id.uuidString.prefix(8))")
            throw SessionArchive.ArchiveError.sessionWasDeleted
        }
        if let v = session.sourceSchemaVersion, v > HRVSession.currentSchemaVersion {
            debugLog("[Archive] Blocked re-archive of session \(session.id.uuidString.prefix(8)) from newer schema v\(v) (this build writes v\(HRVSession.currentSchemaVersion)) — re-encoding would destroy fields this build can't decode", level: .warning)
            throw SessionArchive.ArchiveError.newerSchemaVersion(v)
        }
    }

    /// Defensive rrSeries preservation. Many callers
    /// (sleep refresh, morning feeling, subjective rescore,
    /// sleep-snapshot writes) load sessions via
    /// `retrieveLightweight` for performance, mutate a small field,
    /// and re-archive the result. The lightweight load sets
    /// `rrSeries = nil` on purpose — but then re-archiving would
    /// OVERWRITE the on-disk file with a copy that has no rrSeries,
    /// permanently destroying the strap's beat-by-beat data. The
    /// user-visible symptom: HRV detail charts show "No RR series"
    /// for sessions that were originally recorded with a strap.
    ///
    /// Fix: detect (incoming.rrSeries == nil) AND (an existing file
    /// has a non-nil rrSeries) — if so, splice the existing rrSeries
    /// back onto the incoming session before encoding. The caller's
    /// intent is "update the metadata I touched, leave the rest" —
    /// not "drop the heavyweight payload."
    ///
    /// The splice must not fail SILENTLY when
    /// `_retrieve` throws (stale archive.index hash after an interrupted
    /// write, decrypt failure, EPERM): the re-archive would then
    /// overwrite the file with rrSeries=nil — permanently
    /// destroying the night's beat data, the exact loss this
    /// block exists to prevent. The common failure
    /// is a stale HASH with perfectly decodable bytes, so fall
    /// back to the hash-agnostic reader; the write below then
    /// heals the archive.index hash too.
    private func preservingRRSeries(_ session: HRVSession) -> HRVSession {
        guard session.rrSeries == nil, archive.index.contains(where: { $0.sessionId == session.id }) else {
            return session
        }
        var session = session
        switch storedRRSeries(for: session.id) {
        case .preserved(let beats, let viaRawDecode):
            session.rrSeries = beats
            guard viaRawDecode else { break }
            debugLog("[Archive] rrSeries splice: hash-checked retrieve failed for \(session.id.uuidString.prefix(8)); raw decode salvaged \(beats.points.count) beats — re-archive heals the hash", level: .warning)
        case .noBeatsStored:
            break
        case .unreadable:
            debugLog("[Archive] ⚠️ rrSeries splice FAILED for \(session.id.uuidString.prefix(8)) — existing file unreadable by hash-checked AND raw readers; re-archiving without beat data (it was already unrecoverable on disk)", level: .error)
        }
        return session
    }

    /// What the stored copy of a session actually turned out to hold.
    ///
    /// Three outcomes, not two. The version of this that had two conflated the
    /// last two, and reported "existing file unreadable by hash-checked AND raw
    /// readers … already unrecoverable on disk" whenever the file read
    /// perfectly well and simply had no beats in it.
    ///
    /// That is not a rare shape. It is every workout recorded without a chest
    /// strap, every GPX or Apple Health import, and every recording that died
    /// before its first beat — and each of them logged a data-loss error, at
    /// `.error` level, into the user-facing Recent Problems list, on every
    /// re-archive. A field log did exactly this for a one-second walk that had
    /// captured nothing, and the message sent the reader hunting a storage
    /// fault that had never happened.
    enum StoredRRSeries {
        /// Beats found. `viaRawDecode` is true when the hash-checked read
        /// failed and the hash-agnostic reader rescued them — worth saying,
        /// because the re-archive then heals the stale hash.
        case preserved(RRSeries, viaRawDecode: Bool)
        /// The file read fine and held no beats. Nothing to preserve, nothing
        /// wrong.
        case noBeatsStored
        /// Neither reader could open the file. The real failure.
        case unreadable
    }

    func storedRRSeries(for id: UUID) -> StoredRRSeries {
        if let existing = try? _retrieve(id) {
            return existing.rrSeries.map { .preserved($0, viaRawDecode: false) } ?? .noBeatsStored
        }
        guard let entry = archive.index.first(where: { $0.sessionId == id }),
              let salvaged = try? Self.loadAndDecodeSessionFile(
                  at: archive.resolveFileURL(for: entry),
                  decoder: SessionArchive.sessionDecoder
              )
        else { return .unreadable }
        return salvaged.rrSeries.map { .preserved($0, viaRawDecode: true) } ?? .noBeatsStored
    }

    /// Prevent same-night overnight duplicates with different UUIDs.
    /// If this is a NEW overnight session (not a re-archive of one we already have)
    /// and another overnight session from the same recovery night already exists,
    /// merge data into the existing session instead of creating a duplicate.
    /// Skip when session has linkedSessionIds — that's an explicit split-sleep
    /// segment (from supersedeSameNightSession), not a sync duplicate.
    ///
    /// Returns the resulting entry when the merge path handled the archive, or
    /// nil when the caller should write `session` standalone.
    ///
    /// The diagnostic log below is for the "yesterday's session
    /// is gone" report. When it fires, the NEW session's UUID is discarded and
    /// its data is merged into `existing`. The resulting archive entry is keyed
    /// by the OLDER session's UUID and date — which is why a fresh recording
    /// can appear to "vanish" if it gets folded into an older placeholder-style
    /// entry. Surfacing it in the log lets us confirm the cause from a trace.
    /// A archive.retrieve failure on the existing same-night session (transient
    /// decrypt/decode failure, say) must NOT fall through to the standalone
    /// write — that would create the exact same-night duplicate this exists to
    /// prevent. It throws instead. Returning the existing entry reported the
    /// new night as archived while its beats went nowhere: every caller then
    /// flagged the raw backup archived and cleared the recording marker,
    /// leaving the night in a backup due for deletion. Thrown, the callers
    /// skip both, so the backup stays unarchived and Lost Sessions can recover
    /// the night once the read succeeds.
    private func sameNightMerge(
        of session: HRVSession, skipSameNightMerge: Bool
    ) throws -> SessionArchiveEntry? {
        let isReArchive = archive.index.contains { $0.sessionId == session.id }
        let hasExplicitLinks = !(session.linkedSessionIds ?? []).isEmpty
        guard !isReArchive, !skipSameNightMerge, session.sessionType == .overnight,
              !hasExplicitLinks, archive.sessionMergeModeProvider() != .off,
              let existing = sameNightEntry(for: session.startDate, excluding: session.id)
        else { return nil }
        debugLog("[Archive] sameNightMerge: folding new session \(session.id.uuidString.prefix(8)) (start=\(session.startDate), score=\(session.recoveryScore.map { String(format: "%.2f", $0) } ?? "nil")) into existing \(existing.sessionId.uuidString.prefix(8)) (date=\(existing.date), score=\(existing.recoveryScore.map { String(format: "%.2f", $0) } ?? "nil")) — new UUID will be discarded", level: .warning)
        do {
            guard var existingSession = try _retrieve(existing.sessionId) else { return nil }
            _ = archive.mergeSessionData(from: session, into: &existingSession)
            // Re-archive the merged existing session (this is a re-archive, won't recurse)
            return try _archive(existingSession)
        } catch {
            debugLog("[Archive] sameNightMerge: failed to retrieve session \(existing.sessionId.uuidString.prefix(8)): \(error) — not archiving the new session this pass", level: .warning)
            throw error
        }
    }

    /// Write the session file, then update and persist the archive.index.
    ///
    /// Write to file atomically, with an explicit protection-class option in
    /// addition to `.atomic`. The directory-level `setAttributes`
    /// in `createArchiveDirectoryIfNeeded` does NOT propagate to NEW files in
    /// all iOS versions, because `.atomic` writes go through a temp file +
    /// rename and the rename can drop the inherited attribute. The user's
    /// debug log (hrv_debug_log_1778148804.txt) showed 1,557 EPERM read
    /// failures over 7 days against just-written session files — root cause
    /// was the new file being written with the strict default protection class
    /// even though the directory was already downgraded. Setting the option
    /// explicitly here bypasses the inheritance gap.
    ///
    /// If the archive.index save fails, roll back both the in-memory mutation and the
    /// file write so the archive doesn't end up with an orphan file on disk
    /// and a stale archive.index. (A hard crash between the file write and archive.index save
    /// still leaves an orphan; `reconcileOrphanFiles()` on the next launch
    /// picks those up.)
    /// A previous file that exists but cannot be read aborts the write:
    /// without its bytes, a failed index save would roll the old entry back
    /// over the new file, and the session would fail its hash check.
    ///
    /// The archive entry stores the relative filename, not an absolute path.
    /// All archive.index fields (incl. meanSDNN + the sleep-stage/dip mirrors) are
    /// populated by the shared factory; see SessionArchiveEntry.make.
    private func writeAndIndex(_ session: HRVSession) throws -> SessionArchiveEntry {
        let fileName = "\(session.id.uuidString).json"
        let filePath = archive.archiveDirectory.appendingPathComponent(fileName)
        let (data, hashString, writeOptions) = try encodedForDisk(session)
        // Snapshot pre-write state so we can roll back on failure.
        let preIndex = archive.index
        let preFileExisted = archive.fileManager.fileExists(atPath: filePath.path)
        let preFileData: Data? = preFileExisted ? try Data(contentsOf: filePath) : nil
        try data.write(to: filePath, options: writeOptions)
        let entry = SessionArchiveEntry.make(from: session, hash: hashString, filePath: fileName)
        archive.index.removeAll { $0.sessionId == session.id }
        archive.index.append(entry)
        do {
            try archive.saveIndex()
        } catch {
            rollBackWrite(to: preIndex, filePath: filePath, previousData: preFileData, existed: preFileExisted)
            throw error
        }
        return entry
    }

    /// Encode session via the shared write encoder. `sortedKeys` keeps
    /// byte output deterministic so file hashes are stable across build
    /// configs — see SessionArchive.sessionEncoder doc for the integrity contract.
    ///
    /// Encrypt before disk-write so HRV samples
    /// aren't readable from a filesystem image / device backup. Falls
    /// back to plaintext if the encryption infrastructure isn't
    /// available on this device (rare — would require Keychain failure).
    /// Hash is over the bytes-as-written so the existing integrity
    /// contract still works on read for both formats, and is computed
    /// from the encoded bytes (avoids re-reading from disk).
    private func encodedForDisk(_ session: HRVSession) throws -> (Data, String, Data.WritingOptions) {
        let result = try SessionArchive.SessionFileCodec.encodeForDisk(session, encoder: SessionArchive.sessionEncoder)
        return (result.bytes, result.hash, archiveWriteOptions(for: result.format, sessionID: session.id))
    }

    /// Restore the pre-write state after a failed archive.index save.
    ///
    /// `archive.saveIndex()` nils the derived caches before persisting; on a failed
    /// save we restore `archive.index` but must also drop those caches so a stale
    /// archive.sortedEntriesCache/archive.sessionIdLookup can't keep serving the rolled-back
    /// entry. If the file rollback itself fails, the on-disk archive.index is left
    /// mid-write while the in-memory one has been restored — the one
    /// divergence in this file a later read cannot detect, so it must be loud.
    private func rollBackWrite(
        to preIndex: [SessionArchiveEntry], filePath: URL, previousData: Data?, existed: Bool
    ) {
        archive.index = preIndex
        archive.sortedEntriesCache = nil
        archive.sessionIdLookup = nil
        if let previous = previousData {
            attempt("archive.index.rollbackWrite") {
                try previous.write(to: filePath, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        } else if !existed {
            attempt("archive.index.rollbackRemove") {
                try archive.fileManager.removeItem(at: filePath)
            }
        }
    }

    /// Internal archive.retrieve — caller must hold archive.archiveLock.
    func _retrieve(_ id: UUID) throws -> HRVSession? {
        guard let entry = entryById(id) else {
            return nil
        }
        let rawBytes = try readSessionBytes(for: entry, id: id)
        try verifyHash(of: rawBytes, against: entry, id: id)
        let plaintext = try Self.plaintextBytes(rawBytes, id: id)
        do {
            return try SessionArchive.sessionDecoder.decode(HRVSession.self, from: plaintext)
        } catch {
            debugLog("[Archive] ERROR: Could not decode session \(id): \(error)")
            throw error
        }
    }

    /// The session file's bytes as stored. Resolves both relative (new) and
    /// absolute (legacy) archive.index paths.
    private func readSessionBytes(for entry: SessionArchiveEntry, id: UUID) throws -> Data {
        let fileURL = archive.resolveFileURL(for: entry)
        guard archive.fileManager.fileExists(atPath: fileURL.path) else {
            debugLog("[Archive] ERROR: File not found for session \(id)")
            debugLog("[Archive] Session date: \(entry.date)")
            throw SessionArchive.ArchiveError.fileNotFound
        }
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            debugLog("[Archive] ERROR: Could not read file for session \(id): \(error)")
            throw error
        }
    }

    /// Detect encrypted vs legacy-plaintext via
    /// EncryptionManager's magic prefix (0x46 0x52 = "FR"). Encrypted
    /// files are decrypted to plaintext JSON; legacy files are passed
    /// through unchanged. Re-encryption-on-next-write handles
    /// forward migration without a one-shot batch step.
    ///
    /// Also accepts legacy Format 2 / Format 3 files that
    /// pre-date the `"FR"` magic prefix (see `loadAndDecodeSessionFile`
    /// for the full breakdown). If the file doesn't start with JSON
    /// whitespace, try decrypt before declaring it corrupt.
    static func plaintextBytes(_ rawBytes: Data, id: UUID) throws -> Data {
        if looksEncrypted(rawBytes) {
            do {
                return try AppDependencies.current.storage.encryptionManager.decrypt(rawBytes)
            } catch {
                debugLog("[Archive] ERROR: decrypt failed for session \(id): \(error)")
                throw error
            }
        }
        if looksLikeJSON(rawBytes) { return rawBytes }
        return (try? AppDependencies.current.storage.encryptionManager.decrypt(rawBytes)) ?? rawBytes
    }

    /// Detect EncryptionManager-versioned encrypted files via the "FR"
    /// magic prefix. Used as a fast-path hint by `loadAndDecodeSessionFile`;
    /// the actual decode path also falls back to a decrypt attempt for
    /// pre-magic legacy formats whose first byte happens to not be `{`/`[`.
    static func looksEncrypted(_ data: Data) -> Bool {
        data.count >= 2 && data[0] == 0x46 && data[1] == 0x52
    }

    /// JSON always starts with `{`, `[`, whitespace, or BOM. If the first
    /// non-whitespace byte is anything else, the file is almost certainly
    /// binary-encoded — either the new "FR" format OR one of the two
    /// legacy AES-GCM formats (Format 2 version-prefixed, Format 3 bare).
    /// Used to drive the legacy-decrypt fallback in `loadAndDecodeSessionFile`.
    static func looksLikeJSON(_ data: Data) -> Bool {
        for byte in data.prefix(8) {
            switch byte {
            case 0x09, 0x0A, 0x0D, 0x20: continue // tab, LF, CR, space
            case 0xEF: continue // BOM first byte
            case 0x7B, 0x5B: return true // '{' or '['
            default: return false
            }
        }
        return false
    }

    /// Shared by `_retrieve`/`retrieveLightweight` and the
    /// migration paths in `Archive+Migrations.swift`, so migrations read the SAME
    /// dual-format files those paths handle. A migration that
    /// does `try decoder.decode(HRVSession.self, from: Data(contentsOf:))`
    /// directly fails on encrypted files with
    /// "Unexpected character 'F' around line 1, column 1." (the magic
    /// prefix's first byte), silently skipping
    /// encrypted sessions and spamming the launch log with dozens of
    /// these errors. Centralizing the read avoids the bug AND keeps
    /// future migrations honest about the on-disk format.
    ///
    /// Wider than `looksEncrypted`, which only matches
    /// Format 1 (the `"FR"` magic prefix), but `EncryptionManager.decrypt`
    /// supports three formats (see `extractVersion`):
    ///   1. Magic-prefixed   `[0x46, 0x52, version, ...AES-GCM]` — current
    ///   2. Version-prefixed `[version(1-127), ...AES-GCM]` — legacy v1
    ///   3. Bare             `[...AES-GCM]` — legacy v0
    /// Formats 2 and 3 don't carry the magic bytes, so `looksEncrypted`
    /// returns false and the loader tried to JSON-decode raw ciphertext,
    /// failing with "Unexpected character 'F' around line 1, column 1."
    /// for any session whose first ciphertext byte happened to be 0x46.
    /// Four of Sachie's sessions (E27E41B7, 4C7EB19E, 9234A6B5, C1DC9488)
    /// were stuck permanently unreadable for exactly this reason — they
    /// loaded 84 times across her 7-day log window and failed every time.
    /// Fix: if the file doesn't look like JSON, attempt decrypt before
    /// declaring it corrupt.
    static func loadAndDecodeSessionFile(at fileURL: URL, decoder: JSONDecoder) throws -> HRVSession {
        let rawBytes = try Data(contentsOf: fileURL)
        let plaintext: Data
        if looksEncrypted(rawBytes) {
            plaintext = try AppDependencies.current.storage.encryptionManager.decrypt(rawBytes)
        } else if looksLikeJSON(rawBytes) {
            plaintext = rawBytes
        } else {
            // Not JSON, not the new magic-prefixed format — try the
            // legacy AES-GCM decryptors before giving up. Catches
            // Format 2 / Format 3 files that pre-date the `"FR"` magic.
            do {
                plaintext = try AppDependencies.current.storage.encryptionManager.decrypt(rawBytes)
            } catch {
                // Fall through: hand the raw bytes to JSONDecoder so the
                // existing dataCorrupted error path produces the same
                // diagnostic it always did (caller's log expects it).
                plaintext = rawBytes
            }
        }
        return try decoder.decode(HRVSession.self, from: plaintext)
    }

    /// Load linked session time ranges for split-night display.
    /// Returns nil if the session has no linked sessions.
    func linkedSegments(for session: HRVSession) -> [LinkedSegmentInfo]? {
        guard let linkedIds = session.linkedSessionIds, !linkedIds.isEmpty else { return nil }
        let segments = linkedIds.compactMap { segmentInfo(forLinked: $0) }
        let normalized = Self.normalizedSplitNightSegments(
            currentSessionId: session.id,
            currentStartDate: session.startDate,
            currentEndDate: session.endDate ?? session.startDate,
            linkedSegments: segments
        )
        // Preserve existing API contract: linked ranges only (exclude current session).
        let linkedOnly = normalized.filter { $0.id != session.id }
        return linkedOnly.isEmpty ? nil : linkedOnly
    }

    /// One linked session's span. Nil when it can't be read, or when its end
    /// doesn't advance past its start (nothing to contribute to the night).
    private func segmentInfo(forLinked linkedId: UUID) -> LinkedSegmentInfo? {
        do {
            guard let linked = try archive.retrieve(linkedId) else { return nil }
            let end = linked.endDate ?? linked.startDate
            guard end > linked.startDate else { return nil }
            return LinkedSegmentInfo(id: linked.id, startDate: linked.startDate, endDate: end)
        } catch {
            debugLog("[Archive] linkedSegments: failed to retrieve linked session \(linkedId.uuidString.prefix(8)): \(error)", level: .warning)
            return nil
        }
    }

    /// Segments shorter than this are recording artifacts, not sleep.
    private static let minMeaningfulSegment: TimeInterval = 10 * 60
    /// Two ranges whose ends are within this of each other are the same range.
    private static let duplicateTolerance: TimeInterval = 5 * 60

    /// Normalize split-night ranges by:
    /// - deriving the current session's unique segment
    /// - dropping tiny artifacts (<10m)
    /// - collapsing near-identical and fully-contained overlaps
    /// Returns all meaningful segments, including the current session segment.
    static func normalizedSplitNightSegments(
        currentSessionId: UUID,
        currentStartDate: Date,
        currentEndDate: Date,
        linkedSegments: [LinkedSegmentInfo]
    ) -> [LinkedSegmentInfo] {
        guard currentEndDate > currentStartDate else { return [] }
        let currentSegment = ownSegment(
            id: currentSessionId,
            start: currentStartDate,
            end: currentEndDate,
            linkedSegments: linkedSegments
        )
        let rawSegments = ((currentSegment.map { [$0] } ?? []) + linkedSegments)
            .filter { $0.endDate.timeIntervalSince($0.startDate) >= minMeaningfulSegment }
            .sorted { $0.startDate < $1.startDate }
        return mergeAdjacent(dedupeOverlaps(rawSegments))
    }

    /// The stretch of the night that belongs to THIS session rather than to
    /// one of its linked segments. Nil when that stretch is too short to
    /// count. Linked segments ending before the current one ends is the
    /// child/merged case; linked segments starting after the current start is
    /// the parent case; anything else falls back to the current boundaries.
    private static func ownSegment(
        id: UUID, start: Date, end: Date, linkedSegments: [LinkedSegmentInfo]
    ) -> LinkedSegmentInfo? {
        let segmentStart: Date
        let segmentEnd: Date
        if let linkedEnd = linkedSegments.map(\.endDate).max(), linkedEnd > start, linkedEnd < end {
            segmentStart = linkedEnd
            segmentEnd = end
        } else if let linkedStart = linkedSegments.map(\.startDate).min(), linkedStart > start {
            segmentStart = start
            segmentEnd = min(end, linkedStart)
        } else {
            segmentStart = start
            segmentEnd = end
        }
        guard segmentEnd.timeIntervalSince(segmentStart) >= minMeaningfulSegment else { return nil }
        return LinkedSegmentInfo(id: id, startDate: segmentStart, endDate: segmentEnd)
    }

    /// Collapse near-identical and fully-contained ranges, keeping the longer
    /// of each pair. `segments` must be sorted by start date.
    private static func dedupeOverlaps(_ segments: [LinkedSegmentInfo]) -> [LinkedSegmentInfo] {
        var deduped: [LinkedSegmentInfo] = []
        for candidate in segments {
            guard let last = deduped.last else {
                deduped.append(candidate)
                continue
            }
            switch overlapVerdict(candidate: candidate, last: last) {
            case .keepLonger: replaceIfLonger(&deduped, with: candidate, over: last)
            case .distinct: deduped.append(candidate)
            }
        }
        return deduped
    }

    private static func replaceIfLonger(
        _ deduped: inout [LinkedSegmentInfo],
        with candidate: LinkedSegmentInfo,
        over last: LinkedSegmentInfo
    ) {
        guard duration(candidate) > duration(last) else { return }
        deduped[deduped.count - 1] = candidate
    }

    /// Whether two ranges describe the same segment (so only the longer
    /// survives) or two genuinely different ones.
    private enum OverlapVerdict {
        case keepLonger
        case distinct
    }

    /// Legacy duplicate ranges may drift by more than `duplicateTolerance`
    /// while still representing the same segment, so a mostly-overlapping pair
    /// counts as duplicate too, as does either range containing the other.
    private static func overlapVerdict(
        candidate: LinkedSegmentInfo, last: LinkedSegmentInfo
    ) -> OverlapVerdict {
        let startsClose = abs(candidate.startDate.timeIntervalSince(last.startDate)) <= duplicateTolerance
        let endsClose = abs(candidate.endDate.timeIntervalSince(last.endDate)) <= duplicateTolerance
        if startsClose, endsClose { return .keepLonger }
        if mostlyOverlapping(candidate, last) { return .keepLonger }
        let candidateInsideLast =
            candidate.startDate >= last.startDate.addingTimeInterval(-duplicateTolerance) &&
            candidate.endDate <= last.endDate.addingTimeInterval(duplicateTolerance)
        let lastInsideCandidate =
            last.startDate >= candidate.startDate.addingTimeInterval(-duplicateTolerance) &&
            last.endDate <= candidate.endDate.addingTimeInterval(duplicateTolerance)
        return candidateInsideLast || lastInsideCandidate ? .keepLonger : .distinct
    }

    private static func mostlyOverlapping(_ a: LinkedSegmentInfo, _ b: LinkedSegmentInfo) -> Bool {
        let overlapStart = max(a.startDate, b.startDate)
        let overlapEnd = min(a.endDate, b.endDate)
        let overlapSeconds = overlapEnd.timeIntervalSince(overlapStart)
        guard overlapSeconds > 0 else { return false }
        let shorterDuration = min(duration(a), duration(b))
        guard shorterDuration > 0 else { return false }
        return overlapSeconds / shorterDuration >= SessionArchive.Tuning.duplicateContainmentRatio
    }

    private static func duration(_ segment: LinkedSegmentInfo) -> TimeInterval {
        segment.endDate.timeIntervalSince(segment.startDate)
    }

    /// Merge temporally-adjacent segments. A pause/resume during a single
    /// continuous night of sleep produces N linked recording segments with
    /// sub-minute gaps between them — that's one sleep segment, not N. A
    /// true split-night requires the user to have actually been up for a
    /// while (same threshold the sleep-stage merger uses for awake gaps).
    private static func mergeAdjacent(_ segments: [LinkedSegmentInfo]) -> [LinkedSegmentInfo] {
        let continuityThreshold = Double(SleepConstants.defaultSplitGapMinutes) * 60
        var merged: [LinkedSegmentInfo] = []
        for segment in segments {
            guard let last = merged.last else {
                merged.append(segment)
                continue
            }
            guard segment.startDate.timeIntervalSince(last.endDate) < continuityThreshold else {
                merged.append(segment)
                continue
            }
            // Extend the previous segment's end to cover this one.
            merged[merged.count - 1] = LinkedSegmentInfo(
                id: last.id,
                startDate: last.startDate,
                endDate: max(last.endDate, segment.endDate)
            )
        }
        return merged
    }

    /// O(1) lookup of an archive entry by session ID. Caller must hold archive.archiveLock.
    func entryById(_ id: UUID) -> SessionArchiveEntry? {
        if let lookup = archive.sessionIdLookup {
            return lookup[id]
        }
        let built = Dictionary(archive.index.map { ($0.sessionId, $0) }, uniquingKeysWith: { _, last in last })
        archive.sessionIdLookup = built
        return built[id]
    }

    /// Get all archive entries (cached sort — invalidated on every `archive.saveIndex()`)
    var entries: [SessionArchiveEntry] {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        if let cached = archive.sortedEntriesCache {
            return cached
        }
        let sorted = archive.index.sorted { $0.date > $1.date }
        archive.sortedEntriesCache = sorted
        return sorted
    }

    /// Get entries filtered by tags
    /// - Parameters:
    ///   - includeTags: Only include entries with at least one of these tags (empty = include all)
    ///   - excludeTags: Exclude entries with any of these tags
    func entries(includingTags includeTags: [ReadingTag], excludingTags excludeTags: [ReadingTag] = []) -> [SessionArchiveEntry] {
        let includeIds = Set(includeTags.map(\.id))
        let excludeIds = Set(excludeTags.map(\.id))

        return entries.filter { entry in
            // Check exclusion first
            let entryTagIds = Set(entry.tags.map(\.id))
            if !excludeIds.isEmpty, !excludeIds.isDisjoint(with: entryTagIds) {
                return false
            }

            // Check inclusion
            if includeIds.isEmpty {
                return true
            }
            return !includeIds.isDisjoint(with: entryTagIds)
        }
    }

    /// Get entries for a specific date range
    func entries(from startDate: Date, to endDate: Date) -> [SessionArchiveEntry] {
        entries.filter { $0.date >= startDate && $0.date <= endDate }
    }

    /// Check if a session exists in archive
    func exists(_ id: UUID) -> Bool {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        return archive.index.contains { $0.sessionId == id }
    }

    /// Check if a session exists near a given date (within tolerance window)
    /// Used to determine if H10 data has already been archived
    func hasSessionNear(date: Date, toleranceMinutes: Int = 30) -> Bool {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        let tolerance = TimeInterval(toleranceMinutes * 60)
        let windowStart = date.addingTimeInterval(-tolerance)
        let windowEnd = date.addingTimeInterval(tolerance)
        return archive.index.contains { $0.date >= windowStart && $0.date <= windowEnd }
    }

    /// Delete an archived session (moves to trash, tracks as intentionally deleted)
    ///
    /// Diagnostic: every delete leaves a breadcrumb
    /// in the log naming the session, its date, its type, and its
    /// recovery score. If a session goes missing from history
    /// (a real user report), grepping the log for
    /// `[Archive] delete:` will say whether the deletion was a user
    /// action / migration / sync conflict and exactly when it ran.
    func delete(_ id: UUID) throws {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        guard let entry = entryById(id) else {
            return
        }
        let scoreStr = entry.recoveryScore.map { String(format: "%.1f", $0) } ?? "nil"
        debugLog("[Archive] delete: \(id.uuidString.prefix(8)) date=\(entry.date) type=\(entry.sessionType.rawValue) score=\(scoreStr)", level: .warning)
        try dropFromIndex(entry)
        moveToTrash(archive.resolveFileURL(for: entry), id: id)
    }

    /// Remove from the active archive.index (in-memory) then persist both indexes.
    /// If archive.saveIndex fails, roll back both in-memory changes so neither the
    /// deleted set nor the archive.index are left in an inconsistent state.
    ///
    /// `archive.saveIndex()` nils the derived caches before persisting; drop them on
    /// the rollback path too so a stale archive.sortedEntriesCache/archive.sessionIdLookup
    /// can't keep serving (or hiding) the rolled-back entry.
    private func dropFromIndex(_ entry: SessionArchiveEntry) throws {
        archive.index.removeAll { $0.sessionId == entry.sessionId }
        archive.deletedSessionIds.insert(entry.sessionId)
        Self.recordDeletionTime(entry.sessionId)
        do {
            try archive.saveIndex()
            try archive.saveDeletedIndex()
        } catch {
            archive.index.append(entry)
            archive.deletedSessionIds.remove(entry.sessionId)
            archive.sortedEntriesCache = nil
            archive.sessionIdLookup = nil
            throw error
        }
    }

    /// Check if a session was intentionally deleted by the user
    func wasIntentionallyDeleted(_ id: UUID) -> Bool {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        return archive.deletedSessionIds.contains(id)
    }

    /// Get all intentionally deleted session IDs
    var deletedIds: Set<UUID> {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        return archive.deletedSessionIds
    }

    /// Remove a session from the deleted list (for trash restore)
    func unmarkAsDeleted(_ id: UUID) throws {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        archive.deletedSessionIds.remove(id)
        Self.forgetDeletionTime(id)
        try archive.saveDeletedIndex()
    }

    /// Permanently forget a deleted session (removes from deleted tracking)
    func forgetDeletedSession(_ id: UUID) throws {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        archive.deletedSessionIds.remove(id)
        Self.forgetDeletionTime(id)
        try archive.saveDeletedIndex()
    }

    /// Mark a session as intentionally deleted (for lost sessions that user wants to dismiss)
    /// This adds the ID to the deleted tracking without requiring the session to be in the archive
    func markAsDeleted(_ id: UUID) throws {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        archive.deletedSessionIds.insert(id)
        Self.recordDeletionTime(id)
        try archive.saveDeletedIndex()
    }

    // MARK: - Deletion times

    /// When this device deleted each session. iCloud sync compares it with a
    /// restore made on another device: whichever happened later wins. Kept
    /// beside the deleted-id list rather than in it, so the list's on-disk
    /// format — read by every older build — is unchanged. Deletions made
    /// before this existed have no time, and lose to any restore, which can
    /// only have been made by a build new enough to write one.
    private static let deletionTimesKey = "archive.deletionTimes"

    func deletionTime(of id: UUID) -> Date? {
        (UserDefaults.standard.dictionary(forKey: Self.deletionTimesKey)?[id.uuidString] as? Double)
            .map(Date.init(timeIntervalSince1970:))
    }

    /// Every session this device recorded a deletion time for: what survives
    /// of the deleted list when its own file cannot be read.
    static func idsWithRecordedDeletionTime() -> Set<UUID> {
        Set((UserDefaults.standard.dictionary(forKey: deletionTimesKey) ?? [:]).keys.compactMap(UUID.init(uuidString:)))
    }

    static func recordDeletionTime(_ id: UUID) {
        var times = UserDefaults.standard.dictionary(forKey: deletionTimesKey) ?? [:]
        times[id.uuidString] = Date().timeIntervalSince1970
        UserDefaults.standard.set(times, forKey: deletionTimesKey)
    }

    private static func forgetDeletionTime(_ id: UUID) {
        guard var times = UserDefaults.standard.dictionary(forKey: deletionTimesKey) else { return }
        times.removeValue(forKey: id.uuidString)
        UserDefaults.standard.set(times, forKey: deletionTimesKey)
    }

    /// Clear all deleted session tracking
    func clearDeletedHistory() throws {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        archive.deletedSessionIds.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.deletionTimesKey)
        try archive.saveDeletedIndex()
    }

    /// Check if a session with a similar start time already exists
    /// Uses a 1-hour window to detect duplicates during import
    /// This allows multiple sessions per day while preventing true duplicates
    func sessionExists(for date: Date) -> Bool {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        let oneHour = SessionArchive.Tuning.importDuplicateWindow
        return archive.index.contains { entry in
            abs(entry.date.timeIntervalSince(date)) < oneHour
        }
    }

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

    /// Batch archive multiple sessions efficiently
    /// Writes all sessions first, then updates the archive.index once
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
            indexPartialBatch(outcome.newEntries)
            throw error
        }
        if !outcome.newEntries.isEmpty {
            archive.index.append(contentsOf: outcome.newEntries)
            try archive.saveIndex()
        }
        postBatchChangeNotifications(outcome)
        return outcome.newEntries.count + outcome.updatedIds.count
    }

    /// Files already written for a failed batch are indexed before the error
    /// goes up — a disk that filled halfway through an import otherwise left
    /// them on disk with nothing pointing at them.
    private func indexPartialBatch(_ newEntries: [SessionArchiveEntry]) {
        guard !newEntries.isEmpty else { return }
        archive.index.append(contentsOf: newEntries)
        _ = attempt("Archive.saveIndexAfterFailedBatch") { try archive.saveIndex() }
    }

    /// One session's turn through the batch: skip tombstones and duplicates,
    /// merge into a time-adjacent existing session, or write it out fresh.
    ///
    /// The tombstone gate mirrors `_archive`'s. Without it, a
    /// batch import (file restore, recovery flow) could silently resurrect
    /// sessions the user explicitly deleted.
    ///
    /// Duplicate detection uses time proximity (1 hour) rather than calendar
    /// day, which allows multiple legitimate sessions on the same day while
    /// still preventing true duplicates.
    private func archiveOne(_ session: HRVSession, into outcome: inout BatchOutcome) throws {
        if archive.deletedSessionIds.contains(session.id) {
            debugLog("[Archive] archiveBatch: skipping tombstoned session \(session.id.uuidString.prefix(8))")
            return
        }
        // Skip exact duplicates by ID
        if archive.index.contains(where: { $0.sessionId == session.id }) { return }
        let isNear = Self.isImportNeighbour(of: session)
        if let existingEntry = archive.index.first(where: isNear) {
            mergeIntoExisting(session, entry: existingEntry, outcome: &outcome)
            return
        }
        // Also check against sessions we're adding in this batch
        if outcome.newEntries.contains(where: isNear) {
            return
        }
        outcome.newEntries.append(try writeBatchSession(session))
    }

    /// An index entry close enough in time to be the same recording. Same type
    /// only: a quick reading imported 40 minutes after a workout was being
    /// spliced into the workout's beats.
    private static func isImportNeighbour(of session: HRVSession) -> (SessionArchiveEntry) -> Bool {
        let window = SessionArchive.Tuning.importDuplicateWindow
        return { entry in
            entry.sessionType == session.sessionType && abs(entry.date.timeIntervalSince(session.startDate)) < window
        }
    }

    /// Load the time-adjacent existing session and fold the incoming one into
    /// it. A read failure is logged and the incoming session dropped for this
    /// pass rather than written as a near-duplicate.
    private func mergeIntoExisting(
        _ session: HRVSession, entry: SessionArchiveEntry, outcome: inout BatchOutcome
    ) {
        do {
            guard var existingSession = try _retrieve(entry.sessionId) else { return }
            // Update with any new/better data from import
            guard archive.mergeSessionData(from: session, into: &existingSession) else { return }
            try _archive(existingSession)
            outcome.updatedIds.append(existingSession.id)
        } catch {
            debugLog("[Archive] Failed to update existing session: \(error)")
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
        let (data, hashString) = (result.bytes, result.hash)
        try data.write(to: filePath, options: archiveWriteOptions(for: result.format, sessionID: session.id))
        return SessionArchiveEntry.make(from: session, hash: hashString, filePath: fileName)
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

    /// Find an existing overnight entry from the same "recovery night" as the given date.
    /// Uses the user's sleep schedule so that sessions on the same biological night
    /// (e.g., 10 PM, 1 AM, 7 AM) share the same overnightWindowStart anchor.
    /// Caller must hold archive.archiveLock.
    func sameNightEntry(for date: Date, excluding sessionId: UUID) -> SessionArchiveEntry? {
        let sleepSchedule = archive.sleepScheduleProvider()
        let nightStart = sleepSchedule.overnightWindowStart(relativeTo: date)

        return archive.index.first { entry in
            guard entry.sessionType == .overnight,
                  entry.sessionId != sessionId else { return false }
            return sleepSchedule.overnightWindowStart(relativeTo: entry.date) == nightStart
        }
    }
}

// MARK: - File-scope helpers
//
// Each names no member of SessionArchive and calls nothing inside it, so
// none needs to be a member. `private` at file scope is fileprivate, so
// every call site in this file resolves.

/// Verify hash against the bytes-as-stored (whether they're encrypted
/// ciphertext or legacy plaintext JSON). This preserves the existing
/// tamper/integrity contract regardless of format.
///
/// Fails loudly on mismatch rather than silently "auto-repairing" by
/// accepting whatever decodes — that hides file corruption. Every
/// writer (including `relinkSameNightSessions`) recomputes the hash as
/// part of the write, so a mismatch here indicates real corruption or
/// tampering.
private func verifyHash(of rawBytes: Data, against entry: SessionArchiveEntry, id: UUID) throws {
    let hashString = SessionArchive.SessionFileCodec.sha256Hex(rawBytes)
    guard hashString != entry.fileHash else { return }
    debugLog("[Archive] ERROR: Hash mismatch for session \(id)")
    debugLog("[Archive] Expected: \(entry.fileHash)")
    debugLog("[Archive] Actual:   \(hashString)")
    debugLog("[Archive] File size: \(rawBytes.count) bytes")
    throw SessionArchive.ArchiveError.hashMismatch
}
