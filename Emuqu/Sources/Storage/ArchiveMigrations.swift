import Foundation

/// One-time and deferred repairs to the archive: backfilling fields added after
/// sessions were written, quarantining duplicates, and re-linking sessions that
/// belong to the same night.
///
/// ## Why this is not on `SessionArchive`
///
/// Migrations are the archive's most separable responsibility: they run once per
/// install, mutate stored sessions in place, and nothing on the read path
/// depends on them. The coupling is real, not assumed — these functions read 27
/// members of the archive, mostly the index and the lock that guards it — so
/// this type does not claim to be independent. The difference is that those
/// reads are explicit.
///
/// Migrations mutate archived session FILES, which makes the CloudKit copies
/// stale; `sessionsNeedReuploadNotification` is how they tell the sync manager
/// to re-upload.
///
/// Holds its owner strongly and is built on demand by the archive — a
/// value with no state of its own, so nothing here can outlive what it
/// points at.
struct ArchiveMigrations {
    let archive: SessionArchive

}
