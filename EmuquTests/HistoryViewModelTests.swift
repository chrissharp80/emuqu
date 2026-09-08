@testable import Emuqu
import XCTest

@MainActor
final class HistoryViewModelTests: XCTestCase {
    // `lazy` rather than assigned in `setUp`: the archive is derived from the
    // temp directory, and a stored property cannot read a sibling during init.
    //
    // Isolated on-disk archive. The default `SessionArchive()`
    // points at the SHARED App Group directory; a prior run killed before
    // tearDown leaves twin sessions at this test's FIXED epoch anchors with
    // identical scores, and the same-night collapse tie-break (score → linked
    // count → end → start: all equal for a twin) can then crown the stale twin
    // and hide the tracked canonical row. The UUID keeps every run hermetic.
    private lazy var tempDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("HistoryViewModelTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: tempDir)
    private var createdSessionIds: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        createdSessionIds = []
    }

    override func tearDown() async throws {
        for id in createdSessionIds {
            try? archive.delete(id)
        }
        createdSessionIds = []
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testHistoryCollapsesDuplicateOvernightRowsWithTinySuffixArtifact() async throws {
        let calendar = Calendar.current
        let day0 = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let start = TestDate.adding(.day, -45, to: day0, calendar: calendar)
            .addingTimeInterval(22 * 3600)

        // The canonical row carries the real recovery score. The near-duplicate
        // and the tiny-suffix artifact are UNSCORED sync/placeholder rows — the
        // only kind the same-night collapse folds away. HistoryViewModel's
        // rule deliberately keeps every *scored* same-night session
        // visible (hiding one made a real recovery vanish on re-score), so a
        // duplicate must be scoreless to collapse.
        var canonical = makeSession(
            start: start,
            end: start.addingTimeInterval(11 * 3600 + 41 * 60), // 9:41 AM
            score: 9.2
        )
        var nearDuplicate = makeSession(
            start: start.addingTimeInterval(4 * 60), // 4 minutes later
            end: start.addingTimeInterval(11 * 3600 + 36 * 60) // 9:36 AM, unscored placeholder
        )
        var tinySuffix = makeSession(
            start: start.addingTimeInterval(11 * 3600 + 41 * 60), // 9:41 AM
            end: start.addingTimeInterval(11 * 3600 + 43 * 60) // 9:43 AM, unscored 2-min artifact
        )

        // Keep explicit (non-resolving) links to bypass archive write-time same-night merge.
        canonical.linkedSessionIds = [UUID()]
        nearDuplicate.linkedSessionIds = [UUID()]
        tinySuffix.linkedSessionIds = [UUID()]

        createdSessionIds = [canonical.id, nearDuplicate.id, tinySuffix.id]

        _ = try archive.archive(canonical)
        _ = try archive.archive(nearDuplicate)
        _ = try archive.archive(tinySuffix)

        let viewModel = HistoryViewModel(archive: archive)
        viewModel.refreshIfNeeded(archiveVersion: 1)

        let trackedIds = Set(createdSessionIds)

        // The recompute runs on a `Task.detached` and publishes its result
        // back on the main actor (HistoryViewModel.recomputeFilteredEntries)
        // — `filteredEntries` is still [] immediately after refreshIfNeeded.
        // Poll until the result lands (exactly one tracked id must survive
        // the collapse); on a regression this times out and the assertions
        // below report the real counts.
        let deadline = Date().addingTimeInterval(2.0)
        while Set(viewModel.filteredEntries.map(\.sessionId)).isDisjoint(with: trackedIds),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let remainingIds = Set(viewModel.filteredEntries.map(\.sessionId)).intersection(trackedIds)

        XCTAssertEqual(remainingIds.count, 1, "Only one row should remain for the duplicated overnight night")
        XCTAssertTrue(remainingIds.contains(canonical.id), "Highest-quality canonical entry should be retained")
        XCTAssertFalse(remainingIds.contains(nearDuplicate.id))
        XCTAssertFalse(remainingIds.contains(tinySuffix.id))
    }

    private func makeSession(start: Date, end: Date, score: Double? = nil) -> HRVSession {
        var session = HRVSession(
            id: UUID(),
            startDate: start,
            endDate: end,
            state: .complete,
            sessionType: .overnight,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil
        )
        // nil score = an unscored sync/placeholder duplicate (the only kind the
        // same-night collapse folds away, per HistoryViewModel's rule).
        session.recoveryScore = score
        return session
    }
}
