@testable import Emuqu
import PolarBleSdk
import XCTest

/// The one way a recording comes off the strap (`fetchRecording`), driven
/// against a strap that isn't there.
///
/// Every app flow that downloads — Stop, Retry, Recover, the morning, a pause,
/// a workout's end, crash recovery, the strap merge — goes through it, so
/// each scenario here is the scenario for all of them. The bugs these pin were
/// in the copies it replaced: only one refused an earlier night's file, only
/// one had a deadline, Cancel reached none, and a stopped strap was still
/// "recording" as far as the app knew.
@MainActor
final class StrapTransferTests: XCTestCase {
    private let deviceId = "H10-TRANSFER"

    private func linkedManager(_ radio: FakeStrapRadio, type: PolarDeviceType = .h10) -> PolarManager {
        let manager = PolarManager()
        manager.radioForTesting = radio
        manager.setConnectedDeviceForTesting(id: deviceId, type: type)
        manager.readiness.linkEstablished()
        manager.readiness.settleWithoutSummary()
        return manager
    }

    private func exerciseId(_ start: Date) -> String {
        StrapExerciseDecoder.exerciseId(at: start)
    }

    /// An H10 armed by this app for a workout or a night, still recording.
    private func armedStrap(_ radio: FakeStrapRadio, start: Date, beats: Int) -> PolarManager {
        radio.setRecording(ongoing: true, entryId: exerciseId(start))
        radio.addExercise(entryId: exerciseId(start), date: start, rrMs: Array(repeating: 800, count: beats))
        let manager = linkedManager(radio)
        manager.recordingState = .recording
        manager.isRecordingOnDevice = true
        return manager
    }

    // MARK: - dfa-strap Bug 4: a stopped strap left "recording"

    /// The normal H10 workout stop (stream ≥ 95 %, no download) stopped the
    /// strap but left both flags set, and every later arm was refused as
    /// `alreadyRecording` all night.
    func testTheInlineStopReturnsTheAppToIdle() async throws {
        let radio = FakeStrapRadio()
        let manager = armedStrap(radio, start: Date().addingTimeInterval(-3600), beats: 3_000)

        await manager.stopDeviceRecordingIfNeeded(streamHoldsIt: true)

        XCTAssertTrue(radio.calls.contains(.stopRecording))
        XCTAssertEqual(manager.recordingState, .idle, "the next arm is refused while this reads .recording")
        XCTAssertFalse(manager.isRecordingOnDevice)
        try await manager.recording.startFreshRecording()
        XCTAssertTrue(radio.calls.contains { if case .startRecording = $0 { return true } else { return false } },
                      "tonight's recording was refused after the workout")
    }

