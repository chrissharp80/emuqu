import Foundation
import HealthKit

/// HealthKit queries about sleep: last night's night, a named window, daytime
/// naps, the additional-sleep search, and the two heart-rate-derived estimates
/// used on nights the watch recorded nothing.
///
/// Reads only. Sleep EXPORT, trend analysis and the sleep observers live in
/// `HealthWriteAndObserve+Sleep.swift`; they write and observe, which is a
/// different job with different failure modes.
///
/// A value over the parts it uses: queries run through `access`, and the
/// heart-rate-derived estimates read `heartRate`.
@MainActor
struct SleepHealthQueries {
    let access: HealthKitAccess
    let heartRate: HeartRateHealthQueries

}
