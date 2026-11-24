import Foundation

/// One-time and deferred repairs to the archive: backfilling fields added after
/// sessions were written, quarantining duplicates, and re-linking sessions that
/// belong to the same night.
///
/// Migrations run once per install, mutate stored sessions in place, and
/// nothing on the read path depends on them. They read many members of the
/// archive, mostly the index and the lock that guards it, and every such read
/// is explicit.
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
