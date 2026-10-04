import Foundation

// Sessions recorded before a given moment, for screens that judge a session
// against the ones before it rather than the newest in the archive.

extension RRCollector {
    /// The newest `limit` sessions of `type` that started before `date`,
    /// newest first. Decoded off the main thread without their RR series, as
    /// `recentSessionsAsync(limit:)` does.
    func recentSessionsAsync(limit: Int, before date: Date, type: SessionType = .overnight) async -> [HRVSession] {
        let ids = archive.entries
            .filter { $0.sessionType == type && $0.date < date }
            .prefix(limit)
            .map(\.sessionId)
        let archive = self.archive
        return await Task.detached(priority: .userInitiated) {
            await Self.decodeLightweight(ids, archive: archive)
        }.value
    }

    /// Decodes the sessions in parallel and keeps the order of `ids`, dropping
    /// any that fail to decode.
    nonisolated private static func decodeLightweight(_ ids: [UUID], archive: SessionArchive) async -> [HRVSession] {
        await withTaskGroup(of: (Int, HRVSession?).self) { group in
            addDecodeTasks(&group, ids: ids, archive: archive)
            return await inOrder(group)
        }
    }

    nonisolated private static func addDecodeTasks(
        _ group: inout TaskGroup<(Int, HRVSession?)>, ids: [UUID], archive: SessionArchive
    ) {
        for (index, id) in ids.enumerated() {
            group.addTask { (index, archive.retrieveLightweightOrLog(id)) }
        }
    }

    nonisolated private static func inOrder(_ group: TaskGroup<(Int, HRVSession?)>) async -> [HRVSession] {
        var decoded: [(Int, HRVSession)] = []
        for await (index, session) in group {
            if let session { decoded.append((index, session)) }
        }
        return decoded.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
