import CloudKit
import Foundation

/// Fetching remote session changes and merging them into the local archive.
///
/// ## Why this is its own type
///
/// `CloudKitSyncManager` was 1,815 lines across four files. The pull path is
/// 251 of them behind a single entry point — `pullRemoteChanges` is the only
/// thing anything outside this file calls.
///
/// It is genuinely coupled to the manager: 13 members are read from here,
/// including `privateDB`, `zoneID`, `state` and the schema circuit breaker.
/// That was measured before the move rather than assumed, and it is why this
/// holds a reference rather than pretending to be independent.
///
/// What changes is that the coupling is one explicit `manager.` instead of 13
/// implicit reads that looked like the type's own state. Same reasoning as
/// `SessionRecoveryCoordinator`.
///
/// `unowned` because the manager owns this and outlives it; `weak` would put an
/// optional on every access for a reference that cannot be nil.
@MainActor
struct CloudPullCoordinator {
    let manager: CloudKitSyncManager

}
