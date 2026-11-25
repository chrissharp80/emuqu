import Foundation

// MARK: - Import

extension RRCollector {
    func saveImportedSession(_ session: HRVSession) async throws {
        try await sessionImport.save(session)
    }

    func saveImportedSessionsBatch(_ sessions: [HRVSession]) async throws -> Int {
        try await sessionImport.saveBatch(sessions)
    }
}

extension RRCollector {
    /// Saving imported readings, over the parts it uses.
    var sessionImport: SessionImport {
        SessionImport(
            archive: archive, archiveSignal: archiveSignal, baselineTracker: baselineTracker,
            cloudSyncManager: cloudSyncManager, sessionState: sessionState, settingsManager: settingsManager
        )
    }
}

/// Saving imported readings into the archive, the baseline and iCloud.
///
/// A value over the parts it uses.
@MainActor
struct SessionImport {
    let archive: SessionArchive
    let archiveSignal: ArchiveSignal
    let baselineTracker: BaselineTracker
    let cloudSyncManager: CloudKitSyncManager
    let sessionState: SessionState
    let settingsManager: SettingsManager

    /// Save an imported session to the archive. Throws `duplicateImport` when
    /// the archive already holds a copy of the same recording (same type,
    /// overlapping time), the rule batch import applies too. A recording of
    /// the same sleep within the merge gap is merged by the archive onto one
    /// clock; the merged reading, under the id already there, is then what
    /// iCloud (through the archive's re-upload request) and the baseline get.
    func save(_ session: HRVSession) async throws {
        guard session.state == .complete, session.analysisResult != nil else {
            throw RRCollector.CollectorError.importNotAnalyzed
        }
        guard !archive.store.holdsCopy(of: session) else { throw RRCollector.CollectorError.duplicateImport }
        let entry = try archive.archive(session, skipSameNightMerge: false, requestingReupload: true)
        let merged = entry.sessionId != session.id
        let saved = merged ? archive.retrieveOrLog(entry.sessionId) ?? session : session
        if !merged {
            let cloudSync = cloudSyncManager
            Task { await cloudSync.uploadSession(saved) }
        }
        let sleepSchedule = settingsManager.settings.sleepSchedule
        baselineTracker.update(with: saved, sleepSchedule: sleepSchedule)
        // Against the nights before this one, not a baseline it just joined.
        let deviation = baselineTracker.deviation(for: saved, sleepSchedule: sleepSchedule)
        if let deviation { sessionState.baselineDeviation = deviation }
        archiveSignal.notifyChanged()
    }

    /// Batch save multiple imported sessions efficiently
    func saveBatch(_ sessions: [HRVSession]) async throws -> Int {
        debugLog("[RRCollector] saveImportedSessionsBatch called with \(sessions.count) sessions")
        let validSessions = sessions.filter { $0.state == .complete && $0.analysisResult != nil }
        debugLog("[RRCollector] Valid sessions (complete + analyzed): \(validSessions.count)")
        guard !validSessions.isEmpty else {
            debugLog("[RRCollector] ERROR: No valid sessions to save!")
            return 0
        }
        let savedCount = try archive.store.archiveBatch(validSessions)
        debugLog("[RRCollector] archiveBatch returned: \(savedCount) saved")
        updateBaseline(withImported: validSessions)
        archiveSignal.notifyChanged()
        if savedCount > 0 {
            let cloudSync = cloudSyncManager
            Task { await cloudSync.performFullSync() }
        }
        debugLog("[RRCollector] Archive now has \(archive.store.entries.count) entries")
        return savedCount
    }

    /// Only sessions the batch actually holds now feed the baseline: one it
    /// skipped (deleted by the user, a duplicate, or merged into an existing
    /// reading) must not come back through the baseline. Chronological so the
    /// rolling window sees them in the order they were recorded.
    private func updateBaseline(withImported sessions: [HRVSession]) {
        let archivedIds = Set(archive.store.entries.map(\.sessionId))
        let written = sessions.filter { archivedIds.contains($0.id) }.sorted { $0.startDate < $1.startDate }
        for session in written {
            baselineTracker.update(with: session, sleepSchedule: settingsManager.settings.sleepSchedule)
        }
    }
}
