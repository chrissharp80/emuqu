import Foundation

/// Duplicate-collection guard: `sessionExists` tells a recording that its
/// session id is already archived. Built once at launch with the collector,
/// it also removes the `HRVOffline` folder that older builds kept beside the
/// archive (`removeRetiredOfflineQueue`).
final class ReconciliationManager {
    // MARK: - Properties

    private let archive: SessionArchive

    // MARK: - Initialization

    /// Initialize with an explicit SessionArchive instance.
    /// Note: Do NOT use a default parameter here - callers must provide the shared archive
    /// instance to prevent multiple SessionArchive objects operating on the same files.
    init(archive: SessionArchive) {
        self.archive = archive
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            Self.removeRetiredOfflineQueue(in: documents)
        }
    }

    // MARK: - Public API

    /// Check if a session already exists (blocks duplicate collection)
    /// - Parameter sessionId: Session ID to check
    /// - Returns: True if the session is in the archive
    func sessionExists(_ sessionId: UUID) -> Bool {
        archive.exists(sessionId)
    }

    // MARK: - Retired offline queue

    /// Removes `<documents>/HRVOffline`, where older builds kept an offline
    /// sync queue (`pending.json`, whole sessions as plain JSON) that nothing
    /// read or drained. Nothing writes there now. No folder: nothing to do. A
    /// failed removal is logged and tried again at the next launch.
    static func removeRetiredOfflineQueue(in documents: URL) {
        let folder = documents.appendingPathComponent("HRVOffline", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
            debugLog("[ReconciliationManager] removed the retired HRVOffline queue")
        } catch {
            debugLog("[ReconciliationManager] could not remove the retired HRVOffline queue — retried next launch: \(error)", level: .warning)
        }
    }
}
