import Foundation

extension ArchiveMigrations {
    /// The day the builds that measured HRR from the heart rate at Stop began.
    /// Workouts before it were always measured from the peak.
    static let stopReferencedHRRSince = DateComponents(
        calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 3
    ).date ?? .distantPast

    static let hrrPeakRepairDone = "FlowRecovery.migration.hrrPeakReference.v1.done"

    /// One-time repair: re-measures from the workout's peak the HRR readings
    /// that builds measuring from the heart rate at Stop stored, and asks
    /// iCloud to take the corrected copies. The flag is set once a pass reads
    /// every candidate; a session that fails to load leaves it off.
    func repairStopReferencedHRR() {
        if UserDefaults.standard.bool(forKey: Self.hrrPeakRepairDone) { return }
        var allRead = true
        for id in hrrRepairCandidates() {
            do {
                try repairHRR(of: id)
            } catch {
                allRead = false
                debugLog("[Archive] HRR peak repair: \(id.uuidString.prefix(8)) failed: \(error)", level: .warning)
            }
        }
        if allRead { UserDefaults.standard.set(true, forKey: Self.hrrPeakRepairDone) }
    }

    private func hrrRepairCandidates() -> [UUID] {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        return archive.index
            .filter { $0.sessionType == .workout && $0.date >= Self.stopReferencedHRRSince }
            .map(\.sessionId)
    }

    private func repairHRR(of id: UUID) throws {
        guard try archive.retrieve(id)?.workoutMetadata?.hrrRemeasuredFromPeak() != nil else { return }
        try archive.update(id) { session in
            guard let remeasured = session.workoutMetadata?.hrrRemeasuredFromPeak() else { return }
            session.workoutMetadata?.hrrSamples = remeasured
        }
        debugLog("[Archive] HRR peak repair: re-measured \(id.uuidString.prefix(8)) from the workout's peak")
    }
}
