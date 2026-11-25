@testable import Emuqu
import XCTest

/// "The coach stops recognising it on your workouts": deleting a saved
/// route the live workout is following unbinds it at once, and a route the
/// workout was not following is left alone.
@MainActor
final class SavedRouteDeletionTests: XCTestCase {
    private func recorderFollowing(savedRoute id: UUID) -> WorkoutRecorder {
        let recorder = WorkoutRecorder(core: SnapshotFixtures.collector(), conversation: VoiceConversationController.shared, services: WorkoutServices(.current))
        recorder.plannedRoute = Route.fromGPX(name: "Daily loop", track: [])
        recorder.plannedSavedRouteId = id
        recorder.plannedRouteWasAutoDetected = true
        return recorder
    }

    func testDeletingTheFollowedRouteUnbindsIt() {
        let id = UUID()
        let recorder = recorderFollowing(savedRoute: id)

        recorder.forgetDeletedSavedRoute(id)

        XCTAssertNil(recorder.plannedRoute, "the coach would keep naming a deleted route")
        XCTAssertNil(recorder.plannedSavedRouteId)
        XCTAssertFalse(recorder.plannedRouteWasAutoDetected)
    }

    func testDeletingAnotherRouteLeavesTheFollowedOne() {
        let recorder = recorderFollowing(savedRoute: UUID())

        recorder.forgetDeletedSavedRoute(UUID())

        XCTAssertNotNil(recorder.plannedRoute)
    }
}
