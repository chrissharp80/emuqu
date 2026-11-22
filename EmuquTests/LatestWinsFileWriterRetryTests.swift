@testable import Emuqu
import os
import XCTest

/// A failed write of the route library or contact book is retried instead of
/// dropped, and a purge in the meantime is never undone by the retry. The
/// seal is a test closure that passes bytes through (no keychain) and fails
/// the first `failures` calls.
final class LatestWinsFileWriterRetryTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LatestWinsFileWriterRetryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Passes bytes through unsealed, throwing on the first `failures` calls.
    private func flakySeal(failures: Int) -> JSONFileSeal {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        return JSONFileSeal(
            seal: { data in
                let call = calls.withLock { count -> Int in
                    count += 1
                    return count
                }
                guard call > failures else { throw CocoaError(.fileWriteUnknown) }
                return data
            },
            open: { $0 }
        )
    }

    /// Polls `condition` for up to five seconds; the writer works on its own
    /// queue, so blocking this thread does not hold it up.
    private func waitUntil(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("Timed out waiting for \(what)", file: file, line: line)
    }

    func testAFailedWriteIsRetriedUntilItLands() throws {
        let url = try makeDirectory().appendingPathComponent("routes.json")
        let writer = LatestWinsFileWriter<[String]>(
            url: url, options: [.atomic], label: "retryTest", retryDelays: [0.05, 0.05], seal: flakySeal(failures: 2)
        )

        writer.enqueue(["Loop"])

        waitUntil("the retried write") { FileManager.default.fileExists(atPath: url.path) }
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)), ["Loop"])
    }

    func testADiscardStopsTheRetryOfAFailedWrite() throws {
        let url = try makeDirectory().appendingPathComponent("routes.json")
        let writer = LatestWinsFileWriter<[String]>(
            url: url, options: [.atomic], label: "retryTest", retryDelays: [0.4], seal: flakySeal(failures: 1)
        )

        writer.enqueue(["Loop"])
        Thread.sleep(forTimeInterval: 0.1) // the first write has failed and the retry waits
        writer.discard()

        Thread.sleep(forTimeInterval: 0.6) // past the retry delay
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "A purge must not be written back by a retry")
    }
}
