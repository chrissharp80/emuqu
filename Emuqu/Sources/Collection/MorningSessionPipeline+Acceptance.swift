import Foundation

// MARK: - Acceptance Flow

extension MorningSessionPipeline {
    /// Accept the current session - archives and updates the baseline. The
    /// H10's own copy stays on the strap as a backup until the next recording.
    /// The acceptance holds the recorder while it runs, so no recording
    /// starts under it (`SessionState.RecorderClaim`), and what it clears
    /// when it is done is this night's review only (`clearAcceptanceState`).
    func acceptSession() async throws {
        guard let session = sessionState.currentSession, session.state == .complete else {
            throw RRCollector.CollectorError.noSessionToAccept
        }
        let claim = sessionState.claimRecorder()
        defer { sessionState.releaseRecorder(claim) }
        do {
            try await runAcceptance(session)
        } catch {
            sessionState.lastError = error
            throw error
        }
        clearAcceptedSessionState(of: session.id)
    }

    /// Delegate the heavy work to the acceptance service.
    private func runAcceptance(_ session: HRVSession) async throws {
        let settings = settingsManager.settings
        let trainingContext = await scoringTrainingContext(result: session.analysisResult, sessionEnd: session.endDate ?? session.startDate)
        let inputs = SessionAcceptanceService.AcceptanceInputs(
            scoringConfig: scoring.currentScoringConfig,
            trainingContext: trainingContext,
            baselineStats: scoring.scoringBaselineStats(for: session),
            typicalSleepHours: settings.typicalSleepHours,
            sleepSchedule: settings.sleepSchedule
        )
        _ = try await acceptanceService.processAcceptance(
            session: session,
            inputs: inputs,
            enableHealthKitExport: settings.exportsToAppleHealth,
            clearPersistedRecordingState: { [weak self] in
                self?.recordingStore.clear(ifItIs: session.id)
            }
        )
    }

    /// UI state updates stay here rather than in the service. The accepted
    /// night is kept, so it is no longer the one "Discard" may remove.
    @MainActor
    private func clearAcceptedSessionState(of sessionId: UUID) {
        clearAcceptanceState(of: sessionId)
        archiveSignal.notifyChanged()
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

        let settings = settingsManager.settings
        let trainingContext = await scoringTrainingContext(result: result, sessionEnd: session.endDate ?? session.startDate)

        let updated = await acceptanceService.updateCompositeRecoveryScore(
            for: session,
            scoringConfig: scoring.currentScoringConfig,
            trainingContext: trainingContext,
            baselineStats: scoring.scoringBaselineStats(for: session),
            typicalSleepHours: settings.typicalSleepHours,
            sleepSchedule: settings.sleepSchedule,
            exportMetrics: exportMetrics,
            enableHealthKitExport: settings.exportsToAppleHealth
        )

        if updated {
            await MainActor.run { archiveSignal.notifyChanged() }
        }
        return updated
    }

    /// Clear acceptance UI state — for overnight sessions that are already
    /// archived. The night stays, so "Discard" no longer points at it. The
    /// one reset of the review UI: acceptance and rejection run it too.
    ///
    /// `sessionId` is the session the caller read before its work suspended
    /// (nil when there was none). The review is cleared unless another
    /// session took the recorder since (`SessionState.recorderTaken`): a
    /// recording that began meanwhile is not this review's to clear.
    func clearAcceptanceState(of sessionId: UUID?) {
        guard !sessionState.recorderTaken(since: sessionId) else {
            debugLog("[RRCollector] Review of \(sessionId?.uuidString.prefix(8) ?? "-") ended after another session took the recorder; that session's state is left as it is", level: .warning)
            return
        }
        sessionState.currentSession = nil
        sessionState.forgetReviewedNight()
        sessionState.needsAcceptance = false
        sessionState.recordingPhase = .idle
        sessionState.verificationResult = nil
        sessionState.recoveryWindow = nil
        healthWrites.stopObservingSleepData()
    }

    /// Reject the current session: clears the persisted recording state, the
    /// iCloud live backup and the review state. The strap keeps its own copy,
    /// as it does after acceptance, until the next recording clears it.
    /// A night the morning flow saved to the archive before review has
    /// already been moved to Trash, synced as a deletion and taken out of the
    /// baseline by `discardReviewArchivedSession`, which
    /// `RRCollector.rejectSession` runs first.
    func rejectSession() async {
        let sessionId = sessionState.currentSession?.id
        await acceptanceService.processRejection(
            sessionId: sessionId,
            clearPersistedRecordingState: { [weak self] in
                if let sessionId { self?.recordingStore.clear(ifItIs: sessionId) } else { self?.recordingStore.clear() }
            }
        )
        clearAcceptanceState(of: sessionId)
    }
}
