import Foundation
import HealthKit

/// HealthKit queries about training: workouts, routes, VO2 max, training load.
///
/// ## Why this is its own type
///
/// `HealthKitManager` was 4,531 lines across ten files, the third largest type
/// in the codebase. 734 of them are these queries, and they need exactly three
/// things from the manager — the store, the bounded-query helper, and the
/// sample counter. Measured before the move, not assumed.
///
/// That ratio is what makes this seam real rather than convenient: recovery and
/// pull both needed a dozen members and stayed coupled by design, while this is
/// a body of read-only queries that happen to share an `HKHealthStore`.
///
/// Holds its owner strongly and is built on demand by the manager — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct TrainingHealthQueries {
    let manager: HealthKitManager

}
