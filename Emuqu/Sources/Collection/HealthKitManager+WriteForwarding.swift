import Foundation
import HealthKit

// Exports and observers live in `HealthWriteAndObserve`, keeping ~1,000
// lines off `HealthKitManager`.

extension HealthKitManager {
    func exportSessionMetrics(from session: HRVSession) async throws {
        try await writes.exportSessionMetrics(from: session)
    }

    func deleteAllAppWrittenSleepSamples() async throws -> Int {
        try await writes.deleteAllAppWrittenSleepSamples()
    }

    func startObservingSleepData() { writes.startObservingSleepData() }
    func stopObservingSleepData() { writes.stopObservingSleepData() }

    nonisolated static func categoryResult(
        _ results: [HKSample]?, _ error: Error?
    ) -> Result<[HKCategorySample], Error> {
        HealthWriteAndObserve.categoryResult(results, error)
    }
}
