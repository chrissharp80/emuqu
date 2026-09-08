import Combine
import Foundation

/// Protocol for HealthKit integration
///
/// `@MainActor` alongside `HealthKitManager`: the implementation is
/// `@Observable` and read by SwiftUI, so its state always has to change on the
/// main actor.
@MainActor
protocol HealthKitServiceProtocol: Sendable {
    /// Whether HealthKit is available on this device
    nonisolated var isHealthKitAvailable: Bool { get }

    /// Has `requestAuthorization` been called this app session AND
    /// returned without throwing. Doesn't tell you whether the user
    /// granted access — HealthKit hides that — but DOES tell you
    /// whether to bother running queries (queries before this point
    /// silently return empty for any unauthorized type, which the
    /// dashboard misreads as "no data" and waits 15s for).
    var authorizationRequested: Bool { get }

    /// Request authorization for HealthKit access
    func requestAuthorization() async throws

    // MARK: - Sleep Data Observation

    /// Start observing HealthKit for new sleep data (e.g. Apple Watch sync)
    func startObservingSleepData()

    /// Stop observing HealthKit sleep data
    func stopObservingSleepData()

    // MARK: - Sleep Data

    /// Fetch sleep data for last night (or a specific night via referenceDate)
    func fetchLastNightSleep(relativeTo referenceDate: Date) async throws -> SleepData

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

    /// Fetch VO2max
    func fetchVO2Max() async -> Double?

    /// VO2max trend over a window. Returns
    /// (latest, oldestInWindow, sampleCount). nil when no samples.
    func fetchVO2MaxTrend(days: Int) async -> (latest: Double, oldestInWindow: Double, sampleCount: Int)?

    // MARK: - Recovery Vitals

    /// Fetch recovery vitals (respiratory rate, SpO2, temperature)
    func fetchRecoveryVitals(relativeTo referenceDate: Date) async -> RecoveryVitals

    // MARK: - Background HR Sleep Estimation

    /// Estimate sleep from Apple Watch background HR samples when native sleep tracking is unavailable
    func estimateSleepFromHealthKitHR(windowStart: Date, windowEnd: Date, minimumSamples: Int, minimumSleepMinutes: Int) async -> SleepData?

    /// Fetch raw heart rate samples for Watch-based sleep detection
    func fetchHeartRateSamples(from start: Date, to end: Date) async throws -> [(date: Date, hr: Double)]

    // MARK: - Apple Health Export

    /// Export session metrics (SDNN, HR, resting HR, sleep) to Apple Health
    func exportSessionMetrics(from session: HRVSession) async throws

    /// Export sleep data to Apple Health as sleep category samples
    func exportSleepToHealthKit(sleepData: SleepData, sessionId: UUID) async throws

    // MARK: - Dashboard Queries

    /// Calculate training metrics (TRIMP, ATL/CTL/TSB) for dashboard display.
    /// - Parameter forMorningReading: When true, freezes ATL/CTL/TSB through yesterday only.
    func calculateTrainingMetrics(forMorningReading: Bool) async -> TrainingMetrics

    /// Check if any workout exists in a date range (used to reject false sleep detections)
    func hasWorkoutInRange(from start: Date, to end: Date) async -> Bool

    /// Find the earliest-start and latest-end of any additional HealthKit
    /// sleep samples in the window. Used by extended-sleep detection to
    /// verify that a candidate extension actually starts near the session end
    /// (and is not a separate afternoon nap).
    func findAdditionalSleepRange(after anchor: Date, before cutoff: Date) async -> (start: Date, end: Date)?

    /// Fetch sleep data for the last N days (for trend analysis)
    func fetchSleepTrend(days: Int) async throws -> [SleepData]

    /// Analyze a series of sleep data into trend statistics
    func analyzeSleepTrend(from sleepData: [SleepData]) -> SleepTrendStats

    /// Calculate HR statistics (mean, min, max, nadir time) for a date range
    func calculateHRStats(from start: Date, to end: Date) async throws -> HeartRateStats?
}

// MARK: - Default Parameter Convenience

extension HealthKitServiceProtocol {
    func fetchLastNightSleep() async throws -> SleepData {
        try await fetchLastNightSleep(relativeTo: Date())
    }

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

    func fetchRecoveryVitals() async -> RecoveryVitals {
        await fetchRecoveryVitals(relativeTo: Date())
    }

    func calculateTrainingLoad() async -> HealthKitManager.TrainingLoad {
        await calculateTrainingLoad(relativeTo: Date())
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

    // Bridge: protocol's 1-param signature → concrete's 4-param method with defaults.
    // Reads user's physiological max/resting HR from SettingsManager so TRIMP is
    // normalised against the athlete, not each workout's own peak (a
    // per-workout self.maxHR fallback inflates easy activities' scores).
    func calculateTrainingMetrics(forMorningReading: Bool) async -> TrainingMetrics {
        let settings = AppDependencies.current.app.settingsManager.settings
        return await calculateTrainingMetrics(
            restingHR: Double(settings.effectiveRestingHR),
            userMaxHR: Double(settings.effectiveMaxHR),
            forMorningReading: forMorningReading,
            relativeTo: Date()
        )
    }

    // Bridge: protocol's 1-param signature → concrete's 2-param method with default relativeTo.
    func fetchSleepTrend(days: Int) async throws -> [SleepData] {
        try await fetchSleepTrend(days: days, relativeTo: Date())
    }
}
