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
    /// Called with the session's id between the two writes of a change a
    /// kill can interrupt: a rewrite's file and its index save, a duplicate
    /// cleanup's tombstones and its index save. A test binds it to see what a
    /// kill there leaves on disk; nothing else binds it.
    @TaskLocal static var betweenFileAndIndex: (@Sendable (UUID) -> Void)?

    func interruptedRewriteMarker(for id: UUID) -> URL {
        state.archiveDirectory.appendingPathComponent("\(id.uuidString).rewriting")
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
        guard state.fileManager.fileExists(atPath: marker.path) else { return }
        attempt("Archive.clearRewriteMark") { try state.fileManager.removeItem(at: marker) }
    }

    /// Ask CloudKit sync to upload these sessions again. The request is kept
    /// on disk until sync has saved it (`ReuploadRequestJournal`). Each
    /// writer records it before its write as well, so a kill between the
    /// write and this post leaves the request for the next launch, as the
    /// marker above leaves the rewrite. Not under `archiveLock`: an observer
    /// may read the archive on the posting thread.
    func requestReupload(of ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        state.reuploadRequests.record(ids)
        NotificationCenter.default.post(
            name: .flowRecoveryArchiveSessionsNeedReupload, object: nil, userInfo: ["sessionIds": ids]
        )
    }
}
