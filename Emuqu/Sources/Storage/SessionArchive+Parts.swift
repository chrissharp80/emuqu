import Foundation

extension SessionArchive {
    /// The one-shot launch migrations over this archive.
    var migrations: ArchiveMigrations {
        ArchiveMigrations(archive: self)
    }

    typealias MergeOutcome = SessionMerger.MergeOutcome
}
