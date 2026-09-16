import CoreBluetooth
@testable import Emuqu
import XCTest

/// Tests for PolarManager - BLE connection and streaming
@MainActor
final class PolarManagerTests: XCTestCase {
    // MARK: - RR Data Extraction Tests

    /// Test that RR intervals are correctly extracted when rrAvailable is true
    func testRRDataExtractionWhenAvailable() {
        // This tests the bug we just fixed!
        let manager = PolarManager()

        // Simulate starting streaming to initialize state
        manager.prepareStreamingStateForTesting()

        // Create mock HR data with RR intervals available
        let mockSample = StrapHRSample(hr: 65, rrsMs: [920, 940, 930, 910], rrAvailable: true)

        let mockHrData: [StrapHRSample] = [mockSample]

        // Call the handler (this would be called by Polar SDK)
        manager.ingestHeartRate(mockHrData)

        // Verify RR intervals were extracted
        XCTAssertEqual(manager.streamedRRPoints.count, 4, "Should extract all 4 RR intervals")
        XCTAssertEqual(manager.streamedRRPoints[0].rr_ms, 920)
        XCTAssertEqual(manager.streamedRRPoints[1].rr_ms, 940)
        XCTAssertEqual(manager.streamedRRPoints[2].rr_ms, 930)
        XCTAssertEqual(manager.streamedRRPoints[3].rr_ms, 910)

        // Verify cumulative time is tracked
        let expectedCumulative: Int64 = 920 + 940 + 930 + 910
        XCTAssertEqual(manager.streamingCumulativeMsForTesting, expectedCumulative)
    }

    /// Test that RR intervals are skipped when rrAvailable is false
    func testRRDataSkippedWhenNotAvailable() {
        let manager = PolarManager()

        manager.prepareStreamingStateForTesting()

        // Create mock HR data WITHOUT RR intervals
        let mockSample = StrapHRSample(hr: 65, rrsMs: [], rrAvailable: false)

        let mockHrData: [StrapHRSample] = [mockSample]

        manager.ingestHeartRate(mockHrData)

        // Verify NO RR intervals were added
        XCTAssertEqual(manager.streamedRRPoints.count, 0, "Should not extract RR when rrAvailable is false")
        XCTAssertEqual(manager.streamingCumulativeMsForTesting, 0, "Cumulative time should remain 0")
    }

    /// Test handling multiple samples in a single batch
    func testMultipleSamplesInBatch() {
        let manager = PolarManager()

        manager.prepareStreamingStateForTesting()

        // Create multiple samples in one batch
        let sample1 = StrapHRSample(hr: 65, rrsMs: [920, 940], rrAvailable: true)

        let sample2 = StrapHRSample(hr: 66, rrsMs: [910], rrAvailable: true)

        let sample3 = StrapHRSample(hr: 67, rrsMs: [], rrAvailable: false)

        let mockHrData = [sample1, sample2, sample3]

        manager.ingestHeartRate(mockHrData)

        // Should extract RR from sample1 and sample2, skip sample3
        XCTAssertEqual(manager.streamedRRPoints.count, 3, "Should extract 2 + 1 + 0 = 3 RR intervals")
        XCTAssertEqual(manager.streamedRRPoints[0].rr_ms, 920)
        XCTAssertEqual(manager.streamedRRPoints[1].rr_ms, 940)
        XCTAssertEqual(manager.streamedRRPoints[2].rr_ms, 910)
    }

    /// Test that empty rrsMs array is handled correctly even when rrAvailable is true
    func testEmptyRRsMsArray() {
        let manager = PolarManager()

        manager.prepareStreamingStateForTesting()

        // Edge case: rrAvailable is true but array is empty
        let mockSample = StrapHRSample(hr: 65, rrsMs: [], rrAvailable: true)

        let mockHrData: [StrapHRSample] = [mockSample]

        // Should not crash
        XCTAssertNoThrow(manager.ingestHeartRate(mockHrData))

        // No RR intervals should be added
        XCTAssertEqual(manager.streamedRRPoints.count, 0)
    }

