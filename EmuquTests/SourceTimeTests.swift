import CoreLocation
@testable import Emuqu
import XCTest

/// A measurement keeps the time it was taken. A night's live backup restored
/// on another device, its local backup, a paused night and a Watch Resume
/// are each dated by the recording or the tap, never by a later upload,
/// write, analysis or arrival.
@MainActor
final class SourceTimeTests: XCTestCase {
    /// 22:00 on the night recorded.
    private let start = Date(timeIntervalSince1970: 1_785_538_800)

    private func beats(_ count: Int) -> [RRPoint] {
        (0 ..< count).map { RRPoint(t_ms: Int64($0) * 1_000, rr_ms: 1_000, wallClockMs: Int64($0) * 1_000, hr: 60) }
    }

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SourceTimeTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var collector = RRCollector(
        polarManager: PolarManager(), healthKit: HealthKitManager.forTests(),
        archive: SessionArchive(directory: directory),
        settingsManager: AppDependencies.current.app.settingsManager,
        services: CollectorServices(.current)
    )

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - The live backup in iCloud

    /// The payload carries the recording's start, and still opens as plain
    /// beats for a build that reads only those.
    func testALiveBackupCarriesItsRecordingStart() throws {
        let json = try LiveBackupPayload.encode(beats(3), recordingStart: start)
        let decoded = try LiveBackupPayload.decode(json)
        XCTAssertEqual(decoded.recordingStart, start)
        XCTAssertEqual(decoded.points, beats(3))
        XCTAssertEqual(try JSONDecoder().decode([RRPoint].self, from: json), beats(3))
    }

    /// A payload an older build uploaded opens, with no start.
    func testAnOlderLiveBackupOpensWithoutAStart() throws {
        let decoded = try LiveBackupPayload.decode(try JSONEncoder().encode(beats(3)))
        XCTAssertNil(decoded.recordingStart)
        XCTAssertEqual(decoded.points, beats(3))
    }

    /// A 22:00 recording whose first upload reached iCloud at 01:00 is
    /// restored from 22:00; a backup with no start falls back to the upload.
    func testARestoredLiveBackupIsDatedByItsRecordingStart() {
        let firstUpload = start.addingTimeInterval(3 * 3_600)
        let carried = LiveBackupSummary(sessionId: UUID(), beatCount: 3, captureDate: firstUpload, points: beats(3), recordingStart: start)
        XCTAssertEqual(carried.sessionStart, start)
        let older = LiveBackupSummary(sessionId: UUID(), beatCount: 3, captureDate: firstUpload, points: beats(3))
        XCTAssertEqual(older.sessionStart, firstUpload)
    }

    // MARK: - The local backup

    /// A streamed session's backup is dated by the session's start, not by
    /// its first write, through every append.
    func testAStreamedBackupIsDatedByTheSessionStart() throws {
        let backup = RawRRBackup(directory: directory, notificationCenter: NotificationCenter())
        backup.waitForQueuedWork()
        let sessionId = UUID()
        XCTAssertTrue(backup.incrementalBackup(points: beats(10), sessionId: sessionId, captureDate: start, force: true))
        XCTAssertTrue(backup.incrementalBackup(points: beats(20), sessionId: sessionId, captureDate: start, force: true))
        XCTAssertEqual(try backup.retrieve(sessionId)?.captureDate, start)
        XCTAssertEqual(backup.index.first { $0.id == sessionId }?.captureDate, start)
    }

    // MARK: - A paused night

    /// A night paused with too few beats to analyse ends, and is paused,
    /// when Pause was tapped, not once the download after it finished.
    func testAShortPausedNightIsPausedAtTheTap() {
        let tap = start.addingTimeInterval(3_600)
        let night = HRVSession(startDate: start, sessionType: .overnight)
        let paused = CollectorSessionControl.shortPausedSession(from: night, points: beats(5), pausedAt: tap)
        XCTAssertEqual(paused.pausedDate, tap)
        XCTAssertEqual(paused.endDate, tap)
    }

