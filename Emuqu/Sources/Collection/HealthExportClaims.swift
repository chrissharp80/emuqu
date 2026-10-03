import Foundation
import os

/// Sessions whose Apple Health export is under way.
///
/// The workout recorder exports a session as it finishes, and the back-fill
/// that runs on every return to the foreground exports any session not yet
/// stamped as exported. Both read the stamp before awaiting the export and
/// write it after, so a back-fill that started while the recorder's export
/// was in flight, or a second back-fill from a quick background-and-return,
/// saved the same workout to Apple Health twice. Each exporter claims the
/// session first; a claimed session is left to whoever holds it.
enum HealthExportClaims {
    private static let claimed = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    /// True when the caller now owns the export of `sessionId`.
    static func claim(_ sessionId: UUID) -> Bool {
        claimed.withLock { $0.insert(sessionId).inserted }
    }

    static func release(_ sessionId: UUID) {
        _ = claimed.withLock { $0.remove(sessionId) }
    }
}
