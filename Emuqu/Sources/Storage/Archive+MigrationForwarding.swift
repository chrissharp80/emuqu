import Foundation

// Migrations live in `ArchiveMigrations`; these forwarders let callers reach
// them through `SessionArchive`.

extension SessionArchive {
    /// The migration subsystem, built on each access; it holds no state of its own.
    var migrations: ArchiveMigrations {
        ArchiveMigrations(archive: self)
    }

    func runDeferredMigrations() { migrations.runDeferredMigrations() }
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