    /// Oct 6: a walk's stream was complete, so the stop skipped the download.
    /// At bedtime the night's start found the walk's recording, treated it as
    /// never saved, and fought the strap for 13 s to download it again. The
    /// stop now puts it on the download record, and the start just clears it.
    func testAWorkoutCoveredByItsStreamIsNotRescuedAtTheNextStart() async throws {
        let radio = FakeStrapRadio()
        let walk = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 16 * 3600).rounded(.down))
        let manager = armedStrap(radio, start: walk, beats: 3_000)
        manager.downloadLedger = StrapDownloadLedger(defaults: isolatedDefaults())

        await manager.stopDeviceRecordingIfNeeded(streamHoldsIt: true)
        try await manager.recording.startFreshRecording()

        XCTAssertFalse(radio.calls.contains(.fetchExercise(entryId: exerciseId(walk))),
                       "the walk's strap copy was downloaded again at the next start")
        XCTAssertTrue(radio.calls.contains(.removeExercise(entryId: exerciseId(walk))))
    }

    /// A stop whose session did not save the beats (a skipped morning
    /// download) leaves the recording off the record, so the next start
    /// still rescues it.
    func testAStopTheStreamDidNotCoverIsStillRescued() async throws {
        let radio = FakeStrapRadio()
        let night = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 20 * 3600).rounded(.down))
        let manager = armedStrap(radio, start: night, beats: 3_000)
        manager.downloadLedger = StrapDownloadLedger(defaults: isolatedDefaults())
        var rescued: [RRPoint] = []
        manager.onUnrecoveredDataRescued = { rescued = $0.points }

        await manager.stopDeviceRecordingIfNeeded(streamHoldsIt: false)
        try await manager.recording.startFreshRecording()

        XCTAssertEqual(rescued.count, 3_000, "a night the app never saved was cleared without a rescue")
    }

    /// The same after a download that failed once the strap was stopped.
    func testAFailedDownloadAfterAStopLeavesTheAppIdle() async {
        let radio = FakeStrapRadio()
        let start = Date().addingTimeInterval(-3600)
        let manager = armedStrap(radio, start: start, beats: 3_000)
        radio.refuse("fetchExercise", times: 50, with: PolarErrors.deviceError(description: "transfer failed"))

        let recording = await manager.fetchRecordingIfAvailable(recordedSince: start.addingTimeInterval(-60))

        XCTAssertNil(recording)
        XCTAssertEqual(manager.recordingState, .idle)
        XCTAssertFalse(manager.isRecordingOnDevice, "the strap confirmed the stop")
        XCTAssertTrue(manager.hasStoredExercise, "the stopped strap holds the finished file")
        XCTAssertEqual(manager.storedExerciseDate.map { Int($0.timeIntervalSince1970) }, Int(start.timeIntervalSince1970))
    }

    /// A status read on a link that stays up corrects a stale `.recording`.
    func testAStatusReadCorrectsAStaleRecordingState() async throws {
        let radio = FakeStrapRadio()
        let manager = linkedManager(radio)
        manager.recordingState = .recording
        manager.isRecordingOnDevice = true

        _ = try await manager.checkRecordingStatus()

        XCTAssertEqual(manager.recordingState, .idle)
        XCTAssertFalse(manager.isRecordingOnDevice)
    }

    // MARK: - strap-copies Bug 1: an earlier night's file

    /// Stop and Retry only take a recording that started since the session
    /// began; the strap keeps the previous night until the next recording.
    func testAnAttendedFetchRefusesAnEarlierNight() async {
        let radio = FakeStrapRadio()
        let lastNight = Date().addingTimeInterval(-30 * 3600)
        radio.addExercise(entryId: exerciseId(lastNight), date: lastNight, rrMs: Array(repeating: 900, count: 20_000))
        let manager = linkedManager(radio)

        do {
            _ = try await manager.fetchRecording(recordedSince: Date().addingTimeInterval(-8 * 3600), budget: .attended)
            XCTFail("last night's file was returned as tonight's")
        } catch {
            XCTAssertEqual(StrapRecordingCoordinator.classify(error), .deterministic)
        }
        XCTAssertFalse(radio.calls.contains(.fetchExercise(entryId: exerciseId(lastNight))))
    }

    /// The download carries the recording's own start, which is what dates a
    /// recovered night.
    func testTheDownloadCarriesTheRecordingsOwnStart() async throws {
        let radio = FakeStrapRadio()
        let start = Date().addingTimeInterval(-30 * 3600).rounded()
        radio.addExercise(entryId: exerciseId(start), date: Date(), rrMs: Array(repeating: 1_000, count: 600))
        let manager = linkedManager(radio)

        let recording = try await manager.fetchRecording(recordedSince: nil, budget: .attended)

        XCTAssertEqual(recording.startedAt, start)
        XCTAssertEqual(recording.endedAt, start.addingTimeInterval(600))
    }

    // MARK: - strap-copies Bug 2: Recover on a strap still recording

    /// The H10 lists only finished recordings, so a download that never
    /// stops a running one finds nothing.
    func testARunningRecordingIsStoppedBeforeItIsRead() async throws {
        let radio = FakeStrapRadio()
        let start = Date().addingTimeInterval(-5 * 3600)
        let manager = armedStrap(radio, start: start, beats: 1_000)

        let recording = try await manager.fetchRecording(recordedSince: nil, budget: .attended)

        XCTAssertEqual(recording.points.count, 1_000)
        let order = radio.calls.compactMap { call -> String? in
            switch call {
            case .stopRecording: "stop"
            case .fetchExercise: "fetch"
            default: nil
            }
        }
        XCTAssertEqual(order, ["stop", "fetch"])
    }

    // MARK: - strap-copies Bug 4: no deadline, and Cancel that cancelled nothing

    /// A strap that never answers the download is ended by Cancel at once.
    func testCancelEndsADownloadTheStrapNeverAnswers() async throws {
        let radio = FakeStrapRadio()
        let start = Date().addingTimeInterval(-3600)
        radio.addExercise(entryId: exerciseId(start), date: start, rrMs: Array(repeating: 800, count: 500))
        radio.hang("fetchExercise")
        let manager = linkedManager(radio)
        let transfer = Task { try await manager.fetchRecording(recordedSince: nil, budget: .attended) }
        try await waitUntil { radio.calls.contains(.fetchExercise(entryId: self.exerciseId(start))) }

        let cancelledAt = Date()
        manager.cancelFetch()
        let result = await transfer.result

        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2, "Cancel waited on a call that never answers")
        guard case let .failure(error) = result else { return XCTFail("a hung download returned beats") }
        XCTAssertEqual(error.localizedDescription, PolarManager.PolarError.fetchFailed("").localizedDescription)
        XCTAssertEqual(manager.recordingState, .idle)
        XCTAssertNil(manager.fetchProgress)
    }

    /// The deadline itself returns when the call never does.
    func testTheDeadlineReturnsWhenTheCallNeverDoes() async {
        let started = Date()
        do {
            _ = try await StrapDeadline.race(seconds: 1, timeout: PolarManager.PolarError.fetchFailed("timeout")) {
                await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            }
            XCTFail("a call that never answers returned")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        }
    }

    // MARK: - strap-copies Bug 6: a Skip tapped before the download began

    /// The fetch used to clear the cancel flag on entry, erasing a Skip
    /// tapped during the reconnect that precedes it.
    func testACancelBeforeTheDownloadIsNotErasedByIt() async {
        let radio = FakeStrapRadio()
        let start = Date().addingTimeInterval(-3600)
        radio.addExercise(entryId: exerciseId(start), date: start, rrMs: Array(repeating: 800, count: 500))
        let manager = linkedManager(radio)
        manager.beginTransfer()
        manager.cancelFetch()

        let recording = await manager.fetchRecordingIfAvailable(recordedSince: start.addingTimeInterval(-60))

        XCTAssertNil(recording)
        XCTAssertFalse(radio.calls.contains(.fetchExercise(entryId: exerciseId(start))))
    }

    // MARK: - strap-copies Bug 9: the same night offered on every connect

    /// A download is on record, so the copy the strap keeps is not offered
    /// as missing data.
    func testADownloadedRecordingIsOnRecord() async throws {
        let radio = FakeStrapRadio()
        let start = Date().addingTimeInterval(-3600).rounded()
        radio.addExercise(entryId: exerciseId(start), date: start, rrMs: Array(repeating: 800, count: 500))
        let manager = linkedManager(radio)
        manager.downloadLedger = StrapDownloadLedger(defaults: isolatedDefaults())

        _ = try await manager.fetchRecording(recordedSince: nil, budget: .unattended)

        XCTAssertTrue(manager.hasStoredExercise, "the strap keeps its copy")
        XCTAssertTrue(manager.downloadLedger.wasDownloaded(recordingStartedAt: start))
    }

    // MARK: - Placing beats on a session's clock

    /// A recording armed four minutes into the session counts from its own
    /// start; its beats move four minutes later.
    func testARecordingArmedLateIsPlacedOnTheSessionsClock() {
        let sessionStart = Date(timeIntervalSince1970: 1_790_000_000)
        let recording = StrapRecording(
            points: StrapExerciseDecoder.rrPoints(fromIntervalsMs: [1_000, 1_000]),
            startedAt: sessionStart.addingTimeInterval(240)
        )

        XCTAssertEqual(recording.points(onClockOf: sessionStart).map(\.t_ms), [240_000, 241_000])
        XCTAssertEqual(
            StrapRecording(points: recording.points, startedAt: nil)
                .points(onClockOf: sessionStart, fallbackStart: sessionStart.addingTimeInterval(60)).map(\.t_ms),
            [60_000, 61_000], "the arm time stands in for a recording with no start of its own"
        )
    }

    // MARK: - Helpers

    private func isolatedDefaults() -> UserDefaults {
        let name = "StrapTransferTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name) ?? .standard
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met within \(Int(timeout)) s"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private extension Date {
    /// Whole seconds, as the H10's id stores them.
    func rounded() -> Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}
