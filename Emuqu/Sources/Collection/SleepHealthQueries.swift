import Foundation
import HealthKit

/// HealthKit queries about sleep: last night's night, a named window, daytime
/// naps, the additional-sleep search, and the two heart-rate-derived estimates
/// used on nights the watch recorded nothing.
///
/// Reads only. Sleep EXPORT, trend analysis and the sleep observers live in
/// `HealthKitManager+SleepTrends.swift`; they write and observe, which is a
/// different job with different failure modes.
///
/// Holds its owner strongly and is built on demand by the manager — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct SleepHealthQueries {
    let manager: HealthKitManager

}
