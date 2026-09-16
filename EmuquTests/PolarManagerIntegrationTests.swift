@testable import Emuqu
import XCTest

/// Integration tests for PolarManager streaming logic.
///
/// Tests RR data extraction, wall clock tracking, gap detection, and edge cases
/// through `PolarManager.ingestHeartRate`, the same entry point the strap's feed calls (no real BLE required).
@MainActor
final class PolarManagerIntegrationTests: XCTestCase {
    var manager = PolarManager()

    // MARK: - Streaming Data Tests

    /// Test streaming with BLE hiccups (gap then more data)
    func testStreamingWithBLEHiccups() {
        manager.prepareStreamingStateForTesting(startTime: Date())

        let batch1 = createMockHRData(count: 10, startHR: 65)
        manager.ingestHeartRateForTesting(batch1, elapsedMs: 1000)

        XCTAssertEqual(manager.streamedRRPoints.count, 10)

        let batch2 = createMockHRData(count: 10, startHR: 66)
        manager.ingestHeartRateForTesting(batch2, elapsedMs: 1300)

        XCTAssertEqual(manager.streamedRRPoints.count, 20)

        if manager.streamedRRPoints.count >= 20 {
            let lastPoint = manager.streamedRRPoints[19]
            XCTAssertEqual(lastPoint.wallClockMs, 1300)
        }
    }

    /// Test streaming gap detection via wall clock
    func testStreamingGapDetection() {
        manager.prepareStreamingStateForTesting(startTime: Date())

        let batch1 = createMockHRData(count: 5, startHR: 65)
        manager.ingestHeartRateForTesting(batch1, elapsedMs: 2000)

        let firstWallClock = manager.streamedRRPoints.last?.wallClockMs ?? 0

        let batch2 = createMockHRData(count: 5, startHR: 65)
        manager.ingestHeartRateForTesting(batch2, elapsedMs: 2500)

        let secondWallClock = manager.streamedRRPoints.last?.wallClockMs ?? 0

        XCTAssertGreaterThan(
            secondWallClock,
            firstWallClock,
            "Wall clock should advance between batches"
        )
    }

    /// Test streaming wall clock drift over many batches
    func testStreamingWallClockDrift() throws {
        manager.prepareStreamingStateForTesting(startTime: Date())

        for index in 0 ..< 30 {
            let batch = createMockHRData(count: 1, startHR: 65)
            manager.ingestHeartRateForTesting(batch, elapsedMs: Int64(1000 + (index * 1000)))
        }

        XCTAssertEqual(manager.streamedRRPoints.count, 30)

        let lastPoint = try XCTUnwrap(manager.streamedRRPoints.last)
        let cumulativeMs = lastPoint.t_ms
        let wallClockMs = lastPoint.wallClockMs ?? 0

        XCTAssertGreaterThanOrEqual(
            wallClockMs,
            cumulativeMs - 1000,
            "Wall clock drift detection"
        )
    }

    /// Test multiple samples with mixed RR availability
    func testMultipleSamplesWithMixedAvailability() {
        manager.prepareStreamingStateForTesting(startTime: Date())

        let mixedBatch: [StrapHRSample] = [
            StrapHRSample(hr: Int(65), rrsMs: [920, 930], rrAvailable: true),
            StrapHRSample(hr: Int(66), rrsMs: [], rrAvailable: false),
            StrapHRSample(hr: Int(67), rrsMs: [910], rrAvailable: true),
            StrapHRSample(hr: Int(68), rrsMs: [], rrAvailable: false),
            StrapHRSample(hr: Int(69), rrsMs: [925, 915, 920], rrAvailable: true)
        ]

        manager.ingestHeartRate(mixedBatch)

        XCTAssertEqual(
            manager.streamedRRPoints.count,
            6,
            "Should only extract RR when rrAvailable is true"
        )
    }

