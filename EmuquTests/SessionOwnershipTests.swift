@testable import Emuqu
import XCTest

/// Which record a night, a segment or a strap recording belongs to is decided
/// by identity, span and state, never by a score.
@MainActor
final class SessionOwnershipTests: XCTestCase {
    private let night = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(start: TimeInterval, end: TimeInterval, score: Double? = 7, links: [UUID]? = nil) -> SessionArchiveEntry {
        SessionArchiveEntry(
            sessionId: UUID(), date: night.addingTimeInterval(start), endDate: night.addingTimeInterval(end),
            fileHash: "h", filePath: "f", recoveryScore: score, meanRMSSD: score == nil ? nil : 50,
            sessionType: .overnight, linkedSessionIds: links
        )
    }

    // MARK: - History's row for a linked night

    /// A paused night keeps the partial score it got at the pause; the
    /// resumed session spans the whole night and stands for it.
    func testTheSessionSpanningTheNightStandsForItNotTheHigherScore() {
        let paused = entry(start: 0, end: 4 * 3600, score: 7.8)
        let resumed = entry(start: 0, end: 8 * 3600, score: 6.2, links: [paused.sessionId])
        XCTAssertEqual(HistoryViewModel.chainWinner([paused, resumed])?.sessionId, resumed.sessionId)
        XCTAssertEqual(HistoryViewModel.chainWinner([resumed, paused])?.sessionId, resumed.sessionId)
    }

    // MARK: - The night a recovered recording joins

    /// Recovery merges only into an overnight of the same night of the sleep
    /// schedule, as the archive's own merge does: a recording that starts the
    /// next evening is the next night, however close the spans.
    func testRecoveryJoinsOnlyAnOvernightOfTheSameNight() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SessionOwnershipTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) } // swallow-ok: temporary test folder
        let store = SessionArchive(directory: directory).store
        let evening = try XCTUnwrap(Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: night))
        let archived = SessionArchiveEntry(
            sessionId: UUID(), date: evening, endDate: evening.addingTimeInterval(7 * 3600),
            fileHash: "h", filePath: "f", sessionType: .overnight
        )
        XCTAssertTrue(store.sharesNightAnchor(archived, start: evening.addingTimeInterval(5 * 3600)))
        XCTAssertFalse(store.sharesNightAnchor(archived, start: evening.addingTimeInterval(24 * 3600)))
    }

    // MARK: - Absorbing a night's segment

    /// A recovered fragment from early in the night holds none of a later,
    /// scored segment's beats, so it does not absorb it.
    func testAFragmentDoesNotClaimANightItDoesNotSpan() {
        let later = entry(start: 1.75 * 3600, end: 8 * 3600)
        let fragment = DateInterval(start: night, end: night.addingTimeInterval(1.5 * 3600))
        XCTAssertFalse(MorningProcessingService.newSessionMayClaimNight(over: later, newBeatCount: 6_000, newSpan: fragment))
    }

    /// A resumed night re-anchored to its first segment's start spans it.
    func testASessionSpanningTheSegmentClaimsIt() {
        let first = entry(start: 0, end: 4 * 3600)
        let whole = DateInterval(start: night, end: night.addingTimeInterval(8 * 3600))
        XCTAssertTrue(MorningProcessingService.newSessionMayClaimNight(over: first, newBeatCount: 25_000, newSpan: whole))
        XCTAssertFalse(MorningProcessingService.newSessionMayClaimNight(over: first, newBeatCount: 500, newSpan: whole), "under the beat floor")
    }

    /// An entry with no score is not a real overnight; anything may claim it.
    func testAnUnscoredEntryMayBeClaimed() {
        let unscored = entry(start: 5 * 3600, end: 6 * 3600, score: nil)
        let fragment = DateInterval(start: night, end: night.addingTimeInterval(3600))
        XCTAssertTrue(MorningProcessingService.newSessionMayClaimNight(over: unscored, newBeatCount: 0, newSpan: fragment))
    }

    // MARK: - A crashed workout's strap recording

    /// The strap's recording of an evening's overnight is not the afternoon
    /// run's, even though it began within a day of it.
    func testALaterNightsRecordingIsNotTheWorkouts() {
        let lastHeard = night.addingTimeInterval(40 * 60)
        XCTAssertFalse(SessionRecoveryCoordinator.recording(startedAt: night.addingTimeInterval(4.5 * 3600), belongsToWorkoutLastHeardAt: lastHeard))
        XCTAssertTrue(SessionRecoveryCoordinator.recording(startedAt: night.addingTimeInterval(30), belongsToWorkoutLastHeardAt: lastHeard))
        XCTAssertFalse(SessionRecoveryCoordinator.recording(startedAt: nil, belongsToWorkoutLastHeardAt: lastHeard), "no start cannot be placed")
    }

    /// A workout that died before its first sample still takes the strap
    /// recording armed as it started.
    func testAWorkoutThatDiedAtOnceTakesTheRecordingArmedWithIt() {
        XCTAssertTrue(SessionRecoveryCoordinator.recording(startedAt: night.addingTimeInterval(90), belongsToWorkoutLastHeardAt: night))
    }
}

/// The baseline follows the archive whichever path changed it.
@MainActor
final class BaselineArchiveSyncTests: XCTestCase {
    private lazy var directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BaselineArchiveSyncTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: directory)
    private lazy var tracker = BaselineTracker(baselineFile: directory.appendingPathComponent("HRVBaseline.json"))

    override func tearDown() async throws {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            // swallow-ok: a test that wrote nothing leaves no directory to remove.
        }
        try await super.tearDown()
    }

    /// A change the baseline already agrees with rebuilds nothing; one it
    /// does not (a night it never took in, here an id the archive does not
    /// hold and the baseline does not either) is in step too.
    func testAnIdNeitherSideHoldsIsInStep() {
        var rebuilds = 0
        let sync = BaselineArchiveSync(archive: archive, baseline: tracker) { rebuilds += 1 }
        XCTAssertFalse(sync.isOutOfStep(UUID()))
        sync.note(UUID())
        sync.settle()
        XCTAssertEqual(rebuilds, 0)
    }

    /// A scored overnight the archive holds and the baseline lacks (a Trash
    /// restore, a recovered night, an iCloud import) is out of step, and the
    /// burst it arrives in rebuilds the baseline once.
    func testAScoredNightTheBaselineLacksRebuildsOnce() throws {
        var night = HRVSession(
            id: UUID(), startDate: Date().addingTimeInterval(-9 * 3600), endDate: Date().addingTimeInterval(-2 * 3600),
            state: .complete, sessionType: .overnight, rrSeries: nil,
            analysisResult: SnapshotFixtures.analysisResult(), artifactFlags: nil
        )
        night.recoveryScore = 7
        _ = try archive.archive(night, skipSameNightMerge: true)
        XCTAssertNotNil(archive.store.entries.first { $0.sessionId == night.id }?.meanRMSSD, "the fixture should be a scored night")
        var rebuilds = 0
        let sync = BaselineArchiveSync(archive: archive, baseline: tracker) { rebuilds += 1 }

        XCTAssertTrue(sync.isOutOfStep(night.id))
        sync.note(night.id)
        sync.note(night.id)
        sync.settle()
        XCTAssertEqual(rebuilds, 1)
    }
}
