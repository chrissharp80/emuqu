import Foundation

// Migrations live in `ArchiveMigrations` — 673 lines off
// `SessionArchive`.
//
// These forwarders keep every existing call site working.

extension SessionArchive {
    /// The migration subsystem. Lazy — most launches run none.
    var migrations: ArchiveMigrations {
        ArchiveMigrations(archive: self)
    }

    func runDeferredMigrations() { migrations.runDeferredMigrations() }
    func removeDuplicates() { migrations.removeDuplicates() }
    func relinkSameNightSessions() { migrations.relinkSameNightSessions() }

    /// Pure helpers — no archive state — so they forward to the type.
    static func linkedSessionIdSet(in overnightEntries: [SessionArchiveEntry]) -> Set<UUID> {
        ArchiveMigrations.linkedSessionIdSet(in: overnightEntries)
    }

    static func duplicatesToQuarantine(
        overnightEntries: [SessionArchiveEntry],
        linkedIds: Set<UUID>,
        schedule: SleepSchedule,
        now: Date,
        mergeMode: SessionMergeMode
    ) -> [UUID] {
        ArchiveMigrations.duplicatesToQuarantine(
            overnightEntries: overnightEntries, linkedIds: linkedIds,
            schedule: schedule, now: now, mergeMode: mergeMode
        )
    }

}
