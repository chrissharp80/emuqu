import CloudKit
import Foundation

/// Removing remote data — the zone wipe behind "Delete All My Data".
///
/// A distinct job with three entry points, like `CloudPullCoordinator`. It
/// reads the manager's members (`privateDB`, `zoneID`, `state`, the
/// zone-recreation path) through one explicit reference, so they never look
/// like this type's own state.
@MainActor
struct CloudDeletionCoordinator {
    let manager: CloudKitSyncManager

}
