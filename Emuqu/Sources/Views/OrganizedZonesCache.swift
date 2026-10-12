import Foundation
import os

/// Process-wide memo of organized-recovery zones per session, so a chart
/// that re-renders does not re-run window selection. Bounded LRU; the state
/// lives behind a lock, which is what makes the cache `Sendable`.
///
/// Zones depend on the sleep window the scan used as well as the beats, so
/// each entry records that window. The keyed `get(_:sleepStartMs:sleepEndMs:)`
/// misses when the window changed (a sleep adjustment or a later HealthKit
/// fetch), and the scan reruns for the new one.
final class OrganizedZonesCache: Sendable {
    static let shared = OrganizedZonesCache()

    private static let maxEntries = 128

    /// The zones and the sleep window they were computed for; a nil window
    /// was stored through the unkeyed `set(_:zones:)`.
    private struct Entry {
        let zones: [HRVAnalysisResult.TimeRange]
        let sleepWindowMs: (start: Int64, end: Int64)?
    }

    private struct State {
        var cache: [UUID: Entry] = [:]
        var order: [UUID] = []

        mutating func touch(_ id: UUID) {
            if let idx = order.firstIndex(of: id) {
                order.remove(at: idx)
            }
            order.append(id)
        }

        mutating func store(_ id: UUID, _ entry: Entry) {
            cache[id] = entry
            touch(id)
            while order.count > OrganizedZonesCache.maxEntries {
                let evicted = order.removeFirst()
                cache.removeValue(forKey: evicted)
            }
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private init() {}

    /// The zones stored for `id`, whatever sleep window they were computed
    /// for. Callers that know the window use the keyed overload.
    func get(_ id: UUID) -> [HRVAnalysisResult.TimeRange]? {
        state.withLock { state in
            guard let entry = state.cache[id] else { return nil }
            state.touch(id)
            return entry.zones
        }
    }

    /// The zones stored for `id` when they were computed for exactly this
    /// sleep window; nil otherwise.
    func get(_ id: UUID, sleepStartMs: Int64, sleepEndMs: Int64) -> [HRVAnalysisResult.TimeRange]? {
        state.withLock { state in
            guard let entry = state.cache[id], let window = entry.sleepWindowMs,
                  window.start == sleepStartMs, window.end == sleepEndMs else { return nil }
            state.touch(id)
            return entry.zones
        }
    }

    /// Stores zones without their sleep window; a keyed `get` misses them.
    func set(_ id: UUID, zones: [HRVAnalysisResult.TimeRange]) {
        state.withLock { $0.store(id, Entry(zones: zones, sleepWindowMs: nil)) }
    }

    /// Stores zones together with the sleep window the scan used.
    func set(_ id: UUID, sleepStartMs: Int64, sleepEndMs: Int64, zones: [HRVAnalysisResult.TimeRange]) {
        state.withLock { $0.store(id, Entry(zones: zones, sleepWindowMs: (sleepStartMs, sleepEndMs))) }
    }

    func invalidate(_ id: UUID) {
        state.withLock { state in
            state.cache.removeValue(forKey: id)
            state.order.removeAll { $0 == id }
        }
    }
}
