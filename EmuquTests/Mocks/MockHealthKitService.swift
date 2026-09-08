import Combine
@testable import Emuqu
import Foundation
import os

/// Mock HealthKit service for testing without real HealthKit access.
/// Returns configurable sleep data, training load, and vitals.
@MainActor
final class MockHealthKitService: HealthKitServiceProtocol {
    // MARK: - Sleep Data Observation

    var startObservingSleepDataCallCount = 0
    var stopObservingSleepDataCallCount = 0
    func startObservingSleepData() {
        startObservingSleepDataCallCount += 1
    }

    func stopObservingSleepData() {
        stopObservingSleepDataCallCount += 1
    }

    // MARK: - Configurable Responses
    /// The protocol reads this `nonisolated`, so the mock keeps it behind a
    /// lock rather than on the main actor with the rest of its state.
    nonisolated var isHealthKitAvailable: Bool {
        get { availableBox.withLock { $0 } }
        set { availableBox.withLock { $0 = newValue } }
    }
    private let availableBox = OSAllocatedUnfairLock<Bool>(initialState: true)
    @MainActor var authorizationRequested: Bool = true

    var authorizationError: Error?

    var sleepData: SleepData = .empty
    var sleepDataError: Error?

    var daytimeRestingHR: Double?
    var daytimeRestingHRError: Error?

    var trainingLoad: HealthKitManager.TrainingLoad = .init(
        vo2Max: nil,
        recentWorkouts: [],
        weeklyLoadScore: 0,
        daysSinceHardWorkout: nil,
        acuteChronicRatio: nil,
        metrics: nil
    )

    var vo2Max: Double?

    var recoveryVitals: RecoveryVitals = .init(
        respiratoryRate: nil,
        respiratoryRateBaseline: nil,
        oxygenSaturation: nil,
        oxygenSaturationMin: nil,
        wristTemperature: nil,
        wristTemperatureBaseline: nil,
        restingHeartRate: nil
    )
    var recoveryVitalsError: Error?

    // MARK: - Protocol Implementation

    func requestAuthorization() async throws {
        if let error = authorizationError { throw error }
    }

    func fetchLastNightSleep(relativeTo _: Date = Date()) async throws -> SleepData {
        if let error = sleepDataError { throw error }
        return sleepData
    }

    func fetchSleepData(
        for _: Date,
        recordingEnd _: Date,
        rrPoints _: [RRPoint]?,
        autoSleepExtension _: SleepResolver.AutoSleepExtension?
    ) async throws -> SleepData {
        if let error = sleepDataError { throw error }
        return sleepData
    }

    func fetchDaytimeRestingHR(for _: Date) async throws -> Double? {
        if let error = daytimeRestingHRError { throw error }
        return daytimeRestingHR
    }

    func calculateTrainingLoad(relativeTo _: Date = Date()) async -> HealthKitManager.TrainingLoad {
        trainingLoad
    }

    func fetchVO2Max() async -> Double? {
        vo2Max
    }

    /// Stub for protocol conformance with the real service's trend
    /// overload. Returns nil (no trend) by default; tests that
    /// care about the trend should subclass and override.
    func fetchVO2MaxTrend(days _: Int) async -> (latest: Double, oldestInWindow: Double, sampleCount: Int)? {
        nil
    }

    func fetchRecoveryVitals(relativeTo _: Date = Date()) async -> RecoveryVitals {
        recoveryVitals
    }

    // MARK: - Background HR Sleep Estimation

    var healthKitHRSleepData: SleepData?

    func estimateSleepFromHealthKitHR(windowStart _: Date, windowEnd _: Date, minimumSamples _: Int = 12, minimumSleepMinutes _: Int = 120) async -> SleepData? {
        healthKitHRSleepData
    }

    // MARK: - Heart Rate Samples

    var heartRateSamples: [(date: Date, hr: Double)] = []
    var heartRateSamplesError: Error?

    func fetchHeartRateSamples(from _: Date, to _: Date) async throws -> [(date: Date, hr: Double)] {
        if let error = heartRateSamplesError { throw error }
        return heartRateSamples
    }

    // MARK: - Apple Health Export

    var exportSessionMetricsError: Error?

    func exportSessionMetrics(from _: HRVSession) async throws {
        if let error = exportSessionMetricsError { throw error }
    }

    var exportSleepError: Error?

    func exportSleepToHealthKit(sleepData _: SleepData, sessionId _: UUID) async throws {
        if let error = exportSleepError { throw error }
    }

    // MARK: - Dashboard Queries

    var trainingMetrics = TrainingMetrics.empty

    func calculateTrainingMetrics(forMorningReading _: Bool) async -> TrainingMetrics {
        trainingMetrics
    }

    var workoutInRange = false

    func hasWorkoutInRange(from _: Date, to _: Date) async -> Bool {
        workoutInRange
    }

    var additionalSleepEnd: Date?
    var additionalSleepStart: Date?

    func findAdditionalSleepRange(after anchor: Date, before _: Date) async -> (start: Date, end: Date)? {
        guard let end = additionalSleepEnd else { return nil }
        return (additionalSleepStart ?? anchor, end)
    }

    var sleepTrend: [SleepData] = []
    var sleepTrendError: Error?

    func fetchSleepTrend(days _: Int) async throws -> [SleepData] {
        if let error = sleepTrendError { throw error }
        return sleepTrend
    }

    func analyzeSleepTrend(from _: [SleepData]) -> SleepTrendStats {
        SleepTrendStats(
            averageSleepMinutes: 0, averageDeepSleepMinutes: nil,
            averageEfficiency: 0, trend: .stable, nightsAnalyzed: 0
        )
    }

    var hrStats: HeartRateStats?
    var hrStatsError: Error?

    func calculateHRStats(from _: Date, to _: Date) async throws -> HeartRateStats? {
        if let error = hrStatsError { throw error }
        return hrStats
    }
}
