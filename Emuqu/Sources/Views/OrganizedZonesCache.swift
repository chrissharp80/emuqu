import Foundation
import os

/// Process-wide memo of organized-recovery zones per session, so a chart
/// that re-renders does not re-run window selection. Bounded LRU; the state
/// lives behind a lock, which is what makes the cache `Sendable`.
final class OrganizedZonesCache: Sendable {
    static let shared = OrganizedZonesCache()

    private static let maxEntries = 128

    private struct State {
        var cache: [UUID: [HRVAnalysisResult.TimeRange]] = [:]
        var order: [UUID] = []

        mutating func touch(_ id: UUID) {
            if let idx = order.firstIndex(of: id) {
                order.remove(at: idx)
            }
            order.append(id)
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private init() {}

    func get(_ id: UUID) -> [HRVAnalysisResult.TimeRange]? {
        state.withLock { state in
            guard let value = state.cache[id] else { return nil }
            state.touch(id)
            return value
        }
    }

    func set(_ id: UUID, zones: [HRVAnalysisResult.TimeRange]) {
        state.withLock { state in
            state.cache[id] = zones
            state.touch(id)
            while state.order.count > Self.maxEntries {
                let evicted = state.order.removeFirst()
                state.cache.removeValue(forKey: evicted)
            }
        }
    }

    func invalidate(_ id: UUID) {
        state.withLock { state in
            state.cache.removeValue(forKey: id)
            state.order.removeAll { $0 == id }
        }
    }
}
