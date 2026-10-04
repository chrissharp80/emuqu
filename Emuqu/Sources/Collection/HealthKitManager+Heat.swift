import Foundation
import HealthKit

extension HealthKitManager {
    /// One outdoor workout reduced to what the heat-acclimatization model
    /// needs: when it happened, how long it lasted, and the weather saved
    /// with it. The weather is the temperature and humidity Apple Watch
    /// writes into the workout's metadata; workouts from other sources
    /// usually carry none and add no heat exposure.
    struct HeatWorkoutInput: Sendable, Equatable {
        let date: Date
        let durationMinutes: Double
        let weather: WorkoutWeatherSnapshot?
    }

    /// Fetch outdoor workouts over the last `days` for heat-stimulus scoring.
    /// This reads the SAME HealthKit workout store the training-load model
    /// uses — so it covers the user's full history (years of Apple Watch /
    /// Garmin / Strava sessions), not just workouts recorded inside the app.
    ///
    /// Excludes indoor sessions: a treadmill run or gym session in a
    /// climate-controlled room carries no heat stimulus even on a hot day, so
    /// counting it would over-state acclimation. A workout is treated as
    /// indoor when its `HKMetadataKeyIndoorWorkout` flag is true, or when its
    /// activity type isn't one that's normally done outdoors.
    func fetchOutdoorWorkoutsForHeat(days: Int) async -> [HeatWorkoutInput] {
        guard isHealthKitAvailable else { return [] }
        let calendar = Calendar.current
        let end = Date()
        let startOfToday = calendar.startOfDay(for: end)
        guard let start = calendar.date(byAdding: .day, value: -days, to: startOfToday) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await runBoundedQuery(timeout: Self.backgroundAggregateQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                resolve(Self.heatInputs(from: samples))
            }
        } ?? []
    }

    /// Ghost workouts (under a minute) and indoor sessions are dropped.
    nonisolated private static func heatInputs(from samples: [HKSample]?) -> [HeatWorkoutInput] {
        guard let workouts = samples as? [HKWorkout] else { return [] }
        return workouts.compactMap { workout -> HeatWorkoutInput? in
            let minutes = workout.duration / 60.0
            guard minutes >= 1.0, Self.isOutdoorWorkout(workout) else { return nil }
            return HeatWorkoutInput(
                date: workout.startDate,
                durationMinutes: minutes,
                weather: WorkoutWeatherSnapshot(healthKitMetadata: workout.metadata, observedAt: workout.startDate)
            )
        }
    }

    /// Whether a workout was done outdoors (and so could carry heat stress).
    nonisolated private static func isOutdoorWorkout(_ workout: HKWorkout) -> Bool {
        if let indoor = workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool {
            return !indoor
        }
        // No indoor flag — fall back to the activity type. Only types that
        // are normally done outdoors qualify; gym/studio types are excluded
        // so a hot-day strength session isn't counted as heat exposure.
        return outdoorCapableTypes.contains(workout.workoutActivityType)
    }

    nonisolated private static let outdoorCapableTypes: Set<HKWorkoutActivityType> = [
        .running, .walking, .hiking, .cycling, .crossCountrySkiing,
        .downhillSkiing, .snowboarding, .skatingSports, .paddleSports,
        .rowing, .golf, .tennis, .soccer, .americanFootball, .rugby,
        .baseball, .softball, .cricket, .hockey, .lacrosse, .trackAndField,
        .swimming, .surfingSports, .climbing, .equestrianSports
    ]
}
