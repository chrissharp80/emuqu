import Foundation

// MARK: - Acceptance Flow

extension MorningSessionPipeline {
    /// Accept the current session - archives, updates baseline, and clears H10
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
        let trainingContext = session.analysisResult?.trainingContext
            ?? collector.createTrainingContext(relativeTo: session.endDate ?? session.startDate)
        let inputs = SessionAcceptanceService.AcceptanceInputs(
            scoringConfig: collector.currentScoringConfig,
            trainingContext: trainingContext,
            baselineStats: collector.baselineTracker.recoveryBaselineStats,
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

    /// UI state updates stay here rather than in the service.
    @MainActor
    private func clearAcceptedSessionState() {
        collector.currentSession = nil
        collector.needsAcceptance = false
        collector.recordingPhase = .idle
        collector.verificationResult = nil
        collector.recoveryWindow = nil
        collector.deviceRefinement = nil
        collector.isDeviceFetchInProgress = false
        collector.archiveSignal.notifyChanged()
        collector.healthKit.stopObservingSleepData()
    }

    /// Recompute and re-collector.archive the composite recovery score for a session.
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
        let trainingContext = result.trainingContext
            ?? collector.createTrainingContext(relativeTo: session.endDate ?? session.startDate)

        let updated = await collector.acceptanceService.updateCompositeRecoveryScore(
            for: session,
            scoringConfig: collector.currentScoringConfig,
            trainingContext: trainingContext,
            baselineStats: collector.baselineTracker.recoveryBaselineStats,
            typicalSleepHours: settings.typicalSleepHours,
            sleepSchedule: settings.sleepSchedule,
            exportMetrics: exportMetrics,
            enableHealthKitExport: settings.enableHealthKitExport
        )

        if updated {
            await MainActor.run { collector.archiveSignal.notifyChanged() }
        }
    }

    /// Clear acceptance UI state — for overnight sessions that are already archived.
    func clearAcceptanceState() {
        collector.currentSession = nil
        collector.needsAcceptance = false
        collector.recordingPhase = .idle
        collector.verificationResult = nil
        collector.recoveryWindow = nil
        collector.deviceRefinement = nil
        collector.isDeviceFetchInProgress = false
        collector.healthKit.stopObservingSleepData()
    }

    /// Reject the current session - discards without archiving
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
            collector.deviceRefinement = nil
            collector.isDeviceFetchInProgress = false
            collector.healthKit.stopObservingSleepData()
        }
    }
}
