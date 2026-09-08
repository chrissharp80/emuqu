import Foundation
import HealthKit

// Vitals queries live in `VitalsHealthQueries` — 486 lines out
// of HealthKitManager, along the same seam as the training queries.
//
// These forwarders keep every existing call site working. The queries needed
// six members of the manager: the store, the two query helpers, the own-writes
// heart-rate predicate, and the two pieces of observer bookkeeping that keep
// live vitals updates flowing.

extension HealthKitManager {
    /// The vitals-query subsystem. Lazy — a launch that never opens the
    /// recovery screen never builds it.
    var vitals: VitalsHealthQueries {
        VitalsHealthQueries(manager: self)
    }

    // MARK: - Queries

    func fetchRecoveryVitals(
        relativeTo referenceDate: Date = Date()
    ) async -> HealthKitManager.RecoveryVitals {
        await vitals.fetchRecoveryVitals(relativeTo: referenceDate)
    }

    func startObservingVitalsData() {
        vitals.startObservingVitalsData()
    }

    func fetchDailyActivity(days: Int = 7) async -> [HealthKitManager.DailyActivity] {
        await vitals.fetchDailyActivity(days: days)
    }

    func fetchSumSteps(from start: Date, to end: Date) async -> Int {
        await vitals.fetchSumSteps(from: start, to: end)
    }

    func fetchSumDistance(from start: Date, to end: Date) async -> Double {
        await vitals.fetchSumDistance(from: start, to: end)
    }

    func fetchSumFlights(from start: Date, to end: Date) async -> Int {
        await vitals.fetchSumFlights(from: start, to: end)
    }
}
