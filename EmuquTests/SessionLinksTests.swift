@testable import Emuqu
import os
import XCTest

/// What `linkedSessionIds` say, read the one way every reader reads them
/// (`SessionLinks`): a link says the linking session holds the linked
/// recording's beats, except a paused night's link back to the segment
/// resumed from it. Read as a holding, that back-reference hid a resumed
/// night's final session from every merge, so a strap recording of the night
/// was filed as a second night.
@MainActor
final class SessionLinksTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SessionLinksTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: directory)
    /// 23:00 UTC; the night's anchor is read in `Calendar.current`, pinned to
    /// UTC so the times below fall in one night on every host.
    private let bedtime = Date(timeIntervalSince1970: 4_102_441_200)

    nonisolated private static let savedDefaultTimeZone = OSAllocatedUnfairLock<TimeZone?>(initialState: nil)

    override class func setUp() {
        super.setUp()
        savedDefaultTimeZone.withLock { $0 = NSTimeZone.default }
        NSTimeZone.default = TestTimeZone.utc
    }

    override class func tearDown() {
        if let saved = savedDefaultTimeZone.withLock({ $0 }) { NSTimeZone.default = saved }
        savedDefaultTimeZone.withLock { $0 = nil }
        super.tearDown()
    }

    override func tearDown() async throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try await super.tearDown()
    }

    private func node(_ id: UUID, _ links: [UUID], endingAfterHours hours: Double) -> SessionLinks.Node {
        SessionLinks.Node(id: id, links: links, end: bedtime.addingTimeInterval(hours * 3600))
    }

    // MARK: - The relation

    /// Each shape the links take: a resumed night, a night resumed twice, a
    /// night that superseded a same-night recording, both at once, and a
    /// paused night whose segment was never archived.
    func testOnlyTheRecordingsAnotherHoldsAreAbsorbed() {
        let (parent, first, second, sibling) = (UUID(), UUID(), UUID(), UUID())
        let cases: [(name: String, nodes: [SessionLinks.Node], absorbed: Set<UUID>)] = [
            ("resumed once", [node(parent, [first], endingAfterHours: 2), node(first, [parent], endingAfterHours: 8)], [parent]),
            ("resumed twice", [
                node(parent, [first], endingAfterHours: 2),
                node(first, [parent, second], endingAfterHours: 4),
                node(second, [first], endingAfterHours: 8)
            ], [parent, first]),
            ("superseded", [node(sibling, [], endingAfterHours: 1), node(parent, [sibling], endingAfterHours: 8)], [sibling]),
            ("resumed and superseded", [
                node(parent, [first], endingAfterHours: 2),
                node(first, [parent, sibling], endingAfterHours: 8),
                node(sibling, [], endingAfterHours: 1)
            ], [parent, sibling]),
            ("segment never archived", [node(parent, [first], endingAfterHours: 2)], [first])
        ]
        for testCase in cases {
            XCTAssertEqual(SessionLinks.absorbedIds(in: testCase.nodes), testCase.absorbed, testCase.name)
        }
    }

    /// A recording with no archive entry has its resume parent among the
    /// sessions that list it: the one that stopped before it did. A night
    /// that holds its beats, and so ends after it, is not its parent.
    func testTheParentOfARecordingWithNoEntryStoppedBeforeIt() {
        let child = UUID()
        let childEnd = bedtime.addingTimeInterval(6 * 3600)
        XCTAssertTrue(SessionLinks.isResumeParent(node(UUID(), [child], endingAfterHours: 2), ofUnarchived: child, childEnd: childEnd))
        XCTAssertFalse(SessionLinks.isResumeParent(node(UUID(), [child], endingAfterHours: 8), ofUnarchived: child, childEnd: childEnd))
        XCTAssertFalse(SessionLinks.isResumeParent(node(UUID(), [], endingAfterHours: 2), ofUnarchived: child, childEnd: childEnd))
    }

    // MARK: - Readers

    private func resumedNight() throws -> (parent: HRVSession, final: HRVSession) {
        let parentId = UUID()
        let finalId = UUID()
        let parent = HRVSession(
            id: parentId, startDate: bedtime, endDate: bedtime.addingTimeInterval(2 * 3600), state: .paused,
            rrSeries: nil, analysisResult: nil, artifactFlags: nil,
            linkedSessionIds: [finalId], pausedDate: bedtime.addingTimeInterval(2 * 3600)
        )
        let final = HRVSession(
            id: finalId, startDate: bedtime, endDate: bedtime.addingTimeInterval(8 * 3600), state: .complete,
            rrSeries: nil, analysisResult: nil, artifactFlags: nil, linkedSessionIds: [parentId]
        )
        _ = try archive.archive(parent, skipSameNightMerge: true)
        _ = try archive.archive(final, skipSameNightMerge: true)
        return (parent, final)
    }

    /// The strap's recording of a resumed night, armed at the resume and
    /// downloaded late, is a copy of the night's final session, the one
    /// Recover and the archive's write path fold it into.
    func testAStrapRecordingOfAResumedNightFoldsIntoItsFinalSession() throws {
        let night = try resumedNight()
        var recording = HRVSession(startDate: bedtime.addingTimeInterval(2 * 3600 + 300), sessionType: .overnight)
        recording.endDate = bedtime.addingTimeInterval(8 * 3600)

        XCTAssertEqual(archive.store.lockedMergeTarget(for: recording, sameSleepGap: nil)?.sessionId, night.final.id)
        XCTAssertTrue(archive.store.holdsCopy(of: recording))
    }

    /// A paused night's link to the segment resumed from it lists no
    /// segment to show or unlink; the final session lists the paused part.
    func testAPausedNightListsNoSegmentResumedFromIt() throws {
        let night = try resumedNight()
        XCTAssertNil(archive.linkedSegments(for: night.parent))
        XCTAssertEqual(archive.linkedSegments(for: night.final)?.map(\.id), [night.parent.id])
    }

    /// A backup's parent is the session it was resumed from, never the one
    /// resumed from it: read the other way, the whole night was put in front
    /// of the paused part's beats.
    func testOnlyTheParentIsTakenForABackupsParent() throws {
        let night = try resumedNight()
        let entries = archive.store.entries
        let parentEntry = try XCTUnwrap(entries.first { $0.sessionId == night.parent.id })
        let finalEntry = try XCTUnwrap(entries.first { $0.sessionId == night.final.id })
        let end = bedtime.addingTimeInterval(8 * 3600)
        XCTAssertTrue(SessionRecoveryService.isResumeParent(parentEntry, of: night.final.id, child: SessionLinks.Node(finalEntry), childEnd: end))
        XCTAssertFalse(SessionRecoveryService.isResumeParent(finalEntry, of: night.parent.id, child: SessionLinks.Node(parentEntry), childEnd: end))
    }
}
