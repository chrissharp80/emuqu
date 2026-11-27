import Foundation

/// The lines of a server-sent event stream, split the way the SSE format
/// defines them: at CR LF, LF or CR, and nowhere else. Foundation's
/// `AsyncLineSequence` also ends a line at U+0085, U+2028 and U+2029, which
/// JSON allows unescaped inside a string, so a model's reply holding one of
/// them arrived as a `data:` line cut in two: the second half did not start
/// with `data:`, was skipped, and the event's JSON never closed. Blank lines
/// are passed on, since they end an event.
struct SSELines<Bytes: AsyncSequence>: AsyncSequence where Bytes.Element == UInt8 {
    typealias Element = String

    let bytes: Bytes

    init(_ bytes: Bytes) {
        self.bytes = bytes
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(bytes: bytes.makeAsyncIterator())
    }

    struct Iterator: AsyncIteratorProtocol {
        var bytes: Bytes.AsyncIterator
        var buffer: [UInt8] = []
        /// The previous byte was a CR, so an LF right after it ends nothing.
        var afterCR = false
        var finished = false

        mutating func next() async throws -> String? {
            while !finished, let byte = try await bytes.next() {
                if let line = take(byte) { return line }
            }
            finished = true
            guard !buffer.isEmpty else { return nil }
            defer { buffer.removeAll() }
            return Self.decoded(buffer)
        }

        /// Adds `byte` to the line being read, or ends the line on CR / LF.
        private mutating func take(_ byte: UInt8) -> String? {
            let wasAfterCR = afterCR
            afterCR = byte == 0x0D
            if byte == 0x0A, wasAfterCR { return nil }
            guard byte == 0x0A || byte == 0x0D else {
                buffer.append(byte)
                return nil
            }
            defer { buffer.removeAll(keepingCapacity: true) }
            return Self.decoded(buffer)
        }

        /// The line as text. A line that is not UTF-8 reads as a replacement
        /// character: not blank (a blank line would end the event) and not a
        /// `data:` line, so it is skipped like any other unknown line.
        private static func decoded(_ line: [UInt8]) -> String {
            String(bytes: line, encoding: .utf8) ?? "\u{FFFD}"
        }
    }
}
