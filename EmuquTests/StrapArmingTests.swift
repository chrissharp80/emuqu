@testable import Emuqu
import PolarBleSdk
import XCTest

/// Arming the H10's own recording for a night, driven against a strap that
/// isn't there, from a field log: an H10 at 10 % refused the
/// start with Polar's BATTERY_TOO_LOW, nothing was retried or shown all
/// night, and the morning stop woke the arming loop into clearing and
/// starting the strap during the morning download.
@MainActor
final class StrapArmingTests: XCTestCase {
    private let deviceId = "H10-ARMING"
    private lazy var directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StrapArmingTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: directory)
    private var collectors: [RRCollector] = []

    override func tearDown() async throws {
        for collector in collectors { await collector.overnightStreaming.endDeviceRecordingArming() }
        collectors = []
        PersistedRecordingState.clear()
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            // swallow-ok: a test that archived nothing leaves no directory to remove.
        }
        try await super.tearDown()
    }

    private func linkedManager(_ radio: FakeStrapRadio) -> PolarManager {
        let manager = PolarManager()
        manager.radioForTesting = radio
        manager.setConnectedDeviceForTesting(id: deviceId, type: .h10)
        manager.readiness.linkEstablished()
        manager.readiness.settleWithoutSummary()
        manager.downloadLedger = StrapDownloadLedger(
            defaults: UserDefaults(suiteName: "StrapArmingTests-\(UUID().uuidString)") ?? .standard
        )
        return manager
    }

    /// A night streaming with its arming loop running.
    private func armingNight(_ radio: FakeStrapRadio, battery: Int? = nil) -> RRCollector {
        let manager = linkedManager(radio)
        manager.batteryLevel = battery
        let collector = RRCollector(polarManager: manager, healthKit: HealthKitManager(), archive: archive)
        collectors.append(collector)
        collector.armingRetryInterval = 0.05
        collector.useDeviceBackupForOvernight = true
        collector.isOvernightStreaming = true
        collector.overnightStreaming.launchDeviceRecordingLoop()
        return collector
    }

    private func starts(_ radio: FakeStrapRadio) -> Int {
        radio.calls.filter { if case .startRecording = $0 { return true } else { return false } }.count
    }

    private func exerciseId(_ start: Date) -> String {
        StrapExerciseDecoder.exerciseId(at: start)
    }

    // MARK: - A low battery

    /// Polar's BATTERY_TOO_LOW (PFTP 209) ends arming for the night: the user
    /// is told at once, with the level the strap reported, and nothing is
    /// tried again until the strap reports more charge.
    func testABatteryRefusalIsShownAndNotRetriedUntilTheBatteryRises() async throws {
        let radio = FakeStrapRadio()
        radio.refuse("startRecording", times: 1, with: BlePsFtpException.responseError(errorCode: 209))
        let collector = armingNight(radio, battery: 10)

        try await waitUntil { self.starts(radio) == 1 && collector.lastError != nil }
        guard case .strapBatteryTooLow(percent: 10)? = collector.lastError as? PolarManager.PolarError else {
            return XCTFail("expected the low-battery notice, got \(String(describing: collector.lastError))")
        }
        XCTAssertTrue(collector.lastError?.localizedDescription.contains("10") == true, "the notice names the level")

        collector.polarManager.linkRuntime.signal.fire()
        await sleepQuietly(400_000_000, context: "several retry intervals")
        XCTAssertEqual(starts(radio), 1, "the strap was asked again on the same battery")

        collector.polarManager.batteryLevel = 100
        try await waitUntil { collector.overnightDeviceBackupActive }
        XCTAssertEqual(starts(radio), 2)
        XCTAssertNil(collector.lastError, "the notice stayed after the strap armed")
    }

    func testTheSDKsBatteryRefusalIsRecognised() {
        XCTAssertTrue(StrapRecordingCoordinator.isBatteryTooLow(BlePsFtpException.responseError(errorCode: 209)))
        XCTAssertFalse(StrapRecordingCoordinator.isBatteryTooLow(BlePsFtpException.responseError(errorCode: 106)))
        XCTAssertFalse(StrapRecordingCoordinator.isBatteryTooLow(PolarErrors.notificationNotEnabled))
    }

    // MARK: - A refusal that clears up

    /// A refusal that can clear up is tried again on a timer, so a link that
    /// never changes does not strand the night streaming-only.
    func testATransientRefusalIsRetriedOnATimerWithAStableLink() async throws {
        let radio = FakeStrapRadio()
        radio.refuse("startRecording", times: 1, with: PolarErrors.deviceError(description: "busy"))
        let collector = armingNight(radio)

        try await waitUntil { collector.overnightDeviceBackupActive }

        XCTAssertEqual(starts(radio), 2, "armed on the retry, with no link change")
    }

    // MARK: - The end of the night

    /// The morning stop changes the link signal while the night is still
    /// streaming. Once the night is marked ending, nothing arms.
    func testNothingArmsOnceTheNightIsEnding() async throws {
        let radio = FakeStrapRadio()
        radio.refuse("startRecording", times: 1_000, with: PolarErrors.deviceError(description: "busy"))
        let collector = armingNight(radio)
        try await waitUntil { self.starts(radio) >= 1 }

        await collector.overnightStreaming.endDeviceRecordingArming()
        let attempts = radio.calls.count
        collector.polarManager.linkRuntime.signal.fire()
        await sleepQuietly(300_000_000, context: "what used to wake the arming loop")

        XCTAssertEqual(radio.calls.count, attempts, "the strap was touched after the night began to end")
        XCTAssertNil(collector.overnightArmingTask)
    }

    /// The start itself refuses, before touching the strap, when its session
    /// no longer wants it or another transfer is using the strap.
    func testAStartIsWithdrawnWhenTheSessionEndsOrATransferRuns() async {
        let radio = FakeStrapRadio()
        let manager = linkedManager(radio)
        await assertWithdrawn { try await manager.recording.startFreshRecording(while: { false }) }
        manager.transfersInFlight = 1
        await assertWithdrawn { try await manager.recording.startFreshRecording() }
        XCTAssertTrue(radio.calls.isEmpty, "the strap was touched: \(radio.calls)")
    }

    // MARK: - A recording that was never downloaded

    /// The clear before a start deletes every stored exercise, so one the app
    /// never downloaded is rescued first.
    func testAnUndownloadedRecordingIsRescuedBeforeTheClear() async throws {
        let radio = FakeStrapRadio()
        let lastNight = Date().addingTimeInterval(-20 * 3600)
        radio.addExercise(entryId: exerciseId(lastNight), date: lastNight, rrMs: Array(repeating: 900, count: 700))
        let manager = linkedManager(radio)
        var rescued: [RRPoint] = []
        manager.onUnrecoveredDataRescued = { rescued = $0.points }

        try await manager.recording.startFreshRecording()

        XCTAssertEqual(rescued.count, 700, "an undownloaded night was deleted, not rescued")
        let id = exerciseId(lastNight)
        let fetchIndex = try XCTUnwrap(radio.calls.firstIndex(of: .fetchExercise(entryId: id)))
        let removeIndex = try XCTUnwrap(radio.calls.firstIndex(of: .removeExercise(entryId: id)))
        XCTAssertLessThan(fetchIndex, removeIndex)
    }

    /// A recording already downloaded is the strap's backup copy and is
    /// cleared without another download.
    func testADownloadedRecordingIsClearedWithoutAnotherDownload() async throws {
        let radio = FakeStrapRadio()
        let lastNight = Date().addingTimeInterval(-20 * 3600)
        radio.addExercise(entryId: exerciseId(lastNight), date: lastNight, rrMs: Array(repeating: 900, count: 700))
        let manager = linkedManager(radio)
        manager.downloadLedger.markDownloaded(recordingStartedAt: lastNight)

        try await manager.recording.startFreshRecording()

        XCTAssertFalse(radio.calls.contains(.fetchExercise(entryId: exerciseId(lastNight))))
        XCTAssertTrue(radio.calls.contains(.removeExercise(entryId: exerciseId(lastNight))))
    }

    /// One that cannot be downloaded is kept, and the strap is not armed.
    func testAnUndownloadableRecordingStopsTheStartInsteadOfBeingDeleted() async {
        let radio = FakeStrapRadio()
        let lastNight = Date().addingTimeInterval(-20 * 3600)
        radio.addExercise(entryId: exerciseId(lastNight), date: lastNight, rrMs: Array(repeating: 900, count: 700))
        radio.refuse("fetchExercise", times: 1_000, with: PolarErrors.deviceError(description: "transfer failed"))
        let manager = linkedManager(radio)

        do {
            try await manager.recording.startFreshRecording()
            XCTFail("armed over a recording that was never downloaded")
        } catch {
            XCTAssertEqual(StrapRecordingPolicy.startRefusal(for: error), .undownloadedRecordingOnStrap)
        }
        XCTAssertFalse(radio.calls.contains(.removeExercise(entryId: exerciseId(lastNight))))
        XCTAssertEqual(starts(radio), 0)
    }

    // MARK: - Helpers

    private func assertWithdrawn(_ start: () async throws -> Void) async {
        do {
            try await start()
            XCTFail("the start was not withdrawn")
        } catch {
            XCTAssertTrue(error is CancellationError, "unexpected \(error)")
        }
    }

    private func waitUntil(timeout: TimeInterval = 20, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met within \(Int(timeout)) s"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
