import Foundation
import HealthKit

// Heart rate lives in `HeartRateHealthQueries`, like the other four
// HealthKit domains that are off the manager.
//
// The bounded-query helpers below are forwarded because every other query class
// uses them; they live with heart rate for historical reasons, not by design.

extension HealthKitManager {
    func fetchHeartRateSamples(from start: Date, to end: Date) async throws -> [(date: Date, hr: Double)] {
        try await heartRate.fetchHeartRateSamples(from: start, to: end)
    }

    func fetchHeartRateSamplesDetailed(from start: Date, to end: Date) async throws -> [HeartRateSample] {
        try await heartRate.fetchHeartRateSamplesDetailed(from: start, to: end)
    }

    func fetchDaytimeRestingHR(for sleepDate: Date) async throws -> Double? {
        try await heartRate.fetchDaytimeRestingHR(for: sleepDate)
    }

    func calculateHRStats(from start: Date, to end: Date) async throws -> HeartRateStats? {
        try await heartRate.calculateHRStats(from: start, to: end)
    }

    func exportHeartRate(value: Double, at date: Date, sessionId: UUID) async throws {
        try await heartRate.exportHeartRate(value: value, at: date, sessionId: sessionId)
    }

    func exportRestingHeartRate(value: Double, at date: Date, sessionId: UUID) async throws {
        try await heartRate.exportRestingHeartRate(value: value, at: date, sessionId: sessionId)
    }

    func exportHeartRateSeries(from rrPoints: [RRPoint], sessionStart: Date, sessionId: UUID) async throws {
        try await heartRate.exportHeartRateSeries(
            from: rrPoints, sessionStart: sessionStart, sessionId: sessionId
        )
    }

    func hrReadExcludingOwnWrites(dateRange: NSPredicate) -> NSPredicate {
        heartRate.hrReadExcludingOwnWrites(dateRange: dateRange)
    }

    // MARK: - Bounded-query plumbing, used by every query class

    func runBoundedQuery<T: Sendable>(
        timeout: TimeInterval,
        makeQuery: (@escaping @Sendable (T?) -> Void) -> HKQuery
    ) async -> T? {
        await heartRate.runBoundedQuery(timeout: timeout, makeQuery: makeQuery)
    }

    func runBoundedThrowingQuery<T: Sendable>(
        timeout: TimeInterval,
        makeQuery: (@escaping @Sendable (Result<T, Error>) -> Void) -> HKQuery,
        onTimeout: @escaping @Sendable () -> Result<T, Error>
    ) async throws -> T {
        try await heartRate.runBoundedThrowingQuery(
            timeout: timeout, makeQuery: makeQuery, onTimeout: onTimeout
        )
    }

    nonisolated static func sampleResult(_ results: [HKSample]?, _ error: Error?) -> Result<[HKSample], Error> {
        HeartRateHealthQueries.sampleResult(results, error)
    }

    nonisolated static func quantityResult(
        _ results: [HKSample]?, _ error: Error?
    ) -> Result<[HKQuantitySample], Error> {
        HeartRateHealthQueries.quantityResult(results, error)
    }

    nonisolated static var vitalsQueryTimeoutSec: TimeInterval { HeartRateHealthQueries.vitalsQueryTimeoutSec }
    nonisolated static var sleepQueryTimeoutSec: TimeInterval { HeartRateHealthQueries.sleepQueryTimeoutSec }
    nonisolated static var hrvQueryTimeoutSec: TimeInterval { HeartRateHealthQueries.hrvQueryTimeoutSec }
    nonisolated static var backgroundAggregateQueryTimeoutSec: TimeInterval {
        HeartRateHealthQueries.backgroundAggregateQueryTimeoutSec
    }
}
