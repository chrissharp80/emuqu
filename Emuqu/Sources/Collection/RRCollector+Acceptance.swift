import Foundation

// MARK: - Acceptance Flow

extension MorningSessionPipeline {
    /// Accept the current session - archives and updates the baseline. The
    /// H10's own copy stays on the strap as a backup until the next recording.
    func acceptSession() async throws {
        guard let session = collector.currentSession, session.state == .complete else {
            throw RRCollector.CollectorError.noSessionToAccept
        }
        do {
            try await runAcceptance(session)
        } catch {
            await MainActor.run { collector.lastError = error }
            throw error
        }
        await MainActor.run { clearAcceptedSessionState() }
    }

    /// Delegate the heavy work to the acceptance service.
    private func runAcceptance(_ session: HRVSession) async throws {
        let settings = collector.settingsManager.settings
        let trainingContext = await scoringTrainingContext(result: session.analysisResult, sessionEnd: session.endDate ?? session.startDate)
        let inputs = SessionAcceptanceService.AcceptanceInputs(
            scoringConfig: collector.currentScoringConfig,
            trainingContext: trainingContext,
            baselineStats: collector.scoringBaselineStats(for: session),
            typicalSleepHours: settings.typicalSleepHours,
            sleepSchedule: settings.sleepSchedule
        )
        _ = try await collector.acceptanceService.processAcceptance(
            session: session,
            inputs: inputs,
            enableHealthKitExport: settings.enableHealthKitExport,
            clearPersistedRecordingState: { [weak collector] in
                collector?.clearPersistedRecordingState()
            }
        )
    }

    /// UI state updates stay here rather than in the service. The accepted
    /// night is kept, so it is no longer the one "Discard" may remove.
    @MainActor
    private func clearAcceptedSessionState() {
        clearAcceptanceState()
        collector.archiveSignal.notifyChanged()
    }

    /// Recompute and re-archive the composite recovery score for a session.
    /// Also snapshots sleep and vitals data so the dashboard stays stable.
    /// Called when dismissing results for already-archived sessions (e.g., streaming/quick).
    ///
    /// - Parameter exportMetrics: When `true`, exports the final metrics to Apple Health
    ///   (if the user has HealthKit export enabled). Pass `true` only from the "final"
    ///   acceptance path (auto-accept, dismiss overnight) — not from intermediate updates
    ///   like background device refinement — to avoid duplicate HealthKit samples.
    /// - Returns: `true` when the session was re-archived. `false` when it has
    ///   no analysis result or the write failed: nothing was stored, so changes
    ///   carried on `session` (the auto-accept's pre-night tags and notes) did
    ///   not reach the archive.
    func updateCompositeRecoveryScore(for session: HRVSession, exportMetrics: Bool = false) async -> Bool {
        guard let result = session.analysisResult else { return false }

        let settings = collector.settingsManager.settings
        let trainingContext = await scoringTrainingContext(result: result, sessionEnd: session.endDate ?? session.startDate)

        let updated = await collector.acceptanceService.updateCompositeRecoveryScore(
            for: session,
            scoringConfig: collector.currentScoringConfig,
            trainingContext: trainingContext,
            baselineStats: collector.scoringBaselineStats(for: session),
            typicalSleepHours: settings.typicalSleepHours,
            sleepSchedule: settings.sleepSchedule,
            exportMetrics: exportMetrics,
            enableHealthKitExport: settings.enableHealthKitExport
        )

        if updated {
            await MainActor.run { collector.archiveSignal.notifyChanged() }
        }
        return updated
    }

    /// Clear acceptance UI state — for overnight sessions that are already
    /// archived. The night stays, so "Discard" no longer points at it. The
    /// one reset of the review UI: acceptance and rejection run it too.
    func clearAcceptanceState() {
        collector.currentSession = nil
        collector.sessionState.reviewArchivedSessionId = nil
        collector.needsAcceptance = false
        collector.recordingPhase = .idle
        collector.verificationResult = nil
        collector.recoveryWindow = nil
        collector.healthKit.stopObservingSleepData()
    }

    /// Reject the current session: clears the persisted recording state, the
    /// iCloud live backup and the review state. The strap keeps its own copy,
    /// as it does after acceptance, until the next recording clears it.
    /// A night the morning flow saved to the archive before review has
    /// already been moved to Trash, synced as a deletion and taken out of the
    /// baseline by `discardReviewArchivedSession`, which
    /// `RRCollector.rejectSession` runs first.
    func rejectSession() async {
        await collector.acceptanceService.processRejection(
            sessionId: collector.currentSession?.id,
            clearPersistedRecordingState: { [weak collector] in
                collector?.clearPersistedRecordingState()
            }
        )

        await MainActor.run { clearAcceptanceState() }
    }
}

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
        guard !rewrite.onlyWhileAwaitingAcceptance || needsAcceptance else { return }
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
    func adoptArchivedCopy(_ archived: HRVSession) {
        let state = sessionState
        guard let current = currentSession, current.id == archived.id,
              state.reviewArchivedSessionId == archived.id || pausedSession?.id == archived.id
        else { return }
        let matched = state.reviewArchivedEntries.flatMap { $0.sessionId == archived.id ? $0 : nil }
        var adopted = archived
        if let matched {
            if current.tags != matched.tags { adopted.tags = current.tags }
            if current.notes != matched.notes { adopted.notes = current.notes }
            if current.morningFeeling != matched.morningFeeling { adopted.morningFeeling = current.morningFeeling }
            state.reviewArchivedEntries = SessionState.ReviewEntries(of: archived)
        }
        currentSession = adopted
    }
}
