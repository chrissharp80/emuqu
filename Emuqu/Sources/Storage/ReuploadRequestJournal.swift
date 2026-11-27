import Foundation
import os

/// Sessions changed on this device whose iCloud copy is now older: each
/// request to upload one again, kept on disk from before the change is
/// written until CloudKit sync holds the session queued in its own saved
/// state (`CloudKitSyncManager.markSessionsForReupload`).
///
/// A request made only in memory, by notification, waits behind any sync in
/// progress before sync saves it. Killed in between, the change stayed on
/// this device, the uploaded set still listed the session, and iCloud kept
/// the copy from before it while Settings said everything was synced.
///
/// Each id carries the sequence number of its latest request, so settling
/// what sync saved leaves a request made again since in place.
final class ReuploadRequestJournal: Sendable {
    static let fileName = "reupload_requests.json"

    private struct Requests: Sendable {
        var ids: [UUID: Int] = [:]
        var next = 0
    }

    private let url: URL
    private let requests: OSAllocatedUnfairLock<Requests?>

    init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
        requests = OSAllocatedUnfairLock(initialState: nil)
    }

    /// The requests not yet settled, with their sequence numbers.
    var pending: [UUID: Int] {
        requests.withLock { [url] stored in Self.loaded(&stored, from: url).ids }
    }

    /// Records a request for each id and writes the list before returning,
    /// so a change written after this call cannot outlive its request.
    func record(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        requests.withLock { [url] stored in
            var current = Self.loaded(&stored, from: url)
            for id in ids {
                current.ids[id] = current.next
                current.next += 1
            }
            stored = current
            Self.write(current.ids, to: url)
        }
    }

    /// Drops the requests in `snapshot` still at the sequence number it
    /// holds: sync has saved them. A request made again since stays.
    func settle(_ snapshot: [UUID: Int]) {
        guard !snapshot.isEmpty else { return }
        requests.withLock { [url] stored in
            var current = Self.loaded(&stored, from: url)
            let before = current.ids.count
            current.ids = current.ids.filter { snapshot[$0.key] != $0.value }
            stored = current
            if current.ids.count != before { Self.write(current.ids, to: url) }
        }
    }

    private static func loaded(_ stored: inout Requests?, from url: URL) -> Requests {
        if let stored { return stored }
        var read = Requests()
        read.ids = storedRequests(at: url)
        read.next = (read.ids.values.max() ?? -1) + 1
        stored = read
        return read
    }

    /// The requests in the file; none when it is missing or unreadable
    /// (logged).
    private static func storedRequests(at url: URL) -> [UUID: Int] {
        guard FileManager.default.fileExists(atPath: url.path),
              let decoded = attempt("ReuploadRequests.read", { try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: url)) })
        else { return [:] }
        let pairs = decoded.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } }
        return Dictionary(pairs) { first, _ in first }
    }

    private static func write(_ ids: [UUID: Int], to url: URL) {
        let stored = Dictionary(uniqueKeysWithValues: ids.map { ($0.key.uuidString, $0.value) })
        attempt("ReuploadRequests.write") {
            try PurgeGate.admitWrite { try JSONEncoder().encode(stored).write(to: url, options: .atomic) }
        }
    }
}