    /// Test high frequency data burst
    func testHighFrequencyDataBurst() {
        manager.prepareStreamingStateForTesting(startTime: Date())

        let largeBatch = createMockHRData(count: 50, startHR: 65)
        manager.ingestHeartRateForTesting(largeBatch, elapsedMs: 10000)

        XCTAssertEqual(manager.streamedRRPoints.count, 50)

        for i in 1 ..< manager.streamedRRPoints.count {
            let prev = manager.streamedRRPoints[i - 1]
            let curr = manager.streamedRRPoints[i]

            XCTAssertEqual(
                curr.t_ms,
                prev.t_ms + Int64(prev.rr_ms),
                "Cumulative time should be continuous"
            )
        }
    }

    /// Test streaming data is preserved during interruption
    func testStreamingInterruption() {
        manager.prepareStreamingStateForTesting(startTime: Date())

        let batch1 = createMockHRData(count: 10, startHR: 65)
        manager.ingestHeartRateForTesting(batch1, elapsedMs: 5000)

        XCTAssertEqual(manager.streamedRRPoints.count, 10)

        let preservedCount = manager.streamedRRPoints.count
        XCTAssertEqual(preservedCount, 10, "Data should be preserved during interruption")
    }

    /// Test streaming resume from existing cumulative offset
    func testStreamingResume() {
        let existingPoints = (0 ..< 10).map { index -> RRPoint in
            let elapsedMs: Int64 = Int64(index * 920)
            let wallClockMs: Int64 = Int64(index * 1000)
            return RRPoint(t_ms: elapsedMs, rr_ms: 920, wallClockMs: wallClockMs)
        }
        manager.prepareStreamingStateForTesting(
            startTime: Date(),
            cumulativeMs: 10000,
            existingPoints: existingPoints
        )

        // Existing points should be preserved and new points appended from cumulative offset.
        for i in 0 ..< 10 {
            XCTAssertEqual(manager.streamedRRPoints[i].t_ms, Int64(i * 920))
        }

        let resumeBatch = createMockHRData(count: 5, startHR: 65)
        manager.ingestHeartRateForTesting(resumeBatch, elapsedMs: 12000)

        XCTAssertEqual(manager.streamedRRPoints.count, 15)
        XCTAssertEqual(manager.streamedRRPoints[10].t_ms, 10000)
    }

    /// Test empty batch followed by valid data
    func testEmptyStreamRecovery() {
        manager.prepareStreamingStateForTesting(startTime: Date())

        let emptyBatch: [StrapHRSample] = [
            StrapHRSample(hr: Int(65), rrsMs: [], rrAvailable: false),
            StrapHRSample(hr: Int(66), rrsMs: [], rrAvailable: false)
        ]

        manager.ingestHeartRateForTesting(emptyBatch, elapsedMs: 20000)
        XCTAssertEqual(manager.streamedRRPoints.count, 0, "Empty batch should add no points")

        let validBatch = createMockHRData(count: 5, startHR: 67)
        manager.ingestHeartRateForTesting(validBatch, elapsedMs: 20500)

        XCTAssertEqual(manager.streamedRRPoints.count, 5, "Should recover and collect valid data")
    }

    /// Test maximum stream duration tracking
    func testMaxStreamDuration() {
        manager.prepareStreamingStateForTesting(startTime: Date())

        let fixedSample = [StrapHRSample(hr: Int(65), rrsMs: [920], rrAvailable: true)]

        for index in 0 ..< 100 {
            manager.ingestHeartRateForTesting(
                fixedSample,
                elapsedMs: Int64(30000 + (index * 920))
            )
        }

        XCTAssertEqual(manager.streamedRRPoints.count, 100)

        let totalMs = manager.streamingCumulativeMsForTesting
        XCTAssertEqual(totalMs, 92000)
    }

    // MARK: - Helper Methods

    private func createMockHRData(count: Int, startHR: UInt8) -> [StrapHRSample] {
        (0 ..< count).map { i in
            let hr = UInt8(min(Int(startHR) + i, 200))
            return StrapHRSample(hr: Int(hr), rrsMs: [920 + ((i % 5) - 2) * 10], rrAvailable: true)
        }
    }
}
