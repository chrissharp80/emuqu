import CoreLocation
import Foundation
import HealthKit

// Training queries live in `TrainingHealthQueries` — several hundred lines
// kept out of HealthKitManager, one of the largest types in the codebase.
//
// These forwarders keep every existing call site working. The queries needed
// exactly three members of the manager (the store, the bounded-query helper,
// the sample counter), which is what made this seam worth cutting: recovery and
// cloud pull each needed a dozen and stayed coupled by design.

extension HealthKitManager {
    /// The training-query subsystem. Lazy — most launches never ask for a
    /// workout.
    var training: TrainingHealthQueries {
        TrainingHealthQueries(manager: self)
    }

    // MARK: - Pure helpers (no instance state, so they moved as statics)

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

    func fetchVO2MaxTrend(days: Int = 30) async -> (latest: Double, oldestInWindow: Double, sampleCount: Int)? {
        await training.fetchVO2MaxTrend(days: days)
    }

    func fetchRecentWorkouts(
        days: Int = 7, relativeTo referenceDate: Date = Date()
    ) async -> [HealthKitManager.WorkoutSummary] {
        await training.fetchRecentWorkouts(days: days, relativeTo: referenceDate)
    }

    func fetchWorkoutRoute(from start: Date, to end: Date) async -> [CLLocation]? {
        await training.fetchWorkoutRoute(from: start, to: end)
    }

    func fetchPassiveDistanceMeters(from start: Date, to end: Date) async -> Double {
        await training.fetchPassiveDistanceMeters(from: start, to: end)
    }

    func hasWorkoutInRange(from start: Date, to end: Date) async -> Bool {
        await training.hasWorkoutInRange(from: start, to: end)
    }

    func fetchWorkoutsExtended(
        days: Int = 60, relativeTo referenceDate: Date = Date()
    ) async -> [HealthKitManager.WorkoutSummary] {
        await training.fetchWorkoutsExtended(days: days, relativeTo: referenceDate)
    }

    func fetchAppleRestingHR() async -> Double? {
        await training.fetchAppleRestingHR()
    }

    func fetchVO2Max() async -> Double? {
        await training.fetchVO2Max()
    }

    func calculateTrainingMetrics(
        restingHR: Double = 60,
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
