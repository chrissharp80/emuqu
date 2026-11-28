import CoreLocation
@testable import Emuqu
import XCTest

/// A workout longer than the 12 h the recorder keeps in memory is archived
/// with every per-second row, read back from its crash backup, and a backup
/// is retired only once the archived copy holds every row of it. The fuller
/// copy of a Get Me Back trail is the one archived.
@MainActor
final class WorkoutBackupCoverageTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkoutBackupCoverageTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var collector = RRCollector(
        polarManager: PolarManager(), healthKit: HealthKitManager.forTests(),
        archive: SessionArchive(directory: directory.appendingPathComponent("archive", isDirectory: true)),
        settingsManager: AppDependencies.current.app.settingsManager,
        services: CollectorServices(.current)
    )

    override func setUp() async throws {
        try await super.setUp()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        isolateFromHostRecordingState()
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func rows(_ offsets: some Sequence<Int>) -> [WorkoutSample] {
        offsets.map { WorkoutSample(offsetSec: $0, heartRate: 100 + $0, powerWatts: 200) }
    }

    // MARK: - Merging the held rows with the backup

    private struct MergeCase {
        let name: String
        let held: [Int]
        let heldWrist: [Int]
        let backedUp: [Int]
        let backedUpWrist: [Int]
        let through: Int
        let samples: [Int]
        let wrist: [Int]
    }

    func testTheBackedUpHeadGoesBeforeTheRowsHeld() {
        let cases = [
            MergeCase(name: "the dropped head comes back", held: Array(5 ... 9), heldWrist: [6], backedUp: Array(0 ... 9), backedUpWrist: [1, 6],
                      through: 9, samples: Array(0 ... 9), wrist: [1, 6]),
            MergeCase(name: "a row backed up twice appears once", held: [4, 5], heldWrist: [], backedUp: [0, 1, 1, 2, 3, 4, 5], backedUpWrist: [],
                      through: 5, samples: [0, 1, 2, 3, 4, 5], wrist: []),
            MergeCase(name: "rows past an early stop stay out", held: [], heldWrist: [], backedUp: Array(0 ... 9), backedUpWrist: [2, 8],
                      through: 3, samples: [0, 1, 2, 3], wrist: [2]),
            MergeCase(name: "nothing dropped, nothing added", held: Array(0 ... 4), heldWrist: [], backedUp: Array(0 ... 4), backedUpWrist: [],
                      through: 4, samples: Array(0 ... 4), wrist: [])
        ]
        for row in cases {
            let merged = WorkoutSampleHistory.merged(
                held: .init(samples: rows(row.held), wristHROffsets: row.heldWrist),
                backedUp: .init(samples: rows(row.backedUp), wristHROffsets: row.backedUpWrist),
                through: row.through
            )
            XCTAssertEqual(merged.samples.map(\.offsetSec), row.samples, row.name)
            XCTAssertEqual(merged.wristHROffsets, row.wrist, row.name)
        }
    }

    /// A workout whose oldest rows left memory is saved with all of them,
    /// their wrist-HR marks and their power readings.
    func testACappedWorkoutSavedNormallyKeepsAllSamples() async throws {
        let recorder = WorkoutRecorder(core: collector.recordingCore, conversation: VoiceConversationController.shared, services: WorkoutServices(.current))
        var session = HRVSession(sessionType: .workout)
        session.workoutMetadata = WorkoutMetadata(sport: .crossFit)
        let start = Date().addingTimeInterval(-2_400)
        let all = rows(0 ..< 40)
        recorder.lifecycle.activeHRSource = .none
        recorder.lifecycle.currentSession = session
        recorder.lifecycle.sessionStartDate = start
        recorder.lifecycle.elapsedSeconds = 39
        recorder.lifecycle.phase = .recording
        let backup = recorder.session.services.workoutTrackBackup
        backup.appendIncremental(sessionId: session.id, sport: .crossFit, startDate: start, track: [], samples: all, healthKitHROffsets: [3, 30], barometricSamples: [])
        addTeardownBlock { @MainActor in backup.discard(session.id) }
        recorder.capture.workoutSamples = Array(all.suffix(20))
        recorder.capture.wristHROffsets = [30]
        recorder.capture.sampleHeadTrimmed = true

        await recorder.stop()

        let saved = try XCTUnwrap(recorder.lifecycle.finishedSession?.workoutMetadata)
        XCTAssertEqual(saved.samples?.map(\.offsetSec), Array(0 ..< 40), "the rows dropped from memory are archived")
        XCTAssertEqual(saved.healthKitHROffsets, [3, 30], "a read-back wrist-HR row stays out of the iCloud upload")
        XCTAssertEqual(saved.averagePowerWatts ?? 0, 200, accuracy: 0.01)
        let archived = try XCTUnwrap(collector.archive.retrieve(session.id))
        XCTAssertEqual(archived.workoutMetadata?.samples?.count, 40)
    }

    // MARK: - Retiring a backup

    private struct RetireCase {
        let name: String
        let archivedSamples: [Int]
        let archivedWrist: [Int]
        let archivedFixes: Int
        let fixesAfterEnd: Int
        let trackReplaced: Bool
        let retired: Bool
    }

    /// One rule for every retire site: the save of a finished workout and an
    /// accepted recovery both go through `discard(_:ifCoveredBy:trackReplaced:)`.
    func testABackupGoesOnlyWhenTheArchiveHoldsEveryRow() throws {
        let cases = [
            RetireCase(name: "the archive holds it all", archivedSamples: Array(0 ... 9), archivedWrist: [2], archivedFixes: 5, fixesAfterEnd: 0, trackReplaced: false, retired: true),
            RetireCase(name: "the archive lacks the head", archivedSamples: Array(4 ... 9), archivedWrist: [], archivedFixes: 5, fixesAfterEnd: 0, trackReplaced: false, retired: false),
            RetireCase(name: "a row is missing in the middle", archivedSamples: [0, 1, 2, 3, 5, 6, 7, 8, 9], archivedWrist: [2], archivedFixes: 5, fixesAfterEnd: 0, trackReplaced: false, retired: false),
            RetireCase(name: "a wrist-HR row is not marked", archivedSamples: Array(0 ... 9), archivedWrist: [], archivedFixes: 5, fixesAfterEnd: 0, trackReplaced: false, retired: false),
            RetireCase(name: "the archive has fewer fixes", archivedSamples: Array(0 ... 9), archivedWrist: [2], archivedFixes: 3, fixesAfterEnd: 0, trackReplaced: false, retired: false),
            RetireCase(name: "an Apple Watch route replaced the track", archivedSamples: Array(0 ... 9), archivedWrist: [2], archivedFixes: 3, fixesAfterEnd: 0, trackReplaced: true, retired: true),
            RetireCase(name: "rows and fixes after a trimmed end", archivedSamples: Array(0 ... 6), archivedWrist: [2], archivedFixes: 5, fixesAfterEnd: 2, trackReplaced: false, retired: true)
        ]
        let backup = WorkoutTrackBackup(directory: directory.appendingPathComponent("tracks", isDirectory: true))
        for row in cases {
            let (id, end) = backedUpWorkout(in: backup, fixesAfterEnd: row.fixesAfterEnd)
            var archived = HRVSession(startDate: end.addingTimeInterval(-60), sessionType: .workout)
            archived.endDate = end
            var metadata = WorkoutMetadata(sport: .run, gpsPolyline: WorkoutAnalyzer.encodePolyline(track: fixes(row.archivedFixes, endingAt: end)))
            metadata.samples = rows(row.archivedSamples)
            metadata.healthKitHROffsets = row.archivedWrist
            archived.workoutMetadata = metadata

            let went = backup.discard(id, ifCoveredBy: archived, trackReplaced: row.trackReplaced)

            XCTAssertEqual(went, row.retired, row.name)
            XCTAssertEqual(backup.retrieve(id) == nil, row.retired, row.name)
            backup.discard(id)
        }
    }

    /// A backup of ten rows, wrist HR at offset 2, five fixes up to the end
    /// and `fixesAfterEnd` after it.
    private func backedUpWorkout(in backup: WorkoutTrackBackup, fixesAfterEnd: Int) -> (UUID, Date) {
        let id = UUID()
        let end = Date(timeIntervalSince1970: 10_000)
        let track = fixes(5, endingAt: end) + (0 ..< fixesAfterEnd).map { fix(at: end.addingTimeInterval(Double($0 + 1)), index: 10 + $0) }
        backup.appendIncremental(
            sessionId: id, sport: .run, startDate: end.addingTimeInterval(-60),
            track: track.map(WorkoutTrackBackup.PersistedFix.init), samples: rows(0 ... 9), healthKitHROffsets: [2], barometricSamples: []
        )
        return (id, end)
    }

    private func fixes(_ count: Int, endingAt end: Date) -> [CLLocation] {
        (0 ..< count).map { fix(at: end.addingTimeInterval(Double($0 - count + 1)), index: $0) }
    }

    private func fix(at time: Date, index: Int) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 51 + Double(index) * 0.001, longitude: -1),
            altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 3, timestamp: time
        )
    }

    // MARK: - Get Me Back trail

    /// End and save archives the recorder's trail when a failed save left
    /// the file behind it, and never a trail of another start.
    func testTheFullerCopyOfATrailIsArchived() {
        let start = Date(timeIntervalSince1970: 1_000)
        let crumb = { (n: Int) in
            BreadcrumbFix(from: CLLocation(latitude: 51 + Double(n) * 0.001, longitude: -1))
        }
        let stored = BreadcrumbTrail(startedAt: start, fixes: [crumb(0), crumb(1)])
        let live = BreadcrumbTrail(startedAt: start, fixes: [crumb(0), crumb(1), crumb(2)])
        let other = BreadcrumbTrail(startedAt: start.addingTimeInterval(60), fixes: [crumb(0), crumb(1), crumb(2), crumb(3)])

        XCTAssertEqual(BreadcrumbStore.fuller(stored, live), live, "the recorder holds fixes the file lacks")
        XCTAssertEqual(BreadcrumbStore.fuller(live, stored), live, "the file holds them all")
        XCTAssertEqual(BreadcrumbStore.fuller(nil, live), live, "no save reached the disk")
        XCTAssertEqual(BreadcrumbStore.fuller(stored, other), stored, "another trail is not archived in its place")
        XCTAssertEqual(BreadcrumbStore.fuller(stored, nil), stored)
    }
}
