import Foundation
import HealthKit

/// HealthKit queries about vitals and daily activity: respiratory rate, wrist
/// temperature, blood oxygen, steps, distance, flights.
///
/// Holds its owner strongly and is built on demand by the manager — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct VitalsHealthQueries {
    let manager: HealthKitManager

}
