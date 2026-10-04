import Foundation

/// Duplicate-collection guard: `sessionExists` tells a recording that its
/// session id is already archived or queued. The offline queue itself
/// (`queueForSync` / `pending`, persisted to `HRVOffline/pending.json`) has no
/// caller in the app; nothing drains it.
final class ReconciliationManager {
    // MARK: - Properties

    private let offlineDirectory: URL
    private let fileManager = FileManager.default
    private var pendingSessions: [OfflineSession] = []
    private let archive: SessionArchive
    private let lock = NSLock()

    // MARK: - Initialization

    /// Initialize with an explicit SessionArchive instance.
    /// Note: Do NOT use a default parameter here - callers must provide the shared archive
    /// instance to prevent multiple SessionArchive objects operating on the same files.
    init(archive: SessionArchive) {
        self.archive = archive

        if let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            offlineDirectory = documentsPath.appendingPathComponent("HRVOffline", isDirectory: true)
        } else {
            // Fallback to temporary directory (should never happen on iOS)
            offlineDirectory = fileManager.temporaryDirectory.appendingPathComponent("HRVOffline", isDirectory: true)
            debugLog("[ReconciliationManager] WARNING: Using temporary directory as fallback")
        }

        createDirectoryIfNeeded()
        loadPendingSessions()
    }

    // MARK: - Public API

    /// Check if a session already exists (blocks duplicate collection)
    /// - Parameter sessionId: Session ID to check
    /// - Returns: True if session exists in archive or pending
    func sessionExists(_ sessionId: UUID) -> Bool {
        if archive.exists(sessionId) {
            return true
        }
        // Read pendingSessions under the same lock the mutators use — an
        // unsynchronized read of a CoW Array concurrent with a locked write is
        // a data race (torn read / UB).
        lock.lock()
        defer { lock.unlock() }
        return pendingSessions.contains(where: { $0.id == sessionId })
    }

    /// Queue a session for sync
    /// - Parameter session: The session to queue
    /// - Throws: If session already exists
    func queueForSync(_ session: HRVSession) throws {
        lock.lock()
        defer { lock.unlock() }

        // Check existence inside the lock to avoid TOCTOU race with sessionExists()
        guard !archive.exists(session.id),
              !pendingSessions.contains(where: { $0.id == session.id })
        else {
            throw ReconciliationError.sessionAlreadyExists
        }

        let offlineSession = OfflineSession(session: session)
        pendingSessions.append(offlineSession)
        try savePendingSessions()
    }

    /// Get all sessions pending sync
    var pending: [OfflineSession] {
        lock.lock()
        defer { lock.unlock() }
        return pendingSessions.filter(\.needsSync)
    }

    // MARK: - Private

    private func createDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: offlineDirectory.path) {
            _ = attempt("Reconciliation.create") { try fileManager.createDirectory(at: offlineDirectory, withIntermediateDirectories: true) }
        }
    }

    private var pendingFile: URL {
        offlineDirectory.appendingPathComponent("pending.json")
    }

    private func loadPendingSessions() {
        do {
            let data = try Data(contentsOf: pendingFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            pendingSessions = try decoder.decode([OfflineSession].self, from: data)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // File does not exist yet — not an error, just no pending sessions
            pendingSessions = []
        } catch {
            debugLog("Failed to load pending sessions: \(error)")
            pendingSessions = []
        }
    }

    private func savePendingSessions() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(pendingSessions)
        // Explicit protection class on this HRV-session queue, matching the
        // archive/backup writers.
        try data.write(to: pendingFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - Errors

    enum ReconciliationError: Error, LocalizedError {
        case sessionAlreadyExists

        var errorDescription: String? {
            switch self {
            case .sessionAlreadyExists:
                "A session with this ID already exists"
            }
        }
    }
}
