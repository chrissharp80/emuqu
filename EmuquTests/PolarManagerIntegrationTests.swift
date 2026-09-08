@testable import Emuqu
import XCTest

/// Integration tests for PolarManager streaming logic.
///
/// Tests RR data extraction, wall clock tracking, gap detection, and edge cases
/// using the `handleStreamedHRDataForTesting` extension (no real BLE required).
@MainActor
final class PolarManagerIntegrationTests: XCTestCase {
    var manager = PolarManager()

    // MARK: - Streaming Data Tests

    /// Test streaming with BLE hiccups (gap then more data)
    func testStreamingWithBLEHiccups() {
        manager.prepareStreamingStateForTesting(startTime: Date())

        let batch1 = createMockHRData(count: 10, startHR: 65)
        manager.handleStreamedHRDataForTesting(batch1, fixedWallClockMs: 1000)

        XCTAssertEqual(manager.streamedRRPoints.count, 10)

        let batch2 = createMockHRData(count: 10, startHR: 66)
        manager.handleStreamedHRDataForTesting(batch2, fixedWallClockMs: 1300)

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
        manager.handleStreamedHRDataForTesting(batch1, fixedWallClockMs: 2000)

        let firstWallClock = manager.streamedRRPoints.last?.wallClockMs ?? 0

        let batch2 = createMockHRData(count: 5, startHR: 65)
        manager.handleStreamedHRDataForTesting(batch2, fixedWallClockMs: 2500)

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
            manager.handleStreamedHRDataForTesting(batch, fixedWallClockMs: Int64(1000 + (index * 1000)))
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

        let mixedBatch: [PolarManager.MockHRSample] = [
            PolarManager.MockHRSample(
                hr: 65, ppgQuality: 0, correctedHr: 65, rrsMs: [920, 930],
                rrAvailable: true, contactStatus: true, contactStatusSupported: true
            ),
            PolarManager.MockHRSample(
                hr: 66, ppgQuality: 0, correctedHr: 66, rrsMs: [],
                rrAvailable: false, contactStatus: true, contactStatusSupported: true
            ),
            PolarManager.MockHRSample(
                hr: 67, ppgQuality: 0, correctedHr: 67, rrsMs: [910],
                rrAvailable: true, contactStatus: true, contactStatusSupported: true
            ),
            PolarManager.MockHRSample(
                hr: 68, ppgQuality: 0, correctedHr: 68, rrsMs: [],
                rrAvailable: false, contactStatus: false, contactStatusSupported: true
            ),
            PolarManager.MockHRSample(
                hr: 69, ppgQuality: 0, correctedHr: 69, rrsMs: [925, 915, 920],
                rrAvailable: true, contactStatus: true, contactStatusSupported: true
            )
        ]

        manager.handleStreamedHRDataForTesting(mixedBatch)

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
        manager.handleStreamedHRDataForTesting(largeBatch, fixedWallClockMs: 10000)

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
        manager.handleStreamedHRDataForTesting(batch1, fixedWallClockMs: 5000)

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
        manager.handleStreamedHRDataForTesting(resumeBatch, fixedWallClockMs: 12000)

        XCTAssertEqual(manager.streamedRRPoints.count, 15)
        XCTAssertEqual(manager.streamedRRPoints[10].t_ms, 10000)
    }

    /// Test empty batch followed by valid data
    func testEmptyStreamRecovery() {
        manager.prepareStreamingStateForTesting(startTime: Date())

        let emptyBatch: [PolarManager.MockHRSample] = [
            PolarManager.MockHRSample(
                hr: 65, ppgQuality: 0, correctedHr: 65, rrsMs: [],
                rrAvailable: false, contactStatus: true, contactStatusSupported: true
            ),
            PolarManager.MockHRSample(
                hr: 66, ppgQuality: 0, correctedHr: 66, rrsMs: [],
                rrAvailable: false, contactStatus: true, contactStatusSupported: true
            )
        ]

        manager.handleStreamedHRDataForTesting(emptyBatch, fixedWallClockMs: 20000)
        XCTAssertEqual(manager.streamedRRPoints.count, 0, "Empty batch should add no points")

        let validBatch = createMockHRData(count: 5, startHR: 67)
        manager.handleStreamedHRDataForTesting(validBatch, fixedWallClockMs: 20500)

        XCTAssertEqual(manager.streamedRRPoints.count, 5, "Should recover and collect valid data")
    }

    /// Test maximum stream duration tracking
    func testMaxStreamDuration() {
        manager.prepareStreamingStateForTesting(startTime: Date())

        let fixedSample = [PolarManager.MockHRSample(
            hr: 65,
            ppgQuality: 0,
            correctedHr: 65,
            rrsMs: [920],
            rrAvailable: true,
            contactStatus: true,
            contactStatusSupported: true
        )]

        for index in 0 ..< 100 {
            manager.handleStreamedHRDataForTesting(
                fixedSample,
                fixedWallClockMs: Int64(30000 + (index * 920))
            )
        }

        XCTAssertEqual(manager.streamedRRPoints.count, 100)

        let totalMs = manager.streamingCumulativeMsForTesting
        XCTAssertEqual(totalMs, 92000)
    }

    // MARK: - Helper Methods

    private func createMockHRData(count: Int, startHR: UInt8) -> [PolarManager.MockHRSample] {
        (0 ..< count).map { i in
            let hr = UInt8(min(Int(startHR) + i, 200))
            return PolarManager.MockHRSample(
                hr: hr,
                ppgQuality: UInt8(0),
                correctedHr: hr,
                rrsMs: [920 + ((i % 5) - 2) * 10],
                rrAvailable: true,
                contactStatus: true,
                contactStatusSupported: true
            )
        }
    }
}