    /// Test cumulative time calculation across multiple calls
    func testCumulativeTimeTracking() {
        let manager = PolarManager()

        manager.prepareStreamingStateForTesting()

        // First batch
        let batch1 = [StrapHRSample(hr: 65, rrsMs: [1000, 1000], rrAvailable: true)]

        manager.ingestHeartRate(batch1)
        XCTAssertEqual(manager.streamingCumulativeMsForTesting, 2000)
        XCTAssertEqual(manager.streamedRRPoints.count, 2)

        // Second batch - cumulative should continue
        let batch2 = [StrapHRSample(hr: 65, rrsMs: [1000, 1000, 1000], rrAvailable: true)]

        manager.ingestHeartRate(batch2)
        XCTAssertEqual(manager.streamingCumulativeMsForTesting, 5000, "Cumulative time should be 5 seconds")
        XCTAssertEqual(manager.streamedRRPoints.count, 5, "Should have 5 total points")

        // Verify t_ms values are cumulative
        XCTAssertEqual(manager.streamedRRPoints[0].t_ms, 0)
        XCTAssertEqual(manager.streamedRRPoints[1].t_ms, 1000)
        XCTAssertEqual(manager.streamedRRPoints[2].t_ms, 2000)
        XCTAssertEqual(manager.streamedRRPoints[3].t_ms, 3000)
        XCTAssertEqual(manager.streamedRRPoints[4].t_ms, 4000)
    }

    /// Test wall clock time is captured
    func testWallClockTimeCapture() {
        let manager = PolarManager()

        manager.prepareStreamingStateForTesting(startTime: Date())

        let mockSample = StrapHRSample(hr: 65, rrsMs: [920], rrAvailable: true)

        let mockHrData: [StrapHRSample] = [mockSample]

        manager.ingestHeartRateForTesting(mockHrData, elapsedMs: 120)

        XCTAssertEqual(
            manager.streamedRRPoints[0].wallClockMs,
            120,
            "Wall clock time should match test override"
        )
    }

    /// Test realistic scenario: 2 minutes of continuous streaming
    func testRealisticTwoMinuteStream() {
        let manager = PolarManager()

        manager.prepareStreamingStateForTesting()

        // Simulate ~2 minutes at 65 bpm (130 beats)
        // Typical RR interval at 65 bpm is ~923ms
        let totalBeats = 130
        let avgRR = 923

        // Simulate receiving data in batches (Polar sends ~1 sample per second)
        var expectedCumulativeMs: Int64 = 0
        let variation = [-50, -25, 0, 25, 50]
        for beat in 0 ..< totalBeats {
            let rr = avgRR + variation[beat % variation.count]
            expectedCumulativeMs += Int64(rr)

            let mockSample = StrapHRSample(hr: 65, rrsMs: [rr], rrAvailable: true)

            let mockHrData: [StrapHRSample] = [mockSample]
            manager.ingestHeartRate(mockHrData)
        }

        // Verify we collected all beats
        XCTAssertEqual(manager.streamedRRPoints.count, 130, "Should collect 130 beats")

        // Verify total duration is approximately 2 minutes
        let totalDurationMs = manager.streamingCumulativeMsForTesting
        XCTAssertEqual(
            totalDurationMs,
            expectedCumulativeMs,
            "Total duration should match deterministic RR stream"
        )
    }

    func testBatteryCallbackIgnoresNonConnectedDevice() {
        let manager = PolarManager()
        manager.setConnectedDeviceForTesting(id: "ACTIVE-DEVICE", type: .h10)

        manager.link.apply(.battery(deviceId: "OTHER-DEVICE", level: 42))
        XCTAssertNil(manager.batteryLevel, "Battery should ignore callbacks from non-active device IDs")

        manager.link.apply(.battery(deviceId: "ACTIVE-DEVICE", level: 88))
        XCTAssertEqual(manager.batteryLevel, 88, "Battery should update for the active device")
    }

