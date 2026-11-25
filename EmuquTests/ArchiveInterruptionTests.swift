@testable import Emuqu
import XCTest

/// An archive change killed partway: a rewrite between the file and the
/// index, and a delete between the index and the Trash. The next launch
/// (`SessionArchive.boot`) finishes each.
final class ArchiveInterruptionTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ArchiveInterruptionTests-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            // swallow-ok: a test that wrote nothing leaves no directory.
        }
        super.tearDown()
    }

    private func night() -> HRVSession {
        HRVSession(
            id: UUID(), startDate: Date(timeIntervalSince1970: 1_790_000_000), endDate: Date(timeIntervalSince1970: 1_790_028_800),
            state: .complete, sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
    }

    /// The new file landed, the index did not: the marker the rewrite left
    /// has the next launch re-hash the file, and the edit reads back.
    func testARewriteKilledBeforeTheIndexSaveIsHealedAtLaunch() throws {
        let archive = SessionArchive(directory: directory.appendingPathComponent("Archive"))
        var session = night()
        try archive.archive(session)
        session.notes = "written just before the kill"
        let scratch = SessionArchive(directory: directory.appendingPathComponent("Scratch"))
        try scratch.archive(session)
        let file = "\(session.id.uuidString).json"
        let liveFile = archive.archiveDirectory.appendingPathComponent(file)
        try FileManager.default.removeItem(at: liveFile)
        try FileManager.default.copyItem(at: scratch.archiveDirectory.appendingPathComponent(file), to: liveFile)
        archive.store.markRewriteStarting(session.id)
        XCTAssertThrowsError(try archive.retrieve(session.id), "the stale hash should fail the read before healing")

        archive.boot()

        XCTAssertEqual(try archive.retrieve(session.id)?.notes, "written just before the kill")
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.store.interruptedRewriteMarker(for: session.id).path))
    }

    /// A completed rewrite leaves no marker.
    func testACompletedRewriteLeavesNoMarker() throws {
        let archive = SessionArchive(directory: directory.appendingPathComponent("Archive"))
        var session = night()
        try archive.archive(session)
        session.notes = "edited"
        try archive.archive(session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.store.interruptedRewriteMarker(for: session.id).path))
    }

    /// The index lost the session, the file never reached the Trash: the
    /// next launch moves it there, so a restore finds it as it was.
    func testADeleteKilledBeforeTheTrashMoveIsFinishedAtLaunch() throws {
        let archive = SessionArchive(directory: directory.appendingPathComponent("Archive"))
        var session = night()
        session.notes = "kept through the restore"
        try archive.archive(session)
        XCTAssertTrue(try archive.delete(session.id))
        let trashed = try XCTUnwrap(archive.store.parkedCopies(of: session.id)?.first)
        let leftover = archive.archiveDirectory.appendingPathComponent("\(session.id.uuidString).json")
        try FileManager.default.moveItem(at: trashed, to: leftover)
        XCTAssertFalse(archive.store.trashedIds.contains(session.id))

        archive.boot()

        XCTAssertTrue(archive.store.trashedIds.contains(session.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertFalse(archive.store.exists(session.id))
    }
}
