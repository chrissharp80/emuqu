@testable import Emuqu
import XCTest

/// What the app keeps about how a recording ended, and what the termination
/// report and night acceptance do with it.
@MainActor
final class OvernightEndingRecordTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        isolateFromHostRecordingState()
    }

    // MARK: - Stop requested

    func testMarkStopRequestedKeepsTheRecordingAndAddsTheTime() {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        PersistedRecordingState.save(PersistedRecordingState(
            sessionId: id, startTime: start, sessionType: .overnight, phase: "overnightStreaming", useDeviceInternalBackup: true
        ))
        let stoppedAt = start.addingTimeInterval(6 * 3600)

        PersistedRecordingState.markStopRequested(at: stoppedAt)

        let state = PersistedRecordingState.load()
        XCTAssertEqual(state?.sessionId, id)
        XCTAssertEqual(state?.startTime, start)
        XCTAssertEqual(state?.useDeviceInternalBackup, true)
        XCTAssertEqual(state?.stopRequestedAt, stoppedAt)
    }

    func testMarkStopRequestedWithNoRecordingWritesNothing() {
        PersistedRecordingState.markStopRequested()
        XCTAssertNil(PersistedRecordingState.load())
    }

    /// A record written before the field existed still loads.
    func testARecordWithoutTheStopTimeStillLoads() throws {
        let legacy = """
        {"sessionId":"\(UUID().uuidString)","startTime":0,"sessionType":"overnight","phase":"overnightStreaming"}
        """
        let decoded = try JSONDecoder().decode(PersistedRecordingState.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.stopRequestedAt)
    }

    // MARK: - Termination report

    func testReportDoesNotBlameIOSForAnUnknownCause() {
        let block = CrashLogManager.terminationCauseBlock(stopRequestedAt: nil)
        XCTAssertFalse(block.contains("terminated by iOS"))
        XCTAssertTrue(block.contains("app switcher"))
        XCTAssertTrue(block.contains("still running"))
    }

    func testReportSaysTheRecordingHadAlreadyBeenEnded() {
        let block = CrashLogManager.terminationCauseBlock(stopRequestedAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(block.contains("The recording had been ended at"))
        XCTAssertFalse(block.contains("user"), "an automatic pause sets the same time, so the report names no one")
    }

    // MARK: - Sleep frozen at acceptance

    private func night(minutes: Int) -> SleepData {
        SleepData(
            date: Date(), totalSleepMinutes: minutes, inBedMinutes: minutes, awakeMinutes: 0,
            sleepEfficiency: 90, boundarySource: .hrEstimated
        )
    }

    func testATimedOutFetchKeepsTheMorningNight() {
        let morning = night(minutes: 400)
        XCTAssertEqual(SessionAcceptanceService.sleepToFreeze(fetched: nil, morning: morning)?.nightSleepMinutes, 400)
    }

    func testAnEmptyFetchKeepsTheMorningNight() {
        let morning = night(minutes: 400)
        XCTAssertEqual(SessionAcceptanceService.sleepToFreeze(fetched: night(minutes: 0), morning: morning)?.nightSleepMinutes, 400)
    }

    func testAFetchedNightReplacesTheMorningNight() {
        let fetched = night(minutes: 450)
        XCTAssertEqual(SessionAcceptanceService.sleepToFreeze(fetched: fetched, morning: night(minutes: 400))?.nightSleepMinutes, 450)
    }

    func testAnEmptyFetchIsKeptWhenTheMorningHadNothing() {
        let fetched = night(minutes: 0)
        XCTAssertEqual(SessionAcceptanceService.sleepToFreeze(fetched: fetched, morning: nil)?.nightSleepMinutes, 0)
    }
}
