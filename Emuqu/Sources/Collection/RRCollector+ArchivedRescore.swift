import Foundation

// MARK: - Archived copy of a rescored night

extension RRCollector {
    /// Observe `.reanalysisRewroteArchivedSession`, which
    /// `SessionReanalysisCoordinator` posts on the main actor after it
    /// rewrote a saved session, and carry that copy onto the review card
    /// (`takeArchivedCopy`). The token goes into `notificationObservers`, so
    /// `deinit` removes the observer. The observer runs on the posting
    /// thread, so the card is updated before the poster bumps the archive
    /// signal.
    func installArchivedCopyListener() {
        let token = NotificationCenter.default.addObserver(
            forName: .reanalysisRewroteArchivedSession, object: nil, queue: nil
        ) { [weak self] notification in
            guard let rewrite = notification.object as? ArchivedSessionRewrite else { return }
            MainActor.assumeIsolated { self?.takeArchivedCopy(rewrite) }
        }
        notificationObservers.add(token)
    }

    /// A rescore (`onlyWhileAwaitingAcceptance`) reaches the card only while
    /// a night awaits acceptance; a sleep refresh reaches it whenever the
    /// card holds the archive's copy.
    func takeArchivedCopy(_ rewrite: ArchivedSessionRewrite) {
        guard !rewrite.onlyWhileAwaitingAcceptance || sessionState.needsAcceptance else { return }
        adoptArchivedCopy(rewrite.session)
    }

    /// The night on the review card is the one Accept archives, so a rewrite
    /// of the archive's copy of it is carried onto the card when the card
    /// holds that copy: the night this review saved
    /// (`reviewArchivedSessionId`) or the paused night. Accept would
    /// otherwise write the score from before the rescore back. A card that
    /// merged a download into a night already archived holds a newer night
    /// than the archive, which only Accept replaces, so it is left as it is.
    ///
    /// Of the user's entries (tags, notes, morning feeling), one changed on
    /// the card since it last matched the archive (`reviewArchivedEntries`)
    /// is kept; the others come from the archived copy, which then holds any
    /// edit made elsewhere, in History for instance.
    ///
    /// The paused night's held copy (`pausedSession`) takes the rewrite too,
    /// so nothing that reads it later works from the copy before it.
    func adoptArchivedCopy(_ archived: HRVSession) {
        let state = sessionState
        guard let current = sessionState.currentSession, current.id == archived.id,
              state.reviewArchivedSessionId == archived.id || streamingLifecycle.pausedSession?.id == archived.id
        else { return }
        let matched = state.reviewArchivedEntries.flatMap { $0.sessionId == archived.id ? $0 : nil }
        var adopted = archived
        if let matched {
            if current.tags != matched.tags { adopted.tags = current.tags }
            if current.notes != matched.notes { adopted.notes = current.notes }
            if current.morningFeeling != matched.morningFeeling { adopted.morningFeeling = current.morningFeeling }
            state.reviewArchivedEntries = SessionState.ReviewEntries(of: archived)
        }
        sessionState.currentSession = adopted
        if streamingLifecycle.pausedSession?.id == archived.id, adopted.state == .paused { streamingLifecycle.pausedSession = adopted }
    }
}
