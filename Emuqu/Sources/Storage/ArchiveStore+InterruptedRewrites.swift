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
