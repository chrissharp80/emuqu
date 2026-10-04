import Foundation
import HealthKit

// The sleep-data and training-load entry points that dispatch into the per-
// domain extensions. Authorization, the shared types and the store handle live
// in `HealthKitManager.swift`.

extension HealthKitManager {
    // MARK: - Sleep Data

    typealias SleepTrendStats = Emuqu.SleepTrendStats

    // Sleep queries and HR-based estimation live in HealthKitManager+Sleep.swift;
    // trends, exports, and the sleep observer in HealthKitManager+SleepTrends.swift

    // MARK: - Training Load & Fitness Data

    typealias TrainingMetrics = Emuqu.TrainingMetrics

    typealias TrainingLoad = Emuqu.TrainingLoad

    // MARK: - Recovery Vitals

    typealias RecoveryVitals = Emuqu.RecoveryVitals

    // Recovery vitals fetch implementations live in VitalsHealthQueries+Queries.swift

    // Training load, workout queries, and VO2max fetch implementations live in
    // TrainingHealthQueries+Queries.swift

    // SDNN export implementations live in HealthKitManager+HRV.swift

    // MARK: - Apple Health Export

    // exportHeartRate and exportRestingHeartRate live in HealthKitManager+HeartRate.swift
    // exportWindowedHRV implementation lives in HealthKitManager+HRV.swift
    // exportHeartRateSeries lives in HealthKitManager+HeartRate.swift
    // exportSleepToHealthKit, deleteAllAppWrittenSleepSamples, and exportSessionMetrics
    // live in HealthKitManager+SleepTrends.swift

    // MARK: - Sleep Data Observer

    // start/stopObservingSleepData live in HealthKitManager+SleepTrends.swift

    // MARK: - Vitals Data Observer

    // start/stopObservingVitalsData live in VitalsHealthQueries+Queries.swift

    func fetchBiometricProfile() async -> BiometricProfile {
        async let bodyWeightKg = fetchLatestBodyMassKg()
        let sex: HKBiologicalSex? = (try? healthStore.biologicalSex().biologicalSex)
        // HealthKit's birth-date components are Gregorian; building them with
        // the user's calendar (Buddhist, Japanese) would give the wrong year.
        let dob: Date? = {
            guard let components = try? healthStore.dateOfBirthComponents(),
                  let date = Calendar(identifier: .gregorian).date(from: components) else { return nil }
            return date
        }()
        return await BiometricProfile(
            bodyWeightKg: bodyWeightKg,
            biologicalSex: sex,
            dateOfBirth: dob
        )
    }

    /// Latest body-mass sample in kg, or nil if none / not authorized.
    func fetchLatestBodyMassKg() async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return nil }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await runBoundedQuery(timeout: Self.backgroundAggregateQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                resolve(Self.firstBodyMassKg(samples))
            }
        }
    }

    nonisolated private static func firstBodyMassKg(_ samples: [HKSample]?) -> Double? {
        guard let sample = samples?.first as? HKQuantitySample else { return nil }
        return sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
    }

    // MARK: - Errors

}

// MARK: - Type aliases
//
// The declarations live in `HealthDataTypes.swift`; these keep
// `HealthKitManager.WorkoutSummary` and friends resolving at every call site.

extension HealthKitManager {
    typealias WorkoutSummary = HealthWorkoutSummary
    typealias BiometricProfile = HealthBiometricProfile
    typealias HealthKitError = HealthStoreError
}
