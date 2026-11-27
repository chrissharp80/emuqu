import Combine
import Foundation
import HealthKit

/// Protocol for HealthKit integration
///
/// `@MainActor`, like the query types its conformer (`HealthKitService`)
/// answers through.
@MainActor
protocol HealthKitServiceProtocol: Sendable {
    // The requirements are the queries the injected services
    // (`MorningProcessingService`, `SessionAcceptanceService`,
    // `ReanalysisService`, `HRVAnalysisPipeline`, `SleepBoundaryResolver`)
    // make through this protocol, so a test mock stubs only those. Everything
    // else (authorization, observers, trends, exports, dashboard queries) is
    // called on `HealthKitManager`'s parts and is not part of it.

    /// Whether HealthKit is available on this device
    nonisolated var isHealthKitAvailable: Bool { get }

    // MARK: - Sleep Data

    /// Fetch sleep data for a recording period.
    /// When rrPoints are provided, HR analysis validates HealthKit boundaries and computes RMSSD quality metrics.
    /// When autoSleepExtension is provided, the resolver treats the session
    /// and the extension as a two-interval envelope (gap between is excluded from totals).
    /// `rrStart` is when the strap recording the beats started, for a search
    /// range wider than the recording; nil means `recordingStart`.
    func fetchSleepData(
        for recordingStart: Date,
        recordingEnd: Date,
        rrPoints: [RRPoint]?,
        autoSleepExtension: SleepResolver.AutoSleepExtension?,
        rrStart: Date?
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

    /// `calculateTrainingLoad(relativeTo:)`, but nil when HealthKit did not
    /// answer the workout query (the store locked, an error, a timeout), so a
    /// stored training snapshot is never rewritten from a failed query read
    /// as a period with no workouts.
    func calculateTrainingLoadIfAnswered(relativeTo referenceDate: Date) async -> HealthKitManager.TrainingLoad?

    // MARK: - Recovery Vitals

    /// Fetch recovery vitals (respiratory rate, SpO2, temperature)
    func fetchRecoveryVitals(relativeTo referenceDate: Date) async -> RecoveryVitals

    // MARK: - Background HR Sleep Estimation

    /// Estimate sleep from Apple Watch background HR samples when native sleep tracking is unavailable
    func estimateSleepFromHealthKitHR(windowStart: Date, windowEnd: Date, minimumSamples: Int, minimumSleepMinutes: Int) async -> SleepData?

    /// Sleep boundaries inferred from the strap's own RR series — the
    /// fallback when HealthKit has no sleep for the night. The default calls
    /// `HRSleepEstimator.estimateSleepFromHR` off the main actor (it walks
    /// every beat of the night); a test mock can stub it.
    func estimateSleepFromRR(rrPoints: [RRPoint], recordingStart: Date) async -> SleepData?

    // MARK: - Apple Health Export

    /// Export session metrics (SDNN, HR, resting HR, sleep) to Apple Health
    func exportSessionMetrics(from session: HRVSession) async throws
}

// MARK: - Default Parameter Convenience

extension HealthKitServiceProtocol {
    /// Conformers without daytime-nap support (e.g. test mocks) contribute no
    /// nap credit. `HealthKitService` overrides this with the real query.
    func fetchDaytimeNapMinutes(nightAnchoredAt nightAnchor: Date) async -> Int { 0 }

    func fetchSleepData(
        for recordingStart: Date,
        recordingEnd: Date
    ) async throws -> SleepData {
        try await fetchSleepData(
            for: recordingStart, recordingEnd: recordingEnd,
            rrPoints: nil, autoSleepExtension: nil, rrStart: nil
        )
    }

    func fetchSleepData(
        for recordingStart: Date,
        recordingEnd: Date,
        rrPoints: [RRPoint]?
    ) async throws -> SleepData {
        try await fetchSleepData(
            for: recordingStart, recordingEnd: recordingEnd,
            rrPoints: rrPoints, autoSleepExtension: nil, rrStart: nil
        )
    }

