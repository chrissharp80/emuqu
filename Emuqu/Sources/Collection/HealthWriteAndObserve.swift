import Foundation
import HealthKit

/// The half of HealthKit that writes and watches, rather than reads: exporting
/// SDNN and windowed HRV back to Health, writing sleep, deleting what this app
/// wrote, and the observer queries that notice when the Watch adds new data.
///
/// ## Why this is not on `HealthKitManager`
///
/// As two extensions it added 1,010 lines to that type.
///
/// Reads and writes fail differently and are worth separating on that alone: a
/// failed read yields a missing number, a failed write leaves Health holding
/// something wrong, and a leaked observer query keeps firing after the screen
/// is gone. The three read-only query classes (`VitalsHealthQueries`,
/// `TrainingHealthQueries`, `SleepHealthQueries`) came out earlier for the same
/// reason; this is the other side.
///
/// The `[weak self]` captures are query completion and update handlers. They now
/// weakly hold this object rather than the manager — equivalent, since the
/// manager is the only strong reference and each already no-ops on a nil self.
///
/// Holds its owner strongly and is built on demand by the manager — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
@MainActor
struct HealthWriteAndObserve {
    let manager: HealthKitManager

}
