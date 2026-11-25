@testable import Emuqu
import XCTest

/// "The coach stops recognising it on your workouts": deleting a saved
/// route the live workout is following unbinds it at once, and a route the
/// workout was not following is left alone.
@MainActor
final class SavedRouteDeletionTests: XCTestCase {
    private func recorderFollowing(savedRoute id: UUID) -> WorkoutRecorder {
        let recorder = WorkoutRecorder(core: SnapshotFixtures.collector(), conversation: VoiceConversationController.shared, services: WorkoutServices(.current))
        recorder.route.planned = Route.fromGPX(name: "Daily loop", track: [])
        recorder.route.savedRouteId = id
        recorder.route.wasAutoDetected = true
        return recorder
    }

    func testDeletingTheFollowedRouteUnbindsIt() {
        let id = UUID()
        let recorder = recorderFollowing(savedRoute: id)

        recorder.forgetDeletedSavedRoute(id)

        XCTAssertNil(recorder.route.planned, "the coach would keep naming a deleted route")
        XCTAssertNil(recorder.route.savedRouteId)
        XCTAssertFalse(recorder.route.wasAutoDetected)
    }

    func testDeletingAnotherRouteLeavesTheFollowedOne() {
        let recorder = recorderFollowing(savedRoute: UUID())

        recorder.forgetDeletedSavedRoute(UUID())

        XCTAssertNotNil(recorder.route.planned)
    }
}