    /// A search range wider than the recording, with the beats' own start.
    func fetchSleepData(
        for searchStart: Date,
        recordingEnd: Date,
        rrPoints: [RRPoint]?,
        rrStart: Date
    ) async throws -> SleepData {
        try await fetchSleepData(
            for: searchStart, recordingEnd: recordingEnd,
            rrPoints: rrPoints, autoSleepExtension: nil, rrStart: rrStart
        )
    }

    func fetchSleepData(
        for recordingStart: Date,
        recordingEnd: Date,
        rrPoints: [RRPoint]?,
        autoSleepExtension: SleepResolver.AutoSleepExtension?
    ) async throws -> SleepData {
        try await fetchSleepData(
            for: recordingStart, recordingEnd: recordingEnd,
            rrPoints: rrPoints, autoSleepExtension: autoSleepExtension, rrStart: nil
        )
    }

    func calculateTrainingLoad() async -> HealthKitManager.TrainingLoad {
        await calculateTrainingLoad(relativeTo: Date())
    }

    func estimateSleepFromRR(rrPoints: [RRPoint], recordingStart: Date) async -> SleepData? {
        await Task.detached(priority: .userInitiated) {
            HRSleepEstimator.estimateSleepFromHR(rrPoints: rrPoints, recordingStart: recordingStart)
        }.value
    }

    func estimateSleepFromHealthKitHR(windowStart: Date, windowEnd: Date) async -> SleepData? {
        await estimateSleepFromHealthKitHR(windowStart: windowStart, windowEnd: windowEnd, minimumSamples: 12, minimumSleepMinutes: 120)
    }
}

// MARK: - The app's conformer

/// The protocol over the app's Health queries: each requirement is answered
/// by the query type of its domain. `HealthKitManager.service` builds it.
struct HealthKitService: HealthKitServiceProtocol {
    let heartRate: HeartRateHealthQueries
    let sleepQueries: SleepHealthQueries
    let vitals: VitalsHealthQueries
    let training: TrainingHealthQueries
    let writes: HealthWriteAndObserve

    nonisolated var isHealthKitAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func fetchDaytimeRestingHR(for sleepDate: Date) async throws -> Double? {
        try await heartRate.fetchDaytimeRestingHR(for: sleepDate)
    }

    func fetchSleepData(
        for recordingStart: Date,
        recordingEnd: Date,
        rrPoints: [RRPoint]?,
        autoSleepExtension: SleepResolver.AutoSleepExtension?,
        rrStart: Date?
    ) async throws -> SleepData {
        try await sleepQueries.fetchSleepData(
            for: recordingStart, recordingEnd: recordingEnd,
            rrPoints: rrPoints, autoSleepExtension: autoSleepExtension, rrStart: rrStart
        )
    }

    func fetchDaytimeNapMinutes(nightAnchoredAt nightAnchor: Date) async -> Int {
        await sleepQueries.fetchDaytimeNapMinutes(nightAnchoredAt: nightAnchor)
    }

    func estimateSleepFromHealthKitHR(
        windowStart: Date,
        windowEnd: Date,
        minimumSamples: Int,
        minimumSleepMinutes: Int
    ) async -> SleepData? {
        await sleepQueries.estimateSleepFromHealthKitHR(
            windowStart: windowStart, windowEnd: windowEnd,
            minimumSamples: minimumSamples, minimumSleepMinutes: minimumSleepMinutes
        )
    }

    func fetchRecoveryVitals(relativeTo referenceDate: Date) async -> HealthKitManager.RecoveryVitals {
        await vitals.fetchRecoveryVitals(relativeTo: referenceDate)
    }

    func exportSessionMetrics(from session: HRVSession) async throws {
        try await writes.exportSessionMetrics(from: session)
    }

    /// The morning reading's seven-day load.
    func calculateTrainingLoad(relativeTo referenceDate: Date) async -> HealthKitManager.TrainingLoad {
        await training.calculateTrainingLoad(days: 7, forMorningReading: true, relativeTo: referenceDate)
    }

    func calculateTrainingLoadIfAnswered(relativeTo referenceDate: Date) async -> HealthKitManager.TrainingLoad? {
        await training.answeredTrainingLoad(days: 7, forMorningReading: true, relativeTo: referenceDate)
    }
}
