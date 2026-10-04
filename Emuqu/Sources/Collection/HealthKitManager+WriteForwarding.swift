import Foundation
import HealthKit

// Exports and observers live in `HealthWriteAndObserve`, keeping ~1,000
// lines off `HealthKitManager`.

extension HealthKitManager {
    func exportSDNN(value: Double, at date: Date, sessionId: UUID) async throws {
        try await writes.exportSDNN(value: value, at: date, sessionId: sessionId)
    }

    func exportSessionMetrics(from session: HRVSession) async throws {
        try await writes.exportSessionMetrics(from: session)
    }

    func exportSleepToHealthKit(sleepData: SleepData, sessionId: UUID) async throws {
        try await writes.exportSleepToHealthKit(sleepData: sleepData, sessionId: sessionId)
    }

    func deleteAllAppWrittenSleepSamples() async throws -> Int {
        try await writes.deleteAllAppWrittenSleepSamples()
    }

    func fetchSleepTrend(days: Int = 7, relativeTo referenceDate: Date = Date()) async throws -> [SleepData] {
        try await writes.fetchSleepTrend(days: days, relativeTo: referenceDate)
    }

    func analyzeSleepTrend(from sleepData: [SleepData]) -> SleepTrendStats {
        writes.analyzeSleepTrend(from: sleepData)
    }

    func startObservingSleepData() { writes.startObservingSleepData() }
    func stopObservingSleepData() { writes.stopObservingSleepData() }

    nonisolated static func categoryResult(
        _ results: [HKSample]?, _ error: Error?
    ) -> Result<[HKCategorySample], Error> {
        HealthWriteAndObserve.categoryResult(results, error)
    }
}
