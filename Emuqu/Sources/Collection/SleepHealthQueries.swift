import Foundation
import HealthKit

/// HealthKit queries about sleep: last night's night, a named window, daytime
/// naps, the additional-sleep search, and the two heart-rate-derived estimates
/// used on nights the watch recorded nothing.
///
/// Split out of `HealthKitManager`, following the seam that took
/// `VitalsHealthQueries` and `TrainingHealthQueries` out: several hundred
/// lines needing eleven members of the manager — the store, the bounded-query
/// helpers, and the own-writes predicates.
///
/// Reads only. Sleep EXPORT, trend analysis and the sleep observers remain in
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
