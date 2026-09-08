@testable import Emuqu
import XCTest

final class DataCompressionTests: XCTestCase {
    // MARK: - Roundtrip

    func testCompressDecompressRoundtrip() throws {
        let original = Data("Hello, Emuqu! This is test data for compression.".utf8)
        let compressed = try DataCompression.compress(original)
        let decompressed = try DataCompression.decompress(compressed)
        XCTAssertEqual(decompressed, original)
    }

    func testLargeDataRoundtrip() throws {
        // Simulate a JSON session blob (~10KB of repetitive data)
        let repeatedJSON = String(repeating: "{\"rr_ms\":800,\"t_ms\":12345678},", count: 500)
        let original = try XCTUnwrap(repeatedJSON.data(using: .utf8))

        let compressed = try DataCompression.compress(original)
        let decompressed = try DataCompression.decompress(compressed)

        XCTAssertEqual(decompressed, original)
    }

    // MARK: - Compression Ratio

    func testCompressionReducesSize() throws {
        // Repetitive JSON should compress well (80-90% reduction)
        let json = String(repeating: "{\"heartRate\":72,\"timestamp\":\"2026-01-01T00:00:00Z\"},", count: 200)
        let original = try XCTUnwrap(json.data(using: .utf8))

        let compressed = try DataCompression.compress(original)

        XCTAssertLessThan(
            compressed.count,
            original.count,
            "Compressed should be smaller than original"
        )

        let ratio = Double(compressed.count) / Double(original.count)
        XCTAssertLessThan(
            ratio,
            0.3,
            "Repetitive JSON should compress to <30% of original. Got \(ratio * 100)%"
        )
    }

    // MARK: - Edge Cases

    func testEmptyData() {
        let empty = Data()
        // Empty data may either throw or produce a valid compressed header
        // depending on the platform's compression_encode_buffer behavior.
        // Either outcome is acceptable — what matters is no crash.
        do {
            let compressed = try DataCompression.compress(empty)
            XCTAssertFalse(compressed.isEmpty, "If compression succeeds, result should not be empty")
        } catch {
            XCTAssertTrue(error is DataCompression.CompressionError)
        }
    }

    func testSingleByte() throws {
        let single = Data([0x42])
        let compressed = try DataCompression.compress(single)
        let decompressed = try DataCompression.decompress(compressed)
        XCTAssertEqual(decompressed, single)
    }

    func testBinaryData() throws {
        var bytes = [UInt8](repeating: 0, count: 1024)
        for i in 0 ..< bytes.count {
            bytes[i] = UInt8(i % 256)
        }
        let original = Data(bytes)

        let compressed = try DataCompression.compress(original)
        let decompressed = try DataCompression.decompress(compressed)

        XCTAssertEqual(decompressed, original)
    }

    // MARK: - Invalid Data

    func testDecompressInvalidData() throws {
        let garbage = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB])
        XCTAssertThrowsError(try DataCompression.decompress(garbage))
    }

    // MARK: - Error Descriptions

    func testCompressionErrorDescriptions() {
        XCTAssertNotNil(DataCompression.CompressionError.compressionFailed.errorDescription)
        XCTAssertNotNil(DataCompression.CompressionError.decompressionFailed.errorDescription)
        XCTAssertNotNil(DataCompression.CompressionError.invalidBufferPointer.errorDescription)
    }
}
