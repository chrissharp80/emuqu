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

    private func makeCollector() -> RRCollector {
        RRCollector.withoutCloudAcceptance(polarManager: PolarManager(), archive: archive)
    }

    private func archivedNight(daysAgo: Int) throws -> HRVSession {
        try archivedNight(startingAt: Date().addingTimeInterval(-Double(daysAgo) * 86400 - 8 * 3600))
    }

    private func archivedNight(startingAt start: Date) throws -> HRVSession {
        let id = UUID()
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
        collector.sessionState.currentSession = night
        collector.sessionState.needsAcceptance = true
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
        XCTAssertNil(collector.sessionState.currentSession)
        XCTAssertFalse(collector.sessionState.needsAcceptance)
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

        collector.morning.clearAcceptanceState()
        XCTAssertNil(collector.sessionState.reviewArchivedSessionId)
        collector.sessionState.currentSession = night
        await collector.rejectSession()

        XCTAssertTrue(isArchived(night.id))
    }

    /// A second recording of a night already in history is folded into that
    /// night when it is saved for review. The fold cannot be undone, so
    /// Discard leaves the merged night in history, and nothing is trashed.
    func testDiscardAfterAFoldLeavesTheMergedNight() async throws {
        let collector = makeCollector()
        let lastNight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-3600)
        let night = try archivedNight(startingAt: lastNight)
        let secondId = UUID()
        let secondStart = lastNight.addingTimeInterval(3600)
        let points = (0 ..< 200).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: $0 % 2 == 0 ? 980 : 1020) }
        let second = HRVSession(
            id: secondId, startDate: secondStart, endDate: secondStart.addingTimeInterval(5 * 3600), state: .complete,
            sessionType: .overnight,
            rrSeries: RRSeries(points: points, sessionId: secondId, startDate: secondStart),
            analysisResult: nil, artifactFlags: nil
        )
        collector.sessionState.currentSession = second
        collector.sessionState.needsAcceptance = true

        collector.morning.archiveForReview(second)

        XCTAssertEqual(collector.sessionState.reviewFoldedIntoSessionId, night.id, "The fold was not recorded")
        XCTAssertNil(collector.sessionState.reviewArchivedSessionId, "Discard would aim at an id the archive no longer holds")
        XCTAssertFalse(isArchived(secondId))

        await collector.rejectSession()

        XCTAssertTrue(isArchived(night.id), "Discard removed the night the recording was folded into")
        XCTAssertFalse(archive.wasIntentionallyDeleted(night.id))
        XCTAssertNil(collector.sessionState.reviewFoldedIntoSessionId)
    }

    /// Deleting announces the change the way archiving does, so every
    /// observer of the archive refreshes without the caller telling it.
    func testDeleteAnnouncesTheChange() throws {
        let night = try archivedNight(daysAgo: 1)
        let announced = expectation(forNotification: .flowRecoveryArchiveChanged, object: nil) {
            ($0.object as? UUID) == night.id
        }

        XCTAssertTrue(try archive.delete(night.id))

        wait(for: [announced], timeout: 1)
    }

    /// An id the archive does not hold is not deleted and not announced.
    func testDeletingAnUnknownIdDoesNothing() throws {
        let unknown = UUID()
        let announced = expectation(forNotification: .flowRecoveryArchiveChanged, object: nil) {
            ($0.object as? UUID) == unknown
        }
        announced.isInverted = true

        XCTAssertFalse(try archive.delete(unknown))

        wait(for: [announced], timeout: 0.3)
    }
}
