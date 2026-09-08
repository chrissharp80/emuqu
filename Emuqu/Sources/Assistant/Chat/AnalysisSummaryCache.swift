import Foundation
import os

/// Bounded LRU of generated analysis summaries keyed by session, with an
/// optional fingerprint so a stale summary is never handed back after the
/// session's data changed. The state lives behind a lock, which is what
/// makes the cache `Sendable`.
final class AnalysisSummaryCache: Sendable {
    static let shared = AnalysisSummaryCache()

    private static let maxEntries = 32

    private struct State {
        var entries: [UUID: AnalysisSummaryGenerator.AnalysisSummary] = [:]
        var fingerprints: [UUID: Int] = [:]
        var order: [UUID] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private init() {}

    func set(_ summary: AnalysisSummaryGenerator.AnalysisSummary, forSessionId id: UUID, fingerprint: Int = 0) {
        state.withLock { state in
            state.order.removeAll { $0 == id }
            state.order.append(id)
            state.entries[id] = summary
            state.fingerprints[id] = fingerprint
            while state.order.count > Self.maxEntries {
                let dropped = state.order.removeFirst()
                state.entries.removeValue(forKey: dropped)
                state.fingerprints.removeValue(forKey: dropped)
            }
        }
    }

    func get(forSessionId id: UUID) -> AnalysisSummaryGenerator.AnalysisSummary? {
        state.withLock { $0.entries[id] }
    }

    func get(forSessionId id: UUID, matching fingerprint: Int) -> AnalysisSummaryGenerator.AnalysisSummary? {
        state.withLock { state in
            guard let stored = state.fingerprints[id], stored == fingerprint else { return nil }
            return state.entries[id]
        }
    }

    func invalidate(sessionId: UUID) {
        state.withLock { state in
            state.entries.removeValue(forKey: sessionId)
            state.order.removeAll { $0 == sessionId }
        }
    }

    func clear() {
        state.withLock { state in
            state.entries.removeAll()
            state.order.removeAll()
        }
    }
}
