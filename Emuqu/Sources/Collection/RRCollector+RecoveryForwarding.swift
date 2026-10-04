import Foundation

// Recovery lives in `SessionRecoveryCoordinator` — 1,557 lines kept
// out of what was the largest type in the codebase.
//
// These forwarders exist so the ~29 call sites across the app and the test
// suite did not have to change in the same commit as the move. They are the
// collector's recovery API; the behaviour lives one reference away.

extension RRCollector {
    /// The recovery subsystem. Lazy because most launches never recover
    /// anything, and building it eagerly would put an object on the cold-start
    /// path for a case that usually does not arise.
    var recovery: SessionRecoveryCoordinator {
        SessionRecoveryCoordinator(collector: self)
    }

    func retryFetchRecording() async throws -> HRVSession? {
        return try await recovery.retryFetchRecording()
    }

    func resolveRecoveryTiming(
        rrPoints: [RRPoint],
        recordingEndDate: Date
    ) async -> SessionRecoveryCoordinator.ResolvedRecoveryTiming {
        return await recovery.resolveRecoveryTiming(rrPoints: rrPoints, recordingEndDate: recordingEndDate)
    }

    func mergeWithExistingSession(
        rrPoints: [RRPoint],
        timing: SessionRecoveryCoordinator.ResolvedRecoveryTiming
    ) -> SessionRecoveryCoordinator.MergedRecoveryData {
        return recovery.mergeWithExistingSession(rrPoints: rrPoints, timing: timing)
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

    func permanentlyDelete(_ sessionId: UUID) {
        recovery.permanentlyDelete(sessionId)
    }

    func deleteLostSessions(_ sessionIds: [UUID]) {
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

    func augmentOvernightFromStrap(sessionId: UUID) async -> SessionRecoveryCoordinator.OvernightAugmentResult {
        return await recovery.augmentOvernightFromStrap(sessionId: sessionId)
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
