import CloudKit
import Foundation

/// Fetching remote session changes and merging them into the local archive.
///
/// The type is a namespace with a reference to the manager; its body,
/// `pullRemoteChanges` and the record handling behind it, lives in
/// `CloudKitSyncManager+Pull.swift`.
///
/// It is genuinely coupled to the manager: it reads `privateDB`, `zoneID`,
/// `state`, the archive and the schema circuit breaker, among others. That
/// is why this holds a reference rather than pretending to be independent;
/// what changes is that the coupling is one explicit `manager.` instead of
/// implicit reads that looked like the type's own state. Same reasoning as
/// `SessionRecoveryCoordinator`.
///
/// A strong reference: the manager builds a fresh coordinator for each use,
/// so it never outlives the call that made it.
@MainActor
struct CloudPullCoordinator {
    let manager: CloudKitSyncManager

    /// What one remote record did to the local archive.
    struct RecordOutcome {
        var new = 0
        var deleted = 0
        /// A session archived NEW by this record, or replaced by a newer copy
        /// that arrived without its HealthKit sleep snapshot — handed to the
        /// snapshot backfill, since the upload strips those snapshots.
        var backfillId: UUID?
        /// 1 when a newer iCloud copy replaced this device's copy.
        var refreshed = 0
    }
}
