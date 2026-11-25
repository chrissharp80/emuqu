import Foundation
import HealthKit

/// HealthKit queries about training: workouts, routes, VO2 max, training load.
///
/// A value over the parts it uses: queries run through `access`, and
/// heart-rate reads use `heartRate`'s predicate, and the app's own workouts
/// are read from `archive`.
@MainActor
struct TrainingHealthQueries {
    let access: HealthKitAccess
    let heartRate: HeartRateHealthQueries
    /// The archive whose workouts training load merges with HealthKit's,
    /// resolved on each read.
    let archive: @Sendable () -> SessionArchive
}
