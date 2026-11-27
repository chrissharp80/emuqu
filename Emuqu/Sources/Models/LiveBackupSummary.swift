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

    /// When the backup first reached iCloud: the record's plain field, which
    /// the recovery listing selects and orders on. Not when the recording
    /// began; see `sessionStart`.
    let captureDate: Date

    /// The decoded RR payload.
    let points: [RRPoint]

    /// When the recording began, sealed in the payload
    /// (`LiveBackupPayload`); nil for a backup an older build uploaded.
    var recordingStart: Date?

    /// The start the beats' `t_ms` count from, which a restored night is
    /// dated by: the recording's own start, or, for a backup that carries
    /// none, its first upload.
    var sessionStart: Date { recordingStart ?? captureDate }
}
