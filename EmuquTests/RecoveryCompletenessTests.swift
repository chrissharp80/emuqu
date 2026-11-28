@testable import Emuqu
import XCTest

/// No recovery, export or sync status claims a whole when part of it is
/// missing, and no recovery counts a beat twice: a resumed segment's backup
/// that already holds its parent is not merged with it again, a backup part
/// that cannot be read fails the read, an export over an index that did not
/// load is refused, a recovery that kept a paused or finished copy says so,
/// a fuller backup beside an archived fragment reaches the night, and an
/// upload still running is not reported as failed.
///
/// Everything runs over a temporary archive, raw-backup folder and sync
/// manager; the host's recording marker, paused night and sync bookkeeping
/// are set aside and put back.
@MainActor
final class RecoveryCompletenessTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveryCompletenessTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: directory.appendingPathComponent("Archive", isDirectory: true))
    private lazy var collector = makeCollector()
    private var hostDefaults: HostDefaults?
    private let parentStart = Date(timeIntervalSince1970: 1_790_000_000)

    private static let cloudPullKey = "sessionRecoveryLastCloudPull"
    private static let pausedKeys = [UserDefaultsKeys.pausedSessionId, "pausedSessionUsesDeviceBackup"]

    override func setUp() async throws {
        try await super.setUp()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        isolateFromHostRecordingState()
        hostDefaults = HostDefaults.setAside([Self.cloudPullKey] + Self.pausedKeys + HostDefaults.cloudSyncBookkeeping)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cloudPullKey)
    }

    override func tearDown() async throws {
        hostDefaults?.restore()
        try FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - A segment's backup that holds its parent

    private struct ParentRow {
        let name: String
        let points: [RRPoint]
        let start: Date
        let parent: [RRPoint]
    }

    /// Merged once, whichever way the backup was written: the segment's own
    /// beats get the parent in front, and a backup a pause already merged
    /// keeps the parent once, dated by the parent's start (a second lost or
    /// not, the parent rewritten since or not) or, as older builds dated it,
    /// by the resume.
    func testASegmentBackupThatHoldsItsParentGetsItOnce() {
        let parent = beats(100)
        let own = beats(50, rr: 800)
        let resume = parentStart.addingTimeInterval(3600)
        let merged = mergedPoints(parent: parent, child: own, childStart: resume)
        let rewritten = beats(100, rr: 1001)
        let rows = [
            ParentRow(name: "the segment's own beats", points: own, start: resume, parent: parent),
            ParentRow(name: "merged, dated by the parent's start", points: merged, start: parentStart, parent: parent),
            ParentRow(name: "merged, dated within a second of it", points: merged, start: parentStart.addingTimeInterval(0.6), parent: parent),
            ParentRow(name: "merged, the parent rewritten since", points: merged, start: parentStart, parent: rewritten),
            ParentRow(name: "merged, dated by the resume", points: merged, start: resume, parent: parent)
        ]
        for row in rows {
            let points = mergedPoints(parent: row.parent, child: row.points, childStart: row.start)
            XCTAssertEqual(points.count, 150, row.name)
        }
    }

    /// The crash between a pause's merged backup and its archive: recovery
    /// rebuilds the segment with the parent's beats once, on its clock.
    func testRecoveringAPausedSegmentsMergedBackupHoldsTheParentOnce() async throws {
        let childId = UUID()
        var parent = night(UUID(), points: beats(300), state: .paused, start: parentStart)
        parent.linkedSessionIds = [childId]
        _ = try archive.archive(parent, skipSameNightMerge: true)
        let merged = mergedPoints(parent: beats(300), child: beats(200, rr: 800), childStart: parentStart.addingTimeInterval(3600))
        _ = try collector.rawBackup.backup(points: merged, sessionId: childId, captureDate: parentStart)

        let data = await collector.recovery.recoveryService.retrieveBackupWithParentMerge(childId)

        XCTAssertEqual(data?.series.points.count, 500, "the parent's beats were merged in again")
        XCTAssertEqual(data?.sessionStart, parentStart)
    }

    /// The merge repair rebuilds only a child that lost its parent's beats:
    /// one that holds exactly them (resumed and paused before a beat) is not
    /// given them twice.
    func testTheMergeRepairMergesOnlyAChildThatLacksItsParent() {
        let parent = beats(300)
        let rows: [(name: String, child: [RRPoint], lacks: Bool)] = [
            ("the parent's beats alone", parent, false),
            ("fewer beats of its own", beats(200, rr: 800), true),
            ("merged", parent + beats(200, from: 400_000, rr: 800), false)
        ]
        for row in rows {
            XCTAssertEqual(
                SessionRecoveryCoordinator.lacksParentBeats(childSeries: series(row.child), parentSeries: series(parent)), row.lacks, row.name
            )
        }
    }

    // MARK: - A backup part that cannot be read

    /// A night whose first 200 beats an earlier append set aside: with that
    /// part unreadable the read fails, rather than return the other 100 as
    /// the whole backup and lower its count to them.
    func testABackupPartThatCannotBeReadFailsTheReadAndKeepsTheCount() throws {
        let backup = RawRRBackup(directory: directory.appendingPathComponent("Parts", isDirectory: true))
        let id = UUID()
        try backup.appendBackup(points: beats(300), sessionId: id)
        let live = backup.pointsURL(for: id)
        let lines = try String(contentsOf: live, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true)
        let setAside = URL(fileURLWithPath: live.path + ".corrupted_1")
        try (lines.prefix(200).joined(separator: "\n") + "\n").write(to: setAside, atomically: true, encoding: .utf8)
        try (lines.suffix(100).joined(separator: "\n") + "\n").write(to: live, atomically: true, encoding: .utf8)
        backup.indexLock.withLock {
            if let row = backup.index.firstIndex(where: { $0.id == id }) { backup.index[row].lastBackupTime = .distantPast }
        }
        XCTAssertEqual(try backup.retrieve(id)?.points.count, 300, "the fixture expects both parts read")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: setAside.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: setAside.path) }

        XCTAssertThrowsError(try backup.retrieve(id), "part of the backup was returned as all of it")
        let row = backup.indexLock.withLock { backup.index.first { $0.id == id } }
        XCTAssertEqual(row?.backedUpCount, 300, "the count was lowered to the part that read")
    }

    // MARK: - Exports over an index that did not load

    func testAnExportRunsOnlyOverAnIndexThatLoadedWhole() {
        XCTAssertNil(HistoryExportGate.refusal(indexComplete: true))
        XCTAssertNotNil(HistoryExportGate.refusal(indexComplete: false), "an export over a partial index was let through")
    }

    // MARK: - What a recovery that kept a stored copy says

    /// Resume over a finished copy holding more than the backup: the night
    /// is saved, so nothing is put on the Record tab to resume.
    func testResumeOverAFinishedCopyHoldingMoreReportsItSaved() async throws {
        let id = UUID()
        _ = try collector.rawBackup.backup(points: beats(200), sessionId: id)
        _ = try archive.archive(night(id, points: beats(300), state: .complete, start: parentStart), skipSameNightMerge: true)

        let outcome = await collector.recovery.recoverToPausedState(id, sessionType: .overnight)

        XCTAssertEqual(outcome, .saved(.overnight))
        XCTAssertNil(collector.streamingLifecycle.pausedSession, "a saved night was put on the Record tab to resume")
    }

    /// Save over a paused copy holding more than the backup: the night stays
    /// paused, and is on the Record tab to resume or finish, as the launch
    /// alert then says.
    func testSaveOverAPausedCopyHoldingMoreLeavesItPausedOnTheRecordTab() async throws {
        let id = UUID()
        _ = try collector.rawBackup.backup(points: beats(200), sessionId: id)
        _ = try archive.archive(night(id, points: beats(300), state: .paused, start: parentStart), skipSameNightMerge: true)

        let recovered = await collector.recovery.recoverFromBackup(id)

        XCTAssertEqual(recovered?.state, .paused)
        XCTAssertEqual(collector.streamingLifecycle.pausedSession?.id, id, "a night kept paused was nowhere to resume or finish")
        XCTAssertEqual(collector.recordingStore.pausedSessionId(), id)
    }

    // MARK: - A fuller backup beside an archived fragment

    private struct StrandRow {
        let name: String
        let night: [RRPoint]
        let backup: [RRPoint]
        let strands: Bool
    }

    func testABackupStrandsBeatsOnlyWhereItGoesOnPastTheNight() {
        let rows = [
            StrandRow(name: "fragment of the night", night: beats(300), backup: beats(2000), strands: true),
            StrandRow(name: "same end, more beats", night: beats(1000), backup: beats(1100, rr: 909), strands: false),
            StrandRow(name: "night covers it", night: beats(2000), backup: beats(300), strands: false),
            StrandRow(name: "too few past the night", night: beats(300), backup: beats(400), strands: false),
            StrandRow(name: "night without beats", night: [], backup: beats(300), strands: true)
        ]
        for row in rows {
            let held = night(UUID(), points: row.night, state: .complete, start: parentStart)
            XCTAssertEqual(SessionRecoveryService.strandsBeats(row.backup, from: parentStart, beside: held), row.strands, row.name)
        }
    }

    /// A night recovered from an early pull of another device's backup, and
    /// the fuller backup the scan pulled later: the beats reach the night,
    /// and the backup is then done.
    func testAFullerBackupBesideAnArchivedFragmentReachesTheNight() async throws {
        let id = UUID()
        let start = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 10 * 3600).rounded(.down))
        let full = varyingBeats(3000)
        _ = try archive.archive(night(id, points: Array(full.prefix(300)), state: .complete, start: start), skipSameNightMerge: true)
        _ = try collector.rawBackup.backup(points: full, sessionId: id, captureDate: start)

        await collector.recovery.mergeStrandedFullerBackups()

        XCTAssertGreaterThanOrEqual(try archive.retrieve(id)?.rrSeries?.points.count ?? 0, 3000, "the fuller backup's beats never reached the night")
        XCTAssertFalse(collector.rawBackup.unarchivedSessionIds.contains(id))
    }

    // MARK: - Sync status while an upload runs

    /// A saved session waiting for its upload is not "pending retry"; one
    /// whose upload failed is.
    func testOnlyAnUploadThatFailedCountsAsPendingRetry() throws {
        let manager = CloudKitSyncManager.isolated(archive: archive, directory: directory.appendingPathComponent("Sync", isDirectory: true))
        let waiting = night(UUID(), points: beats(10), state: .complete, start: parentStart)
        let failed = night(UUID(), points: beats(10), state: .complete, start: parentStart.addingTimeInterval(86400))
        _ = try archive.archive(waiting, skipSameNightMerge: true)
        _ = try archive.archive(failed, skipSameNightMerge: true)
        XCTAssertEqual(manager.uploadsWaitingCount, 2, "the fixture expects both waiting")
        XCTAssertEqual(manager.failedUploadsWaitingCount, 0, "an upload that had not failed was shown as pending retry")

        manager.state.markFailed(failed.id)

        XCTAssertEqual(manager.failedUploadsWaitingCount, 1)
    }

    // MARK: - Helpers

    private func makeCollector() -> RRCollector {
        let rawBackup = RawRRBackup(directory: directory.appendingPathComponent(AppConfig.backupDirectoryName, isDirectory: true))
        let tracker = BaselineTracker(baselineFile: directory.appendingPathComponent("HRVBaseline.json"))
        let sync = CloudKitSyncManager.isolated(archive: archive, directory: directory.appendingPathComponent("CollectorSync", isDirectory: true))
        let acceptance = SessionAcceptanceService(
            archive: archive, healthKit: MockHealthKitService(), baselineTracker: tracker, rawBackup: rawBackup,
            onCloudSync: { _ in }, onCloudDelete: { _ in }
        )
        return RRCollector(
            polarManager: PolarManager(), healthKit: HealthKitManager.forTests(), archive: archive, rawBackup: rawBackup,
            baselineTracker: tracker,
            settingsManager: AppDependencies.current.app.settingsManager, cloudSyncManager: sync, acceptanceService: acceptance,
            services: CollectorServices(.current)
        )
    }

    /// `count` beats `rr` ms apart, from `offset`, alternating 10 ms either side.
    private func beats(_ count: Int, from offset: Int64 = 0, rr: Int = 1000) -> [RRPoint] {
        (0 ..< count).map { RRPoint(t_ms: offset + Int64($0) * Int64(rr), rr_ms: $0 % 2 == 0 ? rr - 10 : rr + 10) }
    }

    /// Beats whose intervals vary as a resting heart's do, for an analysis.
    private func varyingBeats(_ count: Int) -> [RRPoint] {
        var time: Int64 = 0
        return (0 ..< count).map { index in
            let interval = 940 + (index * 37) % 120
            defer { time += Int64(interval) }
            return RRPoint(t_ms: time, rr_ms: interval)
        }
    }

    private func series(_ points: [RRPoint]) -> RRSeries {
        RRSeries(points: points, sessionId: UUID(), startDate: parentStart)
    }

    private func mergedPoints(parent: [RRPoint], child: [RRPoint], childStart: Date) -> [RRPoint] {
        SessionRecoveryService.parentMergedPoints(
            parentSeries: series(parent), parentStart: parentStart, childPoints: child, childStart: childStart
        )
    }

    private func night(_ id: UUID, points: [RRPoint], state: HRVSession.SessionState, start: Date) -> HRVSession {
        HRVSession(
            id: id, startDate: start, endDate: points.lastBeatEnd(after: start) ?? start, state: state,
            sessionType: .overnight, rrSeries: points.isEmpty ? nil : RRSeries(points: points, sessionId: id, startDate: start),
            analysisResult: nil, artifactFlags: nil
        )
    }
}
