import Foundation
import HealthKit

/// HealthKit's heart rate: reading night windows and daytime resting HR,
/// computing the stats the morning pipeline needs, and writing HR and resting
/// HR back.
///
/// It also owns the bounded-query plumbing every other HealthKit call uses —
/// `runBoundedQuery`, `runBoundedThrowingQuery` and the per-domain timeouts —
/// and `HealthKitManager` forwards it for the other query classes.
///
/// Holds its owner strongly and is built on demand by the manager — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct HeartRateHealthQueries {
    let manager: HealthKitManager

}
