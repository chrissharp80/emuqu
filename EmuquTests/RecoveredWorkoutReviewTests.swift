@testable import Emuqu
import XCTest

/// The review/trim card for a recovered workout. Its Save closes the card only
/// once the trimmed workout is in the archive; a recovered workout that cannot
/// be read keeps the card up rather than being taken for one with too few
/// beats to trim.
@MainActor
final class RecoveredWorkoutReviewTests: XCTestCase {
    private lazy var directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveredWorkoutReviewTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: directory)

    override func setUp() async throws {
        try await super.setUp()
        isolateFromHostRecordingState()
    }

    override func tearDown() async throws {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            // swallow-ok: a test that archived nothing leaves no directory to remove.
        }
        try await super.tearDown()
    }

    private func recoveredWorkout() -> HRVSession {
        let id = UUID()
        let start = Date().addingTimeInterval(-2 * 3600)
        let points = (0 ..< 600).map { RRPoint(t_ms: Int64($0) * 500, rr_ms: 500) }
        return HRVSession(
            id: id, startDate: start, endDate: start.addingTimeInterval(300), state: .complete,
            sessionType: .workout,
            rrSeries: RRSeries(points: points, sessionId: id, startDate: start),
            analysisResult: nil, artifactFlags: nil
        )
    }

    private func review(of session: HRVSession) -> MorningCoordination.RecoveredWorkoutReview {
        MorningCoordination.RecoveredWorkoutReview(
            sessionId: session.id, sport: "Workout", durationSec: 300, distanceMeters: 0, avgHR: 120
        )
    }

    func testSaveKeepsTheCardWhenTheRecoveredWorkoutCannotBeRead() async throws {
        let collector = RRCollector.withoutCloudAcceptance(polarManager: PolarManager(), archive: archive)
        let workout = recoveredWorkout()
        let entry = try archive.archive(workout, skipSameNightMerge: true)
        try FileManager.default.removeItem(at: archive.state.resolveFileURL(for: entry))
        let card = review(of: workout)
        collector.morningCoordination.recoveredWorkoutReview = card

        let closed = await collector.recovery.retrimRecoveredWorkout(sessionId: workout.id, endSec: 200)

        XCTAssertFalse(closed, "a Save that stored nothing reports it, so the card can say so")
        XCTAssertEqual(
            collector.morningCoordination.recoveredWorkoutReview, card,
            "an unreadable workout is not one with too few beats: the card stays so Save can be tried again"
        )
        XCTAssertTrue(archive.store.exists(workout.id), "nothing was rewritten or removed")
    }
}
