import Foundation

// MARK: - Rewrites interrupted between the file and the index

// Rewriting an archived session replaces `<id>.json`, then saves the index
// with the new file's hash. A kill between the two leaves the index holding
// the old hash, and every read of the session fails its integrity check.
// The archive does not re-hash a mismatch on its own: a mismatch is also
// what real corruption looks like. So each rewrite leaves a marker,
// `<id>.rewriting`, for exactly as long as the two disagree; a marker found
// at launch names a file whose new bytes were written by this app, and that
// file is re-hashed if it still decodes as the session
// (`repairSessionHashIfDecodable`).

extension ArchiveStore {
    func interruptedRewriteMarker(for id: UUID) -> URL {
        archive.archiveDirectory.appendingPathComponent("\(id.uuidString).rewriting")
    }

    /// Left before a rewrite of an archived session. A marker that cannot be
    /// written is logged and the rewrite goes ahead: the save matters more
    /// than the repair of a kill during it.
    func markRewriteStarting(_ id: UUID) {
        attempt("Archive.markRewrite") { try Data().write(to: interruptedRewriteMarker(for: id), options: .atomic) }
    }

    /// Removed once the index holds the file's hash again (saved, or rolled
    /// back with the old file).
    func markRewriteSettled(_ id: UUID) {
        let marker = interruptedRewriteMarker(for: id)
        guard archive.fileManager.fileExists(atPath: marker.path) else { return }
        attempt("Archive.clearRewriteMark") { try archive.fileManager.removeItem(at: marker) }
    }
}

extension SessionArchive {
    /// At boot: re-hash each session a marker says was being rewritten when
    /// the app stopped. A marker stays when the file cannot be read yet
    /// (locked device) so the next launch tries again; it goes once the file
    /// is re-hashed, found to match, or found not to decode (that is real
    /// damage, and reads keep reporting it).
    func healInterruptedRewrites() {
        // With no index loaded every session reads as unarchived: the
        // markers wait for a launch that has one.
        guard !indexReadFailed, !indexDecodeFailed else { return }
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: archiveDirectory.path)
        } catch {
            debugLog("[Archive] Could not list the archive for interrupted rewrites: \(error)", level: .warning)
            return
        }
        for name in names where name.hasSuffix(".rewriting") {
            guard let id = UUID(uuidString: String(name.dropLast(".rewriting".count))) else { continue }
            let result = repairSessionHashIfDecodable(sessionId: id)
            debugLog("[Archive] Interrupted rewrite of \(id.uuidString.prefix(8)): \(result)", level: .warning)
            if result != .notNow || !store.exists(id) { store.markRewriteSettled(id) }
        }
    }
}
