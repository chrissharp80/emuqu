import Combine
import Foundation

/// Protocol for HealthKit integration
///
/// `@MainActor` alongside `HealthKitManager`: the implementation is
/// `@Observable` and read by SwiftUI, so its state always has to change on the
/// main actor.
@MainActor
protocol HealthKitServiceProtocol: Sendable {
    // The requirements are the queries the injected services
    // (`MorningProcessingService`, `SessionAcceptanceService`,
    // `ReanalysisService`, `HRVAnalysisPipeline`, `SleepBoundaryResolver`)
    // make through this protocol, so a test mock stubs only those. Everything
    // else (authorization, observers, trends, exports, dashboard queries) is
    // called on the concrete `HealthKitManager` and is not part of it.

    /// Whether HealthKit is available on this device
    nonisolated var isHealthKitAvailable: Bool { get }

    // MARK: - Sleep Data

    /// Fetch sleep data for a recording period.
    /// When rrPoints are provided, HR analysis validates HealthKit boundaries and computes RMSSD quality metrics.
    /// When autoSleepExtension is provided, the resolver treats the session
    /// and the extension as a two-interval envelope (gap between is excluded from totals).
    func fetchSleepData(
        for recordingStart: Date,
        recordingEnd: Date,
        rrPoints: [RRPoint]?,
        autoSleepExtension: SleepResolver.AutoSleepExtension?
    ) async throws -> SleepData

    /// Total qualifying daytime-nap sleep (minutes) for the waking day leading
    /// into the night anchored at `nightAnchor`. Credited toward the recovery
    /// score's 24-hour sleep duration. Conformers without nap support return 0
    /// via the default implementation below.
    func fetchDaytimeNapMinutes(nightAnchoredAt nightAnchor: Date) async -> Int

    // MARK: - Heart Rate

    /// Fetch daytime resting heart rate
    func fetchDaytimeRestingHR(for sleepDate: Date) async throws -> Double?

    // MARK: - Training Load

    /// Calculate training load metrics
    /// - Parameter relativeTo: Anchor date for calculations. Defaults to now.
    ///   For historical sessions, pass the session's end date so ATL/CTL/TSB reflect that point in time.
    func calculateTrainingLoad(relativeTo referenceDate: Date) async -> HealthKitManager.TrainingLoad

    // MARK: - Recovery Vitals

    /// Fetch recovery vitals (respiratory rate, SpO2, temperature)
    func fetchRecoveryVitals(relativeTo referenceDate: Date) async -> RecoveryVitals

    // MARK: - Background HR Sleep Estimation

    /// Estimate sleep from Apple Watch background HR samples when native sleep tracking is unavailable
    func estimateSleepFromHealthKitHR(windowStart: Date, windowEnd: Date, minimumSamples: Int, minimumSleepMinutes: Int) async -> SleepData?

    /// Sleep boundaries inferred from the strap's own RR series — the
    /// fallback when HealthKit has no sleep for the night. The default calls
    /// `HealthKitManager.estimateSleepFromHR`; a test mock can stub it.
    func estimateSleepFromRR(rrPoints: [RRPoint], recordingStart: Date) -> SleepData?

    // MARK: - Apple Health Export

    /// Export session metrics (SDNN, HR, resting HR, sleep) to Apple Health
    func exportSessionMetrics(from session: HRVSession) async throws
}

// MARK: - Default Parameter Convenience

extension HealthKitServiceProtocol {
    /// Conformers without daytime-nap support (e.g. test mocks) contribute no
    /// nap credit. `HealthKitManager` overrides this with the real query.
    func fetchDaytimeNapMinutes(nightAnchoredAt nightAnchor: Date) async -> Int { 0 }

    func fetchSleepData(
        for recordingStart: Date,
        recordingEnd: Date
    ) async throws -> SleepData {
        try await fetchSleepData(
            for: recordingStart, recordingEnd: recordingEnd,
            rrPoints: nil, autoSleepExtension: nil
        )
    }

    func fetchSleepData(
        for recordingStart: Date,
        recordingEnd: Date,
        rrPoints: [RRPoint]?
    ) async throws -> SleepData {
        try await fetchSleepData(
            for: recordingStart, recordingEnd: recordingEnd,
            rrPoints: rrPoints, autoSleepExtension: nil
        )
    }

    func calculateTrainingLoad() async -> HealthKitManager.TrainingLoad {
        await calculateTrainingLoad(relativeTo: Date())
    }

    func estimateSleepFromRR(rrPoints: [RRPoint], recordingStart: Date) -> SleepData? {
        HealthKitManager.estimateSleepFromHR(rrPoints: rrPoints, recordingStart: recordingStart)
    }

    func estimateSleepFromHealthKitHR(windowStart: Date, windowEnd: Date) async -> SleepData? {
        await estimateSleepFromHealthKitHR(windowStart: windowStart, windowEnd: windowEnd, minimumSamples: 12, minimumSleepMinutes: 120)
    }
}

// MARK: - HealthKitManager Conformance

extension HealthKitManager: HealthKitServiceProtocol {
    func calculateTrainingLoad(relativeTo referenceDate: Date) async -> TrainingLoad {
        await calculateTrainingLoad(days: 7, forMorningReading: true, relativeTo: referenceDate)
    }
}
