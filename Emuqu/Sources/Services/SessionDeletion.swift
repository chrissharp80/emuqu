import Foundation

/// The way a screen moves a reading to the Trash: out of the archive, which
/// announces the change to every observer, and the deletion queued for iCloud
/// so the next pull does not bring it back. It throws when the archive could
/// not move the reading, so the screen can tell the user. The move (an index
/// rewrite and a file move, under the archive's lock) runs off the main actor.
@MainActor
struct SessionDeletion {
    let archive: SessionArchive
    let cloudKit: CloudKitSyncManager

    func moveToTrash(_ sessionId: UUID) async throws {
        let archive = archive
        let removed = try await Task.detached(priority: .userInitiated) { try archive.delete(sessionId) }.value
        guard removed else { return }
        let cloudKit = cloudKit
        Task { await cloudKit.uploadDeletion(sessionId) }
    }
}
