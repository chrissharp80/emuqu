import Foundation
import HealthKit

/// HealthKit queries about training: workouts, routes, VO2 max, training load.
///
/// Holds its owner strongly and is built on demand by the manager — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct TrainingHealthQueries {
    let manager: HealthKitManager

}
