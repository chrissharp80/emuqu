@testable import Emuqu
import XCTest

/// Decoding the Heart Rate Measurement characteristic the app now reads
/// directly.
///
/// The beats used to come through the Polar SDK's decoder. They must come out
/// of this one identically — the same rate, the same intervals to the
/// millisecond — or every HRV figure recorded after the switch would shift
/// against the history it is compared with. Two of these packets are real ones
/// the H10 sent, copied from a field log.
final class HeartRateMeasurementTests: XCTestCase {
    private func parse(_ bytes: [UInt8]) -> StrapHRSample? {
        HeartRateMeasurement.parse(Data(bytes))
    }

    // MARK: - Real H10 packets, copied from a field log

    /// `0x104952036403`: RR present, 73 bpm, intervals 850 and 868 (1/1024 s).
    func testAnH10PacketDecodesToItsRateAndIntervals() {
        XCTAssertEqual(parse([0x10, 0x49, 0x52, 0x03, 0x64, 0x03]),
                       StrapHRSample(hr: 73, rrsMs: [830, 848], rrAvailable: true))
    }

    /// `0x104642033b03`: 70 bpm, intervals 834 and 827 (1/1024 s).
    func testASecondH10PacketDecodesToItsRateAndIntervals() {
        XCTAssertEqual(parse([0x10, 0x46, 0x42, 0x03, 0x3B, 0x03]),
                       StrapHRSample(hr: 70, rrsMs: [814, 808], rrAvailable: true))
    }

    // MARK: - The SDK's rounding

    /// Whole milliseconds, rounded to nearest — the SDK's `mapRr1024ToRrMs`.
    func testIntervalsRoundToTheNearestMillisecondAsTheSDKDid() {
        XCTAssertEqual(parse([0x10, 60, 0x00, 0x04])?.rrsMs, [1_000]) // 1024 → 1000.0
        XCTAssertEqual(parse([0x10, 60, 0x00, 0x02])?.rrsMs, [500]) // 512 → 500.0
        XCTAssertEqual(parse([0x10, 60, 0x01, 0x00])?.rrsMs, [1]) // 1 → 0.98
        XCTAssertEqual(parse([0x10, 60, 0xFF, 0x03])?.rrsMs, [999]) // 1023 → 999.02
    }

    // MARK: - Field layout

    func testASixteenBitRateIsReadLittleEndian() {
        XCTAssertEqual(parse([0x11, 0x2C, 0x01, 0x00, 0x04])?.hr, 300)
    }

    func testEnergyExpendedIsSkippedBeforeTheIntervals() {
        XCTAssertEqual(parse([0x18, 60, 0xAA, 0xBB, 0x00, 0x04]),
                       StrapHRSample(hr: 60, rrsMs: [1_000], rrAvailable: true))
    }

    /// No RR flag: a rate and no intervals — the Verity between sessions.
    func testAPacketWithoutIntervalsSaysSo() {
        XCTAssertEqual(parse([0x00, 64]), StrapHRSample(hr: 64, rrsMs: [], rrAvailable: false))
    }

    /// A trailing odd byte is not half an interval.
    func testATrailingOddByteIsIgnored() {
        XCTAssertEqual(parse([0x10, 60, 0x00, 0x04, 0x07])?.rrsMs, [1_000])
    }

    // MARK: - Short packets are dropped, as the SDK dropped them

    func testPacketsTooShortForWhatTheirFlagsDeclareAreDropped() {
        XCTAssertNil(parse([]))
        XCTAssertNil(parse([0x10]))
        XCTAssertNil(parse([0x01, 60])) // 16-bit rate needs a third byte
        XCTAssertNil(parse([0x08, 60, 0x00])) // energy flagged, one byte short
    }
}
