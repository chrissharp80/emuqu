@testable import Emuqu
import XCTest

/// How a screen that charts the whole history loads it
/// (`RRCollector.decodeInParallel`, `RRCollector.allSessionsAsync`): every
/// session comes back in the archive's order; no more than `decodeWidth`
/// reads run at once, so a cancelled load stops after the reads already
/// running; and a cancelled `allSessionsAsync` returns nil, never part of
/// the history.
@MainActor
final class SessionDecodeTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SessionDecodeTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: directory.appendingPathComponent("Archive", isDirectory: true))

    override func setUp() async throws {
        try await super.setUp()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    /// `count` complete nights on consecutive days, archived.
    private func archiveNights(_ count: Int) throws {
        for day in 0 ..< count {
            let start = Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * 86_400)
            let night = HRVSession(
                id: UUID(), startDate: start, endDate: start.addingTimeInterval(8 * 3600),
                state: .complete, sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
            )
            _ = try archive.archive(night, skipSameNightMerge: true)
        }
    }

    func testEverySessionComesBackInTheArchivesOrder() async throws {
        try archiveNights(RRCollector.decodeWidth * 3 + 1)
        let entries = archive.store.entries
        let archive = archive
        let decoded = await Task.detached { await RRCollector.decodeInParallel(entries, archive: archive) }.value
        XCTAssertEqual(decoded.map(\.id), entries.map(\.sessionId))
    }

    /// A load cancelled before it starts reads only its first window: no
    /// read starts after cancellation.
    func testACancelledDecodeStartsNoNewReads() async throws {
        try archiveNights(RRCollector.decodeWidth * 3)
        let entries = archive.store.entries
        let archive = archive
        let decoded = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return await RRCollector.decodeInParallel(entries, archive: archive)
        }.value
        XCTAssertLessThanOrEqual(decoded.count, RRCollector.decodeWidth)
    }

    func testAllSessionsAsyncReturnsTheWholeArchive() async throws {
        try archiveNights(5)
        let loaded = await makeCollector().allSessionsAsync()
        XCTAssertEqual(loaded?.map(\.id), archive.store.entries.map(\.sessionId))
    }

    /// The screen went away: nil, so nothing partial replaces what it shows.
    func testACancelledAllSessionsAsyncReturnsNil() async throws {
        try archiveNights(5)
        let collector = makeCollector()
        let loaded = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await collector.allSessionsAsync()
        }.value
        XCTAssertNil(loaded)
    }

    private func makeCollector() -> RRCollector {
        RRCollector(
            polarManager: PolarManager(),
            healthKit: HealthKitManager(),
            archive: archive,
            rawBackup: RawRRBackup(directory: directory.appendingPathComponent(AppConfig.backupDirectoryName, isDirectory: true)),
            baselineTracker: BaselineTracker(baselineFile: directory.appendingPathComponent("HRVBaseline.json"))
        )
    }
}
