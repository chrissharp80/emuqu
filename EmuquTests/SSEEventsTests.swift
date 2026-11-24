@testable import Emuqu
import XCTest

/// The event reader every cloud provider shares: an event is its `data:`
/// lines joined, whether or not the line reader passes the blank lines on.
final class SSEEventsTests: XCTestCase {
    private func events(_ lines: [String]) async throws -> [SSEEvent] {
        var read: [SSEEvent] = []
        for try await event in SSEEvents(SSEReplay.lines(lines)) { read.append(event) }
        return read
    }

    /// One JSON value written over several `data:` lines is one event.
    func testAValueOverSeveralDataLinesIsOneEvent() async throws {
        let read = try await events(["event: delta", "data: {\"text\":", "data: \"Slept well.\"}", "", "data: [DONE]"])
        XCTAssertEqual(read, [SSEEvent(name: "delta", data: "{\"text\":\n\"Slept well.\"}"), SSEEvent(name: nil, data: "[DONE]")])
    }

    /// A reader that drops the blank lines still yields each event as soon
    /// as its value is whole, not when the next one starts.
    func testEventsWithoutBlankLinesAreEachTheirOwn() async throws {
        let read = try await events(["data: {\"a\":1}", "data: {\"b\":2}", "data: [DONE]"])
        XCTAssertEqual(read.map(\.data), ["{\"a\":1}", "{\"b\":2}", "[DONE]"])
    }

    /// A line inside a value that is a value on its own does not end the
    /// event early.
    func testALineThatIsAValueOnItsOwnStaysInsideTheEvent() async throws {
        let read = try await events(["data: {\"text\":", "data: \"Slept well.\"", "data: }"])
        XCTAssertEqual(read.map(\.data), ["{\"text\":\n\"Slept well.\"\n}"])
    }

    /// A value that never closes is passed on once it is too long, for the
    /// provider to report, instead of growing for the rest of the stream.
    func testAValueThatNeverClosesIsPassedOnAtTheCap() async throws {
        let cap = SSEEvents<AsyncStream<String>>.Iterator.maxPendingLines
        let read = try await events(["data: {\"choices\":["] + Array(repeating: "data: 1,", count: cap - 1) + ["data: [DONE]"])
        XCTAssertEqual(read.count, 2)
        XCTAssertEqual(read.last?.data, "[DONE]")
    }

    /// A value still open when the lines end is passed on at the end.
    func testAnOpenValueIsPassedOnWhenTheLinesEnd() async throws {
        let read = try await events(["data: {\"a\":", "data: 1,"])
        XCTAssertEqual(read.map(\.data), ["{\"a\":\n1,"])
    }
}
