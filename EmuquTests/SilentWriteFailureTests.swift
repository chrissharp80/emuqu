@testable import Emuqu
import XCTest

/// A write the user made, or was told was made, that fails is either kept for
/// a retry or shown, never only logged while the screen shows it as stored:
/// an edit on a reading, the review card's Discard, a route added to the
/// library, heart-rate recovery on a saved workout, and a reading's export to
/// Apple Health.
@MainActor
final class SilentWriteFailureTests: XCTestCase {
    private struct DiskFull: Error {}

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SilentWriteFailureTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: directory)

    override func setUp() async throws {
        try await super.setUp()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - Edits on a reading

    func testOnlyAnEditThatIsLostIsReported() {
        let cases: [(error: Error, acceptanceSaves: Bool, reported: Bool)] = [
            (SessionArchive.ArchiveError.fileNotFound, false, false),
            (SessionArchive.ArchiveError.sessionWasDeleted, false, false),
            (SessionArchive.ArchiveError.hashMismatch, false, true),
            (DiskFull(), false, true),
            (DiskFull(), true, false),
            (SessionArchive.ArchiveError.hashMismatch, true, false)
        ]
        for (index, entry) in cases.enumerated() {
            XCTAssertEqual(
                ReadingEditFailure.mustReport(entry.error, acceptanceSavesEdit: entry.acceptanceSaves), entry.reported,
                "case \(index): \(entry.error)"
            )
        }
    }

    /// The pre-score feeling's write hands its failure on, so it can be
    /// reported, rather than only logging it.
    func testThePreScoreFeelingWriteThrowsItsFailure() {
        XCTAssertThrowsError(try RecordView.storePreScoreFeeling(4, id: UUID(), archive: archive)) { error in
            XCTAssertFalse(ReadingEditFailure.mustReport(error, acceptanceSavesEdit: false), "a reading not archived loses nothing")
        }
    }

    // MARK: - Review card Discard

    private func archivedNight() throws -> HRVSession {
        let id = UUID()
        let start = Date().addingTimeInterval(-86400 - 8 * 3600)
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

    /// Puts a directory where the archive writes its deleted-session index, so
    /// every delete in this test's archive fails and rolls back.
    private func blockDeletedIndexWrites() throws {
        let deletedIndex = archive.deletedIndexFile
        if FileManager.default.fileExists(atPath: deletedIndex.path) {
            try FileManager.default.removeItem(at: deletedIndex)
        }
        try FileManager.default.createDirectory(at: deletedIndex, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: deletedIndex.appendingPathComponent("blocker"))
    }

    func testADiscardTheArchiveRefusesKeepsTheReviewAndShowsTheError() async throws {
        isolateFromHostRecordingState()
        let collector = RRCollector.withoutCloudAcceptance(polarManager: PolarManager(), archive: archive)
        let night = try archivedNight()
        collector.sessionState.currentSession = night
        collector.sessionState.needsAcceptance = true
        collector.sessionState.reviewArchivedSessionId = night.id
        try blockDeletedIndexWrites()

        let discarded = await collector.rejectSession()

        XCTAssertFalse(discarded)
        XCTAssertTrue(archive.store.exists(night.id), "the night is still archived")
        XCTAssertTrue(collector.sessionState.needsAcceptance, "the card said discarded while the night stayed")
        XCTAssertEqual(collector.sessionState.reviewArchivedSessionId, night.id, "Discard could not be tapped again")
        XCTAssertNotNil(collector.sessionState.lastError)
    }

    // MARK: - Route library

    private func route() -> SavedRoute {
        SavedRoute(
            id: UUID(), name: "Loop", createdAt: Date(), sport: .run, encodedPolyline: Data(),
            totalDistanceMeters: 0, totalAscentMeters: 0, totalDescentMeters: 0, climbCount: 0
        )
    }

    /// A library file that cannot be read nor set aside blocks saves; a route
    /// added then is refused rather than shown as saved from memory only.
    func testARouteAddedToAnUnreadableLibraryIsRefused() throws {
        let url = directory.appendingPathComponent("saved_routes.json")
        try Data("not routes".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        let store = SavedRouteStore(storeURL: url)

        XCTAssertFalse(store.add(route()))

        XCTAssertTrue(store.routes.isEmpty)
    }

    func testARouteAddedToAReadableLibraryIsSaved() {
        let url = directory.appendingPathComponent("saved_routes.json")
        let store = SavedRouteStore(storeURL: url)
        let loop = route()

        XCTAssertTrue(store.add(loop))

        XCTAssertEqual(store.routes.map(\.id), [loop.id])
    }

    // MARK: - Heart-rate recovery on a saved workout

    private func hrr() -> [HRRSample] {
        [HRRSample(offsetSec: 60, hr: 130, drop: 28, peakHR: 158, provenance: .strap)]
    }

    /// The summary shows the samples, so a write the archive refuses keeps
    /// them, and the next retry stores them.
    func testHRRTheArchiveRefusesIsKeptAndStoredByTheRetry() throws {
        let collector = RRCollector(
            polarManager: PolarManager(), healthKit: HealthKitManager.forTests(), archive: archive,
            settingsManager: AppDependencies.current.app.settingsManager, services: CollectorServices(.current)
        )
        let recorder = WorkoutRecorder(core: collector.recordingCore, conversation: VoiceConversationController.shared, services: WorkoutServices(.current))
        var workout = HRVSession(sessionType: .workout)
        workout.workoutMetadata = WorkoutMetadata(sport: .run)
        workout.state = .complete
        workout.endDate = Date()
        let entry = try archive.archive(workout)
        let folder = archive.state.resolveFileURL(for: entry).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)

        recorder.session.keepHRRSamples(hrr(), for: workout.id)
        XCTAssertEqual(recorder.lifecycle.unsavedHRR[workout.id], hrr(), "the samples the summary shows were dropped")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        recorder.session.retryUnsavedWorkouts()

        XCTAssertNil(recorder.lifecycle.unsavedHRR[workout.id])
        XCTAssertEqual(try archive.retrieve(workout.id)?.workoutMetadata?.hrrSamples, hrr())
    }

    // MARK: - Apple Health export of a reading

    private func scratchDefaults() throws -> UserDefaults {
        let name = "SilentWriteFailureTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    func testAFailedExportIsKeptAndASuccessfulOneLetGo() throws {
        let defaults = try scratchDefaults()
        let failed = UUID()
        let exported = UUID()

        PendingNightExports.record(failed, exported: false, in: defaults)
        PendingNightExports.record(exported, exported: false, in: defaults)
        PendingNightExports.record(exported, exported: true, in: defaults)

        XCTAssertEqual(PendingNightExports.pending(in: defaults), [failed])
    }

    func testTheKeptExportsAreBounded() throws {
        let defaults = try scratchDefaults()
        let ids = (0 ... PendingNightExports.limit).map { _ in UUID() }
        for id in ids { PendingNightExports.note(id, in: defaults) }

        XCTAssertEqual(PendingNightExports.pending(in: defaults), Array(ids.dropFirst()), "the oldest failure goes first")
    }

    func testTheRetryExportsAKeptReadingAndLetsItGo() async throws {
        let defaults = try scratchDefaults()
        let night = try archivedNight()
        let gone = UUID()
        PendingNightExports.note(night.id, in: defaults)
        PendingNightExports.note(gone, in: defaults)
        var exportedIds: [UUID] = []

        await PendingNightExports.retry(archive: archive, exportEnabled: true, in: defaults) { exportedIds.append($0.id) }

        XCTAssertEqual(exportedIds, [night.id])
        XCTAssertEqual(PendingNightExports.pending(in: defaults), [], "a reading no longer archived is still kept")
    }

    func testARetryThatFailsAgainKeepsTheReading() async throws {
        let defaults = try scratchDefaults()
        let night = try archivedNight()
        PendingNightExports.note(night.id, in: defaults)

        await PendingNightExports.retry(archive: archive, exportEnabled: true, in: defaults) { _ in throw DiskFull() }

        XCTAssertEqual(PendingNightExports.pending(in: defaults), [night.id])
    }

    func testNoRetryRunsWhileExportIsOff() async throws {
        let defaults = try scratchDefaults()
        let night = try archivedNight()
        PendingNightExports.note(night.id, in: defaults)
        var exportedIds: [UUID] = []

        await PendingNightExports.retry(archive: archive, exportEnabled: false, in: defaults) { exportedIds.append($0.id) }

        XCTAssertEqual(exportedIds, [])
        XCTAssertEqual(PendingNightExports.pending(in: defaults), [night.id])
    }
}
