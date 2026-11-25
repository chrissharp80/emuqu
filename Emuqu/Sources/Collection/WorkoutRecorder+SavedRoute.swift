import Foundation

extension WorkoutRecorder {
    /// The user deleted the saved route `id`: when it is the one this
    /// workout is following, the workout stops following it, so the coach
    /// no longer names it and the session is not stamped with it ("the coach
    /// stops recognising it on your workouts").
    func forgetDeletedSavedRoute(_ id: UUID) {
        guard route.savedRouteId == id else { return }
        route.planned = nil
        route.savedRouteId = nil
        route.wasAutoDetected = false
        route.direction = .forward
        debugLog("[WorkoutRecorder] saved route \(id.uuidString.prefix(8)) deleted during the workout — no longer followed")
    }
}
