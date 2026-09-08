@testable import Emuqu
import os
import XCTest

/// Tests for morning-feeling tag decoding.
///
/// The source carries a "CRITICAL"
/// note: a malformed archive entry — anything other than a string in the tags
/// array — could spin `decodeTags` forever, hanging the archive load until the
/// watchdog killed the app. The loop advances the container explicitly and
/// bails if it ever fails to, and those are the guards pinned here.
///
/// Every decode runs under a watchdog so a regression FAILS rather than hanging
/// the whole suite.
final class MorningFeelingTagCodecTests: XCTestCase {
    /// Decode with a hard time limit. A hang is the defect this file exists to
    /// catch, so it must surface as a failure, not a stalled test run.
    private func decode(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> [MorningFeelingTag]? {
        let data = Data(json.utf8)
        let done = XCTestExpectation(description: "decode completed")
        let out = OSAllocatedUnfairLock<[MorningFeelingTag]?>(initialState: nil)
        Thread.detachNewThread {
            let decoded = try? JSONDecoder().decode(MorningFeelingTagArray.self, from: data).tags
            out.withLock { $0 = decoded }
            done.fulfill()
        }
        if XCTWaiter().wait(for: [done], timeout: 5) != .completed {
            XCTFail("decode did not finish within 5s — the container stopped advancing", file: file, line: line)
            return nil
        }
        return out.withLock { $0 }
    }

    // MARK: - Well-formed input

    func testValidTagsDecode() {
        let raw = MorningFeelingTag.allCases.prefix(3).map(\.rawValue)
        let json = "[" + raw.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        XCTAssertEqual(decode(json)?.count, raw.count)
    }

    func testEmptyArrayDecodes() {
        XCTAssertEqual(decode("[]")?.count, 0)
    }

    // MARK: - Malformed input must degrade, not hang

    func testNumbersInTheArrayAreSkipped() {
        // The exact shape called out as CRITICAL: a non-string element.
        guard let first = MorningFeelingTag.allCases.first else { return XCTFail("no tags defined") }
        let result = decode("[\"\(first.rawValue)\", 42, \"\(first.rawValue)\"]")
        XCTAssertEqual(result?.count, 2, "the number is dropped, the strings survive")
    }

    func testNestedObjectsAreSkipped() {
        guard let first = MorningFeelingTag.allCases.first else { return XCTFail("no tags defined") }
        let result = decode("[{\"a\":1}, \"\(first.rawValue)\"]")
        XCTAssertEqual(result?.count, 1)
    }

    func testNestedArraysAreSkipped() {
        guard let first = MorningFeelingTag.allCases.first else { return XCTFail("no tags defined") }
        XCTAssertEqual(decode("[[1,2,3], \"\(first.rawValue)\"]")?.count, 1)
    }

    func testNullsAreSkipped() {
        guard let first = MorningFeelingTag.allCases.first else { return XCTFail("no tags defined") }
        XCTAssertEqual(decode("[null, \"\(first.rawValue)\", null]")?.count, 1)
    }

    func testUnknownTagStringsAreSkipped() {
        // A tag written by a newer build than this one. Dropping it is correct;
        // failing the whole archive load is not.
        XCTAssertEqual(decode("[\"not_a_real_tag\"]")?.count, 0)
    }

    func testArrayOfOnlyGarbageDecodesToNothing() {
        XCTAssertEqual(decode("[1, 2, {\"x\":true}, null, [9]]")?.count, 0)
    }

    // MARK: - Round trip

    func testEncodeDecodeRoundTrips() throws {
        let tags = Array(MorningFeelingTag.allCases.prefix(4))
        let data = try JSONEncoder().encode(MorningFeelingTagArray(tags))
        let back = try JSONDecoder().decode(MorningFeelingTagArray.self, from: data)
        XCTAssertEqual(back.tags, tags)
    }
}