    // MARK: - A Watch Resume

    /// A Watch Resume ends the pause at the tap, held after the pause began
    /// and not after now.
    func testAWatchResumeIsDatedByTheTap() {
        let pausedAt = start.addingTimeInterval(600)
        let now = start.addingTimeInterval(900)
        let cases: [(requested: Date?, expected: Date)] = [
            (nil, now), (now.addingTimeInterval(-40), now.addingTimeInterval(-40)),
            (start, pausedAt), (now.addingTimeInterval(5), now)
        ]
        for (requested, expected) in cases {
            XCTAssertEqual(WorkoutRecorder.resumeDate(requested: requested, pausedAt: pausedAt, now: now), expected)
        }
    }

    /// A Watch Resume tapped 40 s before it arrived: the workout resumed at
    /// the tap, so those 40 s are active.
    func testAWatchResumeThatArrivedLateCountsTheTimeAfterTheTap() {
        let recorder = WorkoutRecorder(core: collector.recordingCore, conversation: VoiceConversationController.shared, services: WorkoutServices(.current))
        let now = Date()
        let started = now.addingTimeInterval(-900)
        recorder.lifecycle.sessionStartDate = started
        recorder.lifecycle.elapsedSeconds = 600
        recorder.lifecycle.phase = .recording
        recorder.pauseControl.pause()
        recorder.lifecycle.pauseTimeline.movePauseStart(to: now.addingTimeInterval(-300), atElapsed: 600)

        recorder.resumeFromWatch(tappedAt: now.addingTimeInterval(-40), now: now)

        XCTAssertFalse(recorder.lifecycle.isPaused)
        XCTAssertEqual(recorder.lifecycle.pauseTimeline.events.last?.resumedAt, now.addingTimeInterval(-40))
        XCTAssertEqual(recorder.lifecycle.pauseTimeline.activeSeconds(sessionStart: started, now: now), 640)
    }

    /// The motion counters stop being left out at the tap: what the
    /// pedometer and foot pod counted after it is the workout's.
    func testAResumeDatedEarlierCountsTheMotionAfterTheTap() {
        var ledger = PausedMotionLedger()
        ledger.pause(pedometer: 1_000, footPod: 500)
        ledger.note(pedometer: 1_010, footPod: 505, at: start.addingTimeInterval(10))
        ledger.note(pedometer: 1_020, footPod: 510, at: start.addingTimeInterval(20))
        ledger.note(pedometer: 1_100, footPod: 560, at: start.addingTimeInterval(30))
        ledger.resume(pedometer: 1_200, footPod: 600, resumedAt: start.addingTimeInterval(25))
        XCTAssertEqual(ledger.pedometerDistance(1_200), 1_180, accuracy: 0.001)
        XCTAssertEqual(ledger.footPodDistance(600), 590, accuracy: 0.001)
    }

    /// The GPS fixes the phone kept after the tap count again: the first as
    /// the step across the resume, the rest as moving, with their distance.
    func testAResumeDatedEarlierCountsTheFixesAfterTheTap() {
        let location = WorkoutLocationManager(ambientLocation: WorkoutServices(.current).ambientLocationService)
        let fix: (Int) -> CLLocation = { index in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 51.5 + Double(index) * 0.0002, longitude: 0), altitude: 10,
                horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: self.start.addingTimeInterval(TimeInterval(index * 10))
            )
        }
        location.ingestForTesting([fix(0), fix(1)])
        location.isPaused = true
        location.ingestForTesting([fix(2), fix(3), fix(4)])
        location.isPaused = false
        let atArrival = location.distanceMeters

        location.moveResume(to: start.addingTimeInterval(25))

        XCTAssertEqual(location.trackPauses.paused, [2])
        XCTAssertEqual(location.trackPauses.gaps, [3])
        let credited = fix(3).distance(from: fix(2)) + fix(4).distance(from: fix(3))
        XCTAssertEqual(location.distanceMeters, atArrival + credited, accuracy: 0.01)
    }
}
