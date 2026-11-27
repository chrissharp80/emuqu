@testable import Emuqu
import Foundation

/// HealthKit stand-in for the services that take a `HealthKitServiceProtocol`
/// (`MorningProcessingService`, `HRVAnalysisPipeline`, `ReanalysisService`,
/// `SleepBoundaryResolver`, `SessionAcceptanceService`).
///
/// It implements only the protocol's requirements and answers every query
/// with "no HealthKit data": empty sleep, no Watch HR estimate, zero training
/// load, no vitals, and exports that succeed. `daytimeRestingHR`,
/// `trainingLoadMetrics` and `workoutQueryAnswers` are the answers a test sets. A test that needs another answer (a HealthKit error,
/// real sleep, vitals) adds a settable property here and uses it, rather than
/// the mock carrying knobs no test drives. `fetchDaytimeNapMinutes` and
/// `estimateSleepFromRR` come from the protocol's extension (no naps; the
/// strap's own RR estimate).
@MainActor
final class MockHealthKitService: HealthKitServiceProtocol {
    nonisolated var isHealthKitAvailable: Bool { true }

    /// What `fetchDaytimeRestingHR(for:)` returns.
    var daytimeRestingHR: Double?

    func fetchSleepData(
        for _: Date,
        recordingEnd _: Date,
        rrPoints _: [RRPoint]?,
        autoSleepExtension _: SleepResolver.AutoSleepExtension?,
        rrStart _: Date?
    ) async throws -> SleepData {
        .empty
    }

    func fetchDaytimeRestingHR(for _: Date) async throws -> Double? {
        daytimeRestingHR
    }

    /// The training metrics `calculateTrainingLoad(relativeTo:)` reports;
    /// nil, the default, is no training load.
    var trainingLoadMetrics: TrainingMetrics?

    func calculateTrainingLoad(relativeTo _: Date) async -> HealthKitManager.TrainingLoad {
        HealthKitManager.TrainingLoad(
            vo2Max: nil,
            recentWorkouts: [],
            weeklyLoadScore: 0,
            daysSinceHardWorkout: nil,
            acuteChronicRatio: nil,
            metrics: trainingLoadMetrics
        )
    }

    /// Whether HealthKit answers the workout query behind
    /// `calculateTrainingLoadIfAnswered(relativeTo:)`; false is a store that
    /// is locked or a query that timed out.
    var workoutQueryAnswers = true

    func calculateTrainingLoadIfAnswered(relativeTo date: Date) async -> HealthKitManager.TrainingLoad? {
        guard workoutQueryAnswers else { return nil }
        return await calculateTrainingLoad(relativeTo: date)
    }

    func fetchRecoveryVitals(relativeTo _: Date) async -> RecoveryVitals {
        RecoveryVitals(
            respiratoryRate: nil,
            respiratoryRateBaseline: nil,
            oxygenSaturation: nil,
            oxygenSaturationMin: nil,
            wristTemperature: nil,
            wristTemperatureBaseline: nil,
            restingHeartRate: nil
        )
    }

    func estimateSleepFromHealthKitHR(
        windowStart _: Date, windowEnd _: Date, minimumSamples _: Int, minimumSleepMinutes _: Int
    ) async -> SleepData? {
        nil
    }

    /// The ids of the sessions `exportSessionMetrics` was asked to write, in order.
    private(set) var exportedSessionIds: [UUID] = []

    func exportSessionMetrics(from session: HRVSession) async throws {
        exportedSessionIds.append(session.id)
    }
}
