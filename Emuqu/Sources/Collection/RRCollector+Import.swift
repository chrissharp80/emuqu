import Foundation

// MARK: - Import

extension RRCollector {
    func saveImportedSession(_ session: HRVSession) async throws {
        try await SessionImport(collector: self).save(session)
    }

    func saveImportedSessionsBatch(_ sessions: [HRVSession]) async throws -> Int {
        try await SessionImport(collector: self).saveBatch(sessions)
    }
}

/// Saving imported readings into the archive, the baseline and iCloud.
///
/// Holds its owner strongly and is built on demand by the collector — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct SessionImport {
    let collector: RRCollector

    /// Save an imported session to the archive. Throws `duplicateImport` when
    /// the archive already holds a copy of the same recording (same type,
    /// overlapping time), the rule batch import applies too. A recording of
    /// the same sleep within the merge gap is merged by the archive onto one
    /// clock.
    func save(_ session: HRVSession) async throws {
        guard session.state == .complete, session.analysisResult != nil else {
            throw RRCollector.CollectorError.importNotAnalyzed
        }
        guard !collector.archive.holdsCopy(of: session) else { throw RRCollector.CollectorError.duplicateImport }
        try collector.archive.archive(session)
        let cloudSync = collector.cloudSyncManager
        Task { await cloudSync.uploadSession(session) }
        collector.baselineTracker.update(with: session, sleepSchedule: collector.settingsManager.settings.sleepSchedule)
        let deviation = collector.baselineTracker.deviation(for: session)
        if let deviation { collector.baselineDeviation = deviation }
        collector.archiveSignal.notifyChanged()
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
        let savedCount = try collector.archive.archiveBatch(validSessions)
        debugLog("[RRCollector] archiveBatch returned: \(savedCount) saved")
        updateBaseline(withImported: validSessions)
        collector.archiveSignal.notifyChanged()
        if savedCount > 0 {
            let cloudSync = collector.cloudSyncManager
            Task { await cloudSync.performFullSync() }
        }
        debugLog("[RRCollector] Archive now has \(collector.archive.entries.count) entries")
        return savedCount
    }

    /// Only sessions the batch actually holds now feed the baseline: one it
    /// skipped (deleted by the user, a duplicate, or merged into an existing
    /// reading) must not come back through the baseline. Chronological so the
    /// rolling window sees them in the order they were recorded.
    private func updateBaseline(withImported sessions: [HRVSession]) {
        let archivedIds = Set(collector.archive.entries.map(\.sessionId))
        let written = sessions.filter { archivedIds.contains($0.id) }.sorted { $0.startDate < $1.startDate }
        for session in written {
            collector.baselineTracker.update(with: session, sleepSchedule: collector.settingsManager.settings.sleepSchedule)
        }
    }
}
