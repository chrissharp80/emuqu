@testable import Emuqu
import XCTest

/// Every session that records from the strap shares one stream, one buffer,
/// one link, one internal recording and one crash marker. Each case here is
/// one session acting on the strap while another owns it, and checks that it
/// leaves the other session's part alone.
@MainActor
final class StrapSessionOwnershipTests: XCTestCase {
    private let deviceId = "OWN0001"
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StrapSessionOwnershipTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: directory)

    override func setUp() async throws {
        try await super.setUp()
        isolateFromHostRecordingState()
    }

    override func tearDown() async throws {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            // swallow-ok: a test that archived nothing leaves no directory to remove.
        }
        try await super.tearDown()
    }

    private func makeCollector(_ radio: FakeStrapRadio = FakeStrapRadio(), type: PolarDeviceType = .h10) -> RRCollector {
        let manager = PolarManager()
        manager.radio.radioForTesting = radio
        manager.setConnectedDeviceForTesting(id: deviceId, type: type)
        manager.linkState.readiness.linkEstablished()
        manager.linkState.readiness.settleWithoutSummary()
        manager.deviceRecording.downloadLedger = StrapDownloadLedger(
            defaults: UserDefaults(suiteName: "StrapSessionOwnershipTests-\(UUID().uuidString)") ?? .standard
        )
        return RRCollector.withoutCloudAcceptance(polarManager: manager, archive: archive)
    }

    private func makeRecorder(_ collector: RRCollector) -> WorkoutRecorder {
        WorkoutRecorder(core: collector.recordingCore, conversation: VoiceConversationController.shared, services: WorkoutServices(.current))
    }

    /// The stream as a session holds it: live since `start`, its newest beat
    /// just in.
    @discardableResult
    private func buffer(_ collector: RRCollector, since start: Date) -> StrapStreamSession {
        let stream = collector.polarManager.stream
        let sinceStartMs = Int64(Date().timeIntervalSince(start) * 1000)
        stream.prepareStreamingStateForTesting(startTime: start, existingPoints: (0 ..< 10).map {
            RRPoint(t_ms: Int64($0) * 1000, rr_ms: 1000, wallClockMs: sinceStartMs - Int64(10 - $0) * 100)
        })
        return stream
    }

    private func stopped(_ radio: FakeStrapRadio) -> Bool {
        radio.calls.contains(.stopRecording)
    }

    // MARK: - The rule

    /// Whose stream is live, read by its start.
    func testTheLiveStreamIsOnlyTheSessionsThatStartedIt() {
        let collector = makeCollector()
        let own = Date().addingTimeInterval(-60)
        let stream = buffer(collector, since: own)
        let cases: [(ownStart: Date?, owns: Bool)] = [(own, true), (own.addingTimeInterval(-1), false), (nil, false)]
        for (ownStart, owns) in cases {
            XCTAssertEqual(stream.isBuffering(startedAt: ownStart), owns, "own start \(String(describing: ownStart))")
            XCTAssertEqual(stream.isBufferingForAnotherSession(than: ownStart), !owns)
        }
        stream.endStreaming()
        XCTAssertFalse(stream.isBuffering(startedAt: own), "a stopped stream is no one's")
        XCTAssertFalse(stream.isBufferingForAnotherSession(than: nil))
    }

    /// The link goes only when no other session buffers, no transfer runs
    /// and the strap records nothing.
    func testTheLinkIsReleasedOnlyWhenNothingElseUsesTheStrap() {
        let collector = makeCollector()
        let stream = collector.polarManager.stream
        let recording = collector.polarManager.deviceRecording
        XCTAssertTrue(stream.mayReleaseLink(after: nil, recording: recording))
        recording.transfersInFlight = 1
        XCTAssertFalse(stream.mayReleaseLink(after: nil, recording: recording), "a download is using the strap")
        recording.transfersInFlight = 0
        recording.isRecordingOnDevice = true
        XCTAssertFalse(stream.mayReleaseLink(after: nil, recording: recording), "the strap still records")
        recording.isRecordingOnDevice = false
        let other = Date()
        buffer(collector, since: other)
        XCTAssertFalse(stream.mayReleaseLink(after: other.addingTimeInterval(-60), recording: recording), "another session buffers")
        XCTAssertTrue(stream.mayReleaseLink(after: other, recording: recording), "its own stream does not hold it")
    }

    // MARK: - Heart-rate recovery after a workout

    private func hrrService(_ collector: RRCollector, ownStart: Date?) -> HRRCaptureService {
        let core = collector.recordingCore
        return HRRCaptureService(
            strapLink: core.strapLink, strapStream: core.strapStream, ownStreamStart: ownStart,
            access: core.healthAccess, heartRate: core.heartRate
        )
    }

    /// The recovery reads the finished workout's own stream only: the next
    /// workout's or a quick reading's stream started since is not its
    /// recovery, and a Watch workout has none.
    func testHeartRateRecoveryReadsOnlyTheWorkoutsOwnStream() {
        let collector = makeCollector()
        let live = Date().addingTimeInterval(-30)
        buffer(collector, since: live)
        XCTAssertEqual(hrrService(collector, ownStart: live).strapHR(at: 60), 60)
        XCTAssertNil(hrrService(collector, ownStart: live.addingTimeInterval(-600)).strapHR(at: 60), "another session's stream")
        XCTAssertNil(hrrService(collector, ownStart: nil).strapHR(at: 60), "a workout that never streamed")
    }

    /// A workout begun inside the window owns the Watch's heart rate from
    /// its start: later samples are its exertion, not this one's recovery.
    func testRecoverySamplesStopWhereTheNextWorkoutBegan() {
        let stop = Date()
        let samples = [60, 120].map { HRRSample(offsetSec: $0, hr: 120, drop: 30, peakHR: 150, provenance: .watchSamples) }
        let kept = WorkoutRecorder.hrrSamples(samples, stopDate: stop, before: stop.addingTimeInterval(90))
        XCTAssertEqual(kept.map(\.offsetSec), [60])
        XCTAssertEqual(WorkoutRecorder.hrrSamples(samples, stopDate: stop, before: nil).count, 2)
        let collector = makeCollector()
        let recorder = makeRecorder(collector)
        let finished = HRVSession(sessionType: .workout)
        recorder.lifecycle.finishedSession = finished
        XCTAssertNil(recorder.startOfWorkout(after: finished.id), "its own summary is not a later workout")
        let next = HRVSession(startDate: stop.addingTimeInterval(45), sessionType: .workout)
        recorder.lifecycle.currentSession = next
        XCTAssertEqual(recorder.startOfWorkout(after: finished.id), next.startDate)
    }

    /// Releasing the strap after the recovery window: another session's
    /// stream keeps running and its link stays; a recording on the strap
    /// keeps the link too; with nothing else on the strap it goes.
    func testTheRecoveryWindowReleasesOnlyAStrapNothingElseUses() {
        let collector = makeCollector()
        let recorder = makeRecorder(collector)
        let core = collector.recordingCore
        let own = Date().addingTimeInterval(-300)
        let strap = WorkoutRecorder.StrapAfterHRR(stream: core.strapStream, recording: core.strapRecording, discovery: core.strapDiscovery, streamStart: own)
        let stream = buffer(collector, since: Date())
        recorder.releaseStrapAfterHRR(strap)
        XCTAssertTrue(stream.isStreaming, "a quick reading started since was stopped")
        XCTAssertEqual(core.strapLink.connectedDeviceId, deviceId)
        stream.endStreaming()
        core.strapRecording.isRecordingOnDevice = true
        recorder.releaseStrapAfterHRR(strap)
        XCTAssertEqual(core.strapLink.connectedDeviceId, deviceId, "a strap-only recording lost its link")
        core.strapRecording.isRecordingOnDevice = false
        recorder.releaseStrapAfterHRR(strap)
        XCTAssertNil(core.strapLink.connectedDeviceId)
    }

    // MARK: - Starting beside another session

    /// A night being ended still holds the strap: a workout on the strap is
    /// refused until the ending lets go.
    func testAStrapWorkoutDoesNotStartWhileANightIsBeingEnded() throws {
        let collector = makeCollector()
        let recorder = makeRecorder(collector)
        collector.streamingLifecycle.isOvernightStreaming = true
        let claim = try XCTUnwrap(collector.streamingLifecycle.claimOvernightEnding())
        collector.streamingLifecycle.isOvernightStreaming = false
        XCTAssertThrowsError(try recorder.session.resolveEffectiveSource(requested: .strap)) { error in
            XCTAssertEqual(error as? WorkoutRecorderError, .strapBusy)
        }
        XCTAssertEqual(try recorder.session.resolveEffectiveSource(requested: .watch), .watch)
        collector.streamingLifecycle.releaseOvernightEnding(claim)
        XCTAssertEqual(try recorder.session.resolveEffectiveSource(requested: .strap), .strap)
    }

    /// A strap-only recording does not start under another session's
    /// stream: at a strap workout's end its backup download took it.
    func testAStrapOnlyRecordingDoesNotStartWhileASessionBuffers() throws {
        let collector = makeCollector()
        buffer(collector, since: Date())
        XCTAssertThrowsError(try collector.strapGuards.requireConnectedWithNoNightHeld(starting: "a test")) { error in
            XCTAssertEqual(error as? RRCollector.CollectorError, .alreadyRecording)
        }
        collector.polarManager.stream.endStreaming()
        XCTAssertNoThrow(try collector.strapGuards.requireConnectedWithNoNightHeld(starting: "a test"))
    }

    // MARK: - Letting go of a Verity Sense

    /// A quick reading and a night release the sensor after their analysis
    /// only when no session started on it since.
    func testAVeritySenseIsNotReleasedUnderASessionStartedSince() {
        let collector = makeCollector(type: .veritySense)
        let stream = buffer(collector, since: Date())
        collector.quickReading.disconnectVeritySenseAfterQuickSession()
        collector.overnightStreaming.disconnectVeritySenseAfterNight(isVeritySense: true)
        XCTAssertEqual(collector.polarManager.linkState.connectedDeviceId, deviceId)
        XCTAssertTrue(stream.isStreaming)
        stream.endStreaming()
        collector.quickReading.disconnectVeritySenseAfterQuickSession()
        XCTAssertNil(collector.polarManager.linkState.connectedDeviceId)
        collector.polarManager.setConnectedDeviceForTesting(id: deviceId, type: .veritySense)
        collector.overnightStreaming.disconnectVeritySenseAfterNight(isVeritySense: true)
        XCTAssertNil(collector.polarManager.linkState.connectedDeviceId)
    }

    // MARK: - A recording armed too late

    /// A night's arming answered after the night ended is stopped, but not
    /// while another session buffers on the strap: that session's arming
    /// sets it aside, and the stop could end that session's recording.
    func testANightsLateRecordingIsLeftToASessionStartedSince() async {
        let radio = FakeStrapRadio()
        radio.setRecording(ongoing: true, entryId: StrapExerciseDecoder.exerciseId(at: Date()))
        let collector = makeCollector(radio)
        collector.polarManager.deviceRecording.isRecordingOnDevice = true
        buffer(collector, since: Date())
        await collector.overnightStreaming.settleLateArmedRecording()
        XCTAssertFalse(stopped(radio), "a workout started since had the strap stopped")
        collector.polarManager.stream.endStreaming()
        await collector.overnightStreaming.settleLateArmedRecording()
        XCTAssertTrue(stopped(radio))
    }

    /// The same for a workout's arming answered after that workout ended.
    func testAWorkoutsLateRecordingIsLeftToASessionStartedSince() async {
        let radio = FakeStrapRadio()
        radio.setRecording(ongoing: true, entryId: StrapExerciseDecoder.exerciseId(at: Date()))
        let collector = makeCollector(radio)
        collector.polarManager.deviceRecording.isRecordingOnDevice = true
        let recorder = makeRecorder(collector)
        let owner = WorkoutSessionLifecycle.ArmingOwner(workoutId: UUID(), streamStart: Date().addingTimeInterval(-900))
        buffer(collector, since: Date())
        await recorder.session.stopLateArmedBackup(of: owner, recorder: collector.recordingCore.strapRecorder)
        XCTAssertFalse(stopped(radio), "the next session's recording was stopped")
        collector.polarManager.stream.endStreaming()
        await recorder.session.stopLateArmedBackup(of: owner, recorder: collector.recordingCore.strapRecorder)
        XCTAssertTrue(stopped(radio))
    }

    // MARK: - The strap's download record

    /// Only a strap workout's save marks the strap's downloads since its
    /// start as saved; a Watch workout's would mark another session's.
    func testOnlyAStrapWorkoutMarksTheStrapsDownloadsSaved() {
        let collector = makeCollector()
        let recorder = makeRecorder(collector)
        let ledger = collector.polarManager.deviceRecording.downloadLedger
        let napStart = Date().addingTimeInterval(-1800)
        ledger.markDownloaded(recordingStartedAt: napStart)
        recorder.lifecycle.sessionStartDate = Date().addingTimeInterval(-3600)
        recorder.lifecycle.activeHRSource = .watch
        recorder.noteOwnStrapDownloadSaved(.saved, stopDate: Date())
        XCTAssertFalse(ledger.wasSaved(recordingStartedAt: napStart), "a nap still to be saved went on the saved record")
        recorder.lifecycle.activeHRSource = .strap
        recorder.noteOwnStrapDownloadSaved(.saved, stopDate: Date())
        XCTAssertTrue(ledger.wasSaved(recordingStartedAt: napStart))
    }

    // MARK: - The crash marker

    /// The Record screen's clear leaves a workout's marker; the exact clear
    /// takes only the marker it names.
    func testTheRecordScreensClearLeavesAWorkoutsMarker() {
        let collector = makeCollector()
        let store = collector.recordingStore
        let workoutId = UUID()
        store.persist(sessionId: workoutId, startTime: Date(), sessionType: .workout)
        store.clear()
        XCTAssertEqual(store.load()?.sessionId, workoutId, "accepting a night wiped a running workout's marker")
        store.clear(ifItIs: UUID())
        XCTAssertEqual(store.load()?.sessionId, workoutId)
        store.clear(ifItIs: workoutId)
        XCTAssertNil(store.load())
        store.persist(sessionId: UUID(), startTime: Date(), sessionType: .overnight)
        store.clear()
        XCTAssertNil(store.load())
    }

    // MARK: - The diagnostics sampler

    /// The sampler stops with the last recording that asked for it.
    func testTheSamplerRunsUntilTheLastRecordingStops() {
        var holders = SamplingHolders()
        holders.add(.recordScreen)
        holders.add(.workout)
        XCTAssertFalse(holders.remove(.workout), "a Watch workout's stop ended the night's trace")
        XCTAssertTrue(holders.remove(.recordScreen))
        XCTAssertTrue(holders.remove(.workout), "a stop with nothing running stops the sampler")
    }
}
