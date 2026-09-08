import Foundation

// MARK: - Workout-Session Sleep Cleanup Migration
//
// An earlier `morningReading()` selector on the dashboard could pick a
// `.workout`-typed HRVSession as the "morning reading" if it ended before
// the morning cutoff. The dashboard's update paths then attached the
// morning's `sleepSnapshot` to that session and re-archived it. The result:
// workout sessions in the archive carrying overnight sleep snapshots that
// don't apply to them, which contaminates the AI's `WorkoutHistoryEntry`
// surface and the post-summary's data integrity.
//
// This one-shot migration walks the archive once, finds workout sessions
// with a non-nil `sleepSnapshot`, and clears the field. Other workout
// fields (TRIMP, splits, GPS, samples) are untouched. Runs once per
// install — gated by a UserDefaults flag.

extension SessionDataMigrations {
    private static let workoutSleepCleanupKey = "didRunWorkoutSleepCleanup_v1"

    func runWorkoutSleepCleanupIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.workoutSleepCleanupKey) else { return }
        // Snapshot archive entries on the main actor; retrieval itself is
        // safe to run off-actor (SessionArchive owns its own lock).
        let archive = self.archive
        let entries = archive.entries
        guard !entries.isEmpty else {
            defaults.set(true, forKey: Self.workoutSleepCleanupKey)
            return
        }
        var cleaned = 0
        for entry in entries where stripWorkoutSleepSnapshot(entry, archive: archive) {
            cleaned += 1
        }
        defaults.set(true, forKey: Self.workoutSleepCleanupKey)
        debugLog("[WorkoutSleepCleanup] Complete. Stripped sleepSnapshot from \(cleaned) of \(entries.count) sessions.")
    }

    /// A workout should never carry a sleep snapshot. Returns whether one was
    /// actually removed.
    private func stripWorkoutSleepSnapshot(_ entry: SessionArchiveEntry, archive: SessionArchive) -> Bool {
        guard let session = try? archive.retrieve(entry.sessionId),
              session.sessionType == .workout,
              session.sleepSnapshot != nil
        else { return false }
        var updated = session
        updated.sleepSnapshot = nil
        do {
            try archive.archive(updated)
            return true
        } catch {
            debugLog("[WorkoutSleepCleanup] Failed to re-archive \(session.id.uuidString.prefix(8)): \(error)", level: .warning)
            return false
        }
    }
}
