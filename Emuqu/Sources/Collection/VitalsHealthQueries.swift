import Foundation
import HealthKit

/// HealthKit queries about vitals and daily activity: respiratory rate, wrist
/// temperature, blood oxygen, steps, distance, flights.
///
/// A value over the parts it uses: queries run through `access`, heart-rate
/// reads use `heartRate`'s predicate, and the vitals observers live in
/// `observation`.
@MainActor
struct VitalsHealthQueries {
    let access: HealthKitAccess
    let heartRate: HeartRateHealthQueries
    let observation: HealthObservation

}
