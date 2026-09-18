import Foundation

/// The Bluetooth SIG Heart Rate Measurement characteristic (0x2A37), decoded.
///
/// Every heart-rate strap publishes live heart rate this way; the H10 carries
/// its beat-to-beat intervals in it too (a Verity Sense's come from its PPI
/// stream, through the SDK). The app reads it directly
/// (`StandardHeartRateLink`) rather than through the Polar SDK, so the decoding
/// is written out here — and written to produce exactly what the SDK produced
/// for the same bytes (`BleHrClient.processServiceData`): the same flag
/// handling and the same rounding of each 1/1024 s interval to whole
/// milliseconds. An interval that came out a millisecond different would move
/// every HRV figure computed from it, and a night recorded after this change
/// must be comparable with the nights before it.
///
/// Layout:
///   - byte 0: flags — bit 0 rate width (8/16-bit), bit 3 energy expended
///     present, bit 4 RR intervals present
///   - the rate, 1 or 2 bytes little-endian
///   - energy expended, 2 bytes, when flagged (unused here)
///   - RR intervals, 2 bytes each little-endian, in 1/1024 s, when flagged
enum HeartRateMeasurement {
    /// The sample one notification carries, or nil for a packet too short to
    /// hold what its flags declare — the SDK dropped those too.
    static func parse(_ data: Data) -> StrapHRSample? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let flags = bytes[0]
        let wideRate = flags & 0x01 != 0
        guard !wideRate || bytes.count >= 3 else { return nil }
        let hr = wideRate ? Int(bytes[1]) | (Int(bytes[2]) << 8) : Int(bytes[1])
        var offset = wideRate ? 3 : 2
        if flags & 0x08 != 0 {
            guard offset + 2 <= bytes.count else { return nil }
            offset += 2
        }
        let rrPresent = flags & 0x10 != 0
        let rrsMs = rrPresent ? intervals(in: bytes, from: offset) : []
        return StrapHRSample(hr: hr, rrsMs: rrsMs, rrAvailable: rrPresent)
    }

    /// Each 1/1024 s interval in whole milliseconds, rounded as the SDK rounds.
    private static func intervals(in bytes: [UInt8], from start: Int) -> [Int] {
        var result: [Int] = []
        var offset = start
        while offset + 1 < bytes.count {
            let raw = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            result.append(Int((Float(raw) / 1024.0 * 1000.0).rounded()))
            offset += 2
        }
        return result
    }
}
