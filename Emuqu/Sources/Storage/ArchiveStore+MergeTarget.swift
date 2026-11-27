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
    /// stands alone. Caller must hold state.archiveLock.
    ///
    /// A candidate has the same session type, is neither linked to `session`
    /// nor absorbed into another entry's beats (`SessionLinks.absorbedIds`:
    /// a resumed night's final session is not, as its parent only refers
    /// back to it), and for an overnight
    /// shares the night's anchor. A copy of the same recording (overlapping
    /// spans) wins; otherwise, when `sameSleepGap` is given, the nearest
    /// segment of the same sleep within that gap. Recordings further apart
    /// than the gap are separate sleeps and never merge.
    func mergeTarget(for session: HRVSession, sameSleepGap: TimeInterval?) -> SessionArchiveEntry? {
        let sessionSpan = SessionMerger.span(of: session)
        let absorbed = SessionLinks.absorbedIds(in: state.index)
        let related = state.index
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
        return sharesNightAnchor(entry, start: session.startDate)
    }

    /// The archived overnight `entry` and a recording starting at `start`
    /// fall in the same night of the user's sleep schedule.
    func sharesNightAnchor(_ entry: SessionArchiveEntry, start: Date) -> Bool {
        let schedule = state.mergeSettings.sleepSchedule()
        return schedule.overnightWindowStart(relativeTo: entry.date)
            == schedule.overnightWindowStart(relativeTo: start)
    }

    /// The merge gap for a same-sleep fold-in of `session`: the user's gap
    /// for an overnight while merging is on, otherwise none (only copies of
    /// the same recording merge).
    func sameSleepGap(for session: HRVSession) -> TimeInterval? {
        guard session.sessionType == .overnight, state.mergeSettings.mode() != .off else { return nil }
        return state.mergeSettings.gap()
    }

    /// `mergeTarget`, taking the lock: the rule Recover asks for a
    /// recording downloaded off the strap.
    func lockedMergeTarget(for session: HRVSession, sameSleepGap: TimeInterval?) -> SessionArchiveEntry? {
        state.archiveLock.lock()
        defer { state.archiveLock.unlock() }
        return mergeTarget(for: session, sameSleepGap: sameSleepGap)
    }

    /// Whether the archive already holds a copy of `session`'s recording:
    /// same type, overlapping spans. Takes the lock.
    func holdsCopy(of session: HRVSession) -> Bool {
        state.archiveLock.lock()
        defer { state.archiveLock.unlock() }
        return state.index.contains { $0.sessionId == session.id } || mergeTarget(for: session, sameSleepGap: nil) != nil
    }

    /// Whether `entry`, written earlier in the same batch, is a copy of
    /// `session`'s recording.
    static func isCopy(_ entry: SessionArchiveEntry, of session: HRVSession) -> Bool {
        entry.sessionType == session.sessionType
            && SessionMerger.overlaps(SessionMerger.span(of: entry), SessionMerger.span(of: session))
    }

    /// The fold itself, re-archived (a re-archive, which won't recurse). A
    /// night whose beats it changed is then analysed again from them
    /// (`NightBeatsEdit.requestReanalysis`).
    func archiveFold(of session: HRVSession, into existing: HRVSession) throws -> SessionArchiveEntry {
        var merged = existing
        let merge = SessionMerger.mergeSessionDataChangingBeats(from: session, into: &merged)
        if merge.changed { merged.modifiedAt = CloudKitSessionFreshness.stamp() }
        let entry = try _archive(merged)
        if merge.beatsChanged { NightBeatsEdit.requestReanalysis(of: merged, detail: "a same-night recording was folded in") }
        return entry
    }
}
