import Foundation

/// The one rule for a finished workout that looks like an accidental Start:
/// under a minute of active time on the wall clock, and in that time no heart
/// rate (under 60 beats), no movement (50 m or less) and under 30 per-second
/// samples.
///
/// The time is the wall clock less the pauses, never a count of ticks or
/// samples: a workout with no sensor has no background keep-alive, so while
/// the phone is locked the ticker records nothing, and a 40-minute indoor
/// session ended from the lock screen holds a few seconds of samples.
///
/// Such a workout is not saved on its own. The summary says so and offers to
/// save it (`WorkoutSessionLifecycle.saveNotArchived`); its backups stay until
/// the user leaves the summary without saving.
enum WorkoutAccidentalStart {
    /// Active seconds from which a workout is always saved.
    static let maxActiveSeconds: TimeInterval = 60

    static func isAccidental(beats: Int, distanceMeters: Double?, sampleCount: Int, activeSeconds: TimeInterval) -> Bool {
        guard activeSeconds < maxActiveSeconds else { return false }
        return beats < 60 && (distanceMeters ?? 0) <= 50 && sampleCount < 30
    }
}
