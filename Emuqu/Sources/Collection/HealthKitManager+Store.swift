import Foundation
import HealthKit

// The names the per-domain query results go by on `HealthKitManager`.
// Authorization lives in `HealthKitAuthorization.swift`, the workout export
// backfill in `HealthKitBackfill.swift`.

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
    // exportHRV and removeExportedHRV live in HealthKitManager+HRV.swift
    // exportHeartRateSeries lives in HealthKitManager+HeartRate.swift
    // exportSleepToHealthKit, deleteAllAppWrittenSleepSamples, and exportSessionMetrics
    // live in HealthKitManager+SleepTrends.swift

    // MARK: - Sleep Data Observer

    // start/stopObservingSleepData live in HealthKitManager+SleepTrends.swift

    // MARK: - Vitals Data Observer

    // start/stopObservingVitalsData live in VitalsHealthQueries+Queries.swift

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
