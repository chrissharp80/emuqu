import Foundation

// Sessions recorded before a given moment, for screens that judge a session
// against the ones before it rather than the newest in the archive.

extension RRCollector {
    /// The newest `limit` sessions of `type` that started before `date`,
    /// newest first. Decoded off the main thread without their RR series, by
    /// the same parallel decode as `recentSessionsAsync(limit:)`.
    func recentSessionsAsync(limit: Int, before date: Date, type: SessionType = .overnight) async -> [HRVSession] {
        let entries = Array(archive.entries
            .filter { $0.sessionType == type && $0.date < date }
            .prefix(limit))
        let archive = self.archive
        return await Task.detached(priority: .userInitiated) {
            await Self.decodeInParallel(entries, archive: archive)
        }.value
    }
}
