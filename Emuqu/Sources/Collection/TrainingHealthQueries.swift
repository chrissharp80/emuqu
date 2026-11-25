import Foundation
import HealthKit

/// HealthKit queries about training: workouts, routes, VO2 max, training load.
///
/// A value over the parts it uses: queries run through `access`, and
/// heart-rate reads use `heartRate`'s predicate.
@MainActor
struct TrainingHealthQueries {
    let access: HealthKitAccess
    let heartRate: HeartRateHealthQueries

}
