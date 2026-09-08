import Compression
import Foundation

/// Lightweight gzip-style compression using Apple's Compression framework
/// Used to compress HRV session JSON before uploading as CKAsset
enum DataCompression {
    enum CompressionError: Error, LocalizedError {
        case compressionFailed
        case decompressionFailed
        case invalidBufferPointer

        var errorDescription: String? {
            switch self {
            case .compressionFailed:
                "Failed to compress session data for upload."
            case .decompressionFailed:
                "Failed to decompress downloaded session data."
            case .invalidBufferPointer:
                "Internal error: could not access data buffer."
            }
        }
    }

    /// Compress data using ZLIB algorithm
    /// Typical compression ratio for JSON: 80-90% size reduction
    static func compress(_ data: Data) throws -> Data {
        let sourceSize = data.count
        // Allocate destination buffer larger than source to handle incompressible data.
        // compression_encode_buffer returns 0 if the buffer is too small.
        let destinationSize = max(sourceSize + 512, sourceSize * 2)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
        defer { destinationBuffer.deallocate() }
        let compressedSize = try withSourcePointer(data) { sourcePointer in
            compression_encode_buffer(
                destinationBuffer, destinationSize,
                sourcePointer, sourceSize,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard compressedSize > 0 else {
            throw CompressionError.compressionFailed
        }
        return Data(bytes: destinationBuffer, count: compressedSize)
    }

    /// Run `body` against the data's raw bytes, throwing rather than trapping
    /// when the buffer has no base address (an empty `Data`).
    private static func withSourcePointer(
        _ data: Data, _ body: (UnsafePointer<UInt8>) -> Int
    ) throws -> Int {
        try data.withUnsafeBytes { sourceBytes -> Int in
            guard let sourcePointer = sourceBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw CompressionError.invalidBufferPointer
            }
            return body(sourcePointer)
        }
    }

    /// Decompress ZLIB-compressed data
    /// Grows the buffer dynamically until decompressed output fits without truncation
    static func decompress(_ data: Data) throws -> Data {
        let sourceSize = data.count
        // Start at 16x (covers typical JSON compression ratios), double on each retry
        var destinationSize = sourceSize * 16
        let maxDestinationSize = sourceSize * 1024 // Safety cap: 1024x original size
        while destinationSize <= maxDestinationSize {
            if let decompressed = try decodeOnce(data, sourceSize: sourceSize, destinationSize: destinationSize) {
                return decompressed
            }
            // Buffer was fully filled — likely truncated; grow and retry
            destinationSize *= 2
        }
        throw CompressionError.decompressionFailed
    }

    /// One decode attempt at a fixed buffer size. Nil means the output filled
    /// the buffer exactly, which usually means it was truncated — the caller
    /// grows the buffer and retries.
    private static func decodeOnce(
        _ data: Data, sourceSize: Int, destinationSize: Int
    ) throws -> Data? {
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)
        defer { destinationBuffer.deallocate() }
        let decompressedSize = try withSourcePointer(data) { sourcePointer in
            compression_decode_buffer(
                destinationBuffer, destinationSize,
                sourcePointer, sourceSize,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard decompressedSize > 0 else {
            throw CompressionError.decompressionFailed
        }
        guard decompressedSize < destinationSize else { return nil }
        return Data(bytes: destinationBuffer, count: decompressedSize)
    }
}
