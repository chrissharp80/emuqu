import Foundation
import HealthKit

/// HealthKit's heart rate: reading night windows and daytime resting HR,
/// computing the stats the morning pipeline needs, and writing HR and resting
/// HR back.
///
/// It also owns the bounded-query plumbing every other HealthKit call uses —
/// `runBoundedQuery`, `runBoundedThrowingQuery` and the per-domain timeouts.
/// That is a historical accident of where it was written rather than a
/// judgement that it belongs here; it stays put in this move so the change is a
/// straight relocation, and `HealthKitManager` forwards it for the other
/// query classes.
///
/// ## Why this is not on `HealthKitManager`
///
/// As a 506-line extension it would be. This is one of five
/// query domains split out, alongside vitals, training, sleep reads and the
/// write/observe half.
///
/// Holds its owner strongly and is built on demand by the manager — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct HeartRateHealthQueries {
    let manager: HealthKitManager

}
