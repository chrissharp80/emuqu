import Foundation
import HealthKit

/// HealthKit queries about vitals and daily activity: respiratory rate, wrist
/// temperature, blood oxygen, steps, distance, flights.
///
/// Split out of `HealthKitManager`, alongside
/// `TrainingHealthQueries`. 486 lines needing six members of the manager —
/// the store, the query helpers, and the observer bookkeeping that keeps live
/// vitals updates flowing.
///
/// Holds its owner strongly and is built on demand by the manager — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct VitalsHealthQueries {
    let manager: HealthKitManager

}