    func testBatteryCallbackIgnoresInvalidPercentageValues() {
        let manager = PolarManager()
        manager.setConnectedDeviceForTesting(id: "ACTIVE-DEVICE", type: .h10)

        manager.link.apply(.battery(deviceId: "ACTIVE-DEVICE", level: 84))
        XCTAssertEqual(manager.batteryLevel, 84, "Valid battery percentages should be published")

        manager.link.apply(.battery(deviceId: "ACTIVE-DEVICE", level: 255))
        XCTAssertEqual(manager.batteryLevel, 84, "Out-of-range battery callbacks should be ignored")

        let managerWithOnlyInvalidValue = PolarManager()
        managerWithOnlyInvalidValue.setConnectedDeviceForTesting(id: "ACTIVE-DEVICE", type: .h10)
        managerWithOnlyInvalidValue.link.apply(.battery(deviceId: "ACTIVE-DEVICE", level: 200))
        XCTAssertNil(managerWithOnlyInvalidValue.batteryLevel, "Invalid first callback should not fake a percentage")
    }

    func testFirmwareCallbackIgnoresNonConnectedDevice() {
        let manager = PolarManager()
        manager.setConnectedDeviceForTesting(id: "ACTIVE-DEVICE", type: .h10)
        let firmwareUUID = CBUUID(string: "2A26")

        manager.link.apply(.deviceInformation(deviceId: "OTHER-DEVICE", uuid: firmwareUUID.uuidString, value: "5.1.0"))
        XCTAssertNil(manager.firmwareVersion, "Firmware should ignore callbacks from non-active device IDs")

        manager.link.apply(.deviceInformation(deviceId: "ACTIVE-DEVICE", uuid: firmwareUUID.uuidString, value: "5.1.0"))
        XCTAssertEqual(manager.firmwareVersion, "5.1.0", "Firmware should update for the active device")
    }

    func testFirmwareCallbackIgnoresNonFirmwareCharacteristic() {
        let manager = PolarManager()
        manager.setConnectedDeviceForTesting(id: "ACTIVE-DEVICE", type: .h10)
        manager.link.apply(.deviceInformation(deviceId: "ACTIVE-DEVICE", uuid: "2A29", value: "ACME"))
        XCTAssertNil(manager.firmwareVersion, "Only 2A26/2A28 revision characteristics should update firmwareVersion")
    }

    func testSoftwareRevisionOverridesFirmwareRevision() {
        let manager = PolarManager()
        manager.setConnectedDeviceForTesting(id: "ACTIVE-DEVICE", type: .h10)

        manager.link.apply(.deviceInformation(deviceId: "ACTIVE-DEVICE", uuid: "2A26", value: "5.0.0"))
        XCTAssertEqual(manager.firmwareVersion, "5.0.0", "Firmware revision should be used as fallback when no software revision exists")

        manager.link.apply(.deviceInformation(deviceId: "ACTIVE-DEVICE", uuid: "2A28", value: "4.1.10"))
        XCTAssertEqual(manager.firmwareVersion, "4.1.10", "Software revision should replace fallback firmware revision")

        manager.link.apply(.deviceInformation(deviceId: "ACTIVE-DEVICE", uuid: "2A26", value: "5.0.1"))
        XCTAssertEqual(manager.firmwareVersion, "4.1.10", "Software revision should remain authoritative once received")
    }

    func testSoftwareRevisionCanArriveViaStringKeyCallback() {
        let manager = PolarManager()
        manager.setConnectedDeviceForTesting(id: "ACTIVE-DEVICE", type: .h10)

        manager.link.apply(.deviceInformationKey(deviceId: "ACTIVE-DEVICE", key: "2a28", value: "4.1.10"))
        XCTAssertEqual(manager.firmwareVersion, "4.1.10", "String-key callback should update displayed firmware from software revision")
    }
}
