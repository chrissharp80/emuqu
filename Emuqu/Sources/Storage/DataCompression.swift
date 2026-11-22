import Compression
import Foundation

/// Lightweight gzip-style compression using Apple's Compression framework
/// Used to compress HRV session JSON before uploading as CKAsset
enum DataCompression {
    enum CompressionError: Error, LocalizedError {
        case compressionFailed
        case decompressionFailed
        case invalidBufferPointer

        /// Reaches Settings through the sync error line, so it is localized.
        var errorDescription: String? {
            let bundle = LanguageManager.appBundle
            return switch self {
            case .compressionFailed:
                String(localized: "Failed to compress session data for upload.", bundle: bundle)
            case .decompressionFailed:
                String(localized: "Failed to decompress downloaded session data.", bundle: bundle)
            case .invalidBufferPointer:
                String(localized: "Internal error: could not access data buffer.", bundle: bundle)
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

    /// The most any payload may decompress to. A long night, or a long
    /// workout with its GPS track and per-second rows, is a few megabytes of
    /// JSON; the ratio cap alone let a 1.5 MB, highly compressible payload ask
    /// for a 1.5 GB buffer, enough to have the app killed mid-pull.
    static let maxDecompressedSize = 128 * 1024 * 1024

    /// Decompress ZLIB-compressed data
    /// Grows the buffer dynamically until decompressed output fits without
    /// truncation, up to 1024x the input and never past `maxDecompressedSize`;
    /// output that does not fit by then throws.
    static func decompress(_ data: Data) throws -> Data {
        let sourceSize = data.count
        let maxDestinationSize = min(sourceSize * 1024, maxDecompressedSize) // Safety cap
        // Start at 16x (covers typical JSON compression ratios), double on each retry
        var destinationSize = min(sourceSize * 16, maxDestinationSize)
        while true {
            if let decompressed = try decodeOnce(data, sourceSize: sourceSize, destinationSize: destinationSize) {
                return decompressed
            }
            // Buffer was fully filled — likely truncated; grow and retry
            guard destinationSize < maxDestinationSize else { throw CompressionError.decompressionFailed }
            destinationSize = min(destinationSize * 2, maxDestinationSize)
        }
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
