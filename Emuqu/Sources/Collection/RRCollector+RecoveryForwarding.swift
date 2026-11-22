import Foundation

// Recovery lives in `SessionRecoveryCoordinator` (its extensions in
// `RRCollector+Recovery.swift` and `RRCollector+BackupRecovery.swift`), kept
// out of what was the largest type in the codebase.
//
// These forwarders exist so the ~29 call sites across the app and the test
// suite did not have to change in the same commit as the move. They are the
// collector's recovery API; the behaviour lives one reference away.

extension RRCollector {
    /// The recovery subsystem, built afresh on every access. The coordinator
    /// is a value holding only this collector, so building one costs nothing
    /// and there is no stored instance to keep in step.
    var recovery: SessionRecoveryCoordinator {
        SessionRecoveryCoordinator(collector: self)
    }

    func retryFetchRecording() async throws -> HRVSession? {
        return try await recovery.retryFetchRecording()
    }

    func recoverFromDevice() async throws -> HRVSession? {
        return try await recovery.recoverFromDevice()
    }

    func checkForLostSessions() async -> [(id: UUID, date: Date, beatCount: Int)] {
        return await recovery.checkForLostSessions()
    }

    func pullCloudBackupsToLocal() async {
        await recovery.pullCloudBackupsToLocal()
    }

    func checkForDeletedSessions() -> [(id: UUID, date: Date, beatCount: Int)] {
        return recovery.checkForDeletedSessions()
    }

    func restoreFromTrash(_ sessionId: UUID) async -> HRVSession? {
        return await recovery.restoreFromTrash(sessionId)
    }

    @discardableResult
    func permanentlyDelete(_ ids: [UUID]) async -> TrashDeletionOutcome {
        await recovery.permanentlyDelete(ids)
    }

    /// The ids whose deletion mark was stored.
    @discardableResult
    func deleteLostSessions(_ sessionIds: [UUID]) -> Set<UUID> {
        recovery.deleteLostSessions(sessionIds)
    }

    func recoverFromBackup(_ sessionId: UUID) async -> HRVSession? {
        return await recovery.recoverFromBackup(sessionId)
    }

    func retrimRecoveredWorkout(sessionId: UUID, endSec: Double) async {
        await recovery.retrimRecoveredWorkout(sessionId: sessionId, endSec: endSec)
    }

    func discardRecoveredWorkout(sessionId: UUID) {
        recovery.discardRecoveredWorkout(sessionId: sessionId)
    }

    func recoverRouteFromAppleWatch(sessionId: UUID) async -> SessionRecoveryCoordinator.WatchRouteRecoveryResult {
        return await recovery.recoverRouteFromAppleWatch(sessionId: sessionId)
    }

    func augmentWorkoutFromStrap(sessionId: UUID) async -> SessionRecoveryCoordinator.StrapAugmentResult {
        return await recovery.augmentWorkoutFromStrap(sessionId: sessionId)
    }

    func augmentOvernightFromStrap(
        sessionId: UUID, rescoringWith reanalysis: SessionReanalysisCoordinator
    ) async -> SessionRecoveryCoordinator.OvernightAugmentResult {
        return await recovery.augmentOvernightFromStrap(sessionId: sessionId, rescoringWith: reanalysis)
    }

    func surfaceExistingRecoveredWorkoutForReview() {
        recovery.surfaceExistingRecoveredWorkoutForReview()
    }

    func findInterruptedWorkoutSessionId() async -> UUID? {
        return await recovery.findInterruptedWorkoutSessionId()
    }

    func recoverInterruptedWorkoutFromStrap() async -> HRVSession? {
        return await recovery.recoverInterruptedWorkoutFromStrap()
    }

    func autoRecoverInterruptedWorkoutOnLaunch() async {
        await recovery.autoRecoverInterruptedWorkoutOnLaunch()
    }

    func recoverToPausedState(_ sessionId: UUID, sessionType: SessionType) async -> Bool {
        return await recovery.recoverToPausedState(sessionId, sessionType: sessionType)
    }
}
