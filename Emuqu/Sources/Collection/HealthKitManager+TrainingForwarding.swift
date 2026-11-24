import CoreLocation
import Foundation
import HealthKit

// Training queries live in `TrainingHealthQueries`, which needs only three
// members of the manager (the store, the bounded-query helper, the sample
// counter). These forwarders give `HealthKitManager` callers the same
// entry points.

extension HealthKitManager {
    /// The training-query subsystem: a lightweight value built on each access.
    var training: TrainingHealthQueries {
        TrainingHealthQueries(manager: self)
    }

    // MARK: - Pure helpers (no instance state)

    nonisolated static func deduplicateWorkouts(
        _ workouts: [HealthKitManager.WorkoutSummary]
    ) -> [HealthKitManager.WorkoutSummary] {
        TrainingHealthQueries.deduplicateWorkouts(workouts)
    }

    nonisolated static func mergeArchiveAuthoritative(
        archive: [HealthKitManager.WorkoutSummary],
        healthKit: [HealthKitManager.WorkoutSummary],
        additional: [HealthKitManager.WorkoutSummary] = []
    ) -> [HealthKitManager.WorkoutSummary] {
        TrainingHealthQueries.mergeArchiveAuthoritative(
            archive: archive, healthKit: healthKit, additional: additional
        )
    }

    // MARK: - Queries

    func fetchWorkoutRoute(from start: Date, to end: Date) async -> [CLLocation]? {
        await training.fetchWorkoutRoute(from: start, to: end)
    }

    func fetchPassiveDistanceMeters(from start: Date, to end: Date) async -> Double {
        await training.fetchPassiveDistanceMeters(from: start, to: end)
    }

    func fetchWorkoutsExtended(
        days: Int = 60, relativeTo referenceDate: Date = Date()
    ) async -> [HealthKitManager.WorkoutSummary] {
        await training.fetchWorkoutsExtended(days: days, relativeTo: referenceDate)
    }

    func fetchWorkoutsExtendedIfAnswered(
        days: Int, relativeTo referenceDate: Date
    ) async -> [HealthKitManager.WorkoutSummary]? {
        await training.fetchWorkoutsExtendedIfAnswered(days: days, relativeTo: referenceDate)
    }

    func trainingHeartRateAnchors() async -> TrainingLoadSeries.HeartRateAnchors {
        await training.trainingHeartRateAnchors()
    }

    /// Nil anchors resolve as `trainingHeartRateAnchors` does: Apple's
    /// resting HR, else the user's setting; the user's max HR.
    func calculateTrainingMetrics(
        restingHR: Double? = nil,
        userMaxHR: Double? = nil,
        forMorningReading: Bool = true,
        relativeTo referenceDate: Date = Date(),
        additionalWorkouts: [HealthKitManager.WorkoutSummary] = [],
        preloadedHealthKitWorkouts: [HealthKitManager.WorkoutSummary]? = nil
    ) async -> HealthKitManager.TrainingMetrics {
        await training.calculateTrainingMetrics(
            restingHR: restingHR,
            userMaxHR: userMaxHR,
            forMorningReading: forMorningReading,
            relativeTo: referenceDate,
            additionalWorkouts: additionalWorkouts,
            preloadedHealthKitWorkouts: preloadedHealthKitWorkouts
        )
    }

    func calculateTrainingLoad(
        days: Int = 7, forMorningReading: Bool = true, relativeTo referenceDate: Date = Date()
    ) async -> HealthKitManager.TrainingLoad {
        await training.calculateTrainingLoad(
            days: days, forMorningReading: forMorningReading, relativeTo: referenceDate
        )
    }
}
