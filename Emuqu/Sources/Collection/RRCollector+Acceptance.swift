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
        let trainingContext = await acceptanceTrainingContext(session, frozen: session.analysisResult)
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

    /// The analysis result's own training context, else the load as of the
    /// session's end: fetched for a past night, never read from today's cache.
    private func acceptanceTrainingContext(_ session: HRVSession, frozen result: HRVAnalysisResult?) async -> TrainingContext? {
        if let frozen = result?.trainingContext { return frozen }
        return await collector.createTrainingContextEnsuringFresh(relativeTo: session.endDate ?? session.startDate)
    }

    /// UI state updates stay here rather than in the service. The accepted
    /// night is kept, so it is no longer the one "Discard" may remove.
    @MainActor
    private func clearAcceptedSessionState() {
        collector.currentSession = nil
        collector.sessionState.reviewArchivedSessionId = nil
        collector.needsAcceptance = false
        collector.recordingPhase = .idle
        collector.verificationResult = nil
        collector.recoveryWindow = nil
        collector.isDeviceFetchInProgress = false
        collector.archiveSignal.notifyChanged()
        collector.healthKit.stopObservingSleepData()
    }

    /// Recompute and re-archive the composite recovery score for a session.
    /// Also snapshots sleep and vitals data so the dashboard stays stable.
    /// Called when dismissing results for already-archived sessions (e.g., streaming/quick).
    ///
    /// - Parameter exportMetrics: When `true`, exports the final metrics to Apple Health
    ///   (if the user has HealthKit export enabled). Pass `true` only from the "final"
    ///   acceptance path (auto-accept, dismiss overnight) — not from intermediate updates
    ///   like background device refinement — to avoid duplicate HealthKit samples.
    func updateCompositeRecoveryScore(for session: HRVSession, exportMetrics: Bool = false) async {
        guard let result = session.analysisResult else { return }

        let settings = collector.settingsManager.settings
        let trainingContext = await acceptanceTrainingContext(session, frozen: result)

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
    }

    /// Clear acceptance UI state — for overnight sessions that are already
    /// archived. The night stays, so "Discard" no longer points at it.
    func clearAcceptanceState() {
        collector.currentSession = nil
        collector.sessionState.reviewArchivedSessionId = nil
        collector.needsAcceptance = false
        collector.recordingPhase = .idle
        collector.verificationResult = nil
        collector.recoveryWindow = nil
        collector.isDeviceFetchInProgress = false
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

        await MainActor.run {
            collector.currentSession = nil
            collector.needsAcceptance = false
            collector.recordingPhase = .idle
            collector.verificationResult = nil
            collector.recoveryWindow = nil
            collector.isDeviceFetchInProgress = false
            collector.healthKit.stopObservingSleepData()
        }
    }
}
