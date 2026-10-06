@testable import Emuqu
import PolarBleSdk
import XCTest

/// The overnight paths, driven end to end against a strap that isn't there.
///
/// ## Why this exists
///
/// These are the sequences the product is for: arm the H10's own recording at
/// bedtime, fetch it in the morning, or record a night on a Verity Sense and
/// pull it back. Every one of them ran only on hardware, so the way they were
/// checked was to wear the strap overnight and look at the score the next day.
/// A night is a slow test, and a wrong answer costs the user a night they
/// cannot record again.
///
/// `FakeStrapRadio` answers the strap calls from a script, so what is
/// exercised here is the app's own sequencing: waiting for the strap to be
/// usable, retrying the refusals the SDK makes before its services are up,
/// rescuing a recording left from an earlier session, validating the recording
/// belongs to this session, and grouping a split Verity night.
@MainActor
final class StrapNightTests: XCTestCase {
    private let deviceId = "H10-NIGHT"

    /// A manager already linked to a strap, with a scripted radio.
    private func linkedManager(
        _ radio: FakeStrapRadio, type: PolarDeviceType = .h10, settled: Bool = true
    ) -> PolarManager {
        let manager = PolarManager()
        manager.radioForTesting = radio
        manager.setConnectedDeviceForTesting(id: deviceId, type: type)
        manager.readiness.linkEstablished()
        if settled { manager.readiness.settleWithoutSummary() }
        return manager
    }

    private func exerciseId(_ start: Date) -> String {
        StrapExerciseDecoder.exerciseId(at: start)
    }

    // MARK: - Bedtime

    /// Arming the H10 starts a recording, and the recording it starts is filed
    /// under this session's start time.
    func testArmingTheH10StartsARecordingForTonight() async throws {
        let radio = FakeStrapRadio()
        let manager = linkedManager(radio)

        try await manager.recording.startFreshRecording()

        XCTAssertTrue(radio.calls.contains { if case .startRecording = $0 { return true } else { return false } })
        let started = radio.calls.compactMap { call -> String? in
            if case let .startRecording(id) = call { return id } else { return nil }
        }.first
        let id = try XCTUnwrap(started)
        let start = try XCTUnwrap(StrapExerciseDecoder.recordingStart(fromExerciseId: id))
        XCTAssertEqual(start.timeIntervalSinceNow, 0, accuracy: 120, "the id is this session's start time")
    }

    /// The SDK refuses locally until the strap's recording service is up. That
    /// refusal is retried, not reported as a failed night.
    func testArmingSurvivesTheStrapsNotReadyYetRefusals() async throws {
        let radio = FakeStrapRadio()
        radio.refuse("startRecording", times: 2)
        let manager = linkedManager(radio)

        try await manager.link.whenFeatureUsable(.h10Recording, until: Date().addingTimeInterval(30)) {
            try await manager.recording.startFreshRecording()
        }

        let starts = radio.calls.filter { if case .startRecording = $0 { return true } else { return false } }
        XCTAssertEqual(starts.count, 3, "two refusals, then the one that took")
    }

    /// A recording still running from an earlier session is this user's
    /// unrecovered night. It is stopped and its beats rescued before tonight's
    /// recording starts — never silently overwritten.
    func testAnEarlierNightOnTheStrapIsRescuedBeforeTonightStarts() async throws {
        let radio = FakeStrapRadio()
        let lastNight = Date().addingTimeInterval(-24 * 3600)
        radio.setRecording(ongoing: true, entryId: exerciseId(lastNight))
        radio.addExercise(entryId: exerciseId(lastNight), date: lastNight, rrMs: Array(repeating: 900, count: 500))
        let manager = linkedManager(radio)
        var rescued: [RRPoint] = []
        manager.onUnrecoveredDataRescued = { rescued = $0.points }

        try await manager.recording.startFreshRecording()

        XCTAssertEqual(rescued.count, 500, "last night's beats were dropped instead of rescued")
        let order = radio.calls.compactMap { call -> String? in
            switch call {
            case .stopRecording: "stop"
            case .fetchExercise: "fetch"
            case .startRecording: "start"
            default: nil
            }
        }
        XCTAssertEqual(order.prefix(3).map { $0 }, ["stop", "fetch", "start"],
                       "tonight's recording started before the old one was read")
    }

    // MARK: - Morning

