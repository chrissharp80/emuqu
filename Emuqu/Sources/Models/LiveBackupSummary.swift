import Foundation

/// A live RR backup as it exists in CloudKit, with its payload.
///
/// Replaces the 4-tuple `(sessionId: UUID, beatCount: Int, captureDate: Date,
/// points: [RRPoint])` written out in three places across
/// `CloudKitSyncManager` and `CloudKitLiveBackupManager`. Field names are
/// unchanged, so call sites read as before.
///
/// A summary is built only from a backup whose payload decoded, so `points`
/// holds its beats and `beatCount` is their count.
struct LiveBackupSummary: Equatable, Sendable {
    /// Session the backup belongs to.
    let sessionId: UUID

    /// Beats the backup holds, counted from its decoded payload.
    let beatCount: Int

    /// When the backup was written.
    let captureDate: Date

    /// The decoded RR payload.
    let points: [RRPoint]
}
