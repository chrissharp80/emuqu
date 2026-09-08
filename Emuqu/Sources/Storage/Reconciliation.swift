import Foundation

/// Reconciliation manager for offline session sync
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

    /// Mark a session as synced
    func markSynced(_ sessionId: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let index = pendingSessions.firstIndex(where: { $0.id == sessionId }) else {
            return
        }

        pendingSessions[index].syncedAt = Date()

        // Archive the session
        try archive.archive(pendingSessions[index].session)

        // Remove from pending
        pendingSessions.remove(at: index)
        try savePendingSessions()
    }

    /// Mark a sync attempt as failed
    func markFailed(_ sessionId: UUID, error: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let index = pendingSessions.firstIndex(where: { $0.id == sessionId }) else {
            return
        }

        pendingSessions[index].syncAttempts += 1
        pendingSessions[index].lastError = error
        try savePendingSessions()
    }

    /// Attempt to sync all pending sessions
    /// - Parameter syncHandler: Async handler that performs the actual sync
    /// - Returns: Number of successfully synced sessions
    func syncAll(using syncHandler: (HRVSession) async throws -> Void) async -> Int {
        var successCount = 0
        for session in pending {
            do {
                try await syncHandler(session.session)
                try markSynced(session.id)
                successCount += 1
            } catch {
                debugLog("[Reconciliation] Sync failed for \(session.id.uuidString.prefix(8)): \(error)")
                recordSyncFailure(session.id, error: error)
            }
        }
        return successCount
    }

    /// A failure to even record the failure is logged and dropped — the entry
    /// stays pending and the next sweep retries it.
    private func recordSyncFailure(_ id: UUID, error: Error) {
        do {
            try markFailed(id, error: error.localizedDescription)
        } catch {
            debugLog("[Reconciliation] Failed to mark session \(id.uuidString.prefix(8)) as failed: \(error)")
        }
    }

    /// Clean up sessions that have exceeded retry limit
    func cleanupFailedSessions() throws {
        lock.lock()
        defer { lock.unlock() }
        pendingSessions.removeAll { $0.syncAttempts >= 3 && $0.syncedAt == nil }
        try savePendingSessions()
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