    /// The morning fetch returns the night the strap recorded, as beats.
    func testTheMorningFetchReturnsTheNight() async throws {
        let radio = FakeStrapRadio()
        let start = Date().addingTimeInterval(-8 * 3600)
        radio.setRecording(ongoing: true, entryId: exerciseId(start))
        radio.addExercise(entryId: exerciseId(start), date: start, rrMs: Array(repeating: 850, count: 30_000))
        let manager = linkedManager(radio)

        let points = try await manager.fetchRecording(recordedSince: nil, budget: .attended).points

        XCTAssertEqual(points.count, 30_000)
        XCTAssertEqual(points.first?.rr_ms, 850)
        XCTAssertTrue(radio.calls.contains(.stopRecording), "the recording has to be stopped before it can be read")
    }

    /// A recording that started before tonight is not tonight's. Scoring it as
    /// the night is the bug that put an old workout in place of a night's sleep.
    func testARecordingFromBeforeTheSessionIsNotScoredAsTonight() async {
        let radio = FakeStrapRadio()
        let lastNight = Date().addingTimeInterval(-36 * 3600)
        radio.addExercise(entryId: exerciseId(lastNight), date: lastNight, rrMs: Array(repeating: 900, count: 20_000))
        let manager = linkedManager(radio)

        let points = await manager.fetchRecordingIfAvailable(recordedSince: Date().addingTimeInterval(-8 * 3600))?.points

        XCTAssertNil(points, "an older recording was scored as this session")
    }

    /// With both on the strap, the one that belongs to this session is taken.
    func testTonightsRecordingIsPickedOverAnOlderOne() async throws {
        let radio = FakeStrapRadio()
        let lastNight = Date().addingTimeInterval(-36 * 3600)
        let tonight = Date().addingTimeInterval(-7 * 3600)
        radio.addExercise(entryId: exerciseId(lastNight), date: lastNight, rrMs: Array(repeating: 900, count: 100))
        radio.addExercise(entryId: exerciseId(tonight), date: tonight, rrMs: Array(repeating: 800, count: 250))
        let manager = linkedManager(radio)

        let points = await manager.fetchRecordingIfAvailable(recordedSince: Date().addingTimeInterval(-8 * 3600))?.points

        XCTAssertEqual(points?.count, 250)
        XCTAssertEqual(points?.first?.rr_ms, 800, "the older recording was returned")
    }

    /// A download that fails leaves the night on the strap: the fetch reports
    /// nothing rather than a partial night, and the recording is not removed,
    /// so the rescue can read it again.
    func testAFailedDownloadLeavesTheNightOnTheStrap() async {
        let radio = FakeStrapRadio()
        let tonight = Date().addingTimeInterval(-7 * 3600)
        let entryId = exerciseId(tonight)
        radio.addExercise(entryId: entryId, date: tonight, rrMs: Array(repeating: 800, count: 250))
        // A transfer failure, not the SDK's "not ready yet": that refusal is
        // retried on the link, as every strap operation's is.
        radio.refuse("fetchExercise", times: 50, with: PolarErrors.deviceError(description: "transfer failed"))
        let manager = linkedManager(radio)

        let points = await manager.fetchRecordingIfAvailable(recordedSince: Date().addingTimeInterval(-8 * 3600))?.points

        XCTAssertNil(points, "a failed download must not be scored as the night")
        XCTAssertTrue(radio.calls.contains(.fetchExercise(entryId: entryId)), "the download was never attempted")
        XCTAssertFalse(radio.calls.contains(.removeExercise(entryId: entryId)), "a night that was not read was deleted")
    }

    /// The strap keeps recording through a dropped link, so a fetch that runs
    /// after a reconnect still gets the whole night.
    func testTheNightSurvivesADroppedLink() async throws {
        let radio = FakeStrapRadio()
        let start = Date().addingTimeInterval(-8 * 3600)
        radio.setRecording(ongoing: true, entryId: exerciseId(start))
        radio.addExercise(entryId: exerciseId(start), date: start, rrMs: Array(repeating: 870, count: 25_000))
        let manager = linkedManager(radio)
        manager.prepareStreamingStateForTesting()

        let recordingBeforeDrop = manager.isRecordingOnDevice
        manager.link.apply(.disconnected(deviceId: deviceId, loss: .connectionLost))
        XCTAssertEqual(manager.isRecordingOnDevice, recordingBeforeDrop,
                       "the drop must not decide anything about the strap's own recording")
        manager.link.apply(.connected(deviceId: deviceId, name: "Polar H10 NIGHT"))
        manager.readiness.settleWithoutSummary()

        let points = try await manager.fetchRecording(recordedSince: nil, budget: .attended).points
        XCTAssertEqual(points.count, 25_000, "the night was lost across the reconnect")
    }

