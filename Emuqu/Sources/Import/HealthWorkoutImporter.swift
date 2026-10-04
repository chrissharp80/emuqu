import CoreLocation
import Foundation
import HealthKit

// MARK: - Health Workout Importer
//
// Rebuilds a workout Emuqu did not record, from what Apple Health already
// holds. Two problems share this one mechanism:
//
//   1. **Recovery.** If a recording dies mid-workout — a crash, a force-quit,
//      a battery — the walk still happened, and the Watch (or the phone) wrote
//      it to Apple Health anyway. Without this, the user's only record of the
//      hour they spent outside is a one-second stub. With it, they get the
//      route, the distance and the heart rate back.
//
//   2. **People who record somewhere else.** Strava, Garmin, Nike Run Club and
//      the Workout app all write to Apple Health. An app that only knows about
//      its own recordings tells those users their training history is empty and
//      asks them to abandon the tool they already use. Reading what is already
//      there is the difference between "switch to me" and "I work with what you
//      have".
//
// ## What an import can and cannot contain
//
// Apple Health stores heart rate as an already-averaged value, usually one
// every few seconds. It does not store beat-to-beat RR intervals, and nothing
// recovers them from an average. So an imported workout carries distance,
// route, the altitude profile, cadence and the heart-rate trace — and carries
// no RMSSD, no SDNN and no DFA alpha-1. Those fields stay empty rather than
// being filled with a number derived from the wrong input. Nor is the workout
// analysed: it has no mean heart rate, TRIMP or hrTSS, and an elevation gain
// only when a rebuild can read flights climbed.
//
// This is the same bargain the GPX importer already makes, and imported
// sessions are deliberately built to exactly the shape the app has handled
// since GPX import shipped.

@MainActor
struct HealthWorkoutImporter {
    let manager: HealthKitManager

    /// A workout Apple Health has and Emuqu does not.
    struct Candidate: Identifiable, Sendable, Equatable {
        /// The `HKWorkout`'s own UUID — stable across queries, so the list can
        /// hand one back to be imported without holding HealthKit objects in
        /// view state.
        let id: UUID
        let startDate: Date
        let endDate: Date
        let sport: Sport
        /// "Strava", "Apple Watch", "Nike Run Club" — whatever wrote it.
        let sourceName: String
        let distanceMeters: Double?
        /// The temperature and humidity Apple Watch saved with an outdoor
        /// workout; nil for indoor sports and for workouts saved without it.
        let weather: WorkoutWeatherSnapshot?

        var duration: TimeInterval { endDate.timeIntervalSince(startDate) }
    }

    // MARK: - Policy (pure, and therefore testable without a health store)

    /// Below this, it is not a workout.
    ///
    /// HealthKit accumulates zero- and few-second `HKWorkout`s — Strava sync
    /// stubs, Apple's auto-detection, watch faces — usually alongside the real
    /// recording and often with a different activity type. `TrainingHealthQueries`
    /// already drops them for training load; an import list has to drop them
    /// too, or the user is asked to choose between a run and its own ghost.
    nonisolated static let minimumImportableDuration: TimeInterval = 60

    /// Two workouts starting this close together are the same activity.
    ///
    /// Same figure the workout deduplicator uses. A Watch and a phone rarely
    /// agree on a start time to the second, and Strava's sync of an Emuqu
    /// export lands minutes after the original.
    nonisolated static let duplicateStartToleranceSec: TimeInterval = 5 * 60

    /// Emuqu's sport for a HealthKit activity type, or nil when the app has no
    /// equivalent.
    ///
    /// nil means "not offered for import" — deliberately. Emuqu has no swim,
    /// no elliptical and no weightlifting sport, and importing one as a
    /// plausible neighbour would put a workout in the user's history under a
    /// label that is simply wrong, then feed it to pace and TRIMP maths built
    /// for a different activity. Cross training, functional strength and HIIT
    /// are the mixed-modal sessions Emuqu's CrossFit sport records, so they
    /// map there.
    ///
    /// `isIndoor` comes from `HKMetadataKeyIndoorWorkout`, which is how the
    /// Workout app distinguishes a treadmill from a road run — a distinction
    /// Emuqu keeps as separate sports because GPS pace is meaningless on one
    /// of them.
    nonisolated static func sport(for activity: HKWorkoutActivityType, isIndoor: Bool) -> Sport? {
        switch activity {
        case .running: return isIndoor ? .treadmill : .run
        case .walking: return .walk
        case .hiking: return .hike
        case .cycling: return isIndoor ? .indoorBike : .bike
        case .rowing: return .row
        case .crossTraining, .functionalStrengthTraining, .highIntensityIntervalTraining:
            return .crossFit
        default: return nil
        }
    }

    /// True when the archive already holds a workout for this activity.
    ///
    /// Start-time proximity only. Matching on type as well would let Emuqu's
    /// own export come back in as an import whenever Apple's auto-detection
    /// labelled the same hour differently — which is exactly the case the
    /// tolerance exists for.
    nonisolated static func isAlreadyArchived(start: Date, existingStarts: [Date]) -> Bool {
        existingStarts.contains { abs($0.timeIntervalSince(start)) <= duplicateStartToleranceSec }
    }

    /// Turn HealthKit step counts into steps-per-minute at each sample's
    /// midpoint.
    ///
    /// A step sample is a COUNT OVER A WINDOW, not an instant. Dividing by that
    /// window is the whole conversion, and it is why a zero-length sample is
    /// dropped rather than divided by zero — which would be `inf`, and `inf`
    /// reaches an `Int(...)` conversion in the cadence chart and traps.
    nonisolated static func cadenceSamples(from steps: [HealthSampleWindow]) -> [(Date, Double)] {
        steps.compactMap { sample in
            let seconds = sample.duration
            guard seconds > 0, sample.value >= 0 else { return nil }
            let perMinute = sample.value / (seconds / 60)
            guard perMinute.isFinite else { return nil }
            return (sample.start.addingTimeInterval(seconds / 2), perMinute)
        }
    }
}
