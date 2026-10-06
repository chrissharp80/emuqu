@testable import Emuqu
import PolarBleSdk
import XCTest

/// The app-level flows that take a recording off the strap — Stop and its
/// Retry, Recover, the overnight gate shared by the morning and a pause —
/// driven against a strap that isn't there, up to the point each one decides
/// what the recording is and where it goes.
@MainActor
final class StrapRecoveryFlowTests: XCTestCase {
    private let deviceId = "H10-RECOVERY"
    private lazy var directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StrapRecoveryFlowTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var archive = SessionArchive(directory: directory)

    override func tearDown() async throws {
        PersistedRecordingState.clear()
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            // swallow-ok: a test that archived nothing leaves no directory to remove.
        }
        try await super.tearDown()
    }

    private func makeCollector(_ radio: FakeStrapRadio) -> RRCollector {
        let manager = PolarManager()
        manager.radioForTesting = radio
        manager.setConnectedDeviceForTesting(id: deviceId, type: .h10)
        manager.readiness.linkEstablished()
        manager.readiness.settleWithoutSummary()
        manager.downloadLedger = StrapDownloadLedger(
            defaults: UserDefaults(suiteName: "StrapRecoveryFlowTests-\(UUID().uuidString)") ?? .standard
        )
        return RRCollector(polarManager: manager, healthKit: HealthKitManager(), archive: archive)
    }

    private func exerciseId(_ start: Date) -> String {
        StrapExerciseDecoder.exerciseId(at: start)
    }

    private func fetched(_ radio: FakeStrapRadio) -> Bool {
        radio.calls.contains { if case .fetchExercise = $0 { return true } else { return false } }
    }

    // MARK: - Bugs 1 and 3: Retry is Stop, with Stop's date check

    /// Retry used to build `currentSession ?? HRVSession()`, download the
    /// newest file whatever its date, and score last night's file as
    /// tonight's. It is now Stop: the persisted session, and only a
    /// recording started since it began.
    func testRetryDoesNotScoreLastNightsFileAsTonight() async throws {
        let radio = FakeStrapRadio()
        let lastNight = Date().addingTimeInterval(-30 * 3600)
        radio.addExercise(entryId: exerciseId(lastNight), date: lastNight, rrMs: Array(repeating: 900, count: 20_000))
        let collector = makeCollector(radio)
        let tonightId = UUID()
        collector.persistRecordingState(sessionId: tonightId, startTime: Date().addingTimeInterval(-8 * 3600), sessionType: .overnight)

        let session = try await collector.retryFetchRecording()

        XCTAssertEqual(session?.id, tonightId, "Retry filed the attempt under a new session")
        XCTAssertEqual(session?.state, .failed)
        XCTAssertFalse(fetched(radio), "last night's file was downloaded for tonight")
        guard case .noRecordingSinceSessionStart? = collector.lastError as? PolarManager.PolarError else {
            return XCTFail("expected the strap to hold no recording from this session, got \(String(describing: collector.lastError))")
        }
    }

    // MARK: - Bug 2: Recover and a recording still running

    /// A recording no session owns — left by a crash — is what the Recover
    /// card offers, and Recover stops it before reading it.
    func testAnOrphanedRunningRecordingIsOffered() {
        let radio = FakeStrapRadio()
        let collector = makeCollector(radio)
        collector.polarManager.isRecordingOnDevice = true

        XCTAssertTrue(collector.offersStrapRecovery)
    }

    /// A recording a live session owns is that session's; Recover must not
    /// stop it.
    func testRecoverLeavesALiveSessionsRecordingAlone() async {
        let radio = FakeStrapRadio()
        let start = Date().addingTimeInterval(-3600)
        radio.setRecording(ongoing: true, entryId: exerciseId(start))
        let collector = makeCollector(radio)
        collector.polarManager.isRecordingOnDevice = true
        collector.isCollecting = true

        XCTAssertFalse(collector.offersStrapRecovery)
        do {
            _ = try await collector.recoverFromDevice()
            XCTFail("Recover stopped a live session's recording")
        } catch {
            XCTAssertEqual(error as? RRCollector.CollectorError, .alreadyRecording)
        }
        XCTAssertFalse(radio.calls.contains(.stopRecording))
    }

    // MARK: - Bug 9: the same night offered on every connect

    /// The strap keeps a downloaded recording as a backup; it is neither
    /// offered on the Record screen nor recovered a second time.
    func testADownloadedRecordingIsNotOfferedOrRecoveredAgain() async {
        let radio = FakeStrapRadio()
        let collector = makeCollector(radio)
        let start = Date().addingTimeInterval(-3600)
        collector.polarManager.hasStoredExercise = true
        collector.polarManager.storedExerciseDate = start
        XCTAssertTrue(collector.hasUnrecoveredData, "never downloaded: the user's missing data")

        collector.polarManager.downloadLedger.markDownloaded(recordingStartedAt: start)

        XCTAssertFalse(collector.hasUnrecoveredData)
        XCTAssertFalse(collector.offersStrapRecovery)
        do {
            _ = try await collector.recoverFromDevice()
            XCTFail("an already-saved recording was recovered again")
        } catch {
            XCTAssertEqual(error as? RRCollector.CollectorError, .strapRecordingAlreadySaved)
        }
        XCTAssertFalse(fetched(radio))
    }

    // MARK: - Bug 5: Discard after Recover

    /// A night new to the archive is saved for review with the id Discard
    /// takes back out; Recover now saves through the same path.
    func testANightSavedForReviewIsTheOneDiscardRemoves() async throws {
        let collector = makeCollector(FakeStrapRadio())
        let night = completeNight()
        collector.currentSession = night
        collector.needsAcceptance = true

        collector.morning.archiveForReview(night)
        XCTAssertEqual(collector.sessionState.reviewArchivedSessionId, night.id)
        await collector.rejectSession()

        XCTAssertFalse(archive.entries.contains { $0.sessionId == night.id }, "Discard left the recovered night in History")
    }

    /// A night that was already archived is the user's existing record and
    /// is not marked as Discard's to remove.
    func testANightAlreadyArchivedIsNotMarkedForDiscard() throws {
        let collector = makeCollector(FakeStrapRadio())
        let night = completeNight()
        _ = try archive.archive(night, skipSameNightMerge: true)

        collector.morning.archiveForReview(night)

        XCTAssertNil(collector.sessionState.reviewArchivedSessionId)
    }

    // MARK: - Bugs 6 and 7: the overnight gate

    /// A Skip tapped before the download: nothing is read, the strap is not
    /// left recording, and the Skip does not carry into the next night.
    func testASkippedNightIsStoppedAndTheSkipDoesNotCarryOver() async {
        let radio = FakeStrapRadio()
        let start = Date().addingTimeInterval(-8 * 3600)
        radio.setRecording(ongoing: true, entryId: exerciseId(start))
        radio.addExercise(entryId: exerciseId(start), date: start, rrMs: Array(repeating: 900, count: 500))
        let collector = makeCollector(radio)
        collector.polarManager.isRecordingOnDevice = true
        collector.useDeviceBackupForOvernight = true
        collector.deviceFetchPolicy = .skipByUser

        let points = await collector.overnightStreaming.fetchNightFromStrap(
            baseSession: HRVSession(startDate: start), streamingPoints: [], isVeritySense: false
        )

        XCTAssertNil(points)
        XCTAssertFalse(fetched(radio))
        XCTAssertTrue(radio.calls.contains(.stopRecording), "a skipped night left the strap recording")
        XCTAssertEqual(collector.deviceFetchPolicy, .automatic, "the Skip would silently skip the next night")
    }

    /// A pause whose download failed used to only log it; it now reports the
    /// strap's copy exactly as the morning does, and the copy shows as
    /// unrecovered.
    func testAFailedNightDownloadIsReportedNotSilent() async {
        let radio = FakeStrapRadio()
        let start = Date().addingTimeInterval(-3 * 3600)
        radio.setRecording(ongoing: true, entryId: exerciseId(start))
        radio.addExercise(entryId: exerciseId(start), date: start, rrMs: Array(repeating: 900, count: 500))
        radio.refuse("fetchExercise", times: 50, with: PolarErrors.deviceError(description: "transfer failed"))
        let collector = makeCollector(radio)
        collector.polarManager.isRecordingOnDevice = true
        collector.useDeviceBackupForOvernight = true

        let points = await collector.overnightStreaming.fetchNightFromStrap(
            baseSession: HRVSession(startDate: start), streamingPoints: streamWithGap(minutes: 30), isVeritySense: false
        )

        XCTAssertNil(points)
        XCTAssertEqual(collector.lastError as? RRCollector.CollectorError, .strapStillHoldsNight(missingMinutes: 30))
        XCTAssertTrue(collector.hasUnrecoveredData, "Resume would clear a copy nobody was told about")
    }

    // MARK: - Bug 8: a strap the link dropped

    /// The workout's end, the morning and crash recovery all bring a dropped
    /// strap back the same way, and read what it is recording before
    /// deciding anything from those flags.
    func testADroppedStrapIsBroughtBackAndReadBeforeTheTransfer() async {
        let radio = FakeStrapRadio()
        radio.setRecording(ongoing: true, entryId: exerciseId(Date().addingTimeInterval(-1800)))
        let manager = PolarManager()
        manager.radioForTesting = radio
        manager.knownDevices = []
        Task { @MainActor in
            await sleepQuietly(200_000_000, context: "test reconnect")
            manager.link.apply(.connected(deviceId: self.deviceId, name: "Polar H10 RECOVERY"))
            manager.readiness.settleWithoutSummary()
        }

        let back = await manager.reconnectForTransfer()

        XCTAssertTrue(back)
        XCTAssertTrue(manager.isRecordingOnDevice, "the strap's own status was not read after the reconnect")
    }

    // MARK: - Helpers

    private func completeNight() -> HRVSession {
        let id = UUID()
        let start = Date().addingTimeInterval(-9 * 3600)
        let points = (0 ..< 200).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: $0 % 2 == 0 ? 990 : 1010) }
        return HRVSession(
            id: id, startDate: start, endDate: start.addingTimeInterval(7 * 3600), state: .complete,
            sessionType: .overnight, rrSeries: RRSeries(points: points, sessionId: id, startDate: start),
            analysisResult: nil, artifactFlags: nil
        )
    }

    /// Streamed beats whose wall clock jumps `minutes` halfway: the link
    /// dropped and nothing arrived.
    private func streamWithGap(minutes: Int) -> [RRPoint] {
        (0 ..< 400).map { index in
            let t = Int64(index) * 1000
            let wall = index < 200 ? t : t + Int64(minutes) * 60_000
            return RRPoint(t_ms: t, rr_ms: 1000, wallClockMs: wall, hr: 60)
        }
    }
}
