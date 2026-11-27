@testable import Emuqu
import XCTest

/// A Watch End queued out of range reaches the phone after the tap. The
/// workout ends at the tap: the end date, the active time and the per-second
/// samples, beats and power recorded after it are not the workout's.
@MainActor
final class WorkoutStopTimeTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkoutStopTimeTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var collector = RRCollector(
        polarManager: PolarManager(), healthKit: HealthKitManager.forTests(),
        archive: SessionArchive(directory: directory),
        settingsManager: AppDependencies.current.app.settingsManager,
        services: CollectorServices(.current)
    )

    override func setUp() async throws {
        try await super.setUp()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    /// A 60-minute recording whose End was tapped at 20 minutes: one sample a
    /// second with a power reading and a growing distance.
    private func recordingStartedAnHourAgo(now: Date) -> (WorkoutRecorder, Date) {
        let recorder = WorkoutRecorder(core: collector.recordingCore, conversation: VoiceConversationController.shared, services: WorkoutServices(.current))
        var session = HRVSession(sessionType: .workout)
        session.workoutMetadata = WorkoutMetadata(sport: .run)
        let start = now.addingTimeInterval(-3_600)
        recorder.lifecycle.activeHRSource = .none
        recorder.lifecycle.currentSession = session
        recorder.lifecycle.sessionStartDate = start
        recorder.lifecycle.elapsedSeconds = 3_600
        recorder.capture.workoutSamples = (1...3_600).map {
            WorkoutSample(offsetSec: $0, heartRate: 140, distanceMeters: Double($0) * 3, powerWatts: $0 <= 1_200 ? 200 : 400)
        }
        for second in 1...3_600 { recorder.capture.power.add(second <= 1_200 ? 200 : 400) }
        recorder.lifecycle.phase = .recording
        return (recorder, start)
    }

    func testAWatchEndTappedEarlierEndsTheWorkoutAtTheTap() async throws {
        let (recorder, start) = recordingStartedAnHourAgo(now: Date())
        let tap = start.addingTimeInterval(1_200)

        await recorder.stop(requestedStop: tap)

        let finished = try XCTUnwrap(recorder.lifecycle.finishedSession)
        XCTAssertEqual(try XCTUnwrap(finished.endDate).timeIntervalSince(tap), 0, accuracy: 0.001)
        let metadata = try XCTUnwrap(finished.workoutMetadata)
        XCTAssertEqual(metadata.samples?.last?.offsetSec, 1_200, "no sample after the tap")
        XCTAssertEqual(metadata.averagePowerWatts, 200, "no power reading after the tap")
        XCTAssertEqual(metadata.peakPowerWatts, 200)
    }

    /// The tap time is held between the workout's start and now: the Watch's
    /// clock is not the phone's.
    func testTheRequestedStopIsHeldBetweenStartAndNow() {
        let now = Date()
        let start = now.addingTimeInterval(-600)
        XCTAssertEqual(WorkoutRecorder.stopDate(requested: nil, startedAt: start, now: now), now)
        XCTAssertEqual(WorkoutRecorder.stopDate(requested: now.addingTimeInterval(5), startedAt: start, now: now), now)
        XCTAssertEqual(WorkoutRecorder.stopDate(requested: start.addingTimeInterval(-5), startedAt: start, now: now), start)
        let tap = now.addingTimeInterval(-120)
        XCTAssertEqual(WorkoutRecorder.stopDate(requested: tap, startedAt: start, now: now), tap)
    }

    /// Beats are cut on the wall clock: their own clock sums the received
    /// intervals and falls behind at a strap dropout, so a beat received
    /// after the stop can carry a `t_ms` before it.
    func testBeatsAfterTheStopAreLeftOutAcrossADropout() {
        let start = Date(timeIntervalSince1970: 1_785_600_000)
        let beats = [
            RRPoint(t_ms: 0, rr_ms: 1_000, wallClockMs: 0, hr: 60),
            RRPoint(t_ms: 1_000, rr_ms: 1_000, wallClockMs: 1_000, hr: 60),
            // Ten-minute dropout: received at 601 s, summed clock at 2 s.
            RRPoint(t_ms: 2_000, rr_ms: 1_000, wallClockMs: 601_000, hr: 60)
        ]
        let kept = WorkoutAnalyzer.rrPoints(beats, endingAt: start.addingTimeInterval(300), sessionStart: start)
        XCTAssertEqual(kept.map(\.t_ms), [0, 1_000])
    }

    /// The tap time is the stamp the Watch puts on every control it sends.
    func testTheTapTimeIsTheWatchStamp() {
        XCTAssertEqual(WatchConnectivityBridge.tapDate(["type": "stopWorkoutFromWatch", "ts": 1_785_600_000.5]), Date(timeIntervalSince1970: 1_785_600_000.5))
        XCTAssertNil(WatchConnectivityBridge.tapDate(["type": "stopWorkoutFromWatch"]))
        XCTAssertNil(WatchConnectivityBridge.tapDate(["ts": 0.0]))
    }
}
