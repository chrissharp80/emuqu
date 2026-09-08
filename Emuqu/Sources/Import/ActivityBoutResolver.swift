import Foundation

// MARK: - Activity Bout Resolver
//
// Works out when an activity actually ENDED, from the step samples the iPhone
// and Watch record continuously whether or not anything was recording a
// workout.
//
// This exists because of the case a workout importer cannot reach. When a
// recording dies mid-workout, the Watch's own workout session is discarded
// (`WatchWorkoutManager.stop` finalizes nothing — the phone owns the canonical
// workout), and the phone never wrote one because it was gone. So Apple Health
// ends up with no HKWorkout for that hour at all — nothing to import.
//
// What it does still have is the passive record: steps, distance and heart
// rate, sampled the whole time regardless. Those give back the walk. The one
// thing they do not give back is when it ended, because a crashed recording has
// no end — and that is what this resolves.
//
// The shape of the answer: a bout runs from its known start until the activity
// stops for longer than `maxGap`. Sitting down for two minutes mid-walk should
// not end it; going home and staying there should.

enum ActivityBoutResolver {
    /// Quiet stretch that does NOT end a bout.
    ///
    /// Ten minutes is long enough to cover a road crossing, a shoe re-tie, a
    /// conversation or a photo stop, and short enough that arriving home ends
    /// the walk rather than annexing the rest of the afternoon. Step samples
    /// are also written in irregular batches, so a gap smaller than this
    /// routinely means "not written yet" rather than "not walking".
    static let defaultMaxGap: TimeInterval = 10 * 60

    /// Hard ceiling on anything reconstructed this way.
    ///
    /// A reconstruction has no stop event to trust, so it needs a limit that
    /// does not come from the data: a stuck or backfilled sample stream must
    /// not be able to produce a fourteen-hour "walk" that then dominates the
    /// user's training load.
    static let maxBoutDuration: TimeInterval = 6 * 3_600

    /// When the activity that began at `start` stopped, or nil when the
    /// samples show no activity at all — in which case there is nothing to
    /// reconstruct and the caller must say so rather than inventing a duration.
    ///
    /// `activity` is any signal that is present while the user is moving and
    /// absent when they stop — exercise minutes, step counts — in whatever
    /// order and whatever batching HealthKit hands them over. What the value
    /// MEANS is the caller's business; all this reads is "was there any".
    static func end(
        ofBoutStartingAt start: Date,
        activity: [HealthSampleWindow],
        maxGap: TimeInterval = defaultMaxGap,
        maxDuration: TimeInterval = maxBoutDuration
    ) -> Date? {
        let ceiling = start.addingTimeInterval(maxDuration)
        var cursor = start
        var moved = false
        for sample in usable(activity, after: start) {
            // A sample that begins after the cursor by more than the gap is a
            // separate bout: the walk ended, and this is whatever came later.
            if sample.start.timeIntervalSince(cursor) > maxGap { break }
            guard sample.end > cursor else { continue }
            cursor = min(sample.end, ceiling)
            moved = true
            if cursor >= ceiling { break }
        }
        return moved ? cursor : nil
    }

    /// Samples that carry steps and reach past the start, in time order.
    ///
    /// A window straddling the start counts — the user was already walking
    /// when the recording began — but one that ended before it belongs to
    /// whatever they were doing beforehand.
    private static func usable(
        _ windows: [HealthSampleWindow],
        after start: Date
    ) -> [HealthSampleWindow] {
        windows
            .filter { $0.value > 0 && $0.end > start && $0.duration > 0 }
            .sorted { $0.start < $1.start }
    }
}
