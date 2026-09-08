import Foundation

/// A live RR backup as it exists in CloudKit, with its payload.
///
/// Replaces the 4-tuple `(sessionId: UUID, beatCount: Int, captureDate: Date,
/// points: [RRPoint])` written out in three places across
/// `CloudKitSyncManager` and `CloudKitLiveBackupManager`. Field names are
/// unchanged, so call sites read as before.
///
/// `beatCount` is carried alongside `points` rather than derived from it
/// because the recovery UI lists available backups before downloading their
/// payloads — the count comes from the record's metadata, and `points` is empty
/// until the full fetch runs.
struct LiveBackupSummary: Equatable, Sendable {
    /// Session the backup belongs to.
    let sessionId: UUID

    /// Beats the backup claims to hold, from record metadata.
    let beatCount: Int

    /// When the backup was written.
    let captureDate: Date

    /// The RR payload — empty until fetched.
    let points: [RRPoint]
}
