import Foundation

// MARK: - Import

extension RRCollector {
    /// Save an imported session to the archive
    func saveImportedSession(_ session: HRVSession) async throws {
        guard session.state == .complete, session.analysisResult != nil else {
            throw CollectorError.insufficientData
        }
        // Check for duplicate by date
        if archive.sessionExists(for: session.startDate) { return }
        try archive.archive(session)
        Task { await cloudSyncManager.uploadSession(session) }
        baselineTracker.update(with: session, sleepSchedule: settingsManager.settings.sleepSchedule)
        let deviation = baselineTracker.deviation(for: session)
        await MainActor.run {
            if let deviation { baselineDeviation = deviation }
            archiveSignal.notifyChanged()
        }
    }

    /// Batch save multiple imported sessions efficiently
    func saveImportedSessionsBatch(_ sessions: [HRVSession]) async throws -> Int {
        debugLog("[RRCollector] saveImportedSessionsBatch called with \(sessions.count) sessions")
        let validSessions = sessions.filter { $0.state == .complete && $0.analysisResult != nil }
        debugLog("[RRCollector] Valid sessions (complete + analyzed): \(validSessions.count)")
        guard !validSessions.isEmpty else {
            debugLog("[RRCollector] ERROR: No valid sessions to save!")
            return 0
        }
        let savedCount = try archive.archiveBatch(validSessions)
        debugLog("[RRCollector] archiveBatch returned: \(savedCount) saved")
        // Baseline updates are chronological so the rolling window sees the
        // sessions in the order they were recorded.
        for session in validSessions.sorted(by: { $0.startDate < $1.startDate }) {
            baselineTracker.update(with: session, sleepSchedule: settingsManager.settings.sleepSchedule)
        }
        await MainActor.run { archiveSignal.notifyChanged() }
        if savedCount > 0 {
            Task { await cloudSyncManager.performFullSync() }
        }
        debugLog("[RRCollector] Archive now has \(archive.entries.count) entries")
        return savedCount
    }
}
