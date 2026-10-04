@testable import Emuqu
import XCTest

/// "Discard" on the morning review card. The morning flow saves the night to
/// the archive before the user reviews it, so a crash on the card cannot lose
/// it; discarding must take exactly that night back out (to Trash, with a
/// tombstone so nothing re-adds it) and leave every other night alone.
@MainActor
final class SessionDiscardTests: XCTestCase {
    private lazy var directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SessionDiscardTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: directory)

    override func tearDown() async throws {
        PersistedRecordingState.clear()
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            // swallow-ok: a test that archived nothing leaves no directory to remove.
        }
        try await super.tearDown()
    }

    private func makeCollector() -> RRCollector {
        RRCollector(polarManager: PolarManager(), healthKit: HealthKitManager(), archive: archive)
    }

    private func archivedNight(daysAgo: Int) throws -> HRVSession {
        let id = UUID()
        let start = Date().addingTimeInterval(-Double(daysAgo) * 86400 - 8 * 3600)
        let points = (0 ..< 200).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: $0 % 2 == 0 ? 990 : 1010) }
        let night = HRVSession(
            id: id, startDate: start, endDate: start.addingTimeInterval(7 * 3600), state: .complete,
            sessionType: .overnight,
            rrSeries: RRSeries(points: points, sessionId: id, startDate: start),
            analysisResult: nil, artifactFlags: nil
        )
        _ = try archive.archive(night, skipSameNightMerge: true)
        return night
    }

    private func isArchived(_ id: UUID) -> Bool {
        archive.entries.contains { $0.sessionId == id }
    }

    private func review(_ night: HRVSession, savedForReview: UUID?, on collector: RRCollector) {
        collector.currentSession = night
        collector.needsAcceptance = true
        collector.sessionState.reviewArchivedSessionId = savedForReview
    }

    func testDiscardMovesTheNightSavedForReviewToTrash() async throws {
        let collector = makeCollector()
        let earlier = try archivedNight(daysAgo: 3)
        let night = try archivedNight(daysAgo: 1)
        review(night, savedForReview: night.id, on: collector)

        await collector.rejectSession()

        XCTAssertFalse(isArchived(night.id), "The discarded night is still in history")
        XCTAssertTrue(archive.wasIntentionallyDeleted(night.id), "No tombstone: a sync could re-add the night")
        XCTAssertTrue(isArchived(earlier.id))
        XCTAssertNil(collector.sessionState.reviewArchivedSessionId)
        XCTAssertNil(collector.currentSession)
        XCTAssertFalse(collector.needsAcceptance)
    }

    /// A night already in the archive before this review began (reprocessed,
    /// not newly saved) is the user's existing record; Discard leaves it.
    func testDiscardKeepsANightThatWasArchivedBeforeReview() async throws {
        let collector = makeCollector()
        let night = try archivedNight(daysAgo: 1)
        review(night, savedForReview: nil, on: collector)

        await collector.rejectSession()

        XCTAssertTrue(isArchived(night.id))
        XCTAssertFalse(archive.wasIntentionallyDeleted(night.id))
    }

    func testDiscardNeverRemovesANightOtherThanTheOneUnderReview() async throws {
        let collector = makeCollector()
        let other = try archivedNight(daysAgo: 2)
        let night = try archivedNight(daysAgo: 1)
        review(night, savedForReview: other.id, on: collector)

        await collector.rejectSession()

        XCTAssertTrue(isArchived(other.id))
        XCTAssertTrue(isArchived(night.id))
    }

    /// Once a night is kept, a later Discard on the same id must not reach it.
    func testAKeptNightIsNoLongerDiscardable() async throws {
        let collector = makeCollector()
        let night = try archivedNight(daysAgo: 1)
        review(night, savedForReview: night.id, on: collector)

        collector.clearAcceptanceState()
        XCTAssertNil(collector.sessionState.reviewArchivedSessionId)
        collector.currentSession = night
        await collector.rejectSession()

        XCTAssertTrue(isArchived(night.id))
    }
}
