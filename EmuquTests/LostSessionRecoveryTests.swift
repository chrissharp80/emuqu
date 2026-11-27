@testable import Emuqu
import XCTest

/// Lost Sessions and launch recovery of an interrupted workout
/// (`SessionRecoveryCoordinator`, SessionRecoveryCoordinator+Backup.swift).
///
/// Lost Sessions lists raw backups no archived session holds and lets the
/// user delete them. The one thing that keeps a recording in progress out of
/// that list is `liveRecordingIds()`: without it tonight's recording is
/// offered for deletion. Launch auto-recovery picks the interrupted workout
/// from the persisted recording marker and must leave that marker in place
/// whenever it does not recover the workout, so the manual card still offers
/// it.
///
/// Everything runs over a temporary archive, raw-backup folder and sync
/// manager. The host's persisted recording state, its live workout and the
/// two recovery keys in standard defaults are set aside and put back.
@MainActor
final class LostSessionRecoveryTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LostSessionRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: directory.appendingPathComponent("Archive", isDirectory: true))
    private lazy var collector = makeCollector()

    /// `SessionRecoveryService`'s rate limit on the iCloud backup pull and
    /// the per-workout auto-recovery attempt count.
    private static let cloudPullKey = "sessionRecoveryLastCloudPull"
    private static let attemptsKey = "autoRecoverAttempts"
    private var hostDefaults: HostDefaults?

    override func setUp() async throws {
        try await super.setUp()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        isolateFromHostRecordingState()
        hostDefaults = HostDefaults.setAside([Self.cloudPullKey, Self.attemptsKey] + HostDefaults.cloudSyncBookkeeping)
        // A pull made just now: the scan reads only the local backups and
        // never asks iCloud for live ones.
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cloudPullKey)
    }

    override func tearDown() async throws {
        hostDefaults?.restore()
        try FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func makeCollector() -> RRCollector {
        let rawBackup = RawRRBackup(directory: directory.appendingPathComponent(AppConfig.backupDirectoryName, isDirectory: true))
        let tracker = BaselineTracker(baselineFile: directory.appendingPathComponent("HRVBaseline.json"))
        let sync = CloudKitSyncManager.isolated(archive: archive, directory: directory.appendingPathComponent("Sync", isDirectory: true))
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

    private func beats(_ count: Int) -> [RRPoint] {
        (0 ..< count).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: $0 % 2 == 0 ? 990 : 1010) }
    }

    /// A backup of 300 beats, over the 120 a lost session needs to be listed.
    private func backup(_ id: UUID) throws {
        _ = try collector.rawBackup.backup(points: beats(300), sessionId: id)
    }

    // MARK: - Lost Sessions

    /// Of three backups, only the one no session holds and nothing is
    /// recording is lost: an archived night's backup is not, and neither is
    /// the backup of the night recording now.
    func testOnlyABackupNothingHoldsOrRecordsIsLost() async throws {
        let orphan = UUID()
        try backup(orphan)
        let archived = HRVSession(
            id: UUID(), startDate: Date(timeIntervalSince1970: 1_790_000_000), endDate: Date(timeIntervalSince1970: 1_790_028_800),
            state: .complete, sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        try archive.archive(archived)
        try backup(archived.id)
        let recording = HRVSession(sessionType: .overnight)
        collector.sessionState.currentSession = recording
        collector.sessionState.isCollecting = true
        try backup(recording.id)

        let lost = await collector.recovery.checkForLostSessions()

        XCTAssertEqual(lost.map(\.id), [orphan])
        XCTAssertEqual(lost.first?.beatCount, 300)
    }

    /// A second recording of a night the archive already held is folded into
    /// it and has no entry of its own. Its backup is not lost: the night
    /// holds its beats, and recovering it would merge them in again.
    func testARecordingFoldedIntoANightIsNotLost() async throws {
        let lastNight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-3600)
        func recording(from start: Date, hours: Double) -> HRVSession {
            let id = UUID()
            return HRVSession(
                id: id, startDate: start, endDate: start.addingTimeInterval(hours * 3600), state: .complete,
                sessionType: .overnight, rrSeries: RRSeries(points: beats(300), sessionId: id, startDate: start),
                analysisResult: nil, artifactFlags: nil
            )
        }
        let night = recording(from: lastNight, hours: 7)
        _ = try archive.archive(night, skipSameNightMerge: true)
        let second = recording(from: lastNight.addingTimeInterval(3600), hours: 5)
        XCTAssertEqual(try archive.archive(second).sessionId, night.id, "the fixture expects the second recording folded")
        try backup(second.id)
        collector.rawBackup.markAsArchived(second.id)

        let lost = await collector.recovery.checkForLostSessions()

        XCTAssertFalse(lost.contains { $0.id == second.id }, "a recording saved inside another night was offered as lost")
    }

    /// The backup of a paused night is not lost either: the night resumes.
    func testAPausedNightIsNotLost() async throws {
        let paused = HRVSession(sessionType: .overnight)
        collector.streamingLifecycle.pausedSession = paused
        try backup(paused.id)

        let lost = await collector.recovery.checkForLostSessions()

        XCTAssertFalse(lost.contains { $0.id == paused.id }, "a paused night was offered for deletion")
    }

    /// Once the recording stops being live, its backup with no archived
    /// session is lost: the exclusion follows the recording, it is not a
    /// standing exception for the id.
    func testABackupIsLostOnceItsRecordingIsNoLongerLive() async throws {
        let recording = HRVSession(sessionType: .overnight)
        collector.sessionState.currentSession = recording
        collector.sessionState.isCollecting = true
        try backup(recording.id)
        let whileRecording = await collector.recovery.checkForLostSessions()
        XCTAssertTrue(whileRecording.isEmpty)

        collector.sessionState.isCollecting = false
        let afterwards = await collector.recovery.checkForLostSessions()

        XCTAssertEqual(afterwards.map(\.id), [recording.id])
    }

    /// Deleting a lost session marks it deleted: it leaves the lost list and
    /// shows in the deleted one, with its backup still there.
    func testDeletingALostSessionMovesItToTheDeletedList() async throws {
        let orphan = UUID()
        try backup(orphan)

        let marked = collector.recovery.recoveryService.deleteLostSessions([orphan])

        XCTAssertEqual(marked, [orphan])
        let lost = await collector.recovery.checkForLostSessions()
        XCTAssertTrue(lost.isEmpty)
        let deleted = collector.recovery.recoveryService.checkForDeletedSessions()
        XCTAssertEqual(deleted.map(\.id), [orphan])
        XCTAssertEqual(deleted.first?.beatCount, 300)
    }

    // MARK: - Interrupted workout

    /// The persisted marker of a workout that was never archived names the
    /// interrupted workout; while that workout is still recording it is live
    /// and nothing is interrupted; a marker for an overnight is no workout.
    func testTheInterruptedWorkoutIsTheMarkedOneUnlessItIsStillRecording() async {
        let workout = HRVSession(sessionType: .workout)
        collector.recordingStore.persist(sessionId: workout.id, startTime: workout.startDate, sessionType: .workout)

        let interrupted = await collector.recovery.findInterruptedWorkoutSessionId()
        XCTAssertEqual(interrupted, workout.id)

        collector.sessionState.currentSession = workout
        collector.sessionState.isCollecting = true
        let whileRecording = await collector.recovery.findInterruptedWorkoutSessionId()
        XCTAssertNil(whileRecording, "a workout still recording was taken for an interrupted one")

        collector.sessionState.isCollecting = false
        collector.sessionState.currentSession = nil
        collector.recordingStore.persist(sessionId: UUID(), startTime: Date(), sessionType: .overnight)
        let overnight = await collector.recovery.findInterruptedWorkoutSessionId()
        XCTAssertNil(overnight, "an overnight marker was taken for a workout")
    }

    /// After the allowed attempts, launch recovery stops trying (a recovery
    /// that keeps getting the app killed would otherwise loop) and leaves the
    /// marker, so the manual card still offers the workout. The strap is never
    /// asked.
    func testAutoRecoveryAfterItsLastAttemptLeavesTheWorkoutForTheCard() async {
        let workout = HRVSession(sessionType: .workout)
        collector.recordingStore.persist(sessionId: workout.id, startTime: workout.startDate, sessionType: .workout)
        UserDefaults.standard.set([workout.id.uuidString: 3], forKey: Self.attemptsKey)

        await collector.recovery.autoRecoverInterruptedWorkoutOnLaunch()

        XCTAssertEqual(collector.recordingStore.load()?.sessionId, workout.id, "the marker went without a recovery")
        XCTAssertEqual(UserDefaults.standard.dictionary(forKey: Self.attemptsKey)?[workout.id.uuidString] as? Int, 3,
                       "an attempt was counted although none was made")
        XCTAssertFalse(InterruptedWorkoutAutoRecovery.isRunning(workout.id), "the recovery stayed registered")
        XCTAssertFalse(archive.store.exists(workout.id))
    }

    /// A workout the launch alert is already recovering is left to it: launch
    /// recovery does not take it over, and the marker stays.
    func testAutoRecoveryLeavesAWorkoutTheLaunchAlertIsRecovering() async {
        let workout = HRVSession(sessionType: .workout)
        collector.recordingStore.persist(sessionId: workout.id, startTime: workout.startDate, sessionType: .workout)
        XCTAssertTrue(InterruptedWorkoutAutoRecovery.claim(workout.id))
        defer { InterruptedWorkoutAutoRecovery.end(workout.id) }

        await collector.recovery.autoRecoverInterruptedWorkoutOnLaunch()

        XCTAssertEqual(collector.recordingStore.load()?.sessionId, workout.id)
        XCTAssertTrue(InterruptedWorkoutAutoRecovery.isRunning(workout.id), "launch recovery released the alert's claim")
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: Self.attemptsKey), "an attempt was counted")
    }

    // MARK: - iCloud live backups

    /// Another device's live backup that a scan here pulled is not deleted
    /// from iCloud on the next scan: that device may still be recording the
    /// night, and the iCloud copy is its crash-safety backup.
    func testABackupPulledFromAnotherDeviceKeepsItsICloudCopy() {
        let night = UUID()
        let holdings = SessionRecoveryService.CloudBackupHoldings(
            removed: [], archivedNightBeats: [:], localBeats: [night: 300], uploadedHere: []
        )
        XCTAssertEqual(SessionRecoveryService.cloudBackupDisposition(of: night, beats: 300, holdings: holdings), .keep)
    }

    /// A backup this device uploaded and still holds in full is retired from
    /// iCloud, a deleted night's is retired whoever uploaded it, and one not
    /// held here is saved for recovery.
    func testOwnAndFinishedBackupsAreRetiredAndNewOnesSaved() {
        let own = UUID(), finished = UUID(), unseen = UUID()
        let holdings = SessionRecoveryService.CloudBackupHoldings(
            removed: [finished], archivedNightBeats: [:], localBeats: [own: 300], uploadedHere: [own]
        )
        XCTAssertEqual(SessionRecoveryService.cloudBackupDisposition(of: own, beats: 300, holdings: holdings), .retire)
        XCTAssertEqual(SessionRecoveryService.cloudBackupDisposition(of: finished, beats: 300, holdings: holdings), .retire)
        XCTAssertEqual(SessionRecoveryService.cloudBackupDisposition(of: unseen, beats: 300, holdings: holdings), .save)
    }

    // MARK: - Recovery over an archived copy

    /// A backup recovered again for a night the archive holds with more beats
    /// (a strap fetch merged in, a fuller copy from another device) leaves
    /// that night as it is: rebuilt from the backup, it lost what only it held.
    func testRecoveringABackupKeepsAnArchivedCopyThatHoldsMore() async throws {
        let id = UUID()
        _ = try collector.rawBackup.backup(points: beats(200), sessionId: id)
        let fuller = HRVSession(
            id: id, startDate: Date().addingTimeInterval(-3600), endDate: Date(), state: .complete,
            rrSeries: RRSeries(points: beats(300), sessionId: id, startDate: Date().addingTimeInterval(-3600)),
            analysisResult: nil, artifactFlags: nil
        )
        _ = try archive.archive(fuller, skipSameNightMerge: true)

        let recovered = await collector.recovery.recoverFromBackup(id)

        XCTAssertEqual(recovered?.rrSeries?.points.count, 300, "recovery returned the backup's fragment")
        XCTAssertEqual(try archive.retrieve(id)?.rrSeries?.points.count, 300, "the archived night lost the beats only it held")
    }
}
