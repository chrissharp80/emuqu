import CloudKit
import Foundation

/// Removing remote data — the zone wipe behind "Delete All My Data".
///
/// Split out of `CloudKitSyncManager` alongside `CloudPullCoordinator`.
/// Same reasoning: the manager would be 1,815 lines across four files, and
/// this is a distinct job with three entry points.
///
/// Coupled to the manager by 12 members — `privateDB`, `zoneID`, `state`, the
/// zone-recreation path. Measured, not assumed. Holding one explicit reference
/// makes those reads countable instead of looking like this type's own state.
@MainActor
struct CloudDeletionCoordinator {
    let manager: CloudKitSyncManager

}