    // MARK: - Verity Sense

    /// A Verity night split into sub-files is one night, downloaded once.
    func testASplitVerityNightIsReadOnceNotOncePerFile() async throws {
        let radio = FakeStrapRadio()
        let start = Date().addingTimeInterval(-8 * 3600)
        for index in 0 ..< 3 {
            radio.addOfflineRecording(
                path: "/U/0/20260915/R/220000/PPI\(index).REC", date: start, ppiMs: Array(repeating: 900, count: 1_000)
            )
        }
        let manager = linkedManager(radio, type: .veritySense)

        let points = try await manager.fetchRecording(recordedSince: nil, budget: .attended).points

        XCTAssertEqual(points.count, 1_000, "the night came back once per sub-file")
        let reads = radio.calls.filter { if case .getOfflineRecord = $0 { return true } else { return false } }
        XCTAssertEqual(reads.count, 1)
    }

    /// Arming a Verity night starts offline PPI recording on the sensor.
    func testArmingTheVerityStartsOfflinePpiRecording() async throws {
        let radio = FakeStrapRadio()
        let manager = linkedManager(radio, type: .veritySense)

        try await manager.startRecording()

        XCTAssertTrue(radio.calls.contains(.startOfflineRecording))
        let status = try await manager.checkRecordingStatus()
        XCTAssertTrue(status, "the sensor should report the night as recording")
        XCTAssertTrue(manager.isRecordingOnDevice)
    }

    // MARK: - The live feed

    /// The feed opens on the link and delivers the strap's beats into the
    /// session, without the session subscribing to anything.
    func testTheFeedDeliversBeatsIntoARunningSession() async throws {
        let radio = FakeStrapRadio()
        radio.queueHeartRate(bpm: 58, rrsMs: [1_030, 1_020])
        let manager = linkedManager(radio)
        try manager.startStreaming()

        StrapHeartRateFeed(manager: manager).restart()
        try await waitUntil { manager.streamedRRPoints.count >= 2 }

        XCTAssertEqual(manager.currentHeartRate, 58)
        XCTAssertEqual(manager.streamedRRPoints.map(\.rr_ms), [1_030, 1_020])
        XCTAssertEqual(manager.feedStatus, .live)
    }

    /// Live heart rate attaches to the strap the SDK connected, by the
    /// CoreBluetooth identifier the SDK reported with the link. Without it the
    /// subscription has nothing to attach to and no beat ever arrives.
    func testTheHeartRateSubscriptionAttachesToTheStrapTheSDKConnected() async throws {
        let radio = FakeStrapRadio()
        let manager = PolarManager()
        manager.radioForTesting = radio
        let strap = UUID()

        manager.link.apply(.connected(deviceId: deviceId, name: "Polar H10 NIGHT", peripheralId: strap))
        try await waitUntil { !radio.hrPeripheralIds.isEmpty }

        XCTAssertEqual(radio.hrPeripheralIds.first, strap)
    }

    /// A subscription can end before it delivers — the strap refuses
    /// notifications, or the link is not ready for them. The feed re-opens
    /// until it takes; giving up is the failure the user saw as "connected, no
    /// heart rate".
    func testTheFeedKeepsReopeningUntilTheStrapAccepts() async throws {
        let radio = FakeStrapRadio()
        radio.refuse("startHrStreaming", times: 3, with: BleGattException.gattDisconnected)
        radio.queueHeartRate(bpm: 61, rrsMs: [980])
        let manager = linkedManager(radio)
        try manager.startStreaming()

        StrapHeartRateFeed(manager: manager).restart()
        try await waitUntil(timeout: 30) { manager.currentHeartRate != nil }

        XCTAssertEqual(manager.currentHeartRate, 61)
        let opens = radio.calls.filter { $0 == .startHrStreaming }
        XCTAssertGreaterThanOrEqual(opens.count, 4, "the feed gave up instead of re-opening")
    }

    // MARK: - Helpers

    /// Polls `condition` on the main actor until true or the timeout passes.
    private func waitUntil(
        timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met within \(Int(timeout)) s"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
