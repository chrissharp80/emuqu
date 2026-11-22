@testable import Emuqu
import os
import XCTest

/// The lock "Delete All My Data" holds while it runs (`PurgeGate`), and the
/// stores that must not write a purged value back once it has run.
@MainActor
final class PurgeGateTests: XCTestCase {
    override func tearDown() async throws {
        XCTAssertFalse(PurgeGate.isPurging, "a test left the purge gate closed")
        try await super.tearDown()
    }

    /// Writes run while no purge does, are refused while one does, and run
    /// again once it has finished.
    func testWritesAreRefusedOnlyWhileAPurgeRuns() async throws {
        XCTAssertEqual(try PurgeGate.admitWrite { 1 }, 1)

        await PurgeGate.beginPurge()
        XCTAssertTrue(PurgeGate.isPurging)
        XCTAssertThrowsError(try PurgeGate.admitWrite { XCTFail("a write ran while the purge did") }) {
            XCTAssertTrue($0 is PurgeGate.Refused)
        }
        PurgeGate.endPurge()

        XCTAssertFalse(PurgeGate.isPurging)
        XCTAssertEqual(try PurgeGate.admitWrite { 2 }, 2)
    }

    /// Overlapping purges are counted: the gate opens when the last one ends.
    func testTheGateStaysClosedUntilTheLastPurgeEnds() async {
        await PurgeGate.beginPurge()
        await PurgeGate.beginPurge()
        PurgeGate.endPurge()
        XCTAssertTrue(PurgeGate.isPurging, "the gate opened while a purge still ran")
        PurgeGate.endPurge()
        XCTAssertFalse(PurgeGate.isPurging)
    }

    /// A purge starts only once the write already under way has finished; a
    /// write that arrives meanwhile is refused.
    func testAPurgeWaitsForTheWriteInFlight() async throws {
        let admitted = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let writer = Task.detached {
            try PurgeGate.admitWrite {
                admitted.withLock { $0 = true }
                release.wait()
            }
        }
        while !admitted.withLock({ $0 }) { await Task.yield() }
        let purge = Task { @MainActor in
            await PurgeGate.beginPurge()
            return Date()
        }
        while !PurgeGate.isPurging { await Task.yield() }
        XCTAssertThrowsError(try PurgeGate.admitWrite {}, "a new write was let in while the purge waited")

        let released = Date()
        release.signal()
        try await writer.value
        let started = await purge.value
        PurgeGate.endPurge()

        XCTAssertGreaterThanOrEqual(started, released, "the purge started before the write in flight finished")
    }

    /// The usage counters count on from what is stored, so a sweep of their
    /// keys (Delete All My Data) is not undone by the next tap writing the
    /// old totals back from memory.
    func testUsageCountersCountOnFromTheStoredValue() throws {
        let suiteName = "PurgeGateTests.telemetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let telemetry = ValidationTelemetry(defaults: defaults)
        telemetry.recordDashboardOpen()
        telemetry.recordDashboardOpen()
        telemetry.recordChipTap(.hrv)

        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("telemetry.") {
            defaults.removeObject(forKey: key)
        }
        telemetry.recordDashboardOpen()
        telemetry.recordChipTap(.sleep)

        XCTAssertEqual(defaults.integer(forKey: "telemetry.dashboardOpens"), 1)
        XCTAssertEqual(defaults.dictionary(forKey: "telemetry.chipDrillInsByKey") as? [String: Int], ["sleep": 1])
        XCTAssertEqual(telemetry.dashboardOpens, 1)
    }
}
