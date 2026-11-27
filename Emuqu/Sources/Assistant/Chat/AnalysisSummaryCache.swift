import Foundation
import os

/// Bounded cache of generated analysis summaries, least recently used entry
/// evicted first. An entry is keyed by its session and by the fingerprint of
/// what it was generated from, so a stale summary is never handed back after
/// the session's data changed, and summaries of one session generated for
/// different readers (the screen in the display language, the assistant in
/// English) sit side by side instead of replacing each other. The state lives
/// behind a lock, which is what makes the cache `Sendable`.
final class AnalysisSummaryCache: Sendable {
    static let shared = AnalysisSummaryCache()

    private static let maxEntries = 32

    private struct Key: Hashable {
        let sessionId: UUID
        let fingerprint: Int
    }

    private struct State {
        var entries: [Key: AnalysisSummaryGenerator.AnalysisSummary] = [:]
        /// Least recently used first.
        var order: [Key] = []

        mutating func touch(_ key: Key) {
            order.removeAll { $0 == key }
            order.append(key)
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private init() {}

    /// Changes whenever a rescore, a tag edit, or a sleep, window or vitals
    /// change could change the summary generated for `session` from the
    /// session alone. A generator that also reads inputs held outside the
    /// session (the live training load, the baseline, other nights) must fold
    /// them in with `fingerprint(for:inputs:)`. Readers that must not quote an
    /// outdated title or causes read with `get(forSessionId:matching:)` and
    /// the fingerprint they stored with. Hasher seeds per process, which suits
    /// an in-memory cache.
    ///
    /// The summary's language is part of the value: the app language, and
    /// whether the caller runs inside `NarrativeLanguage.english` (the
    /// assistant). A summary cached before a language switch, or one cached
    /// for the screen, is never handed to a reader expecting the other.
    ///
    /// Every session field the generator reads is part of it: the score and
    /// its breakdown's composite (the title), the morning feeling and its tags
    /// (the feel-bad steps), the end date (the reference date), the quality
    /// class, the window and the frozen training load. A field left out lets
    /// an edit to it hand back the summary written before the edit.
    static func fingerprint(for session: HRVSession) -> Int {
        var hasher = Hasher()
        hasher.combine(NarrativeLanguage.isEnglish)
        hasher.combine(LanguageManager.appLocale.identifier)
        combineScore(of: session, into: &hasher)
        combineAnalysis(of: session, into: &hasher)
        hasher.combine(session.tags)
        hasher.combine(session.morningFeeling)
        hasher.combine(session.morningFeelingTags)
        hasher.combine(session.endDate)
        hasher.combine(session.sleepStartMs)
        hasher.combine(session.sleepEndMs)
        hasher.combine(session.sleepSnapshot?.nightSleepMinutes)
        hasher.combine(session.vitalsSnapshot?.respiratoryRate)
        hasher.combine(session.vitalsSnapshot?.oxygenSaturation)
        return hasher.finalize()
    }

    /// The frozen score, its breakdown's composite, the training readiness
    /// and the training load the score was frozen with.
    private static func combineScore(of session: HRVSession, into hasher: inout Hasher) {
        hasher.combine(session.recoveryScore)
        hasher.combine(session.scoreBreakdown?.compositeScore)
        hasher.combine(session.frozenReadiness)
        hasher.combine(session.trainingSnapshot?.atl)
        hasher.combine(session.trainingSnapshot?.ctl)
        hasher.combine(session.trainingSnapshot?.tsb)
    }

    /// The analysis the summary reads and how far it is trusted.
    private static func combineAnalysis(of session: HRVSession, into hasher: inout Hasher) {
        hasher.combine(session.hrvDataQuality)
        hasher.combine(session.analysisResult?.analysisDate)
        hasher.combine(session.analysisResult?.windowStartMs)
        hasher.combine(session.analysisResult?.windowEndMs)
        hasher.combine(session.analysisResult?.timeDomain.rmssd)
        hasher.combine(session.analysisResult?.timeDomain.meanHR)
    }

    /// `fingerprint(for:)` combined with a hash of the generator inputs that do
    /// not live on the session, so the entry misses once any of them changes.
    static func fingerprint(for session: HRVSession, inputs: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(fingerprint(for: session))
        hasher.combine(inputs)
        return hasher.finalize()
    }

    func set(_ summary: AnalysisSummaryGenerator.AnalysisSummary, forSessionId id: UUID, fingerprint: Int = 0) {
        let key = Key(sessionId: id, fingerprint: fingerprint)
        state.withLock { state in
            state.touch(key)
            state.entries[key] = summary
            while state.order.count > Self.maxEntries {
                state.entries.removeValue(forKey: state.order.removeFirst())
            }
        }
    }

    /// The summary stored for this session with exactly this fingerprint, or
    /// nil. A hit makes the entry the most recently used.
    func get(forSessionId id: UUID, matching fingerprint: Int) -> AnalysisSummaryGenerator.AnalysisSummary? {
        let key = Key(sessionId: id, fingerprint: fingerprint)
        return state.withLock { state in
            guard let summary = state.entries[key] else { return nil }
            state.touch(key)
            return summary
        }
    }

    func clear() {
        state.withLock { state in
            state.entries.removeAll()
            state.order.removeAll()
        }
    }
}
