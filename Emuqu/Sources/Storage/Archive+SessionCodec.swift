import CryptoKit
import Foundation

// The on-disk session file codec: encoding and decoding one session file, with
// its own compression and integrity handling, depending on nothing else in the
// archive beyond the shared coders.

extension SessionArchive {
    // MARK: - Session File Codec
    //
    // The encode → encrypt-if-available →
    // SHA256-hex write path is shared by four call sites (`_archive`,
    // `archiveBatch`, `relinkSameNightSessions`, plus the hash step of
    // `repairArchive`'s read side). As hand-rolled copies, one (relink)
    // diverged once in the field — hashing plaintext while writing
    // ciphertext — and broke every subsequent read. Centralizing the path
    // makes that class of drift structurally impossible.
    enum SessionFileCodec {
        /// Hex-encoded SHA256 of bytes exactly as they sit on disk. THE
        /// integrity contract: `_retrieve` hashes bytes-as-stored, so every
        /// write site hashes bytes-as-written (ciphertext when encryption
        /// ran, plaintext on fallback) and every index-rebuild site hashes
        /// the stored file untouched.
        static func sha256Hex(_ data: Data) -> String {
            SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        }

        /// Encode a session for disk: JSON-encode with the CALLER's
        /// encoder, encrypt when the encryption infrastructure is
        /// available, and hash the bytes-as-written.
        ///
        /// `encoder` is deliberately a parameter, NOT unified: `_archive`
        /// writes compact `sortedKeys` output while `archiveBatch` and the
        /// relink migration write `prettyPrinted + sortedKeys`.
        /// Files from those sites already hash differently on disk;
        /// unifying the encoder would change the bytes a re-write produces.
        /// Each call site keeps its own encoder.
        ///
        /// How the bytes came out, so the caller can react rather than guess.
        /// Reasoning in docs/adr/README.md, decision 001.
        enum DiskFormat: Equatable {
            case encrypted
            /// Encryption was unavailable. Bytes are readable JSON and MUST be
            /// written with `.completeFileProtection` and registered with
            /// `PendingEncryptionLedger`.
            case plaintextPendingEncryption
        }

        /// `onPlaintextFallback` runs when encryption is unavailable or the
        /// encrypt call fails — each call site keeps its own warn log
        /// (`_archive` and `archiveBatch` log; relink historically did not).

        static func encodeForDisk(
            _ session: HRVSession,
            encoder: JSONEncoder,
            onPlaintextFallback: () -> Void = {}
        ) throws -> (bytes: Data, hash: String, format: DiskFormat) {
            // Drain in an autoreleasepool. This is the single
            // biggest transient in the overnight-stop path: encoding an
            // HRVSession carrying the full night's rrSeries + artifactFlags
            // (~30k structs each) builds a large boxed JSONEncoder object-tree,
            // and encrypt() allocates a second full copy of the plaintext. On a
            // background Task the enclosing pool may not drain until the task
            // yields, so this tree lingered and stacked with the raw-backup and
            // CloudKit encodes → the 229–314 MB spike iOS SIGKILLed. Draining
            // here frees it immediately. No behavior change — same bytes, same hash.
            try autoreleasepool {
                let plaintext = try encoder.encode(session)
                if let encrypted = encryptOrReportFailure(plaintext, onFailure: onPlaintextFallback) {
                    return (encrypted, sha256Hex(encrypted), .encrypted)
                }
                return (plaintext, sha256Hex(plaintext), .plaintextPendingEncryption)
            }
        }
    }

    /// Mirror two sleep fields from the frozen snapshot into the lightweight
    /// index so the history list doesn't need to load the full session to
    /// know (a) when sleep actually ended and (b) whether the sleep was
    /// split. Reads HealthKit's own values straight through — no gap
    /// heuristics, no re-derivation, no "effective segments" enhancement.
    /// When Apple Health has already told us the sleep was one continuous
    /// block, we report one block.
    static func deriveSleepIndexFields(from session: HRVSession) -> (sleepEnd: Date?, sleepSegmentCount: Int?) {
        (sleepEnd(of: session), sleepSegmentCount(of: session))
    }

    /// The snapshot's own sleep end, or the stored offset converted to a date.
    private static func sleepEnd(of session: HRVSession) -> Date? {
        if let snapshotEnd = session.sleepSnapshot?.sleepEnd { return snapshotEnd }
        guard let endMs = session.sleepEndMs, endMs > 0 else { return nil }
        return session.startDate.addingTimeInterval(TimeInterval(endMs) / 1000)
    }

    private static func sleepSegmentCount(of session: HRVSession) -> Int? {
        // Prefer HealthKit's raw segments when present. These reflect
        // what the Watch actually reported; we don't re-segment them.
        if let snapshot = session.sleepSnapshot, !snapshot.segments.isEmpty {
            return snapshot.segments.count
        }
        // No HK segments — fall back to anything stored on the session
        // (set at acceptance time when HK data was available).
        if let stored = session.sleepSegments, !stored.isEmpty {
            return stored.count
        }
        // A snapshot exists but had no segment list — treat as one
        // block (the sleepStart/sleepEnd define the single envelope).
        return session.sleepSnapshot != nil ? 1 : nil
    }
}

/// Encrypt, or report why not. Never swallows the reason.
///
/// The previous form was `try? AppDependencies.current.storage.encryptionManager.encrypt(...)`,
/// which discarded the error entirely — so a genuine encryption defect
/// and a locked Keychain were indistinguishable in the logs, and both
/// looked like "encryption unavailable".
private func encryptOrReportFailure(_ plaintext: Data, onFailure: () -> Void) -> Data? {
    let manager = AppDependencies.current.storage.encryptionManager
    guard manager.isAvailable else {
        onFailure()
        return nil
    }
    do {
        return try manager.encrypt(plaintext)
    } catch {
        debugLog("[Archive] encrypt failed, falling back pending re-encryption: \(error)", level: .error)
        onFailure()
        return nil
    }
}
