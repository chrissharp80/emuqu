import CloudKit
@testable import Emuqu
import os
import XCTest

/// A change that must reach iCloud, killed partway: what the kill leaves on
/// disk has to carry the request to upload it again, and the next launch's
/// sync has to act on it. Each test stops where a kill would
/// (`ArchiveStore.betweenFileAndIndex`), or rebuilds the state from what a
/// relaunch reads.
final class ReuploadRequestTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReuploadRequestTests-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
        attempt("test.removeDirectory") { try FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func makeArchive() -> SessionArchive {
        SessionArchive(
            directory: directory.appendingPathComponent("Archive"),
            sleepScheduleProvider: { SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0) },
            sessionMergeModeProvider: { .defaultGap },
            mergeGapProvider: { 4.5 * 3600 }
        )
    }

    private func night(start: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> HRVSession {
        HRVSession(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(8 * 3600),
            state: .complete, sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
    }

    /// What `body` saw at the kill point of each rewrite it ran: whether the
    /// session's rewrite marker and its upload-again request were on disk.
    private func atKillPoint(of archive: SessionArchive, _ body: () throws -> Void) rethrows -> [UUID: (marked: Bool, requested: Bool)] {
        let seen = OSAllocatedUnfairLock(initialState: [UUID: (marked: Bool, requested: Bool)]())
        try ArchiveStore.$betweenFileAndIndex.withValue({ id in
            let marked = FileManager.default.fileExists(atPath: archive.store.interruptedRewriteMarker(for: id).path)
            let requested = ReuploadRequestJournal(directory: archive.archiveDirectory).pending[id] != nil
            seen.withLock { $0[id] = (marked, requested) }
        }, operation: body)
        return seen.withLock { $0 }
    }

    // MARK: - The journal

    /// A request outlives the process that made it, and settling what sync
    /// saved leaves a request made again since.
    func testARequestSurvivesARelaunchAndARepeatOutlivesTheSettle() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = ReuploadRequestJournal(directory: directory)
        let (edited, editedAgain) = (UUID(), UUID())
        journal.record([edited, editedAgain])
        let saved = ReuploadRequestJournal(directory: directory).pending
        XCTAssertEqual(Set(saved.keys), [edited, editedAgain], "a relaunch read no requests")

        journal.record([editedAgain])
        journal.settle(saved)

        XCTAssertEqual(Set(ReuploadRequestJournal(directory: directory).pending.keys), [editedAgain])
    }

    // MARK: - Writers record before they write

    /// An edit's request is on disk by the time its file is, so a kill before
    /// the index save, or before sync saved the request, keeps it.
    func testAnEditIsAskedToUploadBeforeItsFileIsWritten() throws {
        let archive = makeArchive()
        let session = night()
        try archive.archive(session)

        let seen = try atKillPoint(of: archive) {
            try archive.update(session.id) { $0.notes = "edited just before the kill" }
        }

        XCTAssertEqual(seen[session.id]?.requested, true)
        XCTAssertEqual(seen[session.id]?.marked, true)
    }

    /// The relink migration rewrites a night's latest recording in place: the
    /// rewrite carries the marker the next launch re-hashes it by, and its
    /// upload-again request, from before the file is written.
    func testARelinkKilledBeforeTheIndexSaveLeavesItsMarkerAndRequest() throws {
        let archive = makeArchive()
        let start = ArchiveIntegrityTests.nightAnchoredDate(daysAgo: 17)
        let early = MergeClockFixture.session(start: start, minutes: 90, meanRR: 1000, sessionType: .overnight)
        let late = MergeClockFixture.session(start: start.addingTimeInterval(4 * 3600), minutes: 120, meanRR: 850, sessionType: .overnight)
        for recording in [early, late] {
            _ = try archive.archive(recording, skipSameNightMerge: true)
        }

        let seen = atKillPoint(of: archive) { archive.migrations.relinkSameNightSessions() }

        XCTAssertEqual(try archive.retrieve(late.id)?.linkedSessionIds, [early.id], "the night was not relinked")
        XCTAssertEqual(seen[late.id]?.marked, true, "a kill here left the stale hash with no marker")
        XCTAssertEqual(seen[late.id]?.requested, true, "a kill here lost the upload of the relinked night")
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.store.interruptedRewriteMarker(for: late.id).path))
    }

    // MARK: - Sync takes the requests

    /// A request a killed launch left is taken into the pending queue at the
    /// next one, saved with the uploaded set, and only then settled.
    @MainActor
    func testSyncTakesARequestALaunchLeftAndSettlesItOnceSaved() async throws {
        let host = HostDefaults.setAside(HostDefaults.cloudSyncBookkeeping)
        defer { host.restore() }
        let archive = makeArchive()
        let session = night()
        try archive.archive(session)
        let syncDirectory = directory.appendingPathComponent("Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDirectory, withIntermediateDirectories: true)
        let manager = CloudKitSyncManager.isolated(archive: archive, directory: syncDirectory)
        manager.state.markUploaded(session.id)
        manager.state.saveSyncState()
        archive.noteReuploadIntent([session.id])

        await manager.markSessionsForReupload([])

        var relaunched = CloudKitSyncState(syncStateURL: syncDirectory.appendingPathComponent("sync_state.json"))
        relaunched.loadAll()
        XCTAssertTrue(relaunched.pendingUploadIds.contains(session.id), "the request did not reach the saved queue")
        XCTAssertFalse(relaunched.uploadedSessionIds.contains(session.id))
        XCTAssertTrue(archive.state.reuploadRequests.pending.isEmpty, "a saved request was not settled")
    }

    /// "Upload it again" saved with the uploaded set alone still reaches the
    /// pending queue on disk: written apart, a kill between left the session
    /// in neither, and the pull marked iCloud's older copy uploaded.
    func testASaveOfTheUploadedSetCarriesThePendingQueue() throws {
        let url = directory.appendingPathComponent("sync_state.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var state = CloudKitSyncState(syncStateURL: url)
        state.loadAll()
        let id = UUID()
        state.markUploaded(id)
        state.saveSyncState()

        state.markRemoved(id)
        state.saveSyncState()

        var relaunched = CloudKitSyncState(syncStateURL: url)
        relaunched.loadAll()
        XCTAssertFalse(relaunched.uploadedSessionIds.contains(id))
        XCTAssertTrue(relaunched.pendingUploadIds.contains(id), "the request to upload again was lost with the launch")
    }

    /// The health scrub's batch stays on its list until the sync state
    /// queueing it is on disk: taken off first, a kill before the save left
    /// those records holding Apple Health readings in iCloud for good.
    @MainActor
    func testTheHealthScrubKeepsABatchUntilItsQueueIsSaved() async throws {
        let keys = [CloudHealthScrubCoordinator.remainingKey, CloudHealthScrubCoordinator.initializedKey]
        let host = HostDefaults.setAside(HostDefaults.cloudSyncBookkeeping + keys)
        defer { host.restore() }
        let syncDirectory = directory.appendingPathComponent("Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDirectory, withIntermediateDirectories: true)
        let manager = CloudKitSyncManager.isolated(archive: makeArchive(), directory: syncDirectory)
        let id = UUID()
        manager.state.markUploaded(id)
        UserDefaults.standard.set([id.uuidString], forKey: CloudHealthScrubCoordinator.remainingKey)
        UserDefaults.standard.set(true, forKey: CloudHealthScrubCoordinator.initializedKey)
        // A file where the folder was: the save of the queue fails.
        try FileManager.default.removeItem(at: syncDirectory)
        try Data().write(to: syncDirectory)

        await manager.healthScrub.dripReupload()

        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: CloudHealthScrubCoordinator.remainingKey), [id.uuidString])
    }

    // MARK: - The pull

    /// A held copy edited after the iCloud copy, with no request left to say
    /// so, is queued to go up by the pull, not marked uploaded.
    @MainActor
    func testThePullQueuesAHeldCopyEditedAfterTheICloudCopy() async throws {
        let host = HostDefaults.setAside(HostDefaults.cloudSyncBookkeeping)
        defer { host.restore() }
        let archive = makeArchive()
        var session = night()
        let uploadedAt = Date(timeIntervalSince1970: 1_790_100_000)
        session.modifiedAt = uploadedAt.addingTimeInterval(60)
        try archive.archive(session)
        let syncDirectory = directory.appendingPathComponent("Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: syncDirectory, withIntermediateDirectories: true)
        let manager = CloudKitSyncManager.isolated(archive: archive, directory: syncDirectory)
        let record = CKRecord(recordType: manager.recordType, recordID: CKRecord.ID(recordName: session.id.uuidString, zoneID: manager.zoneID))
        record["isDeleted"] = Int64(0) as CKRecordValue
        record["startDate"] = session.startDate as CKRecordValue
        record[CloudKitSessionFreshness.modifiedAtField] = uploadedAt as CKRecordValue

        _ = await manager.pull.processRemoteRecord(record, forgotten: [])

        XCTAssertFalse(manager.state.uploadedSessionIds.contains(session.id), "the older iCloud copy was taken for this edit")
        XCTAssertTrue(manager.state.pendingUploadIds.contains(session.id))
    }
}
