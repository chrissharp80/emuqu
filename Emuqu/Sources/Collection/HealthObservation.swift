import Foundation
// `@preconcurrency`: HealthKit query types predate Sendable.
@preconcurrency import HealthKit

/// The observer queries that notice when the Watch adds sleep or vitals data,
/// and the versions they bump. Views and listeners watch the versions to
/// re-fetch. `HealthWriteAndObserve` starts and stops the sleep query,
/// `VitalsHealthQueries` the vitals ones.
@Observable
@MainActor
final class HealthObservation {
    /// The running sleep observer query.
    @ObservationIgnored var sleepObserverQuery: HKQuery?
    /// Incremented each time other sources' sleep samples arrive.
    var sleepDataVersion: Int = 0
    /// The pending sleep-cache warm. Apple Watch syncs sleep samples in
    /// bursts of a dozen within a few seconds; each burst cancels the warm
    /// before it, so only the last batch's fetch lands in the cache.
    @ObservationIgnored var sleepCacheWarmTask: Task<Void, Never>?
    /// The running observer queries for the overnight vitals (respiratory
    /// rate, SpO2, wrist temperature, resting HR), which Apple Watch writes
    /// minutes to hours after sleep ends.
    @ObservationIgnored var vitalsObserverQueries: [HKQuery] = []
    /// Incremented each time other sources' vitals samples arrive.
    var vitalsDataVersion: Int = 0

    nonisolated init() {}
}
