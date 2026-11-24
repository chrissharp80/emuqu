import Foundation

// MARK: - Workout-Session Sleep Cleanup Migration
//
// Builds whose dashboard `morningReading()` selector could pick a
// `.workout`-typed HRVSession as the "morning reading" (when it ended
// before the morning cutoff) attached the morning's `sleepSnapshot` to that
// session and re-archived it. A workout session carrying an overnight sleep
// snapshot contaminates the AI's `WorkoutHistoryEntry` surface and the
// post-summary's data integrity.
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
        // Only workout files are opened, and off the main actor: retrieval
        // decrypts and decodes each one (SessionArchive owns its own lock).
        let archive = self.archive
        let (cleaned, failed, examined) = await Task.detached(priority: .utility) {
            let workouts = archive.store.entries.filter { $0.sessionType == .workout }
            let outcomes = workouts.map { Self.stripWorkoutSleepSnapshot($0, archive: archive) }
            return (outcomes.filter { $0 == .stripped }.count, outcomes.filter { $0 == .failed }.count, workouts.count)
        }.value
        // A workout whose write failed still carries the snapshot: leave the
        // flag unset so the next launch tries again.
        guard failed == 0 else {
            debugLog("[WorkoutSleepCleanup] Stripped sleepSnapshot from \(cleaned) of \(examined) workouts; \(failed) could not be written — retrying next launch", level: .warning)
            return
        }
        defaults.set(true, forKey: Self.workoutSleepCleanupKey)
        debugLog("[WorkoutSleepCleanup] Complete. Stripped sleepSnapshot from \(cleaned) of \(examined) workouts.")
    }

    /// What `stripWorkoutSleepSnapshot` did to one workout.
    private enum WorkoutCleanupOutcome {
        case stripped
        case unchanged
        case failed
    }

    /// A workout should never carry a sleep snapshot. Whether one was
    /// removed, there was none to remove, or the write failed. Only that
    /// field is changed, on the archive's copy as it is at the write, so
    /// nothing saved since the read is put back.
    nonisolated private static func stripWorkoutSleepSnapshot(
        _ entry: SessionArchiveEntry, archive: SessionArchive
    ) -> WorkoutCleanupOutcome {
        guard let session = archive.retrieveOrLog(entry.sessionId, caller: "WorkoutSleepCleanup"),
              session.sessionType == .workout,
              session.sleepSnapshot != nil
        else { return .unchanged }
        do {
            try archive.update(session.id, requestingReupload: false) { $0.sleepSnapshot = nil }
            return .stripped
        } catch {
            debugLog("[WorkoutSleepCleanup] Failed to re-archive \(session.id.uuidString.prefix(8)): \(error)", level: .warning)
            return .failed
        }
    }
}
