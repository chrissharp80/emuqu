import Foundation
import os

/// Bounded cache of generated analysis summaries keyed by session, evicting
/// the least recently stored entry first, with an optional fingerprint so a
/// stale summary is never handed back after the session's data changed. The
/// state lives behind a lock, which is what makes the cache `Sendable`.
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

    /// Changes whenever a rescore, a tag edit, or a sleep, window or vitals
    /// change could change the summary generated for `session`. Readers that
    /// must not quote an outdated title or causes (the assistant's context)
    /// read with `get(forSessionId:matching:)` and this value. Hasher seeds per
    /// process, which suits an in-memory cache.
    static func fingerprint(for session: HRVSession) -> Int {
        var hasher = Hasher()
        hasher.combine(session.recoveryScore)
        hasher.combine(session.frozenReadiness)
        hasher.combine(session.tags)
        hasher.combine(session.analysisResult?.analysisDate)
        hasher.combine(session.analysisResult?.timeDomain.rmssd)
        hasher.combine(session.analysisResult?.timeDomain.meanHR)
        hasher.combine(session.sleepStartMs)
        hasher.combine(session.sleepEndMs)
        hasher.combine(session.sleepSnapshot?.nightSleepMinutes)
        hasher.combine(session.vitalsSnapshot?.respiratoryRate)
        hasher.combine(session.vitalsSnapshot?.oxygenSaturation)
        return hasher.finalize()
    }

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
            state.fingerprints.removeValue(forKey: sessionId)
            state.order.removeAll { $0 == sessionId }
        }
    }

    func clear() {
        state.withLock { state in
            state.entries.removeAll()
            state.fingerprints.removeAll()
            state.order.removeAll()
        }
    }
}
