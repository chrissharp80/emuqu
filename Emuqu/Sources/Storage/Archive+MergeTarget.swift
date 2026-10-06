import Foundation

// MARK: - Which archived recording a new one folds into
//
// The archive's own write path (`sameNightMerge`) and batch import ask the
// same question before they merge: is there an archived copy of this
// recording, or an archived segment of the same sleep? Both take the answer
// from here, under the time rule every merge path shares
// (`SessionMerger.relation`).

extension ArchiveStore {
    /// The archived entry `session` should be merged into, or nil when it
    /// stands alone. Caller must hold archive.archiveLock.
    ///
    /// A candidate has the same session type, is neither linked to `session`
    /// nor absorbed into another entry's linked series, and for an overnight
    /// shares the night's anchor. A copy of the same recording (overlapping
    /// spans) wins; otherwise, when `sameSleepGap` is given, the nearest
    /// segment of the same sleep within that gap. Recordings further apart
    /// than the gap are separate sleeps and never merge.
    func mergeTarget(for session: HRVSession, sameSleepGap: TimeInterval?) -> SessionArchiveEntry? {
        let sessionSpan = SessionMerger.span(of: session)
        let absorbed = Set(archive.index.flatMap { $0.linkedSessionIds ?? [] })
        let related = archive.index
            .filter { !absorbed.contains($0.sessionId) && isMergeCandidate($0, for: session) }
            .map { entry in
                let entrySpan = SessionMerger.span(of: entry)
                let relation = SessionMerger.relation(of: sessionSpan, to: entrySpan, mergeGap: sameSleepGap ?? 0)
                return (entry: entry, relation: relation, gap: SessionMerger.gapBetween(sessionSpan, entrySpan))
            }
        if let copy = related.first(where: { $0.relation == .sameRecording }) {
            return copy.entry
        }
        guard sameSleepGap != nil else { return nil }
        return related.filter { $0.relation == .sameSleep }.min { $0.gap < $1.gap }?.entry
    }

    /// Same type, a different id, not linked either way, and for an
    /// overnight the same night's anchor.
    private func isMergeCandidate(_ entry: SessionArchiveEntry, for session: HRVSession) -> Bool {
        guard entry.sessionId != session.id, entry.sessionType == session.sessionType,
              !(entry.linkedSessionIds ?? []).contains(session.id),
              !(session.linkedSessionIds ?? []).contains(entry.sessionId)
        else { return false }
        guard session.sessionType == .overnight else { return true }
        let schedule = archive.sleepScheduleProvider()
        return schedule.overnightWindowStart(relativeTo: entry.date)
            == schedule.overnightWindowStart(relativeTo: session.startDate)
    }

    /// The merge gap for a same-sleep fold-in of `session`: the user's gap
    /// for an overnight while merging is on, otherwise none (only copies of
    /// the same recording merge).
    func sameSleepGap(for session: HRVSession) -> TimeInterval? {
        guard session.sessionType == .overnight, archive.sessionMergeModeProvider() != .off else { return nil }
        return archive.mergeGapProvider()
    }

    /// Whether the archive already holds a copy of `session`'s recording:
    /// same type, overlapping spans. Takes the lock.
    func holdsCopy(of session: HRVSession) -> Bool {
        archive.archiveLock.lock()
        defer { archive.archiveLock.unlock() }
        return archive.index.contains { $0.sessionId == session.id } || mergeTarget(for: session, sameSleepGap: nil) != nil
    }

    /// Whether `entry`, written earlier in the same batch, is a copy of
    /// `session`'s recording.
    static func isCopy(_ entry: SessionArchiveEntry, of session: HRVSession) -> Bool {
        entry.sessionType == session.sessionType
            && SessionMerger.overlaps(SessionMerger.span(of: entry), SessionMerger.span(of: session))
    }
}
