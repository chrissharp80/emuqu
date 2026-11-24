import Foundation

/// The archive's sessions, decoded one at a time, newest first. A pass over
/// all of them holds one full session (beats included) in memory at a time
/// rather than the whole archive, which on a year or two of nights is hundreds
/// of megabytes. The index decides which sessions a pass visits before
/// anything is decoded, and each decode runs off the caller's actor.
struct ArchivedSessions: Sendable {
    private(set) var entries: [SessionArchiveEntry]
    private let load: @Sendable (UUID) -> HRVSession?

    init(archive: SessionArchive, caller: String) {
        entries = archive.store.entries
        load = { archive.retrieveOrLog($0, caller: caller) }
    }

    /// Sessions already in memory, in the order given.
    init(_ sessions: [HRVSession]) {
        let byId = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        entries = sessions.map { SessionArchiveEntry.make(from: $0, hash: "", filePath: "\($0.id.uuidString).json") }
        load = { byId[$0] }
    }

    var count: Int { entries.count }

    /// The sessions whose index entry passes `isIncluded`.
    func filter(_ isIncluded: (SessionArchiveEntry) -> Bool) -> ArchivedSessions {
        var kept = self
        kept.entries = entries.filter(isIncluded)
        return kept
    }

    /// The session at `index`, decoded off the caller's actor; nil when it
    /// is no longer archived or cannot be read (logged by the archive).
    func session(at index: Int) async -> HRVSession? {
        let id = entries[index].sessionId
        let load = load
        return await Task.detached(priority: .utility) { load(id) }.value
    }
}
